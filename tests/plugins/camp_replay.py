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
        self.proc=subprocess.Popen([str(worker),str(ROOT/'plugins/yuru-camp')],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
        self.scene={};self.version=0;self.index=0;self.timings=[]
        self.seen={name:set() for name in ('nadeshiko','rin','fire','left-paw','right-paw')}
        self.read()
        self.rest={name:tuple(self.scene[name+'-art']['sourceRect']) for name in ('nadeshiko','rin','fire')}
        self.fixed={name:copy.deepcopy(self.scene[name]) for name in ('nadeshiko','rin','fire')}
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
                scale={'nadeshiko':.42,'rin':.45,'fire':.32}[name]
                assert abs(art['width']/rect[2]-scale)<1e-8 and abs(art['height']/rect[3]-scale)<1e-8, 'Frame art stretched'
    def post(self,op,value=None):
        send(self.proc.stdin,{'op':op,'value':value or {},'ack':self.version});self.read()
    def activate(self): self.post('activate',{'id':'yuru-camp','width':800,'height':460,'scale':1})
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
    def moving(self,name='nadeshiko'): return tuple(self.scene[name+'-art']['sourceRect'])!=self.rest[name]
    def close(self):
        if self.proc.poll() is None: self.proc.kill()
        self.proc.wait(timeout=3)

h=Harness()
try:
    topology=len(h.scene);ink=copy.deepcopy(h.scene['monitor-ink-1']['path'])
    h.advance(120,audio=False)
    check(not any(h.moving(n) for n in h.rest),'idle has no invented eating, sipping or flicker')
    for key in ('a','j','space','returnKey','digit1'):
        h.activate();h.tick(key=key,audio=False);h.advance(10,audio=False)
        check(h.moving(),key+' triggers eating without music')
        check(not h.moving('rin') and not h.moving('fire'),'keyboard leaves music actors alone')
        h.advance(90,audio=False);check(not h.moving(),'one press finishes one complete bite')
    h.activate();h.tick(key='a',held=('a',),audio=False);h.advance(12,held=('a',),audio=False)
    check(h.scene['key-a-fill']['fill']=='#F5C98E','held key lights warm apricot')
    for _ in range(120): h.tick(key='a',kind='repeated',held=('a',),audio=False)
    check(not h.moving(),'held repeat cannot create endless eating')
    h.tick(key='a',kind='released',audio=False);h.advance(20,audio=False)
    check(h.scene['key-a-fill']['fill']=='#FFF9EE','release clears key')
    h.activate();f=h.sample(key='a',held=('a','j'),audio=False)
    f['keyboard']['sequence']+=1
    f['keyboard']['events'].append(dict(f['keyboard']['events'][0],sequence=f['keyboard']['sequence'],key='j'))
    h.post('update',f);h.advance(12,held=('a','j'),audio=False)
    check(h.moving() and all(h.scene['key-'+k+'-fill']['fill']=='#F5C98E' for k in ('a','j')),'chord keeps both keys lit, one eating action')
    for mutate,label in [
        (lambda f:f['keyboard'].update(state='secureInput'),'secure input'),
        (lambda f:f['keyboard'].update(sampledAt=f['now']-.5),'stale snapshot'),
        (lambda f:f['keyboard'].update(droppedEventCount=3),'lost events'),
        (lambda f:f['keyboard']['events'][0].update(receivedAt=f['now']-.5),'expired press'),
    ]:
        h.activate();f=h.sample(key='a',audio=False);mutate(f);h.post('update',f);h.advance(10,audio=False)
        check(not h.moving(),label+' cannot trigger eating')
    h.activate();f=h.sample(key='leftShift',audio=False);f['keyboard']['modifiers']=1
    f['keyboard']['events'][0].update(kind='modifiersChanged',modifierIsPressed=True)
    h.post('update',f);h.advance(10,audio=False);check(h.moving(),'modifier works')
    h.activate();f=h.sample(key='a',audio=False);h.post('update',f);h.advance(100,audio=False)
    f['now']=h.sample(audio=False)['now'];f['keyboard']['sampledAt']=f['now'];f['keyboard']['events'][0]['receivedAt']=f['now']
    h.post('update',f);h.advance(10,audio=False);check(not h.moving(),'duplicate press ignored')
    h.activate()
    for _ in range(80):
        f=h.sample(audio=False);f['keyboard']['pressesPerSecond']=200;h.post('update',f)
    check(not h.moving(),'typing summary alone cannot invent presses')

    h.activate();h.tick(beat=True);h.advance(9)
    check(h.moving('rin') and h.moving('fire'),'first reliable beat triggers drawn sip and flame')
    check(not h.moving(),'music cannot make Nadeshiko eat')
    h.advance(100)
    check(not h.moving('rin') and not h.moving('fire'),'without more events music actors settle')
    for _ in range(100):
        h.tick();check(not h.moving('fire'),'no predicted or fabricated beats')
    h.activate()
    for i in range(120): h.tick(beat=i%30==0)
    check(not h.moving('rin'),'beats two through four do not restart the first sip')
    h.tick(beat=True);h.advance(9)
    check(h.moving('rin'),'fifth beat starts the next relaxed sip')
    for mutate,label in [
        (lambda f:f['audio']['frame']['audio'].update(isSilent=True),'silence'),
        (lambda f:f['audio']['beats'][0].update(confidence=.2),'low confidence'),
        (lambda f:f['audio']['beats'][0].update(bpm=250),'invalid tempo'),
        (lambda f:f['audio']['beats'][0].update(receivedAt=f['now']-.5),'expired beat'),
        (lambda f:f['audio'].update(frameAge=.8),'old audio'),
        (lambda f:f['audio'].update(droppedBeatCount=2),'lost beats'),
        (lambda f:f['audio']['frame'].update(sessionID='wrong'),'wrong session'),
    ]:
        h.activate();f=h.sample(beat=True);mutate(f);h.post('update',f);h.advance(9)
        check(not h.moving('rin') and not h.moving('fire'),label+' cannot animate music actors')
    h.activate();f=h.sample(beat=True);h.post('update',f);h.advance(100)
    # Refresh host and PCM clocks but retain the original sequence.
    f['now']=h.sample()['now'];f['audio']['frame']['receivedAt']=f['now'];f['audio']['frame']['audio']['time']=f['now']+5000
    f['audio']['beats'][0]['receivedAt']=f['now'];h.post('update',f);h.advance(9)
    check(not h.moving('rin') and not h.moving('fire'),'duplicate beat ignored')
    h.activate();h.tick(key='a',beat=True);h.advance(9)
    f=h.sample();f['audio'].update(state='recovering',frame=None,frameAge=None,beats=[]);h.post('update',f)
    check(h.moving() and not h.moving('rin') and not h.moving('fire'),'audio disconnect affects only music actors')
    f=h.sample(beat=True);f['keyboard']['state']='secureInput';h.post('update',f);h.advance(9)
    check(not h.moving() and h.moving('rin') and h.moving('fire'),'keyboard loss does not stop music')
    f=h.sample(beat=True);f['audio']['sessionID']='new';f['audio']['frame'].update(sessionID='new',sequence=1);f['audio']['beats'][0]['sequence']=1
    h.post('update',f)
    for i in range(9):
        f=h.sample();f['audio']['sessionID']='new';f['audio']['frame'].update(sessionID='new',sequence=i+2);h.post('update',f)
    check(h.moving('rin') and h.moving('fire'),'fresh low-sequence beat works after audio reconnect')
    check(h.scene['nadeshiko']==h.fixed['nadeshiko'],'audio reconnect preserves character placement')
    h.tick(key='j',beat=True,deltaTime=2)
    check(not any(h.moving(n) for n in h.rest),'long stall settles all actors')

    h.activate()
    for i in range(1800):
        phase=i%90;key='a' if i//90%2==0 else 'j'
        h.tick(key=key if phase==0 else None,held=(key,) if phase<8 else (),beat=i%30==0)
    check(len(h.scene)==topology,'30 seconds of input keeps fixed node count')
    check({n:len(h.seen[n]) for n in ('nadeshiko','rin','fire')}=={'nadeshiko':12,'rin':12,'fire':8},'all 32 scene frames play')
    check(all(len(h.seen[n])==4 for n in ('left-paw','right-paw')),'all eight mitten frames play')
    # The final rebound frame has a registered orientation correction only.
    h.activate();h.tick(key='a',held=('a',),audio=False);h.advance(8,held=('a',),audio=False)
    h.tick(key='a',kind='released',audio=False)
    check(h.scene['left-paw-art']['scaleX']==-1,'rebound thumb remains on the same side')
    h.advance(30,audio=False);check(h.scene['left-paw-art']['scaleX']==1,'rest restores normal source orientation')
    for i in range(240): h.tick(key='a' if i%2 else 'j',audio=False)
    h.advance(150,audio=False);check(not h.moving(),'fast typing cannot accumulate bites')
    check(h.scene['monitor-ink-1']['path']==ink,'static keyboard outline never jitters')
    h.post('appearanceChanged',{'opacity':.4,'ink':'#000000'})
    check(h.scene['yuru-camp']['opacity']==.4,'host opacity retained')
    h.post('resize',{'width':400,'height':230,'scale':2})
    check(len(h.scene)==topology,'resize preserves scene')
    h.post('deactivate');before=copy.deepcopy(h.scene);h.tick(key='a',beat=True)
    check(h.scene==before,'inactive plugin ignores input')
    h.activate();h.advance(60,audio=False);check(not any(h.moving(n) for n in h.rest),'reactivation starts settled')
    h.post('dispose')
    report=dict(checks=checks,nodeCount=topology,drawnFrames={k:len(v) for k,v in h.seen.items()},
        scriptP95Ms=sorted(h.timings)[int(len(h.timings)*.95)],scriptMeanMs=statistics.mean(h.timings),
        fixedActorAnchors=True,constantPixelScale=True,inputs='synthetic, production Lua worker',nativeDesktopAcceptance=False)
    (ROOT/'docs/validation/yuru-camp.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
finally: h.close()
