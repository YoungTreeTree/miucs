#!/usr/bin/env python3
"""Independent float64 NumPy FFT reference for the shared Swift analyzer.

Requires numpy and scipy. Compares every full window, including segment edges.
It does not use the Swift FFT output as an input to the reference calculation.
"""
import argparse
import hashlib
import json
import warnings
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import scipy
from scipy.io import wavfile

ROOT = Path(__file__).resolve().parents[1]
WINDOW, HOP = 2048, 1024


def reference(samples, rate):
    rms = float(np.sqrt(np.mean(samples ** 2)))
    peak = float(np.max(np.abs(samples)))
    result = {"rms": rms, "rmsDBFS": 20 * np.log10(max(rms, 1e-12)), "peak": peak,
              "crestDB": 20 * np.log10(max(peak, 1e-12) / rms) if rms > 1e-12 else None}
    window = np.hanning(WINDOW + 1)[:-1]
    centered = samples - np.mean(samples, axis=0)
    fft = np.fft.rfft(centered * window[:, None], axis=0)
    power = np.mean(np.abs(fft) ** 2, axis=1) / (WINDOW * np.sum(window ** 2))
    power[1:-1] *= 2
    frequencies = np.fft.rfftfreq(WINDOW, 1 / rate)
    audible = (frequencies >= 20) & (frequencies <= 20000)
    power, frequencies = power[audible], frequencies[audible]
    energy = {"low": np.sum(power[frequencies < 250]),
              "mid": np.sum(power[(frequencies >= 250) & (frequencies < 4000)]),
              "high": np.sum(power[frequencies >= 4000])}
    total = sum(energy.values())
    valid = total > 1e-12 and rms > 1e-5
    for name, value in energy.items():
        result[name + "Energy"] = float(value)
        result[name + "Share"] = float(value / total) if valid else None
    result.update(centroidHz=None, bandwidthHz=None, flatness=None,
                  balance=None, sideEnergyRatio=None, correlation=None)
    if valid:
        floor = max(np.max(power) * 1e-12, 1e-24)
        # Documented numerical floor for magnitude moments only, not band energy.
        magnitude = np.where(power >= floor, np.sqrt(power), 0)
        centroid = np.sum(magnitude * frequencies) / np.sum(magnitude)
        result["centroidHz"] = float(centroid)
        result["bandwidthHz"] = float(np.sqrt(np.sum(magnitude * (frequencies - centroid) ** 2) / np.sum(magnitude)))
        result["flatness"] = float(min(np.exp(np.mean(np.log(np.maximum(power, floor)))) / np.mean(power), 1))
    if samples.shape[1] == 2 and rms * rms > 1e-12:
        channel_power = np.mean(samples ** 2, axis=0)
        result["balance"] = float((channel_power[1] - channel_power[0]) / channel_power.sum())
        mid, side = np.mean(samples, axis=1), (samples[:, 0] - samples[:, 1]) / 2
        result["sideEnergyRatio"] = float(np.sum(side ** 2) / (np.sum(mid ** 2) + np.sum(side ** 2)))
        if np.all(np.mean(centered ** 2, axis=0) > 1e-12):
            result["correlation"] = float(np.corrcoef(samples.T)[0, 1])
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("wav")
    parser.add_argument("features")
    parser.add_argument("output")
    args = parser.parse_args()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", wavfile.WavFileWarning)
        rate, samples = wavfile.read(args.wav)
    if samples.dtype.kind != "f":
        raise ValueError("Reference fixture must contain float PCM")
    samples = samples.astype(np.float64)
    if samples.ndim == 1:
        samples = samples[:, None]
    actual = json.loads(Path(args.features).read_text())
    tolerances = {"rms": 1e-7, "rmsDBFS": 1e-5, "peak": 1e-7, "crestDB": 1e-5,
                  "lowEnergy": 1e-7, "midEnergy": 1e-7, "highEnergy": 1e-7,
                  "lowShare": 1e-5, "midShare": 1e-5, "highShare": 1e-5,
                  "centroidHz": 0.1, "bandwidthHz": 0.1, "flatness": 1e-5,
                  "balance": 1e-6, "sideEnergyRatio": 1e-6, "correlation": 1e-6}
    errors = {key: [] for key in tolerances}
    mismatches = []
    expected_count = max(0, (len(samples) - WINDOW) // HOP + 1)
    if len(actual) != expected_count:
        mismatches.append(f"Frame count {len(actual)} != {expected_count}")
    for index, frame in enumerate(actual):
        start = index * HOP
        expected = reference(samples[start:start + WINDOW], rate)
        if abs(frame["time"] - (start + WINDOW / 2) / rate) > 1e-10:
            mismatches.append(f"frame {index}: timestamp mismatch")
        for key, value in expected.items():
            measured = frame.get(key)
            if value is None or measured is None:
                if value != measured:
                    mismatches.append(f"frame {index}: {key} availability mismatch")
                continue
            error = abs(measured - value)
            errors[key].append(error)
            if not np.isfinite(error) or error > tolerances[key]:
                mismatches.append(f"frame {index}: {key} error {error} > {tolerances[key]}")
    report = {
        "date": datetime.now(timezone.utc).isoformat(),
        "reference": f"NumPy {np.__version__} float64 rfft; SciPy {scipy.__version__} WAV decoder",
        "input": Path(args.wav).name,
        "inputSHA256": hashlib.sha256(Path(args.wav).read_bytes()).hexdigest(),
        "analyzerSHA256": hashlib.sha256((ROOT / "Miucs/AudioFeatureAnalyzer.swift").read_bytes()).hexdigest(),
        "frameCount": len(actual), "expectedFrameCount": expected_count,
        "status": "passed" if not mismatches else "failed",
        "comparisons": {key: {"maxAbsoluteError": max(values, default=0),
                               "tolerance": tolerances[key], "comparedFrames": len(values)}
                        for key, values in errors.items()},
        "mismatches": mismatches[:30], "mismatchCount": len(mismatches),
        "notCovered": ["onset quality on natural audio", "tempo", "pitch", "semantic classification"]
    }
    destination = Path(args.output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(f"Independent reference: {report['status']}, {len(actual)} frames, {len(mismatches)} mismatches")
    for message in mismatches[:10]:
        print(message)
    raise SystemExit(bool(mismatches))


if __name__ == "__main__":
    main()
