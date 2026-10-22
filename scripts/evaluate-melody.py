#!/usr/bin/env python3
"""Evaluate the native melody extractor on local ADC2004 WAV + REF pairs.

The dataset remains in ignored build/, never inside the application bundle.
Source: https://www.ee.columbia.edu/~dpwe/LabROSA/projects/melody/
"""
import argparse
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/validation/melody-adc2004.json")
    args = parser.parse_args()
    executable = ROOT / "build/melody-file-probe"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", "-O", "-framework", "Accelerate",
                    "-framework", "AVFoundation", "Miucs/AudioFeatureAnalyzer.swift", "Miucs/MelodyAnalyzer.swift",
                    "Tests/MelodyFileProbe.swift", "-o", str(executable)], cwd=ROOT, check=True)
    tracks = []
    for wav in sorted(args.dataset.glob("*.wav")):
        output = wav.with_suffix(".json")
        subprocess.run([str(executable), str(wav), str(output)], check=True)
        frames = json.loads(output.read_text())
        reference = np.loadtxt(wav.with_name(wav.stem + "REF.txt"))
        times = np.array([f["time"] for f in frames])
        indices = np.searchsorted(reference[:, 0], times).clip(1, len(reference) - 1)
        indices -= (times - reference[indices - 1, 0] < reference[indices, 0] - times)
        expected = reference[indices, 1]
        actual = np.array([f.get("pitchHz", 0) for f in frames])
        voiced, detected = expected > 0, actual > 0
        cents = np.abs(1200 * np.log2(np.maximum(actual, 1) / np.maximum(expected, 1)))
        chroma_cents = np.abs((cents + 600) % 1200 - 600)
        row = {"track": wav.stem, "frames": len(frames),
               "rawPitchAccuracy": float(np.mean((cents[voiced] < 50) & detected[voiced])),
               "rawChromaAccuracy": float(np.mean((chroma_cents[voiced] < 50) & detected[voiced])),
               "voicingRecall": float(np.mean(detected[voiced])),
               "voicingFalseAlarm": float(np.mean(detected[~voiced])) if (~voiced).any() else 0}
        tracks.append(row)
        print(wav.stem, round(row["rawPitchAccuracy"], 3), flush=True)
    if not tracks:
        raise ValueError("No ADC2004 WAV/REF pairs found")
    report = {"date": datetime.now(timezone.utc).isoformat(), "dataset": "ADC2004, 20 annotated excerpts",
              "source": "https://www.ee.columbia.edu/~dpwe/LabROSA/projects/melody/",
              "analyzerSHA256": hashlib.sha256((ROOT / "Miucs/MelodyAnalyzer.swift").read_bytes()).hexdigest(),
              "method": "nearest reference timestamp; frame-center estimates; 50-cent pitch tolerance; mean over tracks",
              "meanRawPitchAccuracy": float(np.mean([t["rawPitchAccuracy"] for t in tracks])),
              "tracks": tracks,
              "limitations": ["Causal harmonic-salience heuristic; complex accompaniment can win over the melody",
                              "Confidence is not a calibrated probability", "Not an unseen-data or general-song accuracy guarantee"]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("Mean raw pitch accuracy:", report["meanRawPitchAccuracy"])


if __name__ == "__main__":
    main()
