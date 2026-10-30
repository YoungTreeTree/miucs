"""A virtual host using the production native client, watchdog, worker and renderer."""

import base64
import copy
import hashlib
import json
import math
import time
from pathlib import Path
from preview import Bridge, png
from .scenario import Signals, validate, viewport, appearance


class Lab:
    def __init__(self, folders, case, plugin=None):
        self.catalog = {}
        for folder in folders:
            folder = Path(folder).resolve()
            m = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
            if m["id"] in self.catalog:
                raise ValueError("Duplicate plugin ID: " + m["id"])
            self.catalog[m["id"]] = {"directory": folder, "manifest": m}
        if not self.catalog:
            raise ValueError("No plugins found")
        self.bridge = None
        self.surface = None
        self.trace = []
        self.error = ""
        self.last_frame = {}
        self.metrics = {}
        self.fingerprint = None
        self.reset(case, plugin or next(iter(self.catalog)))

    def setup(self, plugin):
        if plugin not in self.catalog:
            raise ValueError("Plugin not registered: " + plugin)
        m = self.catalog[plugin]["manifest"]
        initial = self.case.get("initial", {})
        self.viewport = {
            "width": m["layout"]["width"],
            "height": m["layout"]["height"],
            "scale": 1,
        }
        self.viewport.update(initial.get("viewport", {}))
        viewport(self.viewport)
        self.appearance = {"ink": "#3d3d3d", "opacity": 1}
        self.appearance.update(initial.get("appearance", {}))
        appearance(self.appearance)

    def candidate(self, plugin, probe_update=False):
        b = Bridge(
            self.catalog[plugin]["directory"], seed=int(self.case.get("seed", 1))
        )
        try:
            b.post("activate", dict(self.viewport, id=plugin))
            b.post("appearanceChanged", self.appearance)
            if probe_update and self.last_frame:
                probe = copy.deepcopy(self.last_frame)
                probe["deltaTime"] = 0
                probe["audio"]["beats"] = []
                probe["audio"]["onsets"] = []
                probe["keyboard"]["events"] = []
                b.post("update", probe)
            b.render(
                plugin, 16, 16
            )  # Decode assets and validate a live reload before replacement.
            if self.signals.hidden or self.signals.suspended:
                b.post("deactivate", {})
            return b
        except BaseException:
            b.close()
            raise

    def replace(self, plugin, probe_update=False):
        fingerprint = self.files(plugin)
        candidate = self.candidate(plugin, probe_update)
        self.release_surface()
        previous = self.bridge
        self.bridge = candidate
        self.plugin = plugin
        if previous:
            previous.close()
        self.fingerprint = fingerprint
        self.error = ""

    def reset(self, case, plugin=None):
        case = validate(case)
        # Validate every switch before starting or mutating a running session.
        for e in case["events"]:
            if e["type"] == "switch" and e["value"] not in self.catalog:
                raise ValueError("Unregistered switch target: " + e["value"])
        plugin = plugin or getattr(self, "initial_plugin", next(iter(self.catalog)))
        if plugin not in self.catalog:
            raise ValueError("Unknown plugin")
        old = {
            k: getattr(self, k, None)
            for k in ["case", "signals", "viewport", "appearance", "initial_plugin"]
        }
        try:
            self.case = case
            self.signals = Signals(case)
            self.initial_plugin = plugin
            self.setup(plugin)
            self.replace(plugin)
        except BaseException:
            for k, v in old.items():
                setattr(self, k, v)
            raise
        self.trace = []
        self.last_frame = {}
        self.metrics = {}
        self.error = ""

    def files(self, plugin=None):
        result = []
        for p in sorted(self.catalog[plugin or self.plugin]["directory"].rglob("*")):
            if p.is_file():
                st = p.stat()
                result.append((str(p), st.st_mtime_ns, st.st_size))
            if len(result) > 4096:
                raise ValueError("File watch limit exceeded")
        return result

    def reload(self):
        try:
            self.replace(self.plugin, probe_update=True)
            return True
        except Exception as e:
            self.error = "Reload rejected; previous instance kept: " + str(e)
            return False

    def watch(self):
        current = self.files()
        if current != self.fingerprint:
            self.fingerprint = current
            if self.state()["done"]:
                return self.reload()
            self.add_event("reload", {})
            try:
                self.step()
                return True
            except RuntimeError:
                return False
        return False

    def release_surface(self):
        if self.surface:
            self.bridge.lib.miucs_surface_destroy(self.surface)
            self.surface = None

    def commands(self, events):
        for e in events:
            op = e["type"]
            value = e.get("value", {})
            if op == "switch":
                previous_view = copy.deepcopy(self.viewport)
                previous_appearance = copy.deepcopy(self.appearance)
                self.setup(value)
                try:
                    self.replace(value)
                except BaseException:
                    self.viewport = previous_view
                    self.appearance = previous_appearance
                    raise
            elif op == "reload":
                if not self.reload():
                    raise RuntimeError(self.error)
            elif op == "resize":
                next_view = dict(self.viewport, **value)
                viewport(next_view)
                self.viewport = next_view
                self.bridge.post("resize", dict(self.viewport, id=self.plugin))
            elif op == "appearance":
                self.appearance.update(value)
                self.bridge.post("appearanceChanged", self.appearance)
            elif op in {"hide", "suspend"}:
                self.bridge.post("deactivate", {})
            elif (
                op in {"show", "resume"}
                and not self.signals.hidden
                and not self.signals.suspended
            ):
                self.bridge.post("activate", dict(self.viewport, id=self.plugin))

    def step(self, count=1):
        if not isinstance(count, int) or not 1 <= count <= 120:
            raise ValueError("Step count must be 1..120")
        for _ in range(count):
            if self.signals.time >= self.case.get("duration", 10) - 1e-9:
                break
            frame, events = self.signals.tick()
            self.last_frame = frame
            started = time.perf_counter()
            try:
                self.commands(events)
                updated = not self.signals.hidden and not self.signals.suspended
                if updated:
                    self.bridge.post("update", frame)
                snapshot = self.bridge.inspect()
                if snapshot["error"]:
                    raise RuntimeError(snapshot["error"])
                digest = hashlib.sha256(
                    json.dumps(
                        snapshot["nodes"], sort_keys=True, separators=(",", ":")
                    ).encode()
                ).hexdigest()
                self.metrics = {
                    k: snapshot[k]
                    for k in [
                        "updateMs",
                        "luaBytes",
                        "sceneBytes",
                        "version",
                        "completed",
                    ]
                }
                self.metrics["updated"] = updated
                if not updated:
                    self.metrics["updateMs"] = 0
                self.metrics["hostRoundTripMs"] = (time.perf_counter() - started) * 1000
                self.trace.append(
                    {
                        "index": self.signals.index,
                        "time": self.signals.time,
                        "plugin": self.plugin,
                        "hash": digest,
                        "input": frame,
                        "commands": events,
                        "metrics": self.metrics.copy(),
                    }
                )
            except Exception as e:
                self.error = str(e)
                raise
        return self.state()

    def seek(self, target):
        if (
            not isinstance(target, (int, float))
            or not math.isfinite(target)
            or not 0 <= target <= self.case.get("duration", 10)
        ):
            raise ValueError("Seek outside scenario duration")
        # Reconstruct from the seed and saved event stream, never infer hidden Lua state.
        self.reset(self.case, self.initial_plugin)
        while self.signals.time < target - 1e-9:
            self.step()
        return self.state()

    def add_event(self, kind, value):
        candidate = copy.deepcopy(self.case)
        candidate["events"].append(
            {
                "at": min(self.signals.time, self.case.get("duration", 10)),
                "type": kind,
                "value": value,
            }
        )
        candidate = validate(candidate)
        if kind == "switch" and value not in self.catalog:
            raise ValueError("Unknown plugin")
        self.case = candidate
        self.signals.case = copy.deepcopy(candidate)

    def pixels(self, size=None):
        import ctypes as c

        w = round(self.viewport["width"] * self.viewport["scale"])
        h = round(self.viewport["height"] * self.viewport["scale"])
        if size is not None:
            w, h = size
        if not (
            isinstance(w, int)
            and isinstance(h, int)
            and 0 < w <= 8192
            and 0 < h <= 8192
            and w * h <= 4 * 1024 * 1024
        ):
            raise ValueError("Invalid render dimensions")
        if not self.surface:
            self.surface = self.bridge.lib.miucs_surface_create(
                self.bridge.handle, None, self.plugin.encode()
            )
        if not self.surface:
            raise RuntimeError("Cannot create preview surface")
        buffer = c.create_string_buffer(w * h * 4)
        started = time.perf_counter()
        if not self.bridge.lib.miucs_surface_pixels(
            self.surface, w, h, buffer, len(buffer)
        ):
            raise RuntimeError(self.bridge.error())
        self.metrics["cpuRenderMs"] = (time.perf_counter() - started) * 1000
        return w, h, buffer.raw

    def state(self, with_pixels=False):
        s = {
            "plugin": self.plugin,
            "time": self.signals.time,
            "index": self.signals.index,
            "duration": self.case.get("duration", 10),
            "fps": self.signals.fps,
            "hidden": self.signals.hidden,
            "suspended": self.signals.suspended,
            "done": self.signals.time >= self.case.get("duration", 10) - 1e-9,
            "viewport": self.viewport,
            "appearance": self.appearance,
            "audio": self.signals.audio,
            "keyboard": self.signals.keyboard,
            "input": self.last_frame,
            "metrics": self.metrics,
            "error": self.error,
            "hash": self.trace[-1]["hash"] if self.trace else None,
        }
        if with_pixels:
            w, h, bgra = self.pixels()
            s["image"] = {
                "width": w,
                "height": h,
                "bgra": base64.b64encode(bgra).decode(),
            }
        return s

    def export(self, directory):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)

        def write(name, value):
            (directory / name).write_text(
                json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
                encoding="utf-8",
            )

        write("scenario.json", self.case)
        snapshot = self.bridge.inspect()
        write("scene.json", snapshot)
        with (directory / "frames.ndjson").open("w", encoding="utf-8") as out:
            for row in self.trace:
                out.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n")
        w, h, pixels = self.pixels()
        png(directory / "preview.png", pixels, w, h)

        def p95(name):
            series = sorted(
                row["metrics"][name] for row in self.trace if row["metrics"]["updated"]
            )
            return (
                series[min(len(series) - 1, int(len(series) * 0.95))] if series else 0
            )

        report = {
            "plugin": self.plugin,
            "initialPlugin": self.initial_plugin,
            "seed": self.case.get("seed", 1),
            "frames": len(self.trace),
            "seconds": self.signals.time,
            "finalSceneHash": self.trace[-1]["hash"] if self.trace else None,
            "scriptP95Ms": p95("updateMs"),
            "hostRoundTripP95Ms": p95("hostRoundTripMs"),
            "cpuRenderMs": self.metrics.get("cpuRenderMs"),
            "luaBytes": snapshot["luaBytes"],
            "sceneBytes": snapshot["sceneBytes"],
            "error": self.error,
            "measurement": "Synthetic input + CPU preview; not GPU completion, physical input latency or dropped-frame certification.",
        }
        write("report.json", report)
        return report

    def close(self):
        self.release_surface()
        if self.bridge:
            self.bridge.close()
            self.bridge = None
