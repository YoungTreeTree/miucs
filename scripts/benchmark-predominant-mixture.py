#!/usr/bin/env python3
"""Paired current vocal route vs raw-mixture predominant melody, on identical PCM.

Uses existing verified local fixtures. No score-guided tuning, time fitting, or
source stems enter either estimator. Vocal-rest activity is NOT a false alarm
for the new instrument-inclusive target; noise/silence have separate controls.
"""
import importlib.util
import json
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path
import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('singing', ROOT/'scripts/benchmark-singing-pitch.py')
singing = importlib.util.module_from_spec(spec); spec.loader.exec_module(singing)
b = singing.b


def continuity(pitch, step=.02):
    active = pitch > 0
    adjacent = active[1:] & active[:-1]
    jumps = np.abs(np.diff(pitch))
    runs = np.diff(np.r_[False, ~active, False].astype(int))
    lengths = np.flatnonzero(runs == -1) - np.flatnonzero(runs == 1)
    return dict(outputCoverage=float(active.mean()), absentRuns=int(len(lengths)),
                absentSeconds=float((~active).sum()*step),
                jumpsOver7Semitones=int(np.sum(adjacent & (jumps > 7))),
                shortAbsentRunsUnder200ms=int(np.sum(lengths < .2/step)))


def main():
    work = ROOT/'build/predominant-mixture'; work.mkdir(exist_ok=True)
    installed = ROOT/'build/light-arcs-install.json'
    prior_binary = json.loads(installed.read_text()).get('binarySHA256') if installed.exists() else None
    probe, hashes = singing.compile_probe(work)
    manifest = json.loads(b.MANIFEST.read_text()); fixture = ROOT/'build/pop-benchmark'
    b.prepare(fixture, manifest, False)
    model = ROOT/'build/singing-pitch/SingingPitch.mlmodelc'
    separator = ROOT/'build/rapidly/music-stem-separation-96ms.v1.1.rapidly'

    def run(audio):
        output, stats = work/f'{audio.stem}.json', work/f'{audio.stem}.stats.json'
        subprocess.run([str(probe),str(model),str(audio),str(output),str(stats),str(separator)], check=True, timeout=120,
                       stdout=subprocess.DEVNULL)
        old_t,old = singing.frames(output)
        new_t,new = singing.frames(Path(str(output)+'.mixture.json'))
        return old_t,old,new_t,new,json.loads(stats.read_text())

    tracks=[]
    for track in manifest['tracks']:
        name=track['id']; audio=fixture/'mix48k'/f'{name}.wav'
        old_t,old,new_t,new,stats=run(audio)
        ref=np.loadtxt(fixture/'mir1k/PitchLabel'/f'{name}.pv')
        rt=manifest['pitchTimeOriginSeconds']+np.arange(len(ref))*manifest['pitchHopSeconds']
        valid=(rt>=max(old_t[0],new_t[0]))&(rt<=min(old_t[-1],new_t[-1]))
        old_grid,_=b.nearest_reference(rt[valid],old_t,old)
        new_grid,_=b.nearest_reference(rt[valid],new_t,new)
        row=dict(id=name,originalSplit=track['split'],inputSHA256=b.sha256(audio),
                 baseline=b.metrics(old_grid,ref[valid]),current=b.metrics(new_grid,ref[valid]),
                 continuityBaseline=continuity(old_grid),continuityCurrent=continuity(new_grid),
                 scoreBaseline=b.score_comparison(name,old_t,old,rt,ref,manifest['scoreCheck']),
                 scoreCurrent=b.score_comparison(name,new_t,new,rt,ref,manifest['scoreCheck']),runtime=stats)
        tracks.append(row)
        print(name,'vocal-pitch accuracy',round(row['baseline']['rawPitchAccuracy'],3),'->',round(row['current']['rawPitchAccuracy'],3),flush=True)

    controls=[]
    for name in ['fdps_2_01','Ani_2_01','geniusturtle_4_01']:
        rate,pcm=wavfile.read(fixture/'mir1k/Wavfile'/f'{name}.wav')
        audio=work/f'{name}-instrumental.wav'
        wavfile.write(audio,48000,resample_poly(pcm[:,0].astype(np.float32)/65536,3,1))
        ot,o,nt,n,stats=run(audio)
        controls.append(dict(id=audio.stem,inputSHA256=b.sha256(audio),
            baselineOutputCoverage=float(np.mean(o>0)),mixtureOutputCoverage=float(np.mean(n>0)),
            interpretation='No vocal present. Instrument notes are intended output; no instrument pitch reference, so coverage is not accuracy.'))

    rate=48000; rng=np.random.default_rng(417)
    # Fixed pitches and timbres, alternate which simultaneous source is prominent.
    t=np.arange(rate)/rate; samples=[]; notes=[60,64,67,72,65,69]
    for i,midi in enumerate(notes):
        hz=440*2**((midi-69)/12); other=440*2**(([55,57][i%2]-69)/12)
        partials=[.25,1,.65,.3,.2] if i%2==0 else [1,.5,.3,.18,.12]
        lead=sum(.14*p*np.sin(2*np.pi*hz*(h+1)*t) for h,p in enumerate(partials))
        backing=.035*np.sin(2*np.pi*other*t)+.055*np.sin(2*np.pi*110*t)
        hit=rng.uniform(-1,1,rate)*.14*np.exp(-(t%.5)/.025)
        samples.extend(lead+backing+hit)
    synthetic=[]
    for name,pcm in [('lead-handoff',np.array(samples,dtype=np.float32)),('silence',np.zeros(rate*3,dtype=np.float32)),
                     ('percussion-noise',(rng.uniform(-1,1,rate*3)*.2*np.exp(-((np.arange(rate*3)/rate)%.4)/.06)).astype(np.float32))]:
        audio=work/f'{name}.wav';wavfile.write(audio,rate,pcm)
        ot,o,nt,n,stats=run(audio)
        row=dict(id=name,inputSHA256=b.sha256(audio),baselineOutputCoverage=float(np.mean(o>0)),mixtureOutputCoverage=float(np.mean(n>0)),runtime=stats)
        if name=='lead-handoff':
            for label,ts,p in [('baseline',ot,o),('mixture',nt,n)]:
                middle=(ts%1>.18)&(ts%1<.85)&(ts<len(notes))
                expected=np.array(notes)[np.minimum(ts.astype(int),len(notes)-1)]
                row[label+'Accuracy']=float(np.mean((p[middle]>0)&(np.abs(p[middle]-expected[middle])<.5)))
        synthetic.append(row)

    if any(b.sha256(ROOT/name)!=digest for name,digest in hashes.items()):raise RuntimeError('Source changed during benchmark')
    report=dict(createdAt=datetime.now(timezone.utc).isoformat(),machine=platform.platform(),baselineInstalledBinarySHA256=prior_binary,
        sourceSHA256=hashes,separatorSHA256=b.sha256(separator),fixtureSHA256=b.sha256(b.MANIFEST),
        baseline='Rapidly 96ms trial + CREPE Tiny + aligned -9dB vocal energy gate, exactly the previously installed route',
        current='Existing causal MelodyAnalyzer, now default on original mixture; no neural model or separator in this route',
        method='Same 512-sample causal input; common 20ms human reference grid; 50-cent tolerance; macro clip averages; no alignment or pitch fitting. Each route timed independently with raw feature extraction.',
        limits=['31 previously used amateur covers, not new unseen songs or commercial master.',
                'Human annotations cover vocals only. voicingFalseAlarm measures output during vocal rests, NOT errors for instrument-inclusive melody. Overall vocal-reference accuracy is not the new target quality.',
                'Instrument controls lack reference pitches. Synthetic known-pitch control is reported separately.',
                'Runtime excludes I/O, initialization, capture, UI and display; alternate estimator timing excluded. Separator retains demo watermark.'],
        all=b.summary(tracks),tracks=tracks,instrumentControls=controls,syntheticControls=synthetic)
    out=ROOT/'docs/validation/predominant-mixture-benchmark.json';out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(report['all'],indent=2));print(json.dumps(synthetic,indent=2))

if __name__=='__main__':main()
