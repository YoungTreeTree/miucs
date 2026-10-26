#!/usr/bin/env python3
"""Render the fixed opening-score checks, including unvoiced gaps and mistakes."""
import argparse,importlib.util,json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--vocal-energy',action='store_true',help='Compare with the preceding CREPE gate instead of the spectral estimator')
args=parser.parse_args()
stem='vocal-energy' if args.vocal_energy else 'singing-pitch'
s=importlib.util.spec_from_file_location('b',ROOT/'scripts/benchmark-singing-pitch.py');b=importlib.util.module_from_spec(s);s.loader.exec_module(b)
manifest=json.loads((ROOT/'tests/fixtures/melody/tong-hua.json').read_text())
report=json.loads((ROOT/f'docs/validation/{stem}-benchmark.json').read_text())
fig,axes=plt.subplots(2,1,figsize=(13,7),layout='constrained')
for ax,name in zip(axes,['fdps_2_01','geniusturtle_4_01']):
 row=next(t for t in report['tracks'] if t['id']==name)
 new_t,new=b.frames(ROOT/f'build/{stem}-validation/{name}.json')
 suffix='crepe' if args.vocal_energy else 'spectral'
 old_t,old=b.frames(ROOT/f'build/{stem}-validation/{name}.json.{suffix}.json')
 ref=np.loadtxt(ROOT/f'build/pop-benchmark/mir1k/PitchLabel/{name}.pv'); rt=.02+np.arange(len(ref))*.02
 ax.plot(old_t,np.where(old>0,old,np.nan),color='#d98a85',lw=1,alpha=.55,label='Previous CREPE gate' if args.vocal_energy else 'Previous spectral estimator')
 ax.plot(rt,np.where(ref>0,ref,np.nan),color='#333333',lw=1.4,alpha=.8,label='Human performance annotation')
 ax.plot(new_t,np.where(new>0,new,np.nan),color='#177f75',lw=1.7,label='CREPE + aligned vocal energy' if args.vocal_energy else 'CREPE Tiny + voicing gate')
 for i,n in enumerate(row['scoreCurrent']['notes']):
  ax.plot([n['start'],n['end']],[n['expectedMIDI']]*2,color='#415fcc',lw=3,alpha=.8,label='Fixed transposed score' if i==0 else None)
  ax.text((n['start']+n['end'])/2,60.2,str(i+1),ha='center',fontsize=8,color='#415fcc')
 ax.fill_between(rt,40,94,where=ref==0,step='mid',color='#dbdbdb',alpha=.32,label='No reference F0')
 ax.set(xlim=(0,max(new_t)),ylim=(42,94),ylabel='MIDI pitch',xlabel='Audio time (s)',
        title=f"{name}: score matches {row['scoreBaseline']['correct']}/12 → {row['scoreCurrent']['correct']}/12")
 ax.grid(alpha=.15);ax.legend(loc='upper right',fontsize=8,ncol=2)
fig.suptitle('Tong Hua covers — fixed score excerpt and actual pitch contours',fontsize=15)
fig.savefig(ROOT/f'docs/validation/{stem}-comparison.png',dpi=170)
