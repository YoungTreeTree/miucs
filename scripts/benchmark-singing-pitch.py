#!/usr/bin/env python3
"""Paired production-model evaluation on Tong Hua, without reference fitting.

Both estimators receive identical Rapidly output in one pass; its demo watermark
is intact. Calibration used fdps_2 only; the remaining previously used clips are
regressions, not a new unseen test set. The score spans and transposition are fixed.
"""
import importlib.util
import json
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('pop', ROOT / 'scripts/benchmark-pop-melody.py')
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)


def frames(path):
    rows = json.loads(path.read_text())
    times = np.array([x['time'] for x in rows])
    midi = np.array([69 + 12*np.log2(x['pitchHz']/440) if x.get('pitchHz') else 0 for x in rows])
    return times, midi


def compile_probe(work):
    framework = ROOT / 'build/rapidly/RapidlyEngine.xcframework/macos-arm64_x86_64'
    sources = sorted((ROOT / 'modules/audio/core').glob('*.swift'))
    sources += [ROOT / f'modules/audio/platforms/macos/{name}.swift' for name in
                ['AccelerateSpectrumTransform', 'RapidlyVocalProcessor', 'CoreMLSingingPitch']]
    sources += [ROOT / 'tools/macos/SingingPitchFileProbe.swift']
    hashes = {str(p.relative_to(ROOT)): b.sha256(p) for p in sources}
    executable = work / 'probe'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-O',
        '-framework', 'CoreML', '-framework', 'Accelerate', '-framework', 'AVFoundation',
        '-F', str(framework), '-framework', 'RapidlyEngineC', '-Xlinker', '-rpath', '-Xlinker', str(framework),
        *map(str, sources), '-o', str(executable)], check=True)
    return executable, hashes


def main():
    work = ROOT / 'build/singing-pitch-validation'; work.mkdir(exist_ok=True)
    executable, hashes = compile_probe(work)
    manifest = json.loads(b.MANIFEST.read_text()); fixture = ROOT / 'build/pop-benchmark'
    b.prepare(fixture, manifest, False)
    model = ROOT / 'build/singing-pitch/SingingPitch.mlmodelc'
    separator = ROOT / 'build/rapidly/music-stem-separation-96ms.v1.1.rapidly'
    tracks = []
    for track in manifest['tracks']:
        name = track['id']; audio = fixture / 'mix48k' / f'{name}.wav'
        output, stats = work / f'{name}.json', work / f'{name}.stats.json'
        subprocess.run([str(executable), str(model), str(audio), str(output), str(stats), str(separator)], check=True, timeout=90)
        old_t, old = frames(Path(str(output) + '.spectral.json')); new_t, new = frames(output)
        ref = np.loadtxt(fixture / 'mir1k/PitchLabel' / f'{name}.pv')
        rt = manifest['pitchTimeOriginSeconds'] + np.arange(len(ref)) * manifest['pitchHopSeconds']
        # One common human-label grid; exclude endpoints unavailable to either estimator.
        valid = (rt >= max(old_t[0], new_t[0])) & (rt <= min(old_t[-1], new_t[-1]))
        expected = ref[valid]; times = rt[valid]
        old_grid, _ = b.nearest_reference(times, old_t, old)
        new_grid, _ = b.nearest_reference(times, new_t, new)
        row = {'id': name, 'originalSplit': track['split'], 'inputSHA256': b.sha256(audio),
               'baseline': b.metrics(old_grid, expected), 'current': b.metrics(new_grid, expected),
               'scoreBaseline': b.score_comparison(name, old_t, old, rt, ref, manifest['scoreCheck']),
               'scoreCurrent': b.score_comparison(name, new_t, new, rt, ref, manifest['scoreCheck']),
               'runtime': json.loads(stats.read_text())}
        tracks.append(row)
        print(name, 'RPA', round(row['baseline']['rawPitchAccuracy'],3), '->', round(row['current']['rawPitchAccuracy'],3),
              'false alarm', round(row['baseline']['voicingFalseAlarm'],3), '->', round(row['current']['voicingFalseAlarm'],3), flush=True)
    if any(b.sha256(ROOT / name) != digest for name, digest in hashes.items()):
        raise RuntimeError('Sources changed during benchmark; report not written')
    report = {'createdAt': datetime.now(timezone.utc).isoformat(), 'machine': platform.platform(),
        'model': json.loads((ROOT / 'build/singing-pitch/conversion.json').read_text()),
        'sourceSHA256': hashes, 'separatorSHA256': b.sha256(separator),
        'method': 'Paired same watermarked vocal PCM; causal 512-sample feeds; common original 20ms reference grid; no time or pitch fitting; macro per-clip average.',
        'limits': 'Previously used evaluation corpus, not unseen data; not original commercial master. Small fixed score excerpt, transposed for covers. Does not measure capture-to-screen latency or licensed separator quality.',
        'gate': {'onset': .40, 'sustain': .30, 'minimumDBFS': -65,
                 'minimumVocalToMixtureDB': -9, 'onsetConfirmationSeconds': .02},
        'all': b.summary(tracks),
        'development': b.summary([t for t in tracks if t['originalSplit']=='development']),
        'previouslyHeldOut': b.summary([t for t in tracks if t['originalSplit']=='held_out']),
        'performance': {'audioSeconds': sum(t['runtime']['audioSeconds'] for t in tracks),
                        'processingSeconds': sum(t['runtime']['processingMilliseconds'] for t in tracks)/1000,
                        'perClipP95MillisecondsRange': [min(t['runtime']['totalAnalysisMilliseconds']['p95'] for t in tracks), max(t['runtime']['totalAnalysisMilliseconds']['p95'] for t in tracks)],
                        'worstBlockMilliseconds': max(t['runtime']['totalAnalysisMilliseconds']['max'] for t in tracks)},
        'tracks': tracks}
    output = ROOT / 'docs/validation/singing-pitch-benchmark.json'
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k: report[k] for k in ['all','performance']}, indent=2), flush=True)


if __name__ == '__main__': main()
