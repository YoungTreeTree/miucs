#!/usr/bin/env python3
"""Offline regressions for dependency downloads interrupted on CI runners."""
import hashlib
import importlib.util
import io
import pathlib
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('plugin_deps', ROOT/'scripts/prepare-plugin-deps.py')
deps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deps)
PAYLOAD = b'verified dependency bytes'
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()
URL = 'https://example.invalid/dependency'


class Response(io.BytesIO):
    def __init__(self, data=PAYLOAD, length=None):
        super().__init__(data)
        self.headers = {'Content-Length': str(len(data) if length is None else length)}


class ResetAfterPartialRead(Response):
    def read(self, size=-1):
        if self.tell():
            raise ConnectionResetError('connection reset during transfer')
        return super().read(3)


class DependencyDownloadTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = pathlib.Path(directory.name)
        self.file = self.root/'dependency.tar.gz'
        target = patch.object(deps, 'DEST', self.root)
        target.start()
        self.addCleanup(target.stop)
        sleeper = patch.object(deps.time, 'sleep', side_effect=self.assert_no_partial)
        self.sleep = sleeper.start()
        self.addCleanup(sleeper.stop)

    def assert_no_partial(self, *_):
        self.assertEqual(list(self.root.glob('*.download')), [])

    def fetch(self):
        deps.fetch(self.file.name, URL, DIGEST)

    def test_connection_reset_and_partial_transfer_retry_without_publishing(self):
        responses = [urllib.error.URLError(ConnectionResetError('TLS connection reset')),
                     ResetAfterPartialRead(), Response()]
        with patch.object(deps.urllib.request, 'urlopen', side_effect=responses) as request:
            self.fetch()
        self.assertEqual(self.file.read_bytes(), PAYLOAD)
        self.assertEqual(request.call_count, 3)
        self.assertTrue(all(call.kwargs == {'timeout': 30} for call in request.call_args_list))
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [1, 2])
        self.assert_no_partial()

    def test_short_response_and_retryable_http_error_recover(self):
        for failure in (Response(b'partial', length=100), urllib.error.HTTPError(URL, 503, 'unavailable', {}, None)):
            with self.subTest(failure=failure), patch.object(deps.urllib.request, 'urlopen', side_effect=[failure, Response()]):
                deps.download(self.file, URL, DIGEST)
            self.assertEqual(self.file.read_bytes(), PAYLOAD)
            self.assert_no_partial()

    def test_retries_are_bounded_and_no_incomplete_file_is_cached(self):
        with patch.object(deps.urllib.request, 'urlopen', side_effect=TimeoutError('timed out')) as request:
            with self.assertRaisesRegex(RuntimeError, 'after 4 attempts'):
                self.fetch()
        self.assertEqual(request.call_count, 4)
        self.assertEqual(self.sleep.call_count, 3)
        self.assertFalse(self.file.exists())
        self.assert_no_partial()

    def test_checksum_mismatch_preserves_existing_file_without_retry(self):
        self.file.write_bytes(b'existing cache')
        with patch.object(deps.urllib.request, 'urlopen', return_value=Response(b'corrupt')) as request:
            with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
                self.fetch()
        request.assert_called_once()
        self.sleep.assert_not_called()
        self.assertEqual(self.file.read_bytes(), b'existing cache')
        self.assert_no_partial()

    def test_missing_file_fails_without_retry(self):
        with patch.object(deps.urllib.request, 'urlopen', side_effect=urllib.error.HTTPError(URL, 404, 'missing', {}, None)) as request:
            with self.assertRaises(urllib.error.HTTPError):
                self.fetch()
        request.assert_called_once()
        self.sleep.assert_not_called()
        self.assert_no_partial()

    def test_verified_cache_skips_network(self):
        self.file.write_bytes(PAYLOAD)
        with patch.object(deps.urllib.request, 'urlopen') as request:
            self.fetch()
        request.assert_not_called()
        self.assertEqual(self.file.read_bytes(), PAYLOAD)


if __name__ == '__main__':
    unittest.main()
