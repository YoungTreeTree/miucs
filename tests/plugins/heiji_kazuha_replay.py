#!/usr/bin/env python3
"""Replay real worker inputs: cadence, channel independence, expiry and recovery."""
import copy
import json
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/plugins'))
from preview import frame
from wire import send, receive

worker = ROOT / ('build/plugins/Release/miucs-plugin-worker.exe' if sys.platform == 'win32' else 'build/plugins/miucs-plugin-worker')
package = ROOT / 'plugins/heiji-kazuha'
checks = 0


def check(value, label):
    global checks
    checks += 1
    if not value:
        raise AssertionError(label)


class Harness:
    def __init__(self):
        self.proc = subprocess.Popen([str(worker), str(package)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.scene, self.version, self.index, self.timings = {}, 0, 0, []
        self.read()
        self.rest = {name: self.pose(name) for name in ('heiji', 'kazuha')}
        self.seen = {name: set() for name in self.rest}
        self.activate()

    def pose(self, name):
        return tuple(self.scene[name]['sourceRect'])

    def moving(self, name):
        return self.pose(name) != self.rest[name]

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
        if hasattr(self, 'seen'):
            for name in self.rest:
                self.seen[name].add(self.pose(name))

    def post(self, op, value=None):
        send(self.proc.stdin, {'op': op, 'value': value or {}, 'ack': self.version})
        self.read()

    def activate(self):
        self.post('activate', {'id': 'heiji-kazuha', 'width': 800, 'height': 460, 'scale': 1})

    def sample(self, key=None, kind='pressed', held=(), beat=False, bpm=120, audio=True):
        f = frame(self.index)
        self.index += 1
        f['keyboard'].update(events=[], heldKeys=[{'key': k, 'duration': .1} for k in held],
                             pressesPerSecond=0, sampledAt=f['now']+.002)
        if key:
            f['keyboard']['events'] = [dict(sequence=f['keyboard']['sequence'], receivedAt=f['now']+.002,
                                           kind=kind, key=key, modifiers=0)]
        f['audio']['frame']['audio']['time'] += 5000
        f['audio']['frame']['receivedAt'] = f['now']+.001
        f['audio']['onsets'] = []
        f['audio']['beats'] = [dict(sequence=f['audio']['frame']['sequence'], receivedAt=f['now']+.001,
                                  time=f['now']+5000, bpm=bpm, confidence=.9, strength=.8)] if beat else []
        if not audio:
            del f['audio']
        return f

    def tick(self, **kw):
        self.post('update', self.sample(**kw))

    def advance(self, n=60, **kw):
        for _ in range(n):
            self.tick(**kw)

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=3)


h = Harness()
try:
    topology = len(h.scene)
    h.advance(120, audio=False)
    check(not h.moving('heiji') and not h.moving('kazuha'), 'no fake motion without inputs')
    h.tick(key='a', held=('a',), audio=False)
    h.advance(12, held=('a',), audio=False)
    check(h.moving('heiji') and not h.moving('kazuha'), 'typing drives only sword')
    check(h.scene['key-top-a']['fill'] == '#E9A6AA', 'held physical key stays pink')
    for _ in range(100):
        h.tick(key='a', kind='repeated', held=('a',), audio=False)
    check(not h.moving('heiji'), 'OS repeat cannot keep swinging')
    h.tick(key='a', kind='released', audio=False)
    check(h.scene['key-top-a']['fill'] == '#F7F1E4', 'release restores cream')
    for key in ('j', 'space', 'returnKey'):
        h.activate(); h.tick(key=key, audio=False); h.advance(12, audio=False)
        check(h.moving('heiji'), 'all keyboard regions swing: ' + key)
    h.activate()
    f = h.sample(key='leftShift', audio=False)
    f['keyboard']['modifiers'] = 1
    f['keyboard']['events'][0].update(kind='modifiersChanged', modifierIsPressed=True)
    h.post('update', f); h.advance(12, audio=False)
    check(h.moving('heiji'), 'modifier press swings')
    for mutate, label in [
        (lambda f: f['keyboard']['events'][0].update(receivedAt=f['now']-.5), 'stale key'),
        (lambda f: f['keyboard'].update(state='secureInput'), 'secure input'),
        (lambda f: f['keyboard'].update(droppedEventCount=2), 'dropped queue'),
        (lambda f: f['keyboard'].update(sampledAt=f['now']-.5), 'stale snapshot'),
    ]:
        h.activate(); f = h.sample(key='a', audio=False); mutate(f); h.post('update', f); h.advance(12, audio=False)
        check(not h.moving('heiji'), label + ' cannot swing')
    h.activate(); f = h.sample(key='a', audio=False); h.post('update', f); h.advance(60, audio=False)
    f['now'] = h.sample(audio=False)['now']; f['keyboard']['sampledAt'] = f['now']
    f['keyboard']['events'][0]['receivedAt'] = f['now']
    h.post('update', f); h.advance(12, audio=False)
    check(not h.moving('heiji'), 'duplicate press sequence cannot retrigger')
    h.activate()
    for _ in range(60):
        f = h.sample(audio=False); f['keyboard']['pressesPerSecond'] = 200; h.post('update', f)
    check(not h.moving('heiji'), 'summary rate without fresh presses invents no swings')

    def swing_count(interval):
        h.activate(); count = 0; previous = False
        for i in range(360):
            h.tick(key='a' if i % interval == 0 else None, audio=False)
            moving = h.moving('heiji')
            if moving and not previous:
                count += 1
            previous = moving
        h.advance(90, audio=False)
        check(not h.moving('heiji'), 'typing stops without a long animation backlog')
        return count

    slow, fast = swing_count(45), swing_count(5)
    check(fast > slow, 'frequent presses produce faster complete swings')
    h.activate(); h.tick(beat=True); h.advance(15)
    check(h.moving('kazuha') and not h.moving('heiji'), 'beat drives only dancer')
    h.advance(150)
    check(not h.moving('kazuha'), 'one beat cannot create perpetual rotation')
    for mutate, label in [
        (lambda f: f['audio']['frame']['audio'].update(isSilent=True), 'silent audio'),
        (lambda f: f['audio']['beats'][0].update(confidence=.2), 'unreliable beat'),
        (lambda f: f['audio']['beats'][0].update(receivedAt=f['now']-.5), 'stale beat'),
        (lambda f: f['audio'].update(frameAge=.8), 'stale audio frame'),
        (lambda f: f['audio'].update(droppedBeatCount=3), 'dropped beat queue'),
        (lambda f: f['audio']['frame'].update(sessionID='wrong'), 'wrong session'),
    ]:
        h.activate(); f = h.sample(beat=True); mutate(f); h.post('update', f); h.advance(15)
        check(not h.moving('kazuha'), label + ' cannot turn')
    h.activate(); f = h.sample(beat=True); h.post('update', f); h.advance(150)
    f['now'] = h.sample()['now']; f['audio']['frame']['receivedAt'] = f['now']
    f['audio']['beats'][0]['receivedAt'] = f['now']
    h.post('update', f); h.advance(15)
    check(not h.moving('kazuha'), 'duplicate beat cannot restart turn')

    def turn_count(bpm):
        h.activate(); count = 0; previous = False
        for i in range(360):
            h.tick(beat=i % int(3600/bpm) == 0, bpm=bpm)
            moving = h.moving('kazuha')
            if not moving and previous:
                count += 1
            previous = moving
        return count

    slow_turns, fast_turns = turn_count(60), turn_count(120)
    check(fast_turns >= slow_turns * 2 - 1 and fast_turns > slow_turns, 'turn speed follows beat tempo')
    h.activate(); h.tick(beat=True); h.advance(12)
    phase = h.pose('kazuha'); h.tick(beat=True)
    check(h.pose('kazuha') == phase, 'new beat does not snap dancer to front')
    f = h.sample(key='a'); f['audio'].update(state='recovering', frame=None, frameAge=None)
    h.post('update', f); h.advance(12, audio=False)
    check(h.moving('heiji'), 'audio loss leaves keyboard working')
    h.activate(); f = h.sample(beat=True); f['keyboard'].update(state='secureInput')
    h.post('update', f); h.advance(12)
    check(h.moving('kazuha'), 'keyboard loss leaves music working')
    h.activate(); h.tick(key='a'); h.advance(10)
    f = h.sample(beat=True); f['audio']['sessionID'] = 'new'
    f['audio']['frame'].update(sessionID='new', sequence=1); f['audio']['beats'][0]['sequence'] = 1
    h.post('update', f)
    check(h.moving('heiji'), 'new audio session preserves sword motion')
    # Keep the new session long enough to see its low-sequence beat advance.
    for _ in range(12):
        f = h.sample(); f['audio']['sessionID'] = 'new'; f['audio']['frame']['sessionID'] = 'new'; h.post('update', f)
    check(h.moving('kazuha'), 'new audio session accepts low sequence')
    f = h.sample(key='j', beat=True); f['deltaTime'] = 2; h.post('update', f)
    check(not h.moving('heiji') and not h.moving('kazuha'), 'stall resets both without replaying backlog')
    h.activate()
    for i in range(1800):
        h.tick(key='a' if i % 5 == 0 else None, beat=i % 30 == 0)
        for name in ('heiji', 'kazuha'):
            n = h.scene[name]
            check(40 <= n['x'] and n['x']+n['width'] <= 760 and 14 <= n['y'] and n['y']+n['height'] <= 158,
                  name + ' complete art stays inside display')
    check(len(h.scene) == topology, '30 second stress retains fixed scene size')
    check(len(h.seen['heiji']) == 12 and len(h.seen['kazuha']) == 8, 'all generated keyframes actually play')
    h.post('appearanceChanged', {'opacity': .4, 'ink': '#000000'})
    check(h.scene['heiji-kazuha']['opacity'] == .4 and h.scene['keyboard-top']['fill'] == '#344763', 'host opacity preserves skin palette')
    h.post('resize', {'width': 400, 'height': 230, 'scale': 2})
    check(len(h.scene) == topology, 'resize preserves scene')
    h.post('deactivate'); previous = copy.deepcopy(h.scene); h.tick(key='a', beat=True)
    check(h.scene == previous, 'inactive plugin ignores inputs')
    h.activate()
    check(not h.moving('heiji') and not h.moving('kazuha'), 'reactivation starts at rest')
    h.post('dispose')
    report = {'checks': checks, 'nodeCount': topology, 'swordFrames': 12, 'turnFrames': 8,
              'slowFastSwings': [slow, fast], 'turnsAt60And120Bpm': [slow_turns, fast_turns],
              'scriptP95Ms': sorted(h.timings)[int(len(h.timings)*.95)], 'scriptMeanMs': statistics.mean(h.timings),
              'inputs': 'synthetic, production Lua worker', 'nativeDesktopAcceptance': False}
    out = ROOT / 'build/heiji-kazuha-preview'; out.mkdir(exist_ok=True)
    (out / 'tests.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
finally:
    h.close()
