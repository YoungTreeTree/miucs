#!/usr/bin/env python3
"""Reproducible pixel-tail sprite atlas from PixelTailSprite's analytical geometry."""
import math, pathlib
from preview import png
ROOT=pathlib.Path(__file__).resolve().parents[2]
w,h=96*16,88*17
pixels=bytearray(w*h*4)
for index in range(257):
    amplitude=0 if index==0 else ((index-1)//64+1)/4
    phase=0 if index==0 else ((index-1)%64)*2*math.pi/64
    samples=[]
    for i in range(101):
        t=i/100;bend=max(0,(t-.12)/.88)
        x=12+66*t;y=48+5*math.sin(math.pi*t)-15*t**3+amplitude*13*bend*bend*(3-2*bend)*math.sin(phase-2.4*t)
        r=7.5-2.2*t+.4*math.sin(math.pi*t);samples.append((x,y,r))
        if i in (22,42,64,82):samples.append((x-1,y-r+.5,2))
        if i in (32,55,74):samples.append((x-1,y+r-.5,2))
    for cx,cy,r in samples:
        for y in range(max(0,math.floor((cy-r-1)/2)*2),min(86,math.ceil((cy+r-1)/2)*2)+1,2):
            for x in range(max(0,math.floor((cx-r-1)/2)*2),min(94,math.ceil((cx+r-1)/2)*2)+1,2):
                if (x+1-cx)**2+(y+1-cy)**2<=r*r:
                    for dy in range(2):
                        for dx in range(2):pixels[((index//16*88+y+dy)*w+index%16*96+x+dx)*4+3]=255
png(ROOT/'plugins/pixel-keyboard/assets/tail-atlas.png',pixels,w,h)
