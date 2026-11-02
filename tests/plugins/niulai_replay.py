#!/usr/bin/env python3
"""Exercise Niulai's shipped entrypoint through the production Lua worker.

No captures, desktop events or system permissions: all input is synthetic. Native
resource decoding/rendering is covered separately by validate.py/surface probes.
"""
import copy
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/plugins'))
from wire import send, receive
from preview import frame

worker = ROOT / ('build/plugins/Release/miucs-plugin-worker.exe' if sys.platform == 'win32' else 'build/plugins/miucs-plugin-worker')
package = ROOT / 'plugins/niulai-keyboard'
checks = 0

def check(value, message):
    global checks
    checks += 1
    if not value:
        raise AssertionError(message)

manifest = json.loads((package / 'manifest.json').read_text(encoding='utf-8'))
check(manifest['name'] == '牛来', 'exact menu name')
check(manifest['id'] == 'niulai-keyboard', 'stable plugin identity')
check(manifest['layout']['minimumWidth'] == 80, 'original keyboard minimum scale')

with subprocess.Popen([str(worker), str(package)], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as process:
    scene = {}
    version = 0
    def response():
        global scene, version
        reply = receive(process.stdout)
        if not reply.get('ok'):
            raise RuntimeError(reply.get('error', 'worker rejected request'))
        packet = reply['scene']
        if packet['full']:
            scene = {}
        for node in packet['nodes']:
            scene.setdefault(node['id'], {}).update(node)
        for node_id in packet.get('removed', []):
            scene.pop(node_id, None)
        version = packet['version']
    def post(op, value=None):
        send(process.stdin, {'op': op, 'value': value or {}, 'ack': version})
        response()
    def activate():
        post('activate', {'id': 'niulai-keyboard', 'width': 800, 'height': 460, 'scale': 1})
    def sample(index, *, pps=0, beat=False, audio=True, key=None, held=(), event_kind='pressed'):
        f = frame(index)
        f['audio']['beats'] = f['audio']['beats'] if beat else []
        f['audio']['onsets'] = []
        if not audio:
            del f['audio']
        k = f['keyboard']
        # Actual macOS tick takes frame.now before source read() stamps sampledAt.
        k.update(sampledAt=f['now'] + .001, pressesPerSecond=pps,
                 idleDuration=0 if pps else 2, heldKeys=[{'key': h, 'duration': .1} for h in held], events=[])
        if key is not None:
            k['events'] = [dict(sequence=index + 1, receivedAt=f['now'] + .001,
                                kind=event_kind, key=key, modifiers=0)]
        return f
    def atlas_index():
        x, y, _, _ = scene['niulai-rider']['sourceRect']
        return int(y / 220) * 4 + int(x / 220)
    try:
        response()
        activate()
        for i in range(120):
            post('update', {'now': 1 + i / 60, 'deltaTime': 1 / 60})
            check(atlas_index() == 3 and scene['niulai-rider']['source'].endswith('carve.png'), 'idle must not cycle atlas')
        # Two actual beat events select opposing edges; no typing needed.
        activate()
        for i in range(60):
            post('update', sample(i, beat=i in (0, 30)))
            if i == 25:
                check(atlas_index() == 0, 'first beat must reach one edge')
        check(atlas_index() == 7, 'next beat must reach opposite edge')
        # Re-sending a consumed beat cannot reverse the edge again.
        duplicate = sample(30, beat=True)
        duplicate['now'] = 2
        duplicate['audio']['frameAge'] = .5
        post('update', duplicate)
        check(atlas_index() != 0, 'stale duplicate must not trigger opposite edge')
        jumps = []
        for speed in (1, 9):
            activate()
            count, previously_airborne = 0, False
            for i in range(600):
                post('update', sample(i, pps=speed, audio=False))
                airborne = scene['niulai-rider']['source'].endswith('jump.png')
                if airborne and not previously_airborne:
                    count += 1
                previously_airborne = airborne
            jumps.append(count)
        check(0 < jumps[0] < jumps[1] <= 11, f'typing frequency mapping/bounds: {jumps}')
        # Match original pixel-keyboard targets: release lifts in place, not home or an older hold.
        activate()
        post('update', sample(0, audio=False, key='a', held=('a', 'j')))
        post('update', sample(1, audio=False, key='s', held=('a', 's', 'j')))
        for i in range(2, 20):
            post('update', sample(i, audio=False, held=('a', 's', 'j')))
        check(scene['key-top-a']['y'] == 276 and scene['key-top-s']['y'] == 276 and scene['key-top-j']['y'] == 276, 'multiple keys stay down')
        post('update', sample(20, audio=False, key='s', event_kind='released', held=('a', 'j')))
        for i in range(21, 45):
            post('update', sample(i, audio=False, held=('a', 'j')))
        check(scene['key-top-s']['y'] == 272, 'released key returns')
        check(abs(scene['left-hoof']['x'] - (168 + 45 / 2 - 24)) < .1, 'left hoof stays at released S despite older held A')
        check(scene['key-top-j']['y'] == 276, 'other hand hold is independent')
        check(abs(scene['left-hoof']['y'] - (272 + 15 - 8)) < .1, 'released hoof is lifted at last target')
        # Release every key and wait: running-idle still retains the last positions.
        for i in range(45, 165):
            post('update', sample(i, audio=False))
        check(abs(scene['left-hoof']['x'] - (168 + 45 / 2 - 24)) < .1, 'idle must not home released left hoof')
        # A repeat event does not move to its key, while a new opposite-hand press does.
        post('update', sample(165, audio=False, key='a', event_kind='repeated', held=('a',)))
        post('update', sample(166, audio=False, key='l', held=('a', 'l')))
        post('update', sample(167, audio=False, key='l', event_kind='released', held=('a',)))
        for i in range(168, 195):
            post('update', sample(i, audio=False))
        check(abs(scene['left-hoof']['x'] - (168 + 45 / 2 - 24)) < .1, 'repeat must not retarget left hoof')
        check(abs(scene['right-hoof']['x'] - (513 + 45 / 2 - 24)) < .1, 'right hoof retains independently released L')
        lost = sample(195, audio=False, held=('a', 'j'))
        lost['keyboard']['state'] = 'secureInput'
        post('update', lost)
        check(scene['key-top-a']['y'] == 272 and scene['key-top-j']['y'] == 272, 'secure input clears keyboard')
        post('deactivate')
        before = copy.deepcopy(scene)
        post('update', sample(196, pps=9, beat=True))
        check(scene == before, 'inactive plugin must not mutate scene')
        post('dispose')
        process.stdin.close()
        check(process.wait(timeout=3) == 0, 'worker exits cleanly')
        print(f'PASS Niulai production worker: {checks} assertions; low/high jumps={jumps}; clock-skew, independent inputs, multikey, lifecycle')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=3)
