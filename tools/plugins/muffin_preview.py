#!/usr/bin/env python3
"""Export the real skin under synthetic inputs, no desktop/audio recording."""
import argparse
from pathlib import Path
from PIL import Image
from preview import Bridge, ROOT, frame

p=argparse.ArgumentParser()
p.add_argument('--output',type=Path,default=ROOT/'docs/concepts/muffin-puppies/frame-jump-v2')
args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
b=Bridge(ROOT/'plugins/muffin-puppies')
frames=[]
try:
    b.post('activate',{'id':'muffin-puppies','width':800,'height':460,'scale':1})
    for i in range(360):
        f=frame(i)
        # One second idle, 4 seconds input, one second settle.
        active=60<=i<300
        f['audio']['beats']=f['audio']['beats'] if active else []
        f['audio']['onsets']=[]
        k=f['keyboard'];k.update(events=[],heldKeys=[],pressesPerSecond=0)
        if active and i%24==0:
            key=['a','j','f','l','space','h','r','u','b','n'][(i//24)%10]
            k['events']=[{'sequence':k['sequence'],'receivedAt':f['now'],'kind':'pressed','key':key,'modifiers':0}]
            k['heldKeys']=[{'key':key,'duration':0}]
        b.post('update',f)
        if i%2==0:
            raw=b.render('muffin-puppies',800,460)
            # Decode Skia's premultiplied BGRA into straight alpha, retaining transparency.
            rgba=Image.frombytes('RGBA',(800,460),raw,'raw','BGRA')
            image=Image.frombytes('RGBa',(800,460),rgba.tobytes()).convert('RGBA')
            frames.append(image)
        if i==185:
            raw=b.render('muffin-puppies',1600,920)
            rgba=Image.frombytes('RGBA',(1600,920),raw,'raw','BGRA')
            Image.frombytes('RGBa',(1600,920),rgba.tobytes()).convert('RGBA').save(args.output/'runtime-preview.png')
    durations=[33,33,34]*(len(frames)//3)
    frames[0].save(args.output/'runtime-preview.webp',save_all=True,append_images=frames[1:],duration=durations,loop=0,lossless=True)
    print('Exported 180 sampled frames / 6 seconds, transparent WebP and 2x PNG (identical frames may merge)')
finally:
    b.close()
