#!/usr/bin/env python3
"""Compare Lua animations with the frozen pre-removal numerical baseline, frame by frame."""
import gzip,hashlib,json,pathlib,subprocess,sys,time,statistics
ROOT=pathlib.Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools/plugins'))
from wire import send,receive
from preview import frame
out=ROOT/'build/plugin-replay';out.mkdir(parents=True,exist_ok=True)
frames=[frame(i) for i in range(600)]
# Exercise short pitch dropouts, silence, and a long display stall.
for i in range(130,142):frames[i]['audio']['frame']['melody'].update(isMelodic=False,pitchHz=None)
for i in range(260,280):frames[i]['audio']['frame']['audio']['isSilent']=True
frames[400]['deltaTime']=.5
for i in range(320,350):frames[i]['keyboard'].update(state='recovering',events=[],heldKeys=[])
for i in range(430,600):frames[i]['audio']['sessionID']='audio-fixture-b';frames[i]['audio']['frame']['sessionID']='audio-fixture-b'
for i in range(480,600):frames[i]['keyboard']['sessionID']='keys-fixture-b'
for i in range(490,600):frames[i]['audio']['frame']['audio']['sampleRate']=44100
fixture=json.loads(gzip.decompress((ROOT/'tests/plugins/reference.json.gz').read_bytes()))
digest=hashlib.sha256(json.dumps(frames,sort_keys=True,separators=(',',':')).encode()).hexdigest()
assert digest==fixture['inputSHA256'], 'Replay input changed: review and update the baseline explicitly'
reference=fixture['frames']
assert len(reference)==len(frames), 'Reference must cover every input frame'
worker=ROOT/('build/plugins/Release/miucs-plugin-worker.exe' if sys.platform=='win32' else 'build/plugins/miucs-plugin-worker')
with subprocess.Popen([str(worker),str(ROOT/'plugins/pixel-keyboard')],stdin=subprocess.PIPE,stdout=subprocess.PIPE) as p:
    scene={};version=0;updates=[];timings=[];largest=0
    def response():
        global scene,version
        result=receive(p.stdout)
        if not result['ok']:raise RuntimeError(result['error'])
        if 'updateMs' in result:updates.append(result['updateMs'])
        packet=result['scene']
        if packet['full']:scene={}
        for identity in packet.get('removed',[]):scene.pop(identity,None)
        for node in packet['nodes']:scene.setdefault(node['id'],{}).update(node)
        version=packet['version']
    response();send(p.stdin,{'op':'activate','value':{'id':'pixel-keyboard'},'ack':version});response()
    for i,(f,expected) in enumerate(zip(frames,reference)):
        start=time.perf_counter();send(p.stdin,{'op':'update','value':f,'ack':version});response();timings.append((time.perf_counter()-start)*1000)
        rect=scene['keyboard-tail']['sourceRect'];index=int(rect[1]/88)*16+int(rect[0]/96)
        assert index==expected['tail'],(i,index,expected['tail'])
        delta=abs(scene['keyboard-head'].get('rotation',0)-expected['head']);largest=max(largest,delta)
        assert delta<1e-8,(i,delta)
    send(p.stdin,{'op':'dispose','ack':version});response();p.stdin.close();assert p.wait(timeout=2)==0
    report={'plugin':'pixel-keyboard','frames':len(frames),'maximumAbsoluteError':largest,'roundTripP95Ms':sorted(timings)[int(len(timings)*.95)],'roundTripMeanMs':statistics.mean(timings)}
    (out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
    print('奶牛猫 600-frame frozen reference passed')
