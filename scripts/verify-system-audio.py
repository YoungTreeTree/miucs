#!/usr/bin/env python3
"""Compare captured system-audio features against the generated fixture manifest.

Uses the first clean low-tone onset for alignment, then tests segment interiors.
Other system playback is not silently accepted as measurement error.
"""
import argparse
import hashlib
import importlib.util
import json
import statistics
import warnings
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from scipy.io import wavfile

ROOT = Path(__file__).resolve().parents[1]
REFERENCE_SPEC = importlib.util.spec_from_file_location("audio_reference", ROOT / "scripts/verify-audio-reference.py")
REFERENCE_MODULE = importlib.util.module_from_spec(REFERENCE_SPEC)
REFERENCE_SPEC.loader.exec_module(REFERENCE_MODULE)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture")
    parser.add_argument("manifest")
    parser.add_argument("output")
    args = parser.parse_args()
    capture = json.loads(Path(args.capture).read_text())
    manifest = json.loads(Path(args.manifest).read_text())
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", wavfile.WavFileWarning)
        source_rate, source = wavfile.read(Path(args.manifest).with_suffix(".wav"))
    source = source.astype(np.float64)
    frames = capture["frames"]
    report = {"date": datetime.now(timezone.utc).isoformat(), "captureStatus": capture["status"],
              "captureScope": capture.get("captureScope", "system-mix"), "frameCount": len(frames),
              "analyzerSHA256": hashlib.sha256((ROOT / "modules/audio/core/AudioFeatureAnalyzer.swift").read_bytes()).hexdigest(),
              "segments": [], "status": "failed", "issues": []}
    report["fixtureSHA256"] = hashlib.sha256(Path(args.manifest).with_suffix(".wav").read_bytes()).hexdigest()
    report["validationMethod"] = "First clean low-tone onset alignment; segment interiors; afplay launch is not audio onset"
    low = next(s for s in manifest if s["name"] == "low")
    candidates = [f for f in frames if f.get("lowShare", 0) > 0.98 and f["rms"] > low["expectedRMS"] * 0.6]
    if capture["status"] != "completed":
        report["issues"].append(capture["message"])
    elif not candidates:
        report["issues"].append("No clean low-tone segment found; capture may contain other system audio")
    else:
        offset = candidates[0]["time"] - low["start"]
        report["alignmentOffsetSeconds"] = offset
        estimated = capture.get("playbackStartCaptureTime")
        if estimated is not None:
            # Launching afplay precedes its actual first audio sample. This is a
            # startup measurement, not the analyzer's processing latency.
            report["playbackStartupEstimateSeconds"] = offset - estimated
            if offset < estimated - 0.05 or offset > estimated + 2:
                report["issues"].append("Fixture alignment is outside the allowed playback startup interval")
        for segment in manifest:
            start = segment["start"] + offset
            interior = [f for f in frames if start + 0.20 < f["time"] < start + segment["duration"] - 0.15]
            item = {"name": segment["name"], "frameCount": len(interior), "measurements": {}, "issues": []}
            if len(interior) < 2:
                item["issues"].append("Insufficient interior frames")
            else:
                def measured(key):
                    values = [f[key] for f in interior if key in f]
                    return statistics.median(values) if values else None

                def compare(key, expected, tolerance):
                    value = measured(key)
                    item["measurements"][key] = {"median": value, "expected": expected, "tolerance": tolerance}
                    if value is None or abs(value - expected) > tolerance:
                        item["issues"].append(f"{key}: {value}, expected {expected} ± {tolerance}")

                compare("rms", segment["expectedRMS"], max(1e-5, segment["expectedRMS"] * 0.02))
                if segment.get("frequency") is not None:
                    compare("centroidHz", segment["frequency"], 2.0)
                if segment.get("band"):
                    compare(segment["band"] + "Share", 1.0, 0.02)
                for key, tolerance in [("balance", 0.05), ("sideEnergyRatio", 0.03), ("correlation", 0.05)]:
                    if key in segment:
                        compare(key, segment[key], tolerance)
                if segment["expectedRMS"] == 0 and segment["duration"] >= 1:
                    if not all(f["isSilent"] for f in interior if f["time"] > start + 0.4):
                        item["issues"].append("Sustained digital silence did not enter silent state")
                if segment["name"] == "noise":
                    references = []
                    for index in range(0, len(source) - 2048 + 1, 1024):
                        center = (index + 1024) / source_rate
                        if segment["start"] + 0.20 < center < segment["start"] + segment["duration"] - 0.15:
                            references.append(REFERENCE_MODULE.reference(source[index:index + 2048], source_rate)["flatness"])
                    expected_flatness = statistics.median(references)
                    # Band-limited noise is not expected to have full-band flatness near 1.
                    compare("flatness", expected_flatness, max(1e-4, expected_flatness * 0.15))
            item["passed"] = not item["issues"]
            report["segments"].append(item)
        if not report["issues"] and all(s["passed"] for s in report["segments"]):
            report["status"] = "passed"
    report["passedSegments"] = sum(s["passed"] for s in report["segments"])
    report["totalSegments"] = len(manifest)
    destination = Path(args.output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(f"System capture: {report['status']}; {report['passedSegments']}/{len(manifest)} segments passed")
    for issue in report["issues"]:
        print(issue)
    for item in report["segments"]:
        for issue in item["issues"]:
            print(item["name"], issue)
    raise SystemExit(report["status"] != "passed")


if __name__ == "__main__":
    main()
