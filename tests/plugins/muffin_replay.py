#!/usr/bin/env python3
"""Muffin skin: deterministic production-worker input/lifecycle regressions."""
import copy
import json
import pathlib
import statistics
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/plugins'))
from wire import send, receive
from preview import frame

worker = ROOT / ('build/plugins/Release/miucs-plugin-worker.exe' if sys.platform == 'win32' else 'build/plugins/miucs-plugin-worker')
package = ROOT / 'plugins/muffin-puppies'
checks = 0

def check(value, message):
    global checks
    checks += 1
    if not value:
        raise AssertionError(message)

class Harness:
    def __init__(self):
        self.proc = subprocess.Popen([str(worker), str(package)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.scene, self.version, self.index, self.timings = {}, 0, 0, []
        self.read()
        self.idle={side:tuple(self.scene[side+'-dog']['sourceRect']) for side in ('left','right')}
        self.fixed={side:self.transform(side) for side in ('left','right')}
        self.seen={side:set() for side in ('left','right')}
        self.activate()
    def read(self):
        r = receive(self.proc.stdout)
        if not r.get('ok'):
            raise RuntimeError(r.get('error', 'worker failed'))
        p = r['scene']
        if p['full']:
            self.scene = {}
        for n in p['nodes']:
            self.scene.setdefault(n['id'], {}).update(n)
        self.version = p['version']
        if 'updateMs' in r:
            self.timings.append(r['updateMs'])
        if hasattr(self, 'fixed'):
            for side in ('left','right'):
                assert self.transform(side)==self.fixed[side], 'Dog transform must remain constant during frame playback'
                self.seen[side].add(tuple(self.scene[side+'-dog']['sourceRect']))
    def transform(self, side):
        n=self.scene[side+'-dog']
        return tuple(n.get(k,default) for k,default in [('x',0),('y',0),('width',0),('height',0),('scaleX',1),('scaleY',1),('rotation',0)])
    def jumping(self, side):
        return tuple(self.scene[side+'-dog']['sourceRect'])!=self.idle[side]
    def post(self, op, value=None):
        send(self.proc.stdin, {'op': op, 'value': value or {}, 'ack': self.version})
        self.read()
    def activate(self):
        self.post('activate', {'id': 'muffin-puppies', 'width': 800, 'height': 460, 'scale': 1})
    def sample(self, key=None, kind='pressed', held=(), beat=False, audio=True, **kw):
        f = frame(self.index)
        self.index += 1
        f['keyboard'].update(events=[], heldKeys=[{'key': k, 'duration': .1} for k in held],
                             pressesPerSecond=0, sampledAt=f['now']+.002)
        if key:
            f['keyboard']['events'] = [{'sequence': f['keyboard']['sequence'], 'receivedAt': f['now']+.002,
                                       'kind': kind, 'key': key, 'modifiers': 0}]
        # Deliberately separate the audio PCM clock from host monotonic time.
        f['audio']['frame']['audio']['time'] += 5000
        f['audio']['frame']['receivedAt'] = f['now']+.001
        f['audio']['onsets'] = []
        e = dict(sequence=f['audio']['frame']['sequence'], receivedAt=f['now']+.001,
                 time=f['now']+5000, bpm=120., confidence=.9, strength=.8)
        f['audio']['beats'] = [e] if beat else []
        if not audio:
            del f['audio']
        f.update(kw)
        return f
    def tick(self, **kw):
        self.post('update', self.sample(**kw))
    def advance(self, n=45, **kw):
        for _ in range(n):
            self.tick(**kw)
    def bubbles(self):
        return [n for i in range(1,9) if (n:=self.scene[f'bubble-{i}']).get('opacity',0)>0]
    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=3)

h = Harness()
try:
    topology = len(h.scene)
    static_ink = copy.deepcopy(h.scene['monitor-ink-1']['path'])
    h.advance(120, audio=False)
    check(not h.jumping('left') and not h.jumping('right'), 'idle dogs stay still')
    check(not h.bubbles(), 'no fabricated beats in silence')
    h.tick(key='a', held=('a',), audio=False)
    h.advance(12, held=('a',), audio=False)
    check(h.jumping('left'), 'left key jumps Maltese including positive snapshot skew')
    check(not h.jumping('right'), 'left key does not jump retriever')
    check(h.scene['key-a-fill']['fill'] == '#F0AF96', 'physical held key remains highlighted')
    for _ in range(100):
        h.tick(key='a', kind='repeated', held=('a',), audio=False)
    check(not h.jumping('left'), 'held repeat cannot retrigger jump')
    h.tick(key='a', kind='released', audio=False)
    h.advance(20, audio=False)
    check(h.scene['key-a-fill']['fill'] == '#FFF9EE', 'release clears highlight')
    check(abs(h.scene['left-paw']['x']-(118+45/2-18)) < .1, 'released paw stays at last key')
    for key in ('h','digit6','returnKey'):
        h.activate();h.tick(key=key, audio=False);h.advance(12, audio=False)
        check(h.jumping('right') and not h.jumping('left'), key+' maps to right side')
    h.activate()
    h.tick(key='space', audio=False);h.advance(55, audio=False)
    h.tick(key='space', audio=False);h.advance(12, audio=False)
    check(h.jumping('right'), 'space alternates hands')
    h.activate()
    f=h.sample(key='a', held=('a','j'))
    f['keyboard']['sequence']+=1
    e=dict(f['keyboard']['events'][0], sequence=f['keyboard']['sequence'], key='j')
    f['keyboard']['events'].append(e)
    h.post('update',f);h.advance(12,held=('a','j'))
    check(h.jumping('left') and h.jumping('right'), 'simultaneous independent jumps')
    h.activate()
    f=h.sample(key='leftShift');f['keyboard'].update(modifiers=1)
    f['keyboard']['events'][0].update(kind='modifiersChanged', modifierIsPressed=True)
    h.post('update',f);h.advance(12)
    check(h.jumping('left'), 'modifier press triggers correct dog')
    for mutate,label in [
        (lambda f:f['keyboard']['events'][0].update(receivedAt=f['now']-.5),'stale'),
        (lambda f:f['keyboard'].update(state='secureInput'),'secure input'),
        (lambda f:f['keyboard'].update(droppedEventCount=3),'dropped queue'),
        (lambda f:f['keyboard'].update(sampledAt=f['now']-.5),'stale snapshot'),
    ]:
        h.activate();f=h.sample(key='a',audio=False);mutate(f);h.post('update',f);h.advance(15,audio=False)
        check(not h.jumping('left'),label+' cannot jump')
    h.activate();f=h.sample(key='a',audio=False);h.post('update',f);h.advance(50,audio=False)
    f['now']=h.sample(audio=False)['now'];f['keyboard']['sampledAt']=f['now'];f['keyboard']['events'][0]['receivedAt']=f['now']
    h.post('update',f);h.advance(12,audio=False)
    check(not h.jumping('left'),'duplicate sequence cannot jump')
    h.activate()
    f=h.sample();f['keyboard']['pressesPerSecond']=200
    for _ in range(60):
        f['now']+=1/60;f['keyboard']['sampledAt']=f['now'];h.post('update',f)
    check(not h.jumping('left') and not h.jumping('right'),'typing summary alone cannot invent presses')
    h.activate();h.tick(beat=True);h.advance(10)
    check(len(h.bubbles())==1,'one reliable beat makes one bubble')
    check(h.scene['muffin']['sourceRect'][1]==546,'beat selects blowing pose')
    first=copy.deepcopy(h.bubbles()[0]);h.advance(12)
    check(h.bubbles()[0]['x']<first['x'] and h.bubbles()[0]['y']<first['y'],'detached bubble floats upper left')
    h.advance(120)
    check(not h.bubbles() and h.scene['muffin']['sourceRect'][1]==58,'bubbles expire and Muffin rests')
    for mutate,label in [
        (lambda f:f['audio']['frame']['audio'].update(isSilent=True),'silent'),
        (lambda f:f['audio']['beats'][0].update(confidence=.2),'unreliable'),
        (lambda f:f['audio']['beats'][0].update(receivedAt=f['now']-.5),'old beat'),
        (lambda f:f['audio'].update(frameAge=.8),'old frame'),
        (lambda f:f['audio'].update(droppedBeatCount=2),'dropped beats'),
        (lambda f:f['audio']['frame'].update(sessionID='wrong'),'wrong session'),
    ]:
        h.activate();f=h.sample(beat=True);mutate(f);h.post('update',f)
        check(not h.bubbles(),label+' cannot blow bubble')
    h.activate();f=h.sample(beat=True);h.post('update',f);h.advance(15)
    f['now']=h.sample()['now'];f['audio']['frame']['receivedAt']=f['now'];f['audio']['beats'][0]['receivedAt']=f['now']
    h.post('update',f)
    check(len(h.bubbles())==1,'duplicate beat cannot emit twice')
    # Disconnect without changing session and with no frame: must not read missing PCM time.
    f=h.sample();f['audio'].update(state='recovering',frame=None,frameAge=None,beats=[])
    h.post('update',f);h.tick(key='j');h.advance(12)
    check(h.jumping('right'),'audio interruption leaves keyboard independent')
    f=h.sample(beat=True);f['keyboard'].update(state='secureInput')
    h.post('update',f)
    check(len(h.bubbles())>=1,'keyboard unavailable leaves audio independent')
    # New audio session accepts low sequence, regardless of previous high cursor.
    f=h.sample(beat=True)
    f['audio']['sessionID']='new';f['audio']['frame'].update(sessionID='new',sequence=1)
    f['audio']['beats'][0]['sequence']=1
    h.post('update',f)
    check(len(h.bubbles())==1,'audio reconnection resets only audio cursor')
    h.activate();h.tick(key='a',beat=True)
    f=h.sample(key='j',beat=True,deltaTime=2)
    h.post('update',f)
    check(not h.bubbles() and not h.jumping('left') and not h.jumping('right'),'stall settles and discards backlog')
    h.activate()
    max_bubbles=0
    for i in range(1800):
        h.tick(key=('a' if i%2 else 'j') if i%3==0 else None,beat=i%18==0)
        max_bubbles=max(max_bubbles,len(h.bubbles()))
    check(max_bubbles<=8 and len(h.scene)==topology,'30 second stress has fixed node count and bounded bubbles')
    check(all(len(h.seen[side])==16 for side in ('left','right')), 'all 16 model-drawn frames play for both dogs')
    check(all(h.transform(side)==h.fixed[side] for side in ('left','right')), 'frame playback never translates, scales, or rotates dogs')
    check(h.scene['monitor-ink-1']['path']==static_ink,'broken ink never jitters between frames')
    h.post('appearanceChanged',{'opacity':.4,'ink':'#000000'})
    check(h.scene['muffin-puppies']['opacity']==.4,'host opacity supported')
    h.post('resize',{'width':400,'height':230,'scale':2})
    check(len(h.scene)==topology,'resize does not rebuild scene')
    h.post('deactivate');before=copy.deepcopy(h.scene);h.tick(key='a',beat=True)
    check(h.scene==before,'inactive plugin ignores input')
    h.activate();h.advance(60,audio=False)
    check(not h.bubbles() and not h.jumping('left'),'reactivation starts settled')
    h.post('dispose')
    report={'checks':checks,'nodeCount':topology,'maxBubbles':max_bubbles,'scriptP95Ms':sorted(h.timings)[int(len(h.timings)*.95)],
            'scriptMeanMs':statistics.mean(h.timings),'inputs':'synthetic, production Lua worker',
            'nativeDesktopAcceptance':False, 'drawnFramesPerDog':16, 'fixedDogTransforms':True}
    out=ROOT/'build/muffin-preview';out.mkdir(exist_ok=True)
    (out/'tests.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2))
finally:
    h.close()
