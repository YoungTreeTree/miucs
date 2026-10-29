#!/usr/bin/env python3
"""Compare Lua animation outputs with production Swift numerical reference, frame by frame."""
import copy,json,pathlib,subprocess,sys,time,statistics
ROOT=pathlib.Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools/plugins'))
from wire import send,receive
from preview import frame
from trace_reference import path as reference_path
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
swift=copy.deepcopy(frames)
keys={'a':0,'f':3,'j':38,'space':49,'returnKey':36}
for f in swift:
    a=f['audio'];a['version']=1;a['sessionID']='00000000-0000-0000-0000-00000000000'+('3' if a['sessionID'].endswith('-b') else '1');a['frame']['sessionID']=a['sessionID'];a['frame']['version']=1
    k=f['keyboard'];k.update(version=1,sessionID='00000000-0000-0000-0000-00000000000'+('4' if k['sessionID'].endswith('-b') else '2'),modifiers=0)
    for e in k['events']:e['keyCode']=keys[e.pop('key')];e['modifiers']=0
    for e in k['heldKeys']:e['keyCode']=keys[e.pop('key')]
(out/'input.json').write_text(json.dumps(swift))
subprocess.run([str(ROOT/'build/plugin-reference'),str(out/'input.json'),str(out/'reference.json')],check=True)
reference=json.loads((out/'reference.json').read_text())
worker=ROOT/'build/plugins/miucs-plugin-worker'
with subprocess.Popen([str(worker),str(ROOT/'plugins/builtin')],stdin=subprocess.PIPE,stdout=subprocess.PIPE) as p:
    scene={};version=0;updates=[]
    def response():
        global scene,version
        result=receive(p.stdout)
        if not result['ok']:raise RuntimeError(result['error'])
        if 'updateMs' in result:updates.append(result['updateMs'])
        packet=result['scene']
        if packet['full']:scene={}
        for node in packet['nodes']:scene.setdefault(node['id'],{}).update(node)
        version=packet['version']
    response();send(p.stdin,{'op':'activate','value':{'id':'staff-note'},'ack':version});response()
    maximum={};timings=[]
    for i,(f,expected) in enumerate(zip(frames,reference)):
        start=time.perf_counter();send(p.stdin,{'op':'update','value':f,'ack':version});response();timings.append((time.perf_counter()-start)*1000)
        actual={'head':scene['tray-head'].get('rotation',0),'y':scene['staff-note-body']['y'],'scale':scene['staff-note-body']['scaleX'],'opacity':scene['staff-note-body']['opacity'],'sway':scene['staff-note-sway']['rotation']}
        for field,value in actual.items():
            delta=abs(value-expected[field]);maximum[field]=max(maximum.get(field,0),delta)
            assert delta<1e-8,(i,field,value,expected[field])
        commands=reference_path(expected);actual_path=scene['staff-trace'].get('path',[])
        assert len(commands)==len(actual_path),(i,'trace-command-count',len(commands),len(actual_path))
        for command,actual_command in zip(commands,actual_path):
            assert command[0]==actual_command[0],(i,'trace-operation')
            assert max([abs(x-y) for x,y in zip(command[1:],actual_command[1:])]+[0])<1e-8,(i,'trace-geometry')
        for r,ring in enumerate(expected['rings'],1):
            got=scene[f'ring-{r}']
            for field in ['x','y','opacity','rotation']:
                delta=abs(got[field]-ring[field]);maximum['ring-'+field]=max(maximum.get('ring-'+field,0),delta)
                assert delta<1e-8,(i,r,field,got[field],ring[field])
            assert abs(got['scaleX']*10-ring['radius'])<1e-8
    send(p.stdin,{'op':'dispose','ack':version});response();p.stdin.close();assert p.wait(timeout=2)==0
    report={'frames':len(frames),'maximumAbsoluteError':maximum,'roundTripP95Ms':sorted(timings)[int(len(timings)*.95)],'roundTripMeanMs':statistics.mean(timings),'scriptP95Ms':sorted(updates)[int(len(updates)*.95)],'scriptMaxMs':max(updates)}
    (out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))

# Isolate each output in a fresh worker so its deterministic RNG begins at the same seed.
for output in ['pixel-keyboard','pencil-flight']:
    with subprocess.Popen([str(worker),str(ROOT/'plugins/builtin')],stdin=subprocess.PIPE,stdout=subprocess.PIPE) as p:
        scene={};version=0;response();send(p.stdin,{'op':'activate','value':{'id':output},'ack':version});response()
        largest=0
        for i,(f,expected) in enumerate(zip(frames,reference)):
            send(p.stdin,{'op':'update','value':f,'ack':version});response()
            assert abs(scene['tray-head'].get('rotation',0)-expected['head'])<1e-8
            if output=='pixel-keyboard':
                rect=scene['keyboard-tail']['sourceRect'];index=int(rect[1]/88)*16+int(rect[0]/96)
                assert index==expected['tail'],(output,i,index,expected['tail'])
                assert scene['keyboard-head'].get('rotation',0)==scene['tray-head'].get('rotation',0)
            else:
                for key in ['y','rotation','scaleX','scaleY']:
                    delta=abs(scene['flight-bird'][key]-expected['flight'][key]);largest=max(largest,delta)
                    assert delta<1e-8,(output,i,key,scene['flight-bird'][key],expected['flight'][key])
                assert int(scene['flight-score']['text'])==expected['flight']['score']
        send(p.stdin,{'op':'dispose','ack':version});response();p.stdin.close();assert p.wait(timeout=2)==0
        print(output, '600-frame reference passed; max error',largest)
