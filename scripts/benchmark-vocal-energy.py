#!/usr/bin/env python3
"""Compare the aligned mixture-energy gate with a55c496's CREPE-only gate.

Both receive identical Rapidly output, including the intact demo watermark.
Thresholds were selected on fdps_2; the other, previously used clips are regressions.
Neither reference pitches nor score notes are inputs to either estimator.
"""
import importlib.util
import json
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('singing', ROOT / 'scripts/benchmark-singing-pitch.py')
singing = importlib.util.module_from_spec(spec); spec.loader.exec_module(singing)
b = singing.b


def main():
    work = ROOT / 'build/vocal-energy-validation'; work.mkdir(exist_ok=True)
    probe, hashes = singing.compile_probe(work)
    manifest = json.loads(b.MANIFEST.read_text())
    fixture = ROOT / 'build/pop-benchmark'
    model = ROOT / 'build/singing-pitch/SingingPitch.mlmodelc'
    separator = ROOT / 'build/rapidly/music-stem-separation-96ms.v1.1.rapidly'
    b.prepare(fixture, manifest, False)
    tracks = []
    for track in manifest['tracks']:
        name = track['id']; audio = fixture / 'mix48k' / f'{name}.wav'
        output, stats = work / f'{name}.json', work / f'{name}.stats.json'
        subprocess.run([str(probe), str(model), str(audio), str(output), str(stats), str(separator)], check=True, timeout=90)
        old_t, old = singing.frames(Path(str(output) + '.crepe.json'))
        new_t, new = singing.frames(output)
        ref = np.loadtxt(fixture / 'mir1k/PitchLabel' / f'{name}.pv')
        rt = manifest['pitchTimeOriginSeconds'] + np.arange(len(ref)) * manifest['pitchHopSeconds']
        valid = (rt >= max(old_t[0], new_t[0])) & (rt <= min(old_t[-1], new_t[-1]))
        old_grid, _ = b.nearest_reference(rt[valid], old_t, old)
        new_grid, _ = b.nearest_reference(rt[valid], new_t, new)
        row = dict(id=name, originalSplit=track['split'], inputSHA256=b.sha256(audio),
                   baseline=b.metrics(old_grid, ref[valid]), current=b.metrics(new_grid, ref[valid]),
                   scoreBaseline=b.score_comparison(name, old_t, old, rt, ref, manifest['scoreCheck']),
                   scoreCurrent=b.score_comparison(name, new_t, new, rt, ref, manifest['scoreCheck']),
                   runtime=json.loads(stats.read_text()))
        tracks.append(row)
        print(name, 'false alarm', round(row['baseline']['voicingFalseAlarm'], 3), '->',
              round(row['current']['voicingFalseAlarm'], 3), 'miss', round(row['baseline']['missRate'], 3),
              '->', round(row['current']['missRate'], 3), flush=True)
    controls = []
    from scipy.io import wavfile
    from scipy.signal import resample_poly
    for name in ['fdps_2_01', 'Ani_2_01', 'geniusturtle_4_01']:
        rate, pcm = wavfile.read(fixture / 'mir1k/Wavfile' / f'{name}.wav')
        audio = work / f'{name}-accompaniment.wav'
        wavfile.write(audio, 48000, resample_poly(pcm[:, 0].astype(np.float32) / 65536, 3, 1))
        output, stats = work / f'{audio.stem}.json', work / f'{audio.stem}.stats.json'
        subprocess.run([str(probe), str(model), str(audio), str(output), str(stats), str(separator)], check=True, timeout=90)
        _, old = singing.frames(Path(str(output) + '.crepe.json')); _, new = singing.frames(output)
        controls.append(dict(id=audio.stem, inputSHA256=b.sha256(audio),
                             baselineFalseAlarm=float(np.mean(old > 0)), currentFalseAlarm=float(np.mean(new > 0))))
    if any(b.sha256(ROOT / name) != digest for name, digest in hashes.items()):
        raise RuntimeError('Sources changed during benchmark')
    report = dict(createdAt=datetime.now(timezone.utc).isoformat(), machine=platform.platform(),
                  baselineGitRevision='a55c496', sourceSHA256=hashes, separatorSHA256=b.sha256(separator),
                  model=json.loads((ROOT / 'build/singing-pitch/conversion.json').read_text()),
                  method='Paired identical watermarked vocal PCM; original mix reference aligned by sample index; causal 512-sample feed; common 20ms human-label grid; macro per-clip mean. No time/pitch fitting.',
                  gate=dict(minimumVocalToMixtureDB=-9, minimumDBFS=-65, onset=.4, sustain=.3, onsetConfirmationSeconds=.02),
                  limits='Previously used corpus of 31 covers, not unseen data or the commercial master; no licensed separator A/B; performance excludes capture, display, loading, I/O and baseline computation.',
                  all=b.summary(tracks),
                  development=b.summary([r for r in tracks if r['originalSplit'] == 'development']),
                  previouslyHeldOut=b.summary([r for r in tracks if r['originalSplit'] == 'held_out']),
                  performance=dict(audioSeconds=sum(r['runtime']['audioSeconds'] for r in tracks),
                                   processingSeconds=sum(r['runtime']['processingMilliseconds'] for r in tracks)/1000,
                                   perClipP95MillisecondsRange=[min(r['runtime']['totalAnalysisMilliseconds']['p95'] for r in tracks), max(r['runtime']['totalAnalysisMilliseconds']['p95'] for r in tracks)],
                                   worstBlockMilliseconds=max(r['runtime']['totalAnalysisMilliseconds']['max'] for r in tracks)),
                  accompanimentControls=controls, tracks=tracks)
    (ROOT / 'docs/validation/vocal-energy-benchmark.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k: report[k] for k in ['all', 'previouslyHeldOut', 'performance', 'accompanimentControls']}, indent=2))


if __name__ == '__main__':
    main()
