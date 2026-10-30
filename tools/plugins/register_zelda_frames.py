#!/usr/bin/env python3
"""Register original model-drawn atlases, without resampling or rewriting pixels.

The model's rows are not a mechanical grid. Each source region is translated
relative to its painted ground/cuff anchor, at ONE constant pixels-to-world
scale per character. This compensates sheet packing, never invents body motion.
"""
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'plugins/zelda-guardian'


def region_grid(xs, ys):
    return [[xs[c], ys[r], xs[c+1]-xs[c], ys[r+1]-ys[r]]
            for r in range(len(ys)-1) for c in range(len(xs)-1)]


link_ground = list(zip(
    [168,473,758,1037,168,472,773,1078,168,473,770,1074,168,474,771,1078],
    [293]*4 + [599]*4 + [886]*4 + [1154]*4))
link_shield = [
    [270,239],[568,239],[852,242],[1104,249],
    [284,544],[566,541],[875,550],[1182,549],
    [270,830],[571,825],[856,824],[1184,812],
    [268,1091],[568,1095],[872,1096],[1184,1096],
]
guardian_ground = list(zip(
    [158,476,788,1103,163,479,793,1101,170,480,792,1106,161,476,789,1102],
    [283]*4 + [598]*4 + [897]*4 + [1183]*4))
guardian_eye = [
    [114,185],[429,185],[740,195],[1056,185],
    [112,501],[429,500],[740,494],[1057,494],
    [115,791],[432,794],[756,809],[1059,796],
    [114,1087],[430,1087],[744,1097],[1055,1087],
]
data = {
    'link': dict(source='assets/link-actions.png', scale=.64,
                 rects=region_grid([0,343,651,940,1262],[0,337,650,934,1246]),
                 ground=link_ground, contacts=link_shield),
    'guardian': dict(source='assets/guardian-beat.png', scale=.70,
                     rects=region_grid([0,326,637,948,1254],[0,326,641,948,1254]),
                     ground=guardian_ground, contacts=guardian_eye),
}
# The model switched handedness in the last column; exchange those two cells.
# These source regions keep the same cuff anchor and constant image scale.
hand_regions = region_grid([0,444,888,1332,1774],[0,440,887])
hand_ground = [[208,371],[651,371],[1105,371],[1566,371],
               [240,790],[687,790],[1118,790],[1548,790]]
for side, indices in [('leftHand',[0,1,2,7]),('rightHand',[4,5,6,3])]:
    data[side] = dict(source='assets/typing-hands.png', scale=.15,
                      rects=[hand_regions[i] for i in indices],
                      ground=[hand_ground[i] for i in indices])

lines = ['-- Registered original image pixels; regenerate with tools/plugins/register_zelda_frames.py.', 'return {']
for name, entry in data.items():
    im = Image.open(PACKAGE / entry['source'])
    assert im.mode == 'RGBA' and im.getextrema()[3][0] == 0
    lines += [f"  {name}={{source='{entry['source']}',scale={entry['scale']},rects={{"]
    for x,y,w,h in entry['rects']:
        assert x>=0 and y>=0 and x+w<=im.width and y+h<=im.height, (name, im.size, [x,y,w,h])
        lines.append('    {'+','.join(map(str,[x,y,w,h]))+'},')
    lines.append('  },offsets={')
    for (x,y,w,h),(gx,gy) in zip(entry['rects'],entry['ground']):
        lines.append(f'    {{{x-gx},{y-gy}}},')
    lines.append('  },anchors={')
    for (cx,cy),(gx,gy) in zip(entry.get('contacts',[]),entry['ground']):
        lines.append(f'    {{{cx-gx},{cy-gy}}},')
    lines.append('  }},')
lines.append('}')
(PACKAGE/'frames.lua').write_text('\n'.join(lines)+'\n')
(ROOT/'docs/concepts/zelda-guardian/frame-registration.json').write_text(json.dumps(data,indent=2)+'\n')
print('Registered 40 drawn frames: 16 Link, 16 Guardian, 8 hands. Original PNGs unchanged.')
