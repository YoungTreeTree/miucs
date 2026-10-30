#!/usr/bin/env python3
"""Check actual GIF pixels, timing and identical input across skin exports."""

import copy
import hashlib
import http.client
import re
import threading
import json
import pathlib
import sys
import tempfile
import unittest
import zipfile

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/plugins"))
from lab.gifs import export_gifs  # noqa: E402
from lab.session import Lab  # noqa: E402
from lab.server import make_server  # noqa: E402


class GifTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="miucs-gifs-")
        self.root = pathlib.Path(self.temp.name)
        self.folders = []
        for identity in ["skin-a", "skin-b"]:
            folder = self.root / identity
            folder.mkdir()
            (folder / "manifest.json").write_text(
                json.dumps(
                    dict(
                        id=identity,
                        name=identity,
                        version="1.0.0",
                        api=1,
                        entry="main.lua",
                        inputs=["audio", "keyboard"],
                        layout=dict(
                            width=100, height=50, minimumWidth=10, maximumWidth=1000
                        ),
                    )
                ),
                encoding="utf-8",
            )
            (folder / "main.lua").write_text(
                """return {
                create=function() miucs.load{type='group',id='%s',width=100,height=50,children={{type='rect',id='dot',x=0,y=0,width=20,height=20,fill='#ff0000',opacity=.5}}} end,
                update=function(f) miucs.set('dot',{x=(f.now-1)*40}) end
            }"""
                % identity,
                encoding="utf-8",
            )
            self.folders.append(folder)
        self.case = dict(
            version=1, name="Shared input", seed=42, fps=60, duration=0.65, events=[]
        )
        self.output = self.root / "gifs"

    def tearDown(self):
        self.temp.cleanup()

    def test_same_input_timing_pixels_and_repeatability(self):
        original = copy.deepcopy(self.case)
        lab = Lab(self.folders, self.case, "skin-a")
        try:
            lab.step(3)
            before = (lab.bridge.handle, lab.signals.time, lab.trace[-1]["hash"])
            result = export_gifs(self.folders, lab.case, self.output, fps=16, width=100)
            self.assertEqual(
                before, (lab.bridge.handle, lab.signals.time, lab.trace[-1]["hash"])
            )
        finally:
            lab.close()
        self.assertEqual(self.case, original)
        digest = hashlib.sha256(
            (self.output / "inputs.ndjson").read_bytes()
        ).hexdigest()
        encoded = []
        for p in result["report"]["plugins"]:
            self.assertNotIn("error", p)
            self.assertEqual(p["inputHash"], digest)
            self.assertEqual(p["inputFrames"], 39)
            with Image.open(self.output / p["file"]) as im:
                self.assertEqual(im.info["loop"], 0)
                self.assertGreater(im.n_frames, 1)
                colors = im.convert("RGB").getpixel((5, 5))
                self.assertLess(abs(colors[0] - 250), 3)
                self.assertLess(abs(colors[1] - 122), 3)
                total = 0
                hashes = []
                for i in range(im.n_frames):
                    im.seek(i)
                    total += im.info["duration"]
                    hashes.append(
                        hashlib.sha256(im.convert("RGB").tobytes()).hexdigest()
                    )
                self.assertEqual(total, 650)
                self.assertGreater(len(set(hashes)), 1)
                encoded.append(hashes)
        self.assertEqual(encoded[0], encoded[1])
        saved = (self.output / "skin-a.gif").read_bytes()
        export_gifs(self.folders, self.case, self.output, fps=16, width=100)
        self.assertEqual(saved, (self.output / "skin-a.gif").read_bytes())
        with zipfile.ZipFile(self.output / "previews.zip") as z:
            self.assertTrue(
                {
                    "index.html",
                    "skin-a.gif",
                    "skin-b.gif",
                    "scenario.json",
                    "inputs.ndjson",
                    "manifest.json",
                }
                <= set(z.namelist())
            )

    def test_switch_filter_hidden_resize_and_stall(self):
        self.case["events"] = [
            {"at": 0, "type": "switch", "value": "skin-b"},
            {"at": 0.1, "type": "hide"},
            {"at": 0.3, "type": "show"},
            {"at": 0.35, "type": "resize", "value": {"width": 100, "height": 100}},
            {"at": 0.4, "type": "stall", "value": 0.1},
        ]
        result = export_gifs(self.folders, self.case, self.output, fps=20, width=100)
        self.assertEqual(len(result["report"]["ignoredSwitchEvents"]), 1)
        for p in result["report"]["plugins"]:
            self.assertNotIn("error", p)
            self.assertEqual(p["id"] + ".gif", p["file"])
            with Image.open(self.output / p["file"]) as im:
                elapsed = 0
                found = False
                for i in range(im.n_frames):
                    im.seek(i)
                    if 0.15 <= elapsed / 1000 <= 0.2:
                        self.assertEqual(
                            im.convert("RGB").getpixel((5, 5)), (246, 244, 239)
                        )
                        found = True
                    elapsed += im.info["duration"]
                self.assertTrue(found)
                self.assertEqual(im.size, (100, 50))

    def test_http_batch_does_not_change_live_session(self):
        lab = Lab(self.folders, self.case, "skin-a")
        lab.step(3)
        before = (lab.bridge.handle, lab.signals.time, lab.trace[-1]["hash"])
        server = make_server(lab, 0, self.root / "exports")
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        conn = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=20)
        try:
            conn.request("GET", "/")
            response = conn.getresponse()
            page = response.read()
            token = re.search(rb"const token='([^']+)'", page)[1].decode()
            headers = {"X-Miucs-Lab": token, "Content-Type": "application/json"}
            conn.request(
                "POST",
                "/api/gifs",
                json.dumps(dict(fps=10, width=64, seconds=0.3)),
                headers,
            )
            response = conn.getresponse()
            result = json.loads(response.read())
            self.assertEqual(response.status, 200, result)
            self.assertIn("skin-a.gif", result["files"])
            self.assertEqual(
                before, (lab.bridge.handle, lab.signals.time, lab.trace[-1]["hash"])
            )
            for route, status in [
                ("/api/gif/skin-a.gif", 200),
                ("/api/gif/../gifs/skin-a.gif", 404),
            ]:
                conn.request("GET", route, headers=headers)
                response = conn.getresponse()
                body = response.read()
                self.assertEqual(response.status, status)
                if status == 200:
                    self.assertTrue(body.startswith(b"GIF89a"))
                    self.assertEqual(response.getheader("Content-Type"), "image/gif")
            conn.request("GET", "/api/gif/skin-a.gif")
            response = conn.getresponse()
            response.read()
            self.assertEqual(response.status, 403)
        finally:
            conn.close()
            server.shutdown()
            thread.join()
            server.server_close()
            lab.close()

    def test_stall_holds_previous_image(self):
        self.case["events"] = [{"at": 0.1, "type": "stall", "value": 0.3}]
        result = export_gifs(
            self.folders[:1], self.case, self.output, fps=20, width=100
        )
        self.assertNotIn("error", result["report"]["plugins"][0])
        with Image.open(self.output / "skin-a.gif") as im:
            elapsed = 0
            samples = {}
            for i in range(im.n_frames):
                im.seek(i)
                end = elapsed + im.info["duration"]
                for target in [300, 500]:
                    if elapsed <= target < end:
                        samples[target] = im.convert("RGB").getpixel((25, 5))
                elapsed = end
            self.assertEqual(samples[300], (246, 244, 239))
            self.assertNotEqual(samples[500], (246, 244, 239))

    def test_partial_failure_and_limits(self):
        export_gifs(self.folders, self.case, self.output, fps=10, width=64)
        self.assertTrue((self.output / "skin-b.gif").exists())
        (self.folders[1] / "main.lua").write_text("invalid lua", encoding="utf-8")
        result = export_gifs(self.folders, self.case, self.output, fps=10, width=64)
        self.assertIn("file", result["report"]["plugins"][0])
        self.assertIn("error", result["report"]["plugins"][1])
        self.assertNotIn("skin-b.gif", result["files"])
        self.assertFalse((self.output / "skin-b.gif").exists())
        for kw in [{"fps": 0}, {"width": float("nan")}, {"seconds": 5}, {"fps": 2.5}]:
            with self.assertRaises(ValueError):
                export_gifs(self.folders, self.case, self.output, **kw)


if __name__ == "__main__":
    unittest.main(verbosity=2)
