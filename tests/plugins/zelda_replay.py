#!/usr/bin/env python3
"""Exercise the real Lua worker: input isolation, frame registration and lifecycle."""
import copy
import json
from pathlib import Path
import statistics
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/plugins'))
from wire import send,receive
from preview import frame

worker=ROOT/('build/plugins/Release/miucs-plugin-worker.exe' if sys.platform=='win32' else 'build/plugins/miucs-plugin-worker')
checks=0
def check(value,message):
    global checks
    checks+=1
    if not value: raise AssertionError(message)

class Harness:
    def __init__(self):
        self.proc=subprocess.Popen([str(worker),str(ROOT/'plugins/zelda-guardian')],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
        self.scene={};self.version=0;self.index=0;self.timings=[]
        self.seen={name:set() for name in ('link','guardian','left-paw','right-paw')}
        self.read()
        self.rest=tuple(self.scene['link-art']['sourceRect'])
        self.fixed={name:copy.deepcopy(self.scene[name]) for name in ('link','guardian')}
        self.activate()
    def read(self):
        r=receive(self.proc.stdout)
        if not r.get('ok'): raise RuntimeError(r.get('error','worker failed'))
        p=r['scene']
        if p['full']: self.scene={}
        for n in p['nodes']: self.scene.setdefault(n['id'],{}).update(n)
        self.version=p['version']
        if 'updateMs' in r: self.timings.append(r['updateMs'])
        for name in self.seen: self.seen[name].add(tuple(self.scene[name+'-art']['sourceRect']))
        if hasattr(self,'fixed'):
            for name,expected in self.fixed.items():
                assert self.scene[name]==expected, 'Actor world anchor changed'
                art=self.scene[name+'-art'];rect=art['sourceRect']
                scale=.64 if name=='link' else .70
                assert abs(art['width']/rect[2]-scale)<1e-8 and abs(art['height']/rect[3]-scale)<1e-8, 'Frame art stretched'
    def post(self,op,value=None):
        send(self.proc.stdin,{'op':op,'value':value or {},'ack':self.version});self.read()
    def activate(self): self.post('activate',{'id':'zelda-guardian','width':800,'height':460,'scale':1})
    def sample(self,key=None,kind='pressed',held=(),beat=False,audio=True,**overrides):
        f=frame(self.index);self.index+=1
        k=f['keyboard'];k.update(events=[],heldKeys=[{'key':key,'duration':.1} for key in held],sampledAt=f['now']+.002,pressesPerSecond=0)
        if key: k['events']=[dict(sequence=k['sequence'],receivedAt=f['now']+.002,kind=kind,key=key,modifiers=0)]
        a=f['audio'];a['onsets']=[];a['frame']['receivedAt']=f['now']+.001
        a['frame']['audio']['time']+=5000
        a['beats']=[dict(sequence=a['frame']['sequence'],receivedAt=f['now']+.001,time=f['now']+5000,bpm=120,confidence=.9,strength=.8)] if beat else []
        if not audio: del f['audio']
        f.update(overrides);return f
    def tick(self,**kw): self.post('update',self.sample(**kw))
    def advance(self,n=60,**kw):
        for _ in range(n): self.tick(**kw)
    def moving(self): return tuple(self.scene['link-art']['sourceRect'])!=self.rest
    def laser(self): return self.scene['laser'].get('opacity',0)>0
    def close(self):
        if self.proc.poll() is None: self.proc.kill()
        self.proc.wait(timeout=3)

h=Harness()
try:
    nodes=len(h.scene);ink=copy.deepcopy(h.scene['monitor-ink-1']['path'])
    h.advance(120,audio=False)
    check(not h.moving() and not h.laser(),'silence and idle invent no actions')
    for key in ('a','j','space','returnKey','digit1'):
        h.activate();h.tick(key=key,audio=False);h.advance(7,audio=False)
        check(h.moving(),key+' starts drawn action without audio')
        h.advance(80,audio=False);check(not h.moving(),'animation settles without input')
    h.activate();h.tick(key='a',held=('a',),audio=False);h.advance(10,held=('a',),audio=False)
    slash=tuple(h.scene['link-art']['sourceRect'])
    check(h.scene['key-a-fill']['fill']=='#8CE4E8','held physical key lights')
    for _ in range(100): h.tick(key='a',kind='repeated',held=('a',),audio=False)
    check(not h.moving(),'OS repeat does not restart action')
    h.tick(key='a',kind='released',audio=False);h.advance(20,audio=False)
    check(h.scene['key-a-fill']['fill']=='#FFF9EE','release clears highlight')
    h.activate();h.tick(key='j',audio=False);h.advance(10,audio=False)
    check(tuple(h.scene['link-art']['sourceRect'])!=slash,'right keys select shield clip')
    h.activate();h.tick(key='space',audio=False);h.advance(10,audio=False)
    first=tuple(h.scene['link-art']['sourceRect']);h.advance(60,audio=False)
    h.tick(key='space',audio=False);h.advance(10,audio=False)
    check(tuple(h.scene['link-art']['sourceRect'])!=first,'space alternates attack and shield')
    for mutate,label in [
        (lambda f:f['keyboard'].update(state='secureInput'),'secure input'),
        (lambda f:f['keyboard'].update(sampledAt=f['now']-.5),'stale keyboard'),
        (lambda f:f['keyboard'].update(droppedEventCount=3),'dropped key queue'),
        (lambda f:f['keyboard']['events'][0].update(receivedAt=f['now']-.5),'old press'),
    ]:
        h.activate();f=h.sample(key='a',audio=False);mutate(f);h.post('update',f);h.advance(8,audio=False)
        check(not h.moving(),label+' cannot trigger')
    h.activate();f=h.sample(key='leftShift',audio=False)
    f['keyboard']['modifiers']=1;f['keyboard']['events'][0].update(kind='modifiersChanged',modifierIsPressed=True)
    h.post('update',f);h.advance(8,audio=False);check(h.moving(),'modifier press is supported')
    h.activate();f=h.sample(key='a',audio=False);h.post('update',f);h.advance(60,audio=False)
    f['now']=h.sample(audio=False)['now'];f['keyboard']['sampledAt']=f['now'];f['keyboard']['events'][0]['receivedAt']=f['now']
    h.post('update',f);h.advance(8,audio=False);check(not h.moving(),'duplicate keyboard sequence ignored')
    h.activate();h.tick(beat=True)
    check(h.laser(),'actual beat starts laser immediately')
    check(not h.moving(),'audio cannot trigger keyboard character animation')
    h.advance(12);check(not h.laser(),'short laser fades')
    # The next predicted beat has no event: it must NEVER fire.
    for _ in range(150):
        h.tick();check(not h.laser(),'predicted beat cannot fire')
    for mutate,label in [
        (lambda f:f['audio']['frame']['audio'].update(isSilent=True),'silent audio'),
        (lambda f:f['audio']['beats'][0].update(confidence=.2),'low confidence'),
        (lambda f:f['audio']['beats'][0].update(bpm=250),'out-of-range tempo'),
        (lambda f:f['audio']['beats'][0].update(receivedAt=f['now']-.5),'old beat'),
        (lambda f:f['audio'].update(frameAge=.8),'old audio snapshot'),
        (lambda f:f['audio'].update(droppedBeatCount=2),'dropped beats'),
        (lambda f:f['audio']['frame'].update(sessionID='wrong'),'wrong audio session'),
    ]:
        h.activate();f=h.sample(beat=True);mutate(f);h.post('update',f)
        check(not h.laser(),label+' cannot fire')
    h.activate();f=h.sample(beat=True);h.post('update',f);h.advance(20)
    f['now']=h.sample()['now'];f['audio']['frame']['receivedAt']=f['now'];f['audio']['beats'][0]['receivedAt']=f['now']
    h.post('update',f);check(not h.laser(),'duplicate beat cannot fire again')
    h.activate();h.tick(key='a',beat=True)
    f=h.sample();f['audio'].update(state='recovering',frame=None,frameAge=None,beats=[])
    h.post('update',f);check(not h.laser(),'audio loss removes beam')
    h.advance(8,audio=False);check(h.moving(),'audio loss leaves sword action running')
    f=h.sample(beat=True);f['keyboard']['state']='secureInput';h.post('update',f)
    check(h.laser() and not h.moving(),'keyboard loss leaves music independent')
    f=h.sample(beat=True);f['audio']['sessionID']='new';f['audio']['frame'].update(sessionID='new',sequence=1);f['audio']['beats'][0]['sequence']=1
    h.post('update',f);check(h.laser(),'new audio session accepts fresh low sequence')
    h.tick(key='j',beat=True,deltaTime=2)
    check(not h.laser() and not h.moving(),'long stall discards backlog')
    h.activate()
    for i in range(1800):
        key=('a' if i//36%2==0 else 'j') if i%36==0 else None
        h.tick(key=key,beat=i%30==0)
    check(len(h.scene)==nodes,'30 second replay keeps bounded topology')
    check(len(h.seen['link'])==16 and len(h.seen['guardian'])==16,'all 32 character frames play')
    check(all(len(h.seen[name])==4 for name in ('left-paw','right-paw')),'all eight hand frames play')
    # Fast input retains at most one recent action, and must settle shortly after stop.
    for i in range(120): h.tick(key='a' if i%2 else 'j',audio=False)
    h.advance(60,audio=False);check(not h.moving(),'rapid typing cannot accumulate an animation backlog')
    check(h.scene['monitor-ink-1']['path']==ink,'hand-drawn keyboard contour remains stable')
    h.post('appearanceChanged',{'opacity':.4,'ink':'#000000'})
    check(h.scene['zelda-guardian']['opacity']==.4,'global opacity retained')
    h.post('resize',{'width':400,'height':230,'scale':2})
    check(len(h.scene)==nodes,'resize preserves scene')
    h.post('deactivate');before=copy.deepcopy(h.scene);h.tick(key='a',beat=True)
    check(h.scene==before,'inactive plugin ignores input')
    h.activate();h.advance(60,audio=False);check(not h.laser() and not h.moving(),'reactivation resets')
    h.post('dispose')
    report=dict(checks=checks,nodeCount=nodes,drawnFrames={k:len(v) for k,v in h.seen.items()},
        scriptP95Ms=sorted(h.timings)[int(len(h.timings)*.95)],scriptMeanMs=statistics.mean(h.timings),
        fixedActorAnchors=True,constantPixelScale=True,inputs='synthetic, production Lua worker',nativeDesktopAcceptance=False)
    out=ROOT/'docs/validation/zelda-guardian.json';out.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
finally: h.close()
