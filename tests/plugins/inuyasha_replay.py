#!/usr/bin/env python3
"""Production worker replay: synchronized slapstick, input integrity and lifecycle."""
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
registration=json.loads((ROOT/'docs/concepts/inuyasha/frame-registration.json').read_text())
checks=0
def check(value,message):
    global checks
    checks+=1
    if not value:raise AssertionError(message)

class Harness:
    def __init__(self):
        self.proc=subprocess.Popen([str(worker),str(ROOT/'plugins/inuyasha')],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
        self.scene={};self.version=0;self.index=0;self.timings=[]
        self.seen={name:set() for name in registration}
        self.read();self.fixed={name:copy.deepcopy(self.scene[name+'-actor']) for name in registration}
        self.activate()
    def read(self):
        r=receive(self.proc.stdout)
        if not r.get('ok'):raise RuntimeError(r.get('error','worker failed'))
        p=r['scene']
        if p['full']:self.scene={}
        for n in p['nodes']:self.scene.setdefault(n['id'],{}).update(n)
        self.version=p['version']
        if 'updateMs' in r:self.timings.append(r['updateMs'])
        for name in self.seen:self.seen[name].add(self.pose(name))
        if hasattr(self,'fixed'):
            for name,expected in self.fixed.items():
                assert self.scene[name+'-actor']==expected,'Actor world anchor changed'
                art=self.scene[name+'-art'];rect=art['sourceRect'];a=registration[name]
                assert abs(art['width']/rect[2]-a['scale'])<1e-8 and abs(art['height']/rect[3]-a['scale'])<1e-8,'Art stretched'
                off=a['offsets'][self.pose(name)-1]
                assert abs(art['x']-off[0]*a['scale'])<1e-8 and abs(art['y']-off[1]*a['scale'])<1e-8,'Contact drifted'
    def pose(self,name):return registration[name]['rects'].index(self.scene[name+'-art']['sourceRect'])+1
    def settled(self):return all(self.pose(n) in (1,2) for n in ('inuyasha','kagome','shippo')) and self.scene['dust-art'].get('opacity',1)==0
    def post(self,op,value=None):
        send(self.proc.stdin,{'op':op,'value':value or {},'ack':self.version});self.read()
    def activate(self):self.post('activate',{'id':'inuyasha','width':800,'height':460,'scale':1})
    def sample(self,key=None,kind='pressed',held=(),beat=False,audio=True,**overrides):
        f=frame(self.index);self.index+=1
        k=f['keyboard'];k.update(events=[],heldKeys=[{'key':k,'duration':.1} for k in held],sampledAt=f['now']+.002,pressesPerSecond=0)
        if key:k['events']=[dict(sequence=k['sequence'],receivedAt=f['now']+.002,kind=kind,key=key,modifiers=0)]
        a=f['audio'];a['onsets']=[];a['frame']['receivedAt']=f['now']+.001
        a['frame']['audio']['time']+=5000
        a['beats']=[dict(sequence=a['frame']['sequence'],receivedAt=f['now']+.001,time=f['now']+5000,bpm=120,confidence=.9,strength=.8)] if beat else []
        if not audio:del f['audio']
        f.update(overrides);return f
    def tick(self,**kw):self.post('update',self.sample(**kw))
    def advance(self,n=60,**kw):
        for _ in range(n):self.tick(**kw)
    def close(self):
        if self.proc.poll() is None:self.proc.kill()
        self.proc.wait(timeout=3)

h=Harness()
try:
    topology=len(h.scene);ink=copy.deepcopy(h.scene['monitor-ink-1']['path'])
    check(not any(n.get('type')=='text' and not n['id'].startswith('label-') for n in h.scene.values()),'No dialogue or bubble text, only key labels')
    for _ in range(420):
        h.tick(audio=False);check(h.settled(),'idle blinks without invented commands')
    for key in ('a','j','space','returnKey','digit1'):
        h.activate();h.tick(key=key,audio=False);h.advance(10,audio=False)
        check(h.pose('inuyasha')==4,key+' triggers boast without music')
        check(h.pose('kagome') in (1,2) and h.pose('shippo') in (1,2),'typing cannot fabricate pointing or surprise')
        h.advance(45,audio=False);check(h.settled(),'one press finishes one boast')
    h.activate();h.tick(key='a',held=('a',),audio=False)
    check(h.scene['key-a-fill']['fill']=='#EDB09A','held key glows coral')
    for _ in range(100):h.tick(key='a',kind='repeated',held=('a',),audio=False)
    check(h.settled(),'OS repeat cannot create endless boasting')
    h.tick(key='a',kind='released',audio=False)
    check(h.scene['key-a-fill']['fill']=='#FFF7E7','release clears key')
    h.activate();f=h.sample(key='a',held=('a','j'),audio=False);f['keyboard']['sequence']+=1
    f['keyboard']['events'].append(dict(f['keyboard']['events'][0],sequence=f['keyboard']['sequence'],key='j'))
    h.post('update',f);check(all(h.scene['key-'+k+'-fill']['fill']=='#EDB09A' for k in ('a','j')),'chord highlights both keys')
    for mutate,label in [
        (lambda f:f['keyboard'].update(state='secureInput'),'secure input'),
        (lambda f:f['keyboard'].update(sampledAt=f['now']-.5),'stale snapshot'),
        (lambda f:f['keyboard'].update(droppedEventCount=3),'lost events'),
        (lambda f:f['keyboard']['events'][0].update(receivedAt=f['now']-.5),'expired press'),
        (lambda f:f['keyboard']['events'][0].update(receivedAt=f['now']+1),'future press'),
    ]:
        h.activate();f=h.sample(key='a',audio=False);mutate(f);h.post('update',f);h.advance(10,audio=False)
        check(h.settled(),label+' cannot trigger boast')
    h.activate();f=h.sample(key='leftShift',audio=False);f['keyboard']['modifiers']=1
    f['keyboard']['events'][0].update(kind='modifiersChanged',modifierIsPressed=True)
    h.post('update',f);h.advance(10,audio=False);check(h.pose('inuyasha')==4,'modifier triggers boast')
    h.activate();f=h.sample(key='a',audio=False);h.post('update',f);h.advance(50,audio=False)
    f['now']=h.sample(audio=False)['now'];f['keyboard']['sampledAt']=f['now'];f['keyboard']['events'][0]['receivedAt']=f['now']
    h.post('update',f);h.advance(10,audio=False);check(h.settled(),'duplicate keyboard sequence ignored')
    h.activate()
    for _ in range(80):
        f=h.sample(audio=False);f['keyboard']['pressesPerSecond']=200;h.post('update',f)
    check(h.settled(),'typing summary cannot invent events')

    h.activate();h.tick(beat=True);h.advance(30)
    check(h.pose('inuyasha')==9 and h.pose('kagome')==8 and h.pose('shippo')==4,'point, fall and surprise synchronize at impact')
    check(h.scene['dust-art']['opacity']==1,'impact dust visible at contact')
    h.tick(key='a');check(h.pose('inuyasha') in (9,10),'typing cannot interrupt fall')
    h.advance(45);check(h.pose('inuyasha')==13,'fallen character pushes up before standing')
    h.advance(50);check(h.settled(),'complete recovery returns to idle')
    h.activate()
    for i in range(120):h.tick(beat=i%30==0)
    check(h.settled(),'beats two through four cannot restart command')
    h.tick(beat=True);h.advance(30);check(h.pose('inuyasha')==9,'fifth beat starts a fresh command')
    for mutate,label in [
        (lambda f:f['audio']['frame']['audio'].update(isSilent=True),'silence'),
        (lambda f:f['audio']['beats'][0].update(confidence=.2),'low confidence'),
        (lambda f:f['audio']['beats'][0].update(strength=.2),'weak beat'),
        (lambda f:f['audio']['beats'][0].update(bpm=250),'invalid tempo'),
        (lambda f:f['audio']['beats'][0].update(receivedAt=f['now']-.5),'expired beat'),
        (lambda f:f['audio']['beats'][0].update(receivedAt=f['now']+1),'future beat'),
        (lambda f:f['audio'].update(frameAge=.8),'old audio'),
        (lambda f:f['audio'].update(droppedBeatCount=2),'lost beats'),
        (lambda f:f['audio']['frame'].update(sessionID='wrong'),'wrong session'),
    ]:
        h.activate();f=h.sample(beat=True);mutate(f);h.post('update',f);h.advance(30)
        check(h.settled(),label+' cannot trigger command')
    h.activate();f=h.sample(beat=True);h.post('update',f);h.advance(130)
    f['now']=h.sample()['now'];f['audio']['frame']['receivedAt']=f['now'];f['audio']['frame']['audio']['time']=f['now']+5000
    f['audio']['beats'][0]['receivedAt']=f['now'];h.post('update',f);h.advance(30)
    check(h.settled(),'duplicate beat ignored')
    h.activate();h.tick(beat=True);h.advance(20)
    f=h.sample();f['audio'].update(state='recovering',frame=None,frameAge=None,beats=[]);h.post('update',f);h.advance(10,audio=False)
    check(h.pose('inuyasha') in (9,10),'audio loss finishes already-started physical action')
    h.advance(160,audio=False);check(h.settled(),'audio loss leaves no queued command')
    h.activate();f=h.sample(beat=True);f['keyboard']['state']='secureInput';h.post('update',f);h.advance(30)
    check(h.pose('inuyasha')==9,'keyboard loss does not stop beat action')
    h.activate();h.tick(key='a',audio=False);h.advance(10,audio=False)
    check(h.pose('inuyasha')==4,'audio absence preserves typing response')
    f=h.sample(beat=True);f['audio']['sessionID']='new';f['audio']['frame'].update(sessionID='new',sequence=1);f['audio']['beats'][0]['sequence']=1
    h.post('update',f)
    for i in range(30):
        f=h.sample();f['audio']['sessionID']='new';f['audio']['frame'].update(sessionID='new',sequence=i+2);h.post('update',f)
    check(h.pose('inuyasha')==9,'new audio session accepts fresh low sequence')
    h.tick(key='j',beat=True,deltaTime=2);check(h.settled(),'long stall clears all action backlogs')
    # Busy at beat five under 200 BPM: never restart mid-recovery.
    h.activate()
    for i in range(85):
        f=h.sample(beat=i%18==0)
        for b in f['audio']['beats']:b['bpm']=200
        h.post('update',f)
    check(h.pose('inuyasha')==14,'high BPM cannot interrupt recovery')
    h.advance(180);check(h.settled(),'busy command is discarded, not queued')
    h.activate()
    for i in range(900):
        phase=i%90;key='a' if i//90%2==0 else 'j'
        h.tick(key=key if phase==0 else None,held=(key,) if phase<8 else (),beat=i%30==0)
    h.advance(150,audio=False)
    check(len(h.scene)==topology,'15 seconds of mixed input keeps fixed node count')
    check({k:len(v) for k,v in h.seen.items()}=={'inuyasha':16,'kagome':12,'shippo':8,'dust':4},'all 40 drawn frames are reachable')
    for i in range(240):h.tick(key='a' if i%2 else 'j',audio=False)
    h.advance(100,audio=False);check(h.settled(),'fast typing leaves no accumulated boast')
    check(h.scene['monitor-ink-1']['path']==ink,'static outlines do not jitter')
    h.post('appearanceChanged',{'opacity':.4,'ink':'#000000'});check(h.scene['inuyasha']['opacity']==.4,'host opacity retained')
    h.post('resize',{'width':400,'height':230,'scale':2});check(len(h.scene)==topology,'resize preserves scene')
    h.post('deactivate');before=copy.deepcopy(h.scene);h.tick(key='a',beat=True);check(h.scene==before,'inactive skin ignores input')
    h.activate();check(h.settled(),'reactivation resets to idle')
    h.post('dispose')
    report=dict(checks=checks,nodeCount=topology,drawnFrames={k:len(v) for k,v in h.seen.items()},
        scriptP95Ms=sorted(h.timings)[int(len(h.timings)*.95)],scriptMeanMs=statistics.mean(h.timings),
        fixedActorAnchors=True,constantPixelScale=True,noDialogueText=True,
        inputs='synthetic, production Lua worker',nativeDesktopAcceptance=False)
    (ROOT/'docs/validation/inuyasha.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
finally:h.close()
