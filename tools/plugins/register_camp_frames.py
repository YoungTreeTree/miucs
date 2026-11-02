#!/usr/bin/env python3
"""Register model-drawn chair, fire-pit and cuff contacts; never rewrite PNGs."""
import json
from pathlib import Path
from PIL import Image

ROOT=Path(__file__).resolve().parents[2]
PACKAGE=ROOT/'plugins/yuru-camp'

def cells(width,ys,columns=4):
    xs=[round(i*width/columns) for i in range(columns+1)]
    return [[xs[c],ys[r],xs[c+1]-xs[c],ys[r+1]-ys[r]]
            for r in range(len(ys)-1) for c in range(columns)]

def register(source,regions,scale,mirrored=()):
    im=Image.open(PACKAGE/source)
    assert im.mode=='RGBA' and im.getextrema()[3][0]==0
    result=dict(source=source,scale=scale,rects=regions,offsets=[],contacts=[],bounds=[],mirrored=[])
    for i,(x,y,w,h) in enumerate(regions):
        assert x>=0 and y>=0 and x+w<=im.width and y+h<=im.height
        alpha=im.crop((x,y,x+w,y+h)).getchannel('A').point(lambda a:255 if a>96 else 0)
        bounds=alpha.getbbox();assert bounds, (source,i)
        l,t,r,b=bounds
        # Guard against a crop through visible art or a neighboring cell.
        assert l>1 and t>1 and r<w-1 and b<h-1, (source,i,bounds,(w,h))
        # Lowest solid contact band: chair feet/fire-pit legs/knitted sleeve cuff.
        band=alpha.crop((0,max(t,b-18),w,b)).getbbox()
        gx=x+round((band[0]+band[2])/2);gy=y+b
        result['contacts'].append([gx,gy])
        result['offsets'].append([x-gx,y-gy])
        result['bounds'].append([x+l,y+t,x+r,y+b])
        result['mirrored'].append(i in mirrored)
    return result

prop_regions=cells(1254,[0,325,640,935,1254])
data={
    'nadeshiko':register('assets/nadeshiko-eat.png',cells(1448,[0,365,710,1086]),.42),
    'rin':register('assets/rin-sip.png',cells(1448,[0,375,710,1086]),.45),
    'fire':register('assets/camp-props.png',prop_regions[:8],.32),
    # Rebound cells were painted with reversed thumbs. A static source orientation
    # correction preserves the original drawn frame and the hand's cuff anchor.
    'leftHand':register('assets/camp-props.png',prop_regions[8:12],.20,mirrored=(3,)),
    'rightHand':register('assets/camp-props.png',prop_regions[12:16],.20,mirrored=(3,)),
}

lines=['-- Original pixels registered at fixed contacts. See tools/plugins/register_camp_frames.py.','return {']
for name,e in data.items():
    lines.append(f"  {name}={{source='{e['source']}',scale={e['scale']},rects={{")
    lines.extend('    {'+','.join(map(str,v))+'},' for v in e['rects'])
    lines.append('  },offsets={')
    lines.extend('    {'+','.join(map(str,v))+'},' for v in e['offsets'])
    lines.append('  },mirrored={'+','.join(str(b).lower() for b in e['mirrored'])+'}},')
lines.append('}')
(PACKAGE/'frames.lua').write_text('\n'.join(lines)+'\n')
(ROOT/'docs/concepts/yuru-camp/frame-registration.json').write_text(json.dumps(data,indent=2)+'\n')
print('Registered 12 eating + 12 sipping + 8 flame + 8 mitten frames; all PNG pixels unchanged.')
