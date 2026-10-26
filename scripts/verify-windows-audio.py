#!/usr/bin/env python3
"""Compare the production Windows analyzer to the independent NumPy reference.

Only generated PCM is used; no microphone, loopback, or desktop capture.
Requires the existing tests/requirements.txt Python dependencies and .NET 8 SDK.
"""
import argparse
import hashlib
import importlib.util
import json
import subprocess
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotnet", default="dotnet")
    parser.add_argument("--output", default="build/windows-audio-reference.json")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("independent_reference", ROOT / "scripts/verify-audio-reference.py")
    reference = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reference)
    rate = 48000
    t = np.arange(rate, dtype=np.float64) / rate
    rng = np.random.default_rng(20261026)
    sine = .5 * np.sin(2 * np.pi * 440 * t)
    mixture = .3 * np.sin(2 * np.pi * 93.75 * t) + .2 * np.sin(2 * np.pi * 1500 * t) + .1 * np.sin(2 * np.pi * 6000 * t)
    noise = rng.normal(0, .08, (rate, 2))
    pcm = np.concatenate([
        np.column_stack((sine, sine)), np.column_stack((sine, -sine)),
        np.column_stack((mixture, mixture * .25)), noise,
        np.full((rate // 2, 2), .1), np.zeros((rate // 2, 2))
    ]).astype("<f4")
    work = ROOT / "build/windows-reference"
    work.mkdir(parents=True, exist_ok=True)
    source, features = work / "synthetic.f32", work / "features.json"
    pcm.tofile(source)
    subprocess.run([args.dotnet, "run", "--project", str(ROOT / "tests/platforms/windows/CoreTests/Miucs.CoreTests.csproj"),
                    "--", "--audio-reference", str(source), str(features)], cwd=ROOT, check=True)
    actual = json.loads(features.read_text())
    errors, mismatches = {}, []
    expected_count = (len(pcm) - 2048) // 1024 + 1
    if len(actual) != expected_count:
        mismatches.append(f"Frame count: {len(actual)} != {expected_count}")
    tolerances = {"centroidHz": 1e-6, "bandwidthHz": 1e-5}
    for i, frame in enumerate(actual):
        expected = reference.reference(pcm[i * 1024:i * 1024 + 2048].astype(np.float64), rate)
        if abs(frame["time"] - (i * 1024 + 1024) / rate) > 1e-12:
            mismatches.append(f"Frame {i}: wrong window center time")
        for key, value in expected.items():
            measured = frame.get(key)
            if value is None or measured is None:
                if value != measured: mismatches.append(f"Frame {i}: {key} missing-value mismatch")
                continue
            error = abs(measured - value)
            errors[key] = max(errors.get(key, 0), error)
            if not np.isfinite(error) or error > tolerances.get(key, 1e-8):
                mismatches.append(f"Frame {i}: {key} error {error}")
    source_hash = hashlib.sha256()
    for path in sorted((ROOT / "modules/audio/platforms/windows/Core").glob("*.cs")):
        source_hash.update(path.name.encode()); source_hash.update(path.read_bytes())
    report = {
        "status": "passed" if not mismatches else "failed", "frameCount": len(actual),
        "reference": f"NumPy {np.__version__} float64 rfft, existing independent reference.reference()",
        "syntheticSeed": 20261026, "sampleRate": rate, "channelCount": 2,
        "analyzerSHA256": source_hash.hexdigest(), "inputSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "maxAbsoluteErrors": errors, "defaultTolerance": 1e-8, "overrideTolerances": tolerances,
        "mismatches": mismatches[:30], "mismatchCount": len(mismatches),
        "notCovered": ["Windows WASAPI hardware", "real music melody accuracy", "beat accuracy on real music"]
    }
    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Windows NumPy reference: {report['status']}; {len(actual)} frames; {len(mismatches)} mismatches")
    for message in mismatches[:10]: print(message)
    raise SystemExit(bool(mismatches))


if __name__ == "__main__":
    main()
