"""Deterministic feature-level signals. No capture, wall clocks or global RNG."""

import copy
import json
import math
import re
from pathlib import Path

AUDIO_STATES = {
    "stopped",
    "connecting",
    "running",
    "recovering",
    "suspended",
    "permissionRequired",
    "userStopped",
}
KEY_STATES = {
    "stopped",
    "connecting",
    "running",
    "permissionRequired",
    "suspended",
    "secureInput",
    "recovering",
}
AUDIO_DEFAULT = {
    "state": "running",
    "rms": 0.08,
    "peak": 0.2,
    "envelope": 0.1,
    "silent": False,
    "pitchHz": 440.0,
    "pitchSweep": 5.0,
    "confidence": 0.9,
    "melodic": True,
    "bpm": 120.0,
    "beatConfidence": 0.9,
    "beatStrength": 0.8,
    "onsetStrength": 0.7,
    "lowEnergy": 0.003,
    "midEnergy": 0.004,
    "highEnergy": 0.001,
    "flux": 0.01,
    "onsetThreshold": 0.2,
    "centroidHz": 1500.0,
    "bandwidthHz": 2200.0,
    "flatness": 0.2,
    "sampleRate": 48000,
    "channelCount": 2,
    "age": 0.0,
    "drop": 0,
    "bands": [0.2] * 24,
}
KEY_DEFAULT = {
    "state": "running",
    "rate": 4.0,
    "keys": ["a", "f", "j", "space", "returnKey"],
    "modifiers": 0,
    "age": 0.0,
    "drop": 0,
}
EVENT_TYPES = {
    "audio",
    "keyboard",
    "press",
    "release",
    "repeat",
    "modifiers",
    "beat",
    "onset",
    "reconnect",
    "hide",
    "show",
    "suspend",
    "resume",
    "resize",
    "appearance",
    "switch",
    "reload",
    "fps",
    "stall",
}
NUMERIC = {
    "rms": (0, 1),
    "peak": (0, 1),
    "envelope": (0, 1),
    "pitchHz": (20, 20000),
    "pitchSweep": (0, 24),
    "confidence": (0, 1),
    "bpm": (0, 300),
    "beatConfidence": (0, 1),
    "beatStrength": (0, 1),
    "onsetStrength": (0, 1),
    "lowEnergy": (0, 1),
    "midEnergy": (0, 1),
    "highEnergy": (0, 1),
    "flux": (0, 10),
    "onsetThreshold": (0, 10),
    "centroidHz": (0, 24000),
    "bandwidthHz": (0, 24000),
    "flatness": (0, 1),
    "sampleRate": (8000, 192000),
    "channelCount": (1, 8),
    "age": (0, 10),
    "drop": (0, 10000),
    "rate": (0, 30),
    "modifiers": (0, 255),
}


def number(value, lo, hi):
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or not lo <= value <= hi
    ):
        raise ValueError(f"Expected a finite number in [{lo}, {hi}]")
    return value


def key(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", value):
        raise ValueError("Invalid physical key or plugin ID")


def controls(kind, value):
    defaults = AUDIO_DEFAULT if kind == "audio" else KEY_DEFAULT
    if not isinstance(value, dict) or set(value) - set(defaults):
        raise ValueError(f"Unknown {kind} controls")
    for name, v in value.items():
        if name == "state":
            if not isinstance(v, str) or v not in (
                AUDIO_STATES if kind == "audio" else KEY_STATES
            ):
                raise ValueError("Unknown input state")
        elif name in {"silent", "melodic"}:
            if not isinstance(v, bool):
                raise ValueError("Expected boolean")
        elif name == "keys":
            if not isinstance(v, list) or not 1 <= len(v) <= 32:
                raise ValueError("Expected 1..32 physical keys")
            for k in v:
                key(k)
        elif name == "bands":
            if not isinstance(v, list) or len(v) != 24:
                raise ValueError("Expected 24 display bands")
            for x in v:
                number(x, 0, 1)
        else:
            number(v, *NUMERIC[name])
            if (
                name in {"drop", "modifiers", "sampleRate", "channelCount"}
                and int(v) != v
            ):
                raise ValueError("Expected integer")


def viewport(value):
    if not isinstance(value, dict) or set(value) - {"width", "height", "scale"}:
        raise ValueError("Invalid viewport")
    for k, v in value.items():
        number(v, 0.25 if k == "scale" else 16, 4 if k == "scale" else 2048)
    if (
        value.get("width", 800) * value.get("height", 460) * value.get("scale", 1) ** 2
        > 4 * 1024 * 1024
    ):
        raise ValueError("Preview target exceeds 4 megapixels")


def appearance(value):
    if not isinstance(value, dict) or set(value) - {"ink", "opacity"}:
        raise ValueError("Invalid appearance")
    if "ink" in value and (
        not isinstance(value["ink"], str)
        or not re.fullmatch("#[a-fA-F0-9]{6}", value["ink"])
    ):
        raise ValueError("Ink must be #RRGGBB")
    if "opacity" in value:
        number(value["opacity"], 0, 1)


def event(e, duration):
    if not isinstance(e, dict) or set(e) - {"at", "type", "value"}:
        raise ValueError("Invalid timeline event")
    number(e.get("at"), 0, duration)
    kind = e.get("type")
    v = e.get("value", {})
    if not isinstance(kind, str) or kind not in EVENT_TYPES:
        raise ValueError("Unknown event type")
    if kind in {"audio", "keyboard"}:
        controls(kind, v)
    elif kind in {"press", "release", "repeat"}:
        if not isinstance(v, dict) or set(v) - {"key", "age"}:
            raise ValueError("Invalid key event")
        key(v.get("key"))
        number(v.get("age", 0), 0, 10)
    elif kind == "modifiers":
        number(v, 0, 255)
    elif kind in {"beat", "onset"}:
        number(v, 0, 1)
    elif kind == "reconnect":
        if not isinstance(v, str) or v not in {"audio", "keyboard"}:
            raise ValueError("Reconnect source must be audio or keyboard")
    elif kind == "resize":
        viewport(v)
    elif kind == "appearance":
        appearance(v)
    elif kind == "switch":
        key(v)
    elif kind == "fps":
        number(v, 1, 120)
    elif kind == "stall":
        number(v, 0, 5)
    elif v != {}:
        raise ValueError("This lifecycle event takes no value")


def validate(case):
    if not isinstance(case, dict) or set(case) - {
        "version",
        "name",
        "seed",
        "fps",
        "duration",
        "initial",
        "events",
    }:
        raise ValueError("Invalid scenario fields")
    if case.get("version") != 1:
        raise ValueError("Unsupported scenario version")
    if not isinstance(case.get("name"), str) or len(case["name"]) > 160:
        raise ValueError("Invalid scenario name")
    number(case.get("seed", 1), 0, 2**53 - 1)
    if int(case.get("seed", 1)) != case.get("seed", 1):
        raise ValueError("Seed must be an integer")
    number(case.get("fps", 60), 1, 120)
    number(case.get("duration", 10), 0.1, 60)
    initial = case.get("initial", {})
    if not isinstance(initial, dict) or set(initial) - {
        "audio",
        "keyboard",
        "viewport",
        "appearance",
    }:
        raise ValueError("Invalid initial controls")
    for name, v in initial.items():
        if name in {"audio", "keyboard"}:
            controls(name, v)
        elif name == "viewport":
            viewport(v)
        else:
            appearance(v)
    events = case.get("events", [])
    if not isinstance(events, list) or len(events) > 2048:
        raise ValueError("At most 2048 events")
    for e in events:
        event(e, case.get("duration", 10))
    result = copy.deepcopy(case)
    result["events"] = sorted(events, key=lambda e: e["at"])
    return result


def load(path):
    path = Path(path)
    if path.stat().st_size > 1024 * 1024:
        raise ValueError("Scenario exceeds 1 MiB")
    return validate(json.loads(path.read_text(encoding="utf-8")))


class Signals:
    def __init__(self, case):
        self.case = validate(case)
        self.time = 0.0
        self.index = 0
        self.cursor = 0
        self.fps = case.get("fps", 60)
        initial = case.get("initial", {})
        self.audio = copy.deepcopy(AUDIO_DEFAULT)
        self.audio.update(initial.get("audio", {}))
        self.keyboard = copy.deepcopy(KEY_DEFAULT)
        self.keyboard.update(initial.get("keyboard", {}))
        self.generation = {"audio": 1, "keyboard": 1}
        self.sequence = {"audio": 0, "keyboard": 0}
        self.beat_sequence = 0
        self.onset_sequence = 0
        self.held = {}
        self.auto = {}
        self.presses = []
        self.last_press = 0.0
        self.silence_start = None
        self.hidden = False
        self.suspended = False
        self.next_press = 0.0
        self.next_beat = 0.0
        self.keys = []
        self.beats = []
        self.onsets = []
        self.dropped = {"keyboard": 0, "beat": 0, "onset": 0}

    def fresh(self, source):
        self.generation[source] += 1
        self.sequence[source] = 0
        if source == "keyboard":
            self.held = {}
            self.auto = {}
            self.keys = []
            self.presses = []
            self.last_press = self.time
            self.next_press = self.time
        else:
            self.beats = []
            self.onsets = []
            self.beat_sequence = 0
            self.onset_sequence = 0
            self.next_beat = self.time

    def emit_key(self, kind, k, age=0):
        if self.keyboard["state"] != "running":
            return
        received = 1 + self.time - age
        self.sequence["keyboard"] += 1
        duration = max(0, self.time - self.held.get(k, self.time))
        if kind == "pressed":
            if k in self.held:
                kind = "repeated"
            else:
                self.held[k] = self.time
                self.presses.append(self.time)
                self.last_press = self.time
        if kind == "released":
            self.held.pop(k, None)
        self.keys.append(
            {
                "sequence": self.sequence["keyboard"],
                "receivedAt": received,
                "kind": kind,
                "key": k,
                "modifiers": int(self.keyboard["modifiers"]),
                "heldDuration": duration,
            }
        )

    def emit_audio(self, kind, strength):
        if self.audio["state"] != "running" or self.audio["silent"]:
            return
        attr = "beat_sequence" if kind == "beat" else "onset_sequence"
        seq = getattr(self, attr) + 1
        setattr(self, attr, seq)
        e = {
            "sequence": seq,
            "receivedAt": 1 + self.time - self.audio["age"],
            "time": 1000 + self.time,
            "strength": strength,
        }
        if kind == "beat":
            e.update(bpm=self.audio["bpm"], confidence=self.audio["beatConfidence"])
            self.beats.append(e)
        else:
            self.onsets.append(e)

    def tick(self):
        commands = []
        self.keys = []
        self.beats = []
        self.onsets = []
        self.dropped = {"keyboard": 0, "beat": 0, "onset": 0}
        stall = 0
        while (
            self.cursor < len(self.case["events"])
            and self.case["events"][self.cursor]["at"] <= self.time + 1e-9
        ):
            e = self.case["events"][self.cursor]
            self.cursor += 1
            kind = e["type"]
            v = e.get("value", {})
            if kind in {"audio", "keyboard"}:
                target = getattr(self, kind)
                old = target["state"]
                target.update(v)
                if target["state"] != old:
                    self.fresh(kind)
            elif kind in {"press", "release", "repeat"}:
                self.emit_key(
                    {"press": "pressed", "release": "released", "repeat": "repeated"}[
                        kind
                    ],
                    v["key"],
                    v.get("age", 0),
                )
            elif kind == "modifiers":
                self.keyboard["modifiers"] = int(v)
                self.emit_key("modifiersChanged", "leftShift")
            elif kind in {"beat", "onset"}:
                self.emit_audio(kind, v)
            elif kind == "reconnect":
                self.fresh(v)
            elif kind == "fps":
                self.fps = v
            elif kind == "stall":
                stall += v
            else:
                if kind == "hide":
                    self.hidden = True
                if kind == "show":
                    self.hidden = False
                    self.fresh("audio")
                    self.fresh("keyboard")
                if kind == "suspend":
                    self.suspended = True
                if kind == "resume":
                    self.suspended = False
                    self.fresh("audio")
                    self.fresh("keyboard")
                commands.append(e)
        dt = 1 / self.fps + stall
        self.time += dt
        self.index += 1
        now = 1 + self.time
        for automatic_key, pressed_at in list(self.auto.items()):
            if self.time - pressed_at >= 0.08:
                self.emit_key("released", automatic_key)
                del self.auto[automatic_key]
        if not self.hidden and not self.suspended:
            rate = self.keyboard["rate"]
            if rate > 0 and self.time >= self.next_press:
                key_index = int(self.time * rate) % len(self.keyboard["keys"])
                automatic_key = self.keyboard["keys"][key_index]
                self.emit_key("pressed", automatic_key, self.keyboard["age"])
                self.auto[automatic_key] = self.time
                self.next_press = self.time + 1 / rate
            bpm = self.audio["bpm"]
            if bpm > 0 and self.time >= self.next_beat:
                self.emit_audio("beat", self.audio["beatStrength"])
                self.emit_audio("onset", self.audio["onsetStrength"])
                self.next_beat = self.time + 60 / bpm

        def current(events, cap, drop):
            keep = [e for e in events if 0 <= now - e["receivedAt"] <= 0.25]
            lost = len(events) - len(keep) + max(0, len(keep) - cap) + int(drop)
            return keep[-cap:], lost

        keys, klost = current(self.keys, 128, self.keyboard["drop"])
        beats, blost = current(self.beats, 64, self.audio["drop"])
        onsets, olost = current(self.onsets, 64, self.audio["drop"])
        if self.hidden or self.suspended:
            keys = []
            beats = []
            onsets = []
            self.presses = []
            self.held = {}
            self.auto = {}
        self.presses = [t for t in self.presses if self.time - t <= 1]
        a = self.audio
        k = self.keyboard
        self.sequence["audio"] += 1

        def session(source):
            return f"virtual-{source}-{self.generation[source]}"

        if a["silent"]:
            if self.silence_start is None:
                self.silence_start = self.time
        else:
            self.silence_start = None
        rms = 0 if a["silent"] else a["rms"]
        pitch = a["pitchHz"] * 2 ** (math.sin(self.time) * a["pitchSweep"] / 12)
        features = {
            "time": 1000 + self.time,
            "sampleRate": int(a["sampleRate"]),
            "channelCount": int(a["channelCount"]),
            "rms": rms,
            "rmsDBFS": 20 * math.log10(max(rms, 1e-6)),
            "peak": 0 if a["silent"] else a["peak"],
            "envelope": 0 if a["silent"] else a["envelope"],
            "isSilent": a["silent"],
            "silenceDuration": 0
            if self.silence_start is None
            else self.time - self.silence_start,
            "lowEnergy": a["lowEnergy"],
            "midEnergy": a["midEnergy"],
            "highEnergy": a["highEnergy"],
            "spectralFlux": max(a["flux"], a["onsetStrength"] if onsets else 0),
            "onsetThreshold": a["onsetThreshold"],
            "isOnset": bool(onsets),
            "centroidHz": a["centroidHz"],
            "bandwidthHz": a["bandwidthHz"],
            "flatness": a["flatness"],
            "displayBands": a["bands"],
        }
        audio = {
            "version": 1,
            "sessionID": session("audio"),
            "state": a["state"],
            "frame": None,
            "frameAge": None,
            "onsets": onsets,
            "beats": beats,
            "spectralFluxPeak": features["spectralFlux"],
            "droppedOnsetCount": olost,
            "droppedBeatCount": blost,
        }
        if a["state"] == "running":
            audio["frameAge"] = a["age"]
            audio["frame"] = {
                "version": 1,
                "sessionID": session("audio"),
                "sequence": self.sequence["audio"],
                "receivedAt": now - a["age"],
                "audio": features,
                "melody": {
                    "time": 1000 + self.time,
                    "pitchHz": pitch if a["melodic"] else None,
                    "isMelodic": a["melodic"],
                    "confidence": a["confidence"],
                },
            }
        keyboard = {
            "version": 1,
            "sessionID": session("keyboard"),
            "sequence": self.sequence["keyboard"],
            "sampledAt": now,
            "state": k["state"],
            "modifiers": int(k["modifiers"]),
            "pressesPerSecond": len(self.presses),
            "idleDuration": max(0, self.time - self.last_press),
            "droppedEventCount": klost,
            "heldKeys": [
                {"key": key, "duration": max(0, self.time - start)}
                for key, start in sorted(self.held.items())
            ],
            "events": keys,
        }
        return {
            "now": now,
            "deltaTime": dt,
            "audio": audio,
            "keyboard": keyboard,
        }, commands
