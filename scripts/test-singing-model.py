#!/usr/bin/env python3
"""Real Core ML negative controls; accompaniment leakage is reported, not hidden."""
import importlib.util,json,subprocess
from pathlib import Path
import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly
ROOT=Path(__file__).resolve().parents[1]
s=importlib.util.spec_from_file_location('b',ROOT/'scripts/benchmark-singing-pitch.py');b=importlib.util.module_from_spec(s);s.loader.exec_module(b)
w=ROOT/'build/singing-controls';w.mkdir(exist_ok=True)
probe, hashes=b.compile_probe(w)
sr=48000;rng=np.random.default_rng(20261024);parts=[]
for kind,hz in [('quiet',0),('voice',220),('noise',0),('voice',329.6276),('quiet',0)]:
 t=np.arange(int(sr*.6))/sr
 if kind=='voice':x=sum(.1/i**1.3*np.sin(2*np.pi*hz*i*t) for i in range(1,7))
 elif kind=='noise':x=rng.normal(0,.05,len(t))
 else:x=np.zeros(len(t))
 parts.append(x)
wavfile.write(w/'synthetic.wav',sr,np.concatenate(parts).astype(np.float32))
for name in ['fdps_2_01','Ani_2_01','geniusturtle_4_01']:
 rate,x=wavfile.read(ROOT/f'build/pop-benchmark/mir1k/Wavfile/{name}.wav')
 wavfile.write(w/f'{name}-accompaniment.wav',48000,resample_poly(x[:,0].astype(np.float32)/65536,3,1))
rows=[]
for audio in sorted(w.glob('*.wav')):
 output=w/(audio.stem+'.json');stats=w/(audio.stem+'.stats.json')
 args=[str(probe),str(ROOT/'build/singing-pitch/SingingPitch.mlmodelc'),str(audio),str(output),str(stats)]
 if 'accompaniment' in audio.stem:args+=[str(ROOT/'build/rapidly/music-stem-separation-96ms.v1.1.rapidly')]
 subprocess.run(args,check=True)
 frames=json.loads(output.read_text());baseline=json.loads(Path(str(output)+'.spectral.json').read_text())
 if 'accompaniment' in audio.stem:
  row={'case':audio.stem,'expected':'no singer; accompaniment only','baselineFalseAlarm':float(np.mean([bool(f.get('pitchHz')) for f in baseline])), 'currentFalseAlarm':float(np.mean([bool(f.get('pitchHz')) for f in frames]))}
 else:
  def region(lo,hi):return [f for f in frames if lo<f['time']<hi]
  a=region(.72,1.08);e=region(1.92,2.28)
  row={'case':'synthetic','quietVoiced':sum(bool(f.get('pitchHz')) for f in region(.1,.5)+region(2.6,2.9)), 'noiseVoiced':sum(bool(f.get('pitchHz')) for f in region(1.32,1.68)), 'A3Hits':int(sum(f.get('pitchHz') is not None and abs(1200*np.log2(f['pitchHz']/220))<50 for f in a)), 'A3Frames':len(a),'E4Hits':int(sum(f.get('pitchHz') is not None and abs(1200*np.log2(f['pitchHz']/329.6276))<50 for f in e)), 'E4Frames':len(e)}
 rows.append(row);print(row,flush=True)
report={'cases':rows,'sourceSHA256':hashes,'scope':'Synthetic silence/noise/harmonic tones use the real Core ML estimator. Accompaniment-only clips use intact Rapidly demo output. No calibration on these controls.'}
(ROOT/'docs/validation/singing-pitch-controls.json').write_text(json.dumps(report,indent=2)+'\n')
x=next(r for r in rows if r['case']=='synthetic')
assert x['quietVoiced']==0 and x['noiseVoiced']==0 and x['A3Hits']/x['A3Frames']>=.9 and x['E4Hits']/x['E4Frames']>=.9
