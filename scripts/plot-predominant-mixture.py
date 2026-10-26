#!/usr/bin/env python3
"""Plot fixed comparison excerpts; no alignment or reference fitting."""
import importlib.util,json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('s',ROOT/'scripts/benchmark-singing-pitch.py')
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
manifest=json.loads(s.b.MANIFEST.read_text());score=manifest['scoreCheck']
fig,axes=plt.subplots(2,1,figsize=(12,6.5),constrained_layout=True)
for ax,name in zip(axes,['fdps_2_01','geniusturtle_4_01']):
    ref=np.loadtxt(ROOT/'build/pop-benchmark/mir1k/PitchLabel'/f'{name}.pv')
    rt=manifest['pitchTimeOriginSeconds']+np.arange(len(ref))*manifest['pitchHopSeconds']
    ax.plot(rt,np.where(ref>0,ref,np.nan),color='#30363d',lw=1.7,label='Human vocal pitch')
    for suffix,label,color in [('.json','Previous: separated vocals','#cd7b4d'),('.json.mixture.json','New: predominant mixture','#3b7c9d')]:
        ts,p=s.frames(ROOT/'build/predominant-mixture'/f'{name}{suffix}')
        ax.plot(ts,np.where(p>0,p,np.nan),color=color,lw=.9,alpha=.85,label=label)
    for i,((a,b),midi) in enumerate(zip(score['clips'][name],score['scoreMIDI'])):
        ax.plot([a,b],[midi+score['performedTransposeSemitones']]*2,color='#758c4c',lw=2.3,alpha=.7,label='Fixed score excerpt' if i==0 else None)
    ax.set(title=name,xlabel='Audio time (s)',ylabel='MIDI pitch',xlim=(0,8),ylim=(42,76))
    ax.grid(alpha=.15);ax.legend(loc='upper right',fontsize=8,ncol=2)
fig.suptitle('Same mixture input | Vocal-only annotations do not label instrumental melody',fontsize=13)
fig.savefig(ROOT/'docs/validation/predominant-mixture-comparison.png',dpi=160)
