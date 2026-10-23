#!/usr/bin/env python3
"""Reproduce the Tong Hua mixed-audio benchmark with the production Swift analyzer.

python3 scripts/benchmark-pop-melody.py --prepare --adc-dataset build/adc2004 --diagnose-vocals

Requires numpy, scipy and matplotlib. Audio/annotations and per-frame predictions
stay in ignored build/. The committed fixture contains provenance, checksums and
a short independent score comparison, not full recordings, lyrics or sheet music.
"""
import argparse
import hashlib
import json
import platform
import subprocess
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import scipy
from scipy.io import wavfile
from scipy.signal import resample_poly

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tests/fixtures/melody/tong-hua.json"
ADC_DEVELOPMENT = {
    "daisy2", "daisy3", "jazz2", "jazz3", "midi1", "midi2",
    "opera_fem2", "opera_male3", "pop1", "pop4",
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ensure_source(path, url, expected_hash, download):
    if not path.exists() and download:
        path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != expected_hash:
            raise ValueError(f"Downloaded checksum mismatch: {path.name}")
        path.write_bytes(data)
    if not path.exists():
        raise FileNotFoundError(f"Missing {path}; run again with --prepare")
    if sha256(path) != expected_hash:
        raise ValueError(f"Fixture checksum mismatch: {path}")


def prepare(work, manifest, download):
    mix_dir = work / "mix48k"
    mix_dir.mkdir(parents=True, exist_ok=True)
    base = f"https://raw.githubusercontent.com/ryanwhite04/MIR-1K/{manifest['revision']}"
    for track in manifest["tracks"]:
        name = track["id"]
        audio = work / "mir1k/Wavfile" / f"{name}.wav"
        pitch = work / "mir1k/PitchLabel" / f"{name}.pv"
        ensure_source(audio, f"{base}/Wavfile/{name}.wav", track["audioSHA256"], download)
        ensure_source(pitch, f"{base}/PitchLabel/{name}.pv", track["pitchSHA256"], download)
        rate, samples = wavfile.read(audio)
        if rate != 16000 or samples.dtype != np.int16 or samples.ndim != 2 or samples.shape[1] != 2:
            raise ValueError(f"Unexpected original PCM format: {audio}")
        labels = np.loadtxt(pitch)
        if labels.ndim != 1 or len(labels) < 2 or not np.all(np.isfinite(labels)) or np.any(labels < 0):
            raise ValueError(f"Invalid reference pitch array: {pitch}")
        last_center = manifest["pitchTimeOriginSeconds"] + (len(labels) - 1) * manifest["pitchHopSeconds"]
        if not 0 <= len(samples) / rate - last_center <= 0.06:
            raise ValueError(f"Reference duration disagrees with PCM: {name}")
        # MIR-1K stores accompaniment left and vocals right at equal RMS here.
        # Mix FIRST: the analyzer must never exploit the separated vocal channel.
        mixture = samples.astype(np.float64).mean(axis=1) / 32768
        mixture = resample_poly(mixture, 3, 1)
        wavfile.write(mix_dir / audio.name, 48000,
                      np.clip(mixture * 32767, -32768, 32767).astype(np.int16))


def compile_probe(analyzer, executable):
    executable.parent.mkdir(parents=True, exist_ok=True)
    sources = sorted((ROOT / "modules/audio/core").glob("*.swift"))
    sources = [str(analyzer if p.name == "MelodyAnalyzer.swift" else p) for p in sources]
    subprocess.run([
        "swiftc", "-swift-version", "6", "-parse-as-library", "-O",
        "-framework", "Accelerate", "-framework", "AVFoundation", *sources,
        str(ROOT / "modules/audio/platforms/macos/AccelerateSpectrumTransform.swift"),
        str(ROOT / "tools/macos/MelodyFileProbe.swift"), "-o", str(executable),
    ], check=True, cwd=ROOT)


def run_probe(executable, audio, directory):
    directory.mkdir(parents=True, exist_ok=True)
    predictions = directory / f"{audio.stem}.json"
    statistics = directory / f"{audio.stem}.stats.json"
    subprocess.run([str(executable), str(audio), str(predictions), str(statistics)], check=True)
    frames = json.loads(predictions.read_text())
    times = np.array([f["time"] for f in frames])
    hz = np.array([f.get("pitchHz", 0) for f in frames])
    midi = np.where(hz > 0, 69 + 12 * np.log2(np.maximum(hz, 1) / 440), 0)
    return times, midi, json.loads(statistics.read_text())


def nearest_reference(times, reference_times, pitches):
    # Clamp only for indexing. Out-of-annotation endpoints are excluded rather
    # than silently extending the first/last reference indefinitely.
    indices = np.searchsorted(reference_times, times).clip(1, len(reference_times) - 1)
    indices -= times - reference_times[indices - 1] < reference_times[indices] - times
    valid = (times >= reference_times[0]) & (times <= reference_times[-1])
    return pitches[indices], valid


def metrics(actual, expected):
    voiced, detected = expected > 0, actual > 0
    error = np.abs(actual - expected)
    correct = detected & (error < 0.5)
    chroma = detected & (np.abs((error + 6) % 12 - 6) < 0.5)

    def fraction(mask, denominator):
        count = int(np.sum(denominator))
        return float(np.sum(mask & denominator) / count) if count else None

    return {
        "frames": len(actual), "referenceVoicedFrames": int(voiced.sum()),
        "referenceUnvoicedFrames": int((~voiced).sum()),
        "rawPitchAccuracy": fraction(correct, voiced),
        "rawChromaAccuracy": fraction(chroma, voiced),
        "octaveErrorRate": fraction(chroma & ~correct, voiced),
        "otherPitchErrorRate": fraction(detected & ~chroma, voiced),
        "missRate": fraction(~detected, voiced),
        "voicingFalseAlarm": fraction(detected, ~voiced),
        "overallAccuracy": float(np.mean((correct & voiced) | (~detected & ~voiced))),
    }


def score_comparison(track, times, actual, ref_times, reference, score):
    spans = score["clips"].get(track)
    if spans is None:
        return None
    notes = []
    for (start, end), score_midi in zip(spans, score["scoreMIDI"]):
        expected = score_midi + score["performedTransposeSemitones"]
        prediction = actual[(times >= start) & (times < end)]
        label = reference[(ref_times >= start) & (ref_times < end)]
        voiced = prediction[prediction > 0]
        median = float(np.median(voiced)) if len(voiced) >= max(len(prediction) / 2, 1) else None
        reference_median = float(np.median(label[label > 0])) if np.any(label > 0) else None
        notes.append({
            "start": start, "end": end, "expectedMIDI": expected,
            "estimatedMedianMIDI": median, "performedMedianMIDI": reference_median,
            "matchesScore": median is not None and abs(median - expected) < 0.5,
            "performanceMatchesScore": reference_median is not None and abs(reference_median - expected) < 0.5,
        })
    return {"notes": notes, "correct": sum(n["matchesScore"] for n in notes), "total": len(notes),
            "performanceCorrect": sum(n["performanceMatchesScore"] for n in notes)}


def summary(tracks):
    keys = [key for key in tracks[0]["baseline"] if not key.endswith("Frames") and key != "frames"]
    def mean(version, key):
        values = [t[version][key] for t in tracks if t[version][key] is not None]
        return float(np.mean(values)) if values else None
    return {version: {key: mean(version, key) for key in keys}
            for version in ("baseline", "current")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true", help="Download missing checksum-pinned excerpts")
    parser.add_argument("--work", type=Path, default=ROOT / "build/pop-benchmark")
    parser.add_argument("--output", type=Path, default=ROOT / "docs/validation/tong-hua-benchmark.json")
    parser.add_argument("--adc-dataset", type=Path)
    parser.add_argument("--diagnose-vocals", action="store_true", help="Also measure the old analyzer on isolated development vocals; diagnostic only")
    args = parser.parse_args()
    work = args.work.resolve()
    manifest = json.loads(MANIFEST.read_text())
    prepare(work, manifest, args.prepare)
    baseline_source = work / "baseline/MelodyAnalyzer.swift"
    baseline_source.parent.mkdir(parents=True, exist_ok=True)
    original = subprocess.check_output([
        "git", "show", f"{manifest['baselineGitRevision']}:modules/audio/core/MelodyAnalyzer.swift"
    ], cwd=ROOT)
    if hashlib.sha256(original).hexdigest() != manifest["baselineAnalyzerSHA256"]:
        raise ValueError("Baseline source does not match the frozen manifest")
    baseline_source.write_bytes(original)
    current_source = ROOT / "modules/audio/core/MelodyAnalyzer.swift"
    executables = {v: work / v / "melody-file-probe" for v in ("baseline", "current")}
    compile_probe(baseline_source, executables["baseline"])
    compile_probe(current_source, executables["current"])
    rows, chart_data = [], {}
    for track in manifest["tracks"]:
        name = track["id"]
        audio = work / "mix48k" / f"{name}.wav"
        reference = np.loadtxt(work / "mir1k/PitchLabel" / f"{name}.pv")
        ref_times = manifest["pitchTimeOriginSeconds"] + np.arange(len(reference)) * manifest["pitchHopSeconds"]
        row = {"track": name, "split": track["split"], "mixtureSHA256": sha256(audio)}
        for version, executable in executables.items():
            times, actual, statistics = run_probe(executable, audio, work / version / "frames")
            expected, valid = nearest_reference(times, ref_times, reference)
            row[version] = metrics(actual[valid], expected[valid])
            row[version + "Performance"] = statistics
            checked = score_comparison(name, times, actual, ref_times, reference, manifest["scoreCheck"])
            if checked:
                row[version + "ScoreCheck"] = checked
            if name == "geniusturtle_4_01":
                chart_data[version] = (times, actual)
                chart_data["reference"] = (ref_times, reference)
        rows.append(row)
        print(f"{name}: {row['baseline']['rawPitchAccuracy']:.3f} -> {row['current']['rawPitchAccuracy']:.3f}", flush=True)
    report = {
        "date": datetime.now(timezone.utc).isoformat(), "song": manifest["song"],
        "fixture": str(MANIFEST.relative_to(ROOT)), "fixtureSHA256": sha256(MANIFEST),
        "audio": manifest["audio"], "mixture": manifest["mix"],
        "baselineAnalyzerSHA256": sha256(baseline_source), "currentAnalyzerSHA256": sha256(current_source),
        "evaluatorSHA256": sha256(Path(__file__)),
        "probeSHA256": sha256(ROOT / "tools/macos/MelodyFileProbe.swift"),
        "environment": {"python": platform.python_version(), "numpy": np.__version__, "scipy": scipy.__version__,
                        "macOS": platform.mac_ver()[0], "architecture": platform.machine()},
        "method": "Nearest human reference at frame center; 50-cent tolerance; macro mean over clips; no optimized offset, transposition, or DTW against predictions. Missing voiced frames count as errors.",
        "durationSeconds": sum(r["currentPerformance"]["audioSeconds"] for r in rows),
        "summary": summary(rows),
        "splits": {split: summary([r for r in rows if r["split"] == split]) for split in ("development", "held_out")},
        "tracks": rows,
        "limitations": [
            "Three amateur covers of one song, at one mixing ratio; not the commercial master or an all-song accuracy claim.",
            "Two cover performers were held out during tuning; the song itself was used for development.",
            "Full-clip frame metrics use independent manual performed-pitch labels. The separate score check covers only the 12-note opening in two recordings, not the whole score.",
            "A predominant-melody heuristic is not a singing-voice detector; accompaniment-only sections can still yield pitches.",
            "Frame-center accuracy does not measure live capture/display latency; timings cover the analyzer only.",
        ],
    }
    if args.diagnose_vocals:
        diagnostic_rows = []
        directory = work / "vocal-diagnostic"
        directory.mkdir(parents=True, exist_ok=True)
        for track in manifest["tracks"]:
            if track["split"] != "development":
                continue
            name = track["id"]
            _, pcm = wavfile.read(work / "mir1k/Wavfile" / f"{name}.wav")
            vocals = resample_poly(pcm[:, 1].astype(np.float64) / 32768, 3, 1)
            audio = directory / f"{name}.wav"
            wavfile.write(audio, 48000, np.clip(vocals * 32767, -32768, 32767).astype(np.int16))
            times, actual, _ = run_probe(executables["baseline"], audio, directory / "frames")
            labels = np.loadtxt(work / "mir1k/PitchLabel" / f"{name}.pv")
            ref_times = manifest["pitchTimeOriginSeconds"] + np.arange(len(labels)) * manifest["pitchHopSeconds"]
            expected, valid = nearest_reference(times, ref_times, labels)
            diagnostic_rows.append({"track": name, **metrics(actual[valid], expected[valid])})
        report["isolatedVocalDiagnostic"] = {
            "scope": "Baseline analyzer, development singer only, original right-channel vocals; NEVER included in mixed-audio scores or claimed as real-time source separation",
            "meanRawPitchAccuracy": float(np.mean([r["rawPitchAccuracy"] for r in diagnostic_rows])),
            "tracks": diagnostic_rows,
        }
    if args.adc_dataset:
        adc = []
        for audio in sorted(args.adc_dataset.resolve().glob("*.wav")):
            reference = np.loadtxt(audio.with_name(audio.stem + "REF.txt"))
            pitches = np.where(reference[:, 1] > 0, 69 + 12 * np.log2(np.maximum(reference[:, 1], 1) / 440), 0)
            row = {"track": audio.stem, "split": "development" if audio.stem in ADC_DEVELOPMENT else "held_out"}
            for version, executable in executables.items():
                times, actual, _ = run_probe(executable, audio, work / version / "adc")
                expected, valid = nearest_reference(times, reference[:, 0], pitches)
                row[version] = metrics(actual[valid], expected[valid])
            adc.append(row)
        if len(adc) != 20:
            raise ValueError("Expected all 20 ADC2004 excerpts")
        report["adc2004"] = {"summary": summary(adc), "tracks": adc,
                             "splits": {s: summary([r for r in adc if r["split"] == s]) for s in ("development", "held_out")}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    plot(report, chart_data, args.output.with_suffix(".png"))
    print(json.dumps({"song": report["summary"], "held_out": report["splits"]["held_out"],
                      "adc2004": report.get("adc2004", {}).get("summary")}, indent=2))


def plot(report, chart_data, output):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(3, 1, figsize=(12, 8.5), gridspec_kw={"height_ratios": [1, 1, 1.15]}, layout="constrained")
    for ax, version in zip(axes[:2], ("baseline", "current")):
        rt, ref = chart_data["reference"]
        times, prediction = chart_data[version]
        ax.plot(rt, np.where(ref > 0, ref, np.nan), color="#16816a", lw=2.4, label="Human reference")
        ax.plot(times, np.where(prediction > 0, prediction, np.nan), color="#bf5b45" if version == "baseline" else "#3e61aa", lw=1, alpha=.85, label=version.title())
        # The score is an independent, discrete target. Do not visually present
        # the annotated performed f0 as if it were the original notated score.
        score = json.loads(MANIFEST.read_text())["scoreCheck"]
        for i, ((start, end), midi) in enumerate(zip(score["clips"]["geniusturtle_4_01"], score["scoreMIDI"])):
            ax.plot([start, end], [midi + score["performedTransposeSemitones"]] * 2,
                    color="#674b85", ls="--", lw=1.1,
                    label="Score (transposed)" if i == 0 else None)
        ax.fill_between(rt, 38, 82, where=ref == 0, color="#d9dde5", alpha=.5, label="No voiced melody in reference")
        ax.set(xlim=(0, rt[-1]), ylim=(40, 80), ylabel="Pitch (MIDI)", title=f"{version.title()} - held-out cover, geniusturtle_4_01")
        ax.grid(alpha=.18); ax.legend(loc="upper right", fontsize=8, ncol=2)
    axes[1].set_xlabel("Time in clip (seconds)")
    groups = [("Tong Hua development", report["splits"]["development"]),
              ("Tong Hua held-out performers", report["splits"]["held_out"])]
    if "adc2004" in report:
        groups.append(("ADC2004 regression (20 clips)", report["adc2004"]["summary"]))
    x = np.arange(len(groups))
    for offset, version, color in [(-.18, "baseline", "#bf5b45"), (.18, "current", "#3e61aa")]:
        values = [100 * summary[version]["rawPitchAccuracy"] for _, summary in groups]
        bars = axes[2].bar(x + offset, values, .34, color=color, label=version.title())
        axes[2].bar_label(bars, fmt="%.1f%%", padding=3, fontsize=10)
    axes[2].set(xticks=x, xticklabels=[n for n, _ in groups], ylim=(0, 100), ylabel="Correct pitch (%)",
                title="Mixed audio, 50-cent tolerance; macro mean over clips")
    axes[2].legend(loc="upper left", ncol=2, fontsize=9); axes[2].grid(axis="y", alpha=.18)
    fig.suptitle("Tong Hua: production melody extraction vs independent annotations", fontsize=15)
    fig.savefig(output, dpi=160)
    plt.close(fig)


if __name__ == "__main__":
    main()
