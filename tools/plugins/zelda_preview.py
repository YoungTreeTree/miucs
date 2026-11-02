#!/usr/bin/env python3
"""Render nine seconds of the production skin, using synthetic input only."""
import argparse
from pathlib import Path
from PIL import Image
from preview import Bridge,ROOT,frame

p=argparse.ArgumentParser()
p.add_argument('--output',type=Path,default=ROOT/'docs/concepts/zelda-guardian')
args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
b=Bridge(ROOT/'plugins/zelda-guardian')
frames=[]

def render(width=800,height=460):
    raw=b.render('zelda-guardian',width,height)
    premultiplied=Image.frombytes('RGBA',(width,height),raw,'raw','BGRA')
    return Image.frombytes('RGBa',(width,height),premultiplied.tobytes()).convert('RGBA')

try:
    b.post('activate',{'id':'zelda-guardian','width':800,'height':460,'scale':1})
    for i in range(540):
        f=frame(i)
        audio_active=180<=i<480
        typing=60<=i<180 or 300<=i<480
        f['audio']['beats']=f['audio']['beats'] if audio_active else []
        f['audio']['onsets']=[]
        f['audio']['frame']['audio']['isSilent']=not audio_active
        k=f['keyboard'];k.update(events=[],heldKeys=[],pressesPerSecond=0)
        if typing:
            key=['a','j','r','u','f','l','space','h'][(i//36)%8]
            phase=i%36
            if phase<8: k['heldKeys']=[{'key':key,'duration':phase/60}]
            if phase in (0,8):
                k['events']=[dict(sequence=k['sequence'],receivedAt=f['now'],kind='pressed' if phase==0 else 'released',key=key,modifiers=0)]
        b.post('update',f)
        if i%2==0: frames.append(render())
        if i in (30,151,363):
            name={30:'runtime-idle.png',151:'runtime-slash.png',363:'runtime-preview.png'}[i]
            render(1600,920).save(args.output/name)
    durations=[33,33,34]*(len(frames)//3)
    frames[0].save(args.output/'runtime-preview.webp',save_all=True,append_images=frames[1:],duration=durations,loop=0,lossless=True)
    # GIF on warm white is a widely supported preview; the plugin and WebP retain alpha.
    gif=[]
    for im in frames[::2]:
        canvas=Image.new('RGBA',im.size,'#FFFDF8');canvas.alpha_composite(im)
        gif.append(canvas.convert('RGB'))
    gif[0].save(args.output/'runtime-preview.gif',save_all=True,append_images=gif[1:],duration=[70,60,70]*(len(gif)//3),loop=0,disposal=2)
    print('Exported 9s / 270 sampled frames: real Skia rendering, transparent WebP, GIF, 2x snapshots.')
finally: b.close()
