#!/usr/bin/env python3
"""Real wall-clock soak with bounded CPU surfaces, switching and worker reloads.
This checks process RSS trends; it does not substitute for GPU/physical input latency measurement.
"""
import argparse,ctypes as c,json,os,pathlib,subprocess,sys,time
ROOT=pathlib.Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools/plugins'))
from preview import Bridge,frame
p=argparse.ArgumentParser();p.add_argument('--seconds',type=float,default=1800);p.add_argument('--fps',type=float,default=60);a=p.parse_args()
def rss():
    if sys.platform=='darwin':
        rows=subprocess.check_output(['ps','-axo','pid,ppid,rss'],text=True).splitlines()[1:];items=[tuple(map(int,r.split())) for r in rows]
        return sum(m for pid,parent,m in items if pid==os.getpid() or parent==os.getpid())
    return 0
start=time.monotonic();b=None;surface=None;index=0;samples=[];last_sample=0;generation=-1;active=None;slow=0
try:
    while time.monotonic()-start<a.seconds:
        elapsed=time.monotonic()-start
        # Create a fresh worker every five minutes, and switch entry every ten seconds.
        gen=int(elapsed//300)
        if gen!=generation:
            if surface:b.lib.miucs_surface_destroy(surface);surface=None
            if b:b.close()
            b=Bridge(ROOT/'plugins/builtin');generation=gen;active=None
        mode=['pixel-keyboard','staff-note','pencil-flight'][int(elapsed//10)%3]
        if mode!=active:
            if surface:b.lib.miucs_surface_destroy(surface)
            b.post('activate',{'id':mode});surface=b.lib.miucs_surface_create(b.handle,None,mode.encode());active=mode
        begin=time.monotonic();b.post('update',frame(index));pixels=c.create_string_buffer(800*460*4)
        if not b.lib.miucs_surface_pixels(surface,800,460,pixels,len(pixels)):raise RuntimeError(b.error())
        spent=time.monotonic()-begin;slow+=spent>1/a.fps;index+=1
        if elapsed-last_sample>=30 or not samples:
            samples.append({'seconds':round(elapsed,2),'rssKiB':rss(),'generation':generation,'frames':index,'overBudget':slow})
            (ROOT/'build/plugin-soak.json').write_text(json.dumps({'status':'running','samples':samples},indent=2));print(samples[-1],flush=True);last_sample=elapsed
        time.sleep(max(0,1/a.fps-spent))
    (ROOT/'build/plugin-soak.json').write_text(json.dumps({'status':'complete','duration':time.monotonic()-start,'frames':index,'overBudget':slow,'samples':samples},indent=2))
finally:
    if surface:b.lib.miucs_surface_destroy(surface)
    if b:b.close()
