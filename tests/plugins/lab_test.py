#!/usr/bin/env python3
"""Virtual signals, deterministic production-worker replay, reload isolation and HTTP access."""

import http.client
import json
import pathlib
import re
import sys
import tempfile
import threading
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/plugins"))
from lab.scenario import Signals, validate, load  # noqa: E402
from lab.session import Lab  # noqa: E402
from lab.server import make_server, PRESETS  # noqa: E402


def case(events=None, **kwargs):
    return dict(
        version=1,
        name="test",
        seed=42,
        fps=60,
        duration=1,
        initial={"keyboard": {"rate": 0}, "audio": {"bpm": 0}},
        events=events or [],
        **kwargs,
    )


def event(kind, value=None, at=0):
    e = {"at": at, "type": kind}
    if value is not None:
        e["value"] = value
    return e


class SignalsTest(unittest.TestCase):
    def test_repeatable_all_presets(self):
        for path in PRESETS.glob("*.json"):
            c = load(path)
            a = Signals(c)
            b = Signals(c)
            while a.time < c["duration"]:
                self.assertEqual(a.tick(), b.tick(), path.stem)

    def test_contract_clocks_reconnect_and_stale_events(self):
        s = Signals(
            case(
                [
                    event("press", {"key": "a", "age": 0.8}),
                    event("beat", 0.9),
                    event("reconnect", "audio", at=0.02),
                ]
            )
        )
        f, _ = s.tick()
        self.assertEqual(f["keyboard"]["events"], [])
        self.assertEqual(f["keyboard"]["droppedEventCount"], 1)
        self.assertGreater(f["audio"]["frame"]["audio"]["time"], f["now"] + 900)
        old_a = f["audio"]["sessionID"]
        old_k = f["keyboard"]["sessionID"]
        s.tick()
        f, _ = s.tick()
        self.assertNotEqual(f["audio"]["sessionID"], old_a)
        self.assertEqual(f["keyboard"]["sessionID"], old_k)

    def test_repeat_modifier_release(self):
        s = Signals(
            case(
                [
                    event("press", {"key": "a"}),
                    event("repeat", {"key": "a"}, 0.02),
                    event("modifiers", 1, 0.04),
                    event("release", {"key": "a"}, 0.06),
                ]
            )
        )
        events = []
        for _ in range(6):
            f, _ = s.tick()
            events += f["keyboard"]["events"]
        self.assertEqual(
            [e["kind"] for e in events],
            ["pressed", "repeated", "modifiersChanged", "released"],
        )
        self.assertGreater(events[1]["heldDuration"], 0)
        self.assertEqual(events[2]["modifiers"], 1)
        self.assertEqual(f["keyboard"]["heldKeys"], [])

    def test_hidden_does_not_replay(self):
        s = Signals(
            case(
                [
                    event("hide"),
                    event("press", {"key": "a"}, 0.02),
                    event("beat", 0.9, 0.02),
                    event("show", at=0.1),
                ]
            )
        )
        for _ in range(8):
            f, _ = s.tick()
            self.assertEqual(f["keyboard"]["events"], [])
            self.assertEqual(f["audio"]["beats"], [])
        self.assertEqual(f["keyboard"]["heldKeys"], [])

    def test_high_typing_rate_releases_all_keys(self):
        c = case()
        c["initial"]["keyboard"]["rate"] = 30
        c["events"] = [event("keyboard", {"rate": 0}, 0.5)]
        s = Signals(c)
        for _ in range(60):
            f, _ = s.tick()
        self.assertEqual(f["keyboard"]["heldKeys"], [])

    def test_backpressure_and_clock_gap(self):
        c = case([event("press", {"key": f"key{i}"}) for i in range(200)])
        f, _ = Signals(c).tick()
        self.assertEqual(len(f["keyboard"]["events"]), 128)
        self.assertEqual(f["keyboard"]["droppedEventCount"], 72)
        f, _ = Signals(case([event("stall", 0.5), event("fps", 10)])).tick()
        self.assertAlmostEqual(f["deltaTime"], 0.6)

    def test_validation(self):
        invalid = [
            {"fps": float("nan")},
            {"seed": 1.2},
            {"initial": {"viewport": {"width": 2048, "height": 2048, "scale": 4}}},
            {"events": [event("unknown")]},
            {"events": [event("press", {"key": "../escape"})]},
            {"initial": {"audio": {"bands": [1]}}},
            {"events": [event("audio", {"state": {}})]},
        ]
        for override in invalid:
            c = case()
            c.update(override)
            with self.assertRaises(ValueError):
                validate(c)


class NativeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="miucs-lab-test-")
        self.folder = pathlib.Path(self.temp.name)
        self.manifest = {
            "id": "lab-test",
            "name": "Test",
            "version": "1.0.0",
            "api": 1,
            "entry": "main.lua",
            "inputs": ["audio", "keyboard"],
            "layout": {
                "width": 100,
                "height": 100,
                "minimumWidth": 10,
                "maximumWidth": 200,
            },
        }
        (self.folder / "manifest.json").write_text(
            json.dumps(self.manifest), encoding="utf-8"
        )
        self.source = self.folder / "main.lua"
        self.good = """local x=0;return {
          create=function() miucs.load{type='group',id='lab-test',width=100,height=100,children={{type='rect',id='dot',width=5,height=5,fill='#ffffff'}}} end,
          update=function(f) x=x+miucs.random();miucs.set('dot',{x=x}) end
        }"""
        self.source.write_text(self.good, encoding="utf-8")
        self.lab = None

    def tearDown(self):
        if self.lab:
            self.lab.close()
        self.temp.cleanup()

    def start(self, c=None):
        self.lab = Lab([self.folder], c or case())
        return self.lab

    def test_seed_replay_seek_and_export(self):
        lab = self.start()
        lab.step(30)
        hashes = [r["hash"] for r in lab.trace]
        lab.seek(0.5)
        self.assertEqual(hashes, [r["hash"] for r in lab.trace])
        c = case()
        c["seed"] = 43
        lab.reset(c)
        lab.step(30)
        self.assertNotEqual(hashes, [r["hash"] for r in lab.trace])
        report = lab.export(self.folder / "results")
        self.assertEqual(report["frames"], 30)
        self.assertTrue(
            (self.folder / "results/preview.png").read_bytes().startswith(b"\x89PNG")
        )
        self.assertEqual(
            len((self.folder / "results/frames.ndjson").read_text().splitlines()), 30
        )
        self.assertGreater(report["luaBytes"], 0)

    def test_failed_reload_keeps_live_instance(self):
        lab = self.start()
        lab.step()
        old = lab.bridge.handle
        for broken in [
            "this is invalid Lua",
            self.good.replace("x=x+miucs.random()", 'error("update failure")'),
            self.good.replace("x=x+miucs.random()", "while true do end"),
        ]:
            self.source.write_text(broken, encoding="utf-8")
            self.assertFalse(lab.reload())
            self.assertEqual(lab.bridge.handle, old)
            lab.step()
        self.source.write_text(self.good, encoding="utf-8")
        self.assertTrue(lab.reload())
        self.assertNotEqual(lab.bridge.handle, old)

    def test_failed_render_reload_and_reset(self):
        lab = self.start()
        lab.step()
        old = lab.bridge.handle
        self.source.write_text(
            "return {create=function() miucs.load{type='image',id='lab-test',source='bad.png',width=100,height=100} end}",
            encoding="utf-8",
        )
        (self.folder / "bad.png").write_text("bad", encoding="utf-8")
        self.assertFalse(lab.reload())
        self.assertEqual(old, lab.bridge.handle)
        lab.step()
        with self.assertRaises(RuntimeError):
            lab.reset(case())
        self.assertEqual(old, lab.bridge.handle)
        lab.step()

    def test_watch_and_bounds(self):
        lab = self.start()
        lab.step()
        self.assertFalse(lab.watch())
        self.source.write_text(self.good + "\n", encoding="utf-8")
        self.assertTrue(lab.watch())
        self.assertEqual(lab.case["events"][-1]["type"], "reload")
        expected = lab.trace[-1]["hash"]
        lab.seek(lab.signals.time)
        self.assertEqual(expected, lab.trace[-1]["hash"])
        with self.assertRaises(ValueError):
            lab.add_event("switch", "missing")
        with self.assertRaises(ValueError):
            lab.step(1000)
        with self.assertRaises(ValueError):
            lab.seek(100)

    def test_worker_failure_is_reported(self):
        self.source.write_text(
            self.good.replace("x=x+miucs.random()", "while true do end"),
            encoding="utf-8",
        )
        lab = self.start()
        with self.assertRaises(RuntimeError):
            lab.step()
        self.assertTrue(lab.error)

    def test_http(self):
        lab = self.start()
        server = make_server(lab, 0, self.folder / "exports")
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        conn = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=10)

        def request(method, path, body=None, headers=None):
            conn.request(method, path, body, headers or {})
            r = conn.getresponse()
            return r.status, r.read()

        try:
            status, page = request("GET", "/")
            self.assertEqual(status, 200)
            token = re.search(rb"const token='([^']+)'", page)[1].decode()
            headers = {"X-Miucs-Lab": token, "Content-Type": "application/json"}
            self.assertEqual(request("GET", "/api/state")[0], 403)
            self.assertEqual(
                request("GET", "/", headers={"Host": "attacker.invalid"})[0], 403
            )
            self.assertEqual(
                request(
                    "GET",
                    "/api/state",
                    headers=dict(headers, Origin="https://attacker.invalid"),
                )[0],
                403,
            )
            self.assertEqual(request("POST", "/api/step", "[]", headers)[0], 400)
            self.assertEqual(
                request("POST", "/api/step", '{"count":1}', headers)[0], 200
            )
            self.assertEqual(
                request("GET", "/api/download/../../main.lua", headers=headers)[0], 404
            )
            self.assertEqual(request("POST", "/api/export", "{}", headers)[0], 200)
            self.assertEqual(
                request("GET", "/api/download/report.json", headers=headers)[0], 200
            )
        finally:
            conn.close()
            server.shutdown()
            thread.join()
            server.server_close()


class BuiltinsTest(unittest.TestCase):
    def test_all_plugins_and_scenarios(self):
        folders = sorted(p.parent for p in (ROOT / "plugins").glob("*/manifest.json"))
        for folder in folders:
            plugin = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))[
                "id"
            ]
            # Compress lifecycle timestamps to exercise every event without a long soak.
            for preset in PRESETS.glob("*.json"):
                c = load(preset)
                c["duration"] = 1.2
                for e in c["events"]:
                    e["at"] /= 10
                lab = Lab(folders, c, plugin)
                try:
                    while not lab.state()["done"]:
                        lab.step(120)
                    self.assertFalse(lab.error, (plugin, preset.name))
                    w, h, pixels = lab.pixels()
                    self.assertTrue(any(pixels), (plugin, preset.name))
                    expected = lab.trace[-1]["hash"]
                    lab.seek(c["duration"])
                    self.assertEqual(
                        expected, lab.trace[-1]["hash"], (plugin, preset.name)
                    )
                finally:
                    lab.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
