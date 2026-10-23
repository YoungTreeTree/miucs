#!/usr/bin/env python3
"""Evaluate causal Rapidly vocals against the same mixed Tong Hua PCM and labels.

The SDK's demo watermark remains intact. No reference stem is given to Rapidly.
The finite file tail is flushed for pitch scoring; performance uses live input only.
"""
import importlib.util
import json
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pop_benchmark", ROOT / "scripts/benchmark-pop-melody.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def main():
    subprocess.run(["zsh", "scripts/setup-rapidly.sh"], cwd=ROOT, check=True)
    work = ROOT / "build/rapidly-benchmark"
    work.mkdir(parents=True, exist_ok=True)
    sdk = ROOT / "build/rapidly"
    framework = sdk / "RapidlyEngine.xcframework/macos-arm64_x86_64"
    model = sdk / "music-stem-separation-96ms.v1.1.rapidly"
    raw_probe = work / "raw-probe"
    probe = work / "rapidly-probe"
    sources = {"analyzerSHA256": ROOT / "modules/audio/core/MelodyAnalyzer.swift",
               "adapterSHA256": ROOT / "modules/audio/platforms/macos/RapidlyVocalProcessor.swift",
               "probeSHA256": ROOT / "tools/macos/RapidlyFileProbe.swift",
               "frameworkSHA256": framework / "RapidlyEngineC.framework/RapidlyEngineC"}
    hashes = {name: bench.sha256(path) for name, path in sources.items()}
    bench.compile_probe(ROOT / "modules/audio/core/MelodyAnalyzer.swift", raw_probe)
    subprocess.run([
        "swiftc", "-swift-version", "6", "-parse-as-library", "-O",
        "-framework", "Accelerate", "-framework", "AVFoundation",
        "-F", str(framework), "-framework", "RapidlyEngineC",
        "-Xlinker", "-rpath", "-Xlinker", str(framework),
        *map(str, sorted((ROOT / "modules/audio/core").glob("*.swift"))),
        str(ROOT / "modules/audio/platforms/macos/AccelerateSpectrumTransform.swift"),
        str(ROOT / "modules/audio/platforms/macos/RapidlyVocalProcessor.swift"),
        str(ROOT / "tools/macos/RapidlyFileProbe.swift"), "-o", str(probe),
    ], check=True, cwd=ROOT)
    manifest = json.loads(bench.MANIFEST.read_text())
    fixture = ROOT / "build/pop-benchmark"
    bench.prepare(fixture, manifest, False)
    tracks = []
    for track in manifest["tracks"]:
        name = track["id"]
        audio = fixture / "mix48k" / f"{name}.wav"
        raw_times, raw_midi, _ = bench.run_probe(raw_probe, audio, work / "raw")
        frames_file, stats_file = work / f"{name}.json", work / f"{name}.stats.json"
        subprocess.run([str(probe), str(model), str(audio), str(frames_file), str(stats_file)], check=True, timeout=60)
        frames, stats = json.loads(frames_file.read_text()), json.loads(stats_file.read_text())
        times = np.array([f["time"] for f in frames])
        hz = np.array([f.get("pitchHz", 0) for f in frames])
        midi = np.where(hz > 0, 69 + 12 * np.log2(np.maximum(hz, 1) / 440), 0)
        reference = np.loadtxt(fixture / "mir1k/PitchLabel" / f"{name}.pv")
        ref_times = manifest["pitchTimeOriginSeconds"] + np.arange(len(reference)) * manifest["pitchHopSeconds"]
        raw_ref, raw_valid = bench.nearest_reference(raw_times, ref_times, reference)
        vocal_ref, vocal_valid = bench.nearest_reference(times, ref_times, reference)
        result = {"id": name, "originalSplit": track["split"], "inputSHA256": bench.sha256(audio),
                  "baseline": bench.metrics(raw_midi[raw_valid], raw_ref[raw_valid]),
                  "current": bench.metrics(midi[vocal_valid], vocal_ref[vocal_valid]), "runtime": stats,
                  "scoreBaseline": bench.score_comparison(name, raw_times, raw_midi, ref_times, reference, manifest["scoreCheck"]),
                  "scoreRapidly": bench.score_comparison(name, times, midi, ref_times, reference, manifest["scoreCheck"])}
        tracks.append(result)
        print(f"{name}: {result['baseline']['rawPitchAccuracy']:.1%} -> {result['current']['rawPitchAccuracy']:.1%}", flush=True)
    report = {
        "createdAt": datetime.now(timezone.utc).isoformat(), "machine": platform.platform(),
        "sdkRevision": "a75155656556b38709fe77a706958dcbe1f13624", "sdkVersion": "1.1.0",
        "model": model.name, "modelSHA256": bench.sha256(model),
        **hashes,
        "mode": tracks[0]["runtime"]["mode"],
        "method": "Same mixed 48k mono PCM, 512-sample causal feeds. Human pitch labels and fixed score intervals. No pitch/time fitting; original SDK output timeline verified separately with recombined busses. Includes intact demo watermark when no offline key is supplied.",
        "limits": "Previously used evaluation corpus, not new held-out data. Finite tail flushed only for scoring. Does not measure capture-to-screen latency or licensed model quality.",
        "all": bench.summary(tracks),
        "development": bench.summary([t for t in tracks if t["originalSplit"] == "development"]),
        "previouslyHeldOut": bench.summary([t for t in tracks if t["originalSplit"] == "held_out"]),
        "performance": {
            "audioSeconds": sum(t["runtime"]["audioSeconds"] for t in tracks),
            "processingSeconds": sum(t["runtime"]["totalProcessingMilliseconds"] for t in tracks) / 1000,
            "perClipP95MillisecondsRange": [min(t["runtime"]["separationAndMelodyMilliseconds"]["p95"] for t in tracks),
                                             max(t["runtime"]["separationAndMelodyMilliseconds"]["p95"] for t in tracks)],
            "worstBlockMilliseconds": max(t["runtime"]["separationAndMelodyMilliseconds"]["max"] for t in tracks),
        },
        "tracks": tracks,
    }
    if any(bench.sha256(path) != hashes[name] for name, path in sources.items()):
        raise RuntimeError("A benchmark source changed during execution; report not overwritten")
    output = ROOT / "docs/validation/rapidly-benchmark.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"all": report["all"], "performance": report["performance"]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
