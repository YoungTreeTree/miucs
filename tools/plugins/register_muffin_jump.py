#!/usr/bin/env python3
"""Read model-drawn shadows to register sprite regions; never redraw/warp pixels.

The generated sheets are irregularly spaced. Source rectangles of identical
size center the painted ground shadows. All airborne displacement relative to
that ground remains exactly as drawn by the image model.
"""
from pathlib import Path
from PIL import Image
import numpy as np
import json
ROOT=Path(__file__).resolve().parents[2]
ASSETS=ROOT/'plugins/muffin-puppies/assets'
rows=[(0,345),(345,663),(663,977),(977,1254)]
report={}
for name in ('maltese','golden'):
    im=Image.open(ASSETS/f'{name}-jump-v3.png')
    assert im.size==(1254,1254) and im.mode=='RGBA'
    a=np.array(im)
    rects=[];anchors=[]
    # Each species keeps ONE constant frame size, with sufficient top/bottom gutters.
    # The golden sheet's last rows are packed closer together than its first rows.
    height,baseline=(295,280) if name=='maltese' else (280,265)
    for y0,y1 in rows:
        for c in range(4):
            x0,x1=round(c*im.width/4),round((c+1)*im.width/4)
            cell=a[y0:y1,x0:x1];rgb=cell[:,:,:3].astype(float)
            gray=(rgb.max(2)-rgb.min(2)<25)&(rgb.mean(2)>90)&(rgb.mean(2)<220)&(cell[:,:,3]>180)
            counts=gray.sum(1);ym=int(np.argmax(counts))
            assert counts[ym]>100, 'Missing painted ground anchor'
            # Read the visible bottom of the ground shadow; feet can occlude its top.
            lower=[y for y in range(ym,min(ym+20,len(counts))) if counts[y]>35]
            bottom=max(lower)+y0+1
            _,xs=np.where(gray[max(0,ym-3):ym+4])
            cx=int(round((float(xs.min())+float(xs.max()))/2+x0))
            rect=[cx-150,bottom-baseline,300,height]
            assert 0<=rect[0] and 0<=rect[1] and rect[0]+300<=im.width and rect[1]+height<=im.height
            x,y,w,h=rect
            alpha=a[y:y+h,x:x+w,3]
            border=np.concatenate([alpha[:2].ravel(),alpha[-2:].ravel(),alpha[:,:2].ravel(),alpha[:,-2:].ravel()])
            assert not np.any(border>100), f'{name} frame {len(rects)+1}: neighboring art or clipped body at edge'
            rects.append(rect);anchors.append([cx,bottom])
    report[name]={'source':f'assets/{name}-jump-v3.png','rects':rects,'shadowAnchors':anchors}
lines=['-- Generated source rectangles: original pixels, fixed-size cells, painted shadow anchor.',
       '-- Regenerate with tools/plugins/register_muffin_jump.py. No animation trajectory here.',
       'return {']
for name,data in report.items():
    lines.append(f"  {name}={{source='{data['source']}',rects={{")
    lines.extend('    {'+','.join(map(str,r))+'},' for r in data['rects'])
    lines.append('  }},')
lines.append('}')
(ROOT/'plugins/muffin-puppies/jump_frames.lua').write_text('\n'.join(lines)+'\n')
(ROOT/'docs/concepts/muffin-puppies/jump-registration.json').write_text(json.dumps(report,indent=2)+'\n')
print('Registered 32 model-drawn frames at painted shadows; no pixels modified')
