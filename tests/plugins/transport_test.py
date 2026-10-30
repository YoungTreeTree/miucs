#!/usr/bin/env python3
import pathlib,sys,tempfile,subprocess,json,time,os,shutil,struct,ctypes
ROOT=pathlib.Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools/plugins'))
from preview import Bridge, frame
from wire import send,receive,pack
worker=ROOT/'build/plugins/miucs-plugin-worker'
if os.name=='nt':worker=ROOT/'build/plugins/Release/miucs-plugin-worker.exe'
manifest={'id':'test','name':'Test','version':'1.0.0','api':1,'entry':'main.lua','inputs':[], 'layout':{'width':100,'height':100,'minimumWidth':10,'maximumWidth':200}}
checks=0
def expect(value):
    global checks
    assert value;checks+=1
with tempfile.TemporaryDirectory(prefix='miucs-plugin-test-') as folder:
    root=pathlib.Path(folder);(root/'manifest.json').write_text(json.dumps(manifest))
    source=root/'main.lua'
    source.write_text('return {create=function() miucs.load{type="rect",id="test",width=100,height=100} end, update=function(f) assert(f.keyboard==nil and f.audio==nil) end}')
    b=Bridge(root)
    try:
        b.post('update',frame(0));expect(not b.error())
        raw=b.render('test',100,100);expect(any(raw))
    finally:b.close()
    # Flood the async queue, then place an appearance control behind the pending input.
    manifest['inputs']=['keyboard'];(root/'manifest.json').write_text(json.dumps(manifest))
    source.write_text("local count=0;local last=0;return {create=function() miucs.load{type='group',id='test',width=100,height=100,children={{type='rect',id='bar',width=1,height=100}}} end,update=function(f) for _,e in ipairs(f.keyboard.events) do assert(e.sequence>last);last=e.sequence;count=count+1 end;miucs.set('bar',{x=count}) end,appearanceChanged=function() miucs.set('bar',{fill='#ffffff'}) end}")
    b=Bridge(root)
    try:
        for i in range(50):
            f=frame(i);f['now']=1+i*.001;f['keyboard'].update(sampledAt=f['now'],sequence=i+1,events=[{'sequence':i+1,'receivedAt':f['now'],'kind':'pressed','key':'a'}])
            data=pack({'op':'update','value':f});expect(b.lib.miucs_plugin_post(b.handle,data,len(data))==1)
        data=pack({'op':'appearanceChanged','value':{}});b.lib.miucs_plugin_post(b.handle,data,len(data))
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            raw=b.render('test',100,100)
            if raw[50*4:50*4+4]==b'\xff'*4:break
            if b.error():raise RuntimeError(b.error())
            time.sleep(.01)
        expect(raw[50*4:50*4+4]==b'\xff'*4)
    finally:b.close()
    source.write_text("return {create=function() miucs.load{type='path',id='geometry',visible=false,path={{'M',10,0},{'L',10,100}}};miucs.load{type='group',id='test',width=100,height=100,children={{type='path',id='drawing',pathRef='geometry',stroke='#ffffff',strokeWidth=2}}} end,update=function() miucs.set('geometry',{path={{'M',20,0},{'L',20,100}}}) end}")
    b=Bridge(root);surface=b.lib.miucs_surface_create(b.handle,None,b'test');pixels=ctypes.create_string_buffer(100*100*4)
    try:
        b.lib.miucs_surface_pixels(surface,100,100,pixels,len(pixels));expect(pixels.raw[10*4+3]>0)
        b.post('update',{});b.lib.miucs_surface_pixels(surface,100,100,pixels,len(pixels))
        expect(pixels.raw[10*4+3]==0 and pixels.raw[20*4+3]>0)
    finally:b.lib.miucs_surface_destroy(surface);b.close()
    # Keep one surface alive while geometry, stacking, hierarchy and output roots change.
    source.write_text("return {create=function() miucs.load{type='group',id='test',width=100,height=100,children={{type='rect',id='red',width=100,height=100,fill='#ff0000'},{type='rect',id='blue',width=100,height=100,fill='#0000ff'}}};miucs.load{type='rect',id='other',width=100,height=100,fill='#00ff00'} end,update=function(f) if f.add then miucs.load{type='group',id='new',width=100,height=100,children={{type='rect',id='new-child',width=100,height=100,fill='#ffffff'}}} else miucs.set(f.id,f.properties) end end}")
    b=Bridge(root);surface=b.lib.miucs_surface_create(b.handle,None,b'test');pixels=ctypes.create_string_buffer(100*100*4)
    try:
        def pixel(x=50,y=50):
            expect(b.lib.miucs_surface_pixels(surface,100,100,pixels,len(pixels))==1)
            return pixels.raw[(y*100+x)*4:(y*100+x)*4+4]
        expect(pixel()==bytes([255,0,0,255]))
        expect(pixel()==bytes([255,0,0,255])) # unchanged frame reuses its stamp
        b.post('update',{'id':'blue','properties':{'x':60}})
        expect(pixel()==bytes([0,0,255,255]))
        expect(pixel(80)==bytes([255,0,0,255]))
        b.post('update',{'id':'red','properties':{'z':2}})
        expect(pixel(80)==bytes([0,0,255,255]))
        b.post('update',{'id':'blue','properties':{'z':2,'order':5}})
        expect(pixel(80)==bytes([255,0,0,255]))
        b.post('update',{'id':'blue','properties':{'visible':False}})
        expect(pixel(80)==bytes([0,0,255,255]))
        b.post('update',{'id':'red','properties':{'fill':'#ffffff'}})
        expect(pixel()==b'\xff'*4)
        # The same-version sync must not leave a stale tree or output stamp.
        b.post('sync',{});expect(pixel()==b'\xff'*4)
        expect(b.render('other',100,100)[:4]==bytes([0,255,0,255]))
        b.post('update',{'add':True});expect(b.render('new',100,100)[:4]==b'\xff'*4)
    finally:b.lib.miucs_surface_destroy(surface);b.close()
    source.write_text('return {update=function() while true do pcall(function() while true do end end) end end}')
    b=Bridge(root);start=time.monotonic()
    try:
        try:b.post('update',{});raise AssertionError('loop survived')
        except RuntimeError:expect(time.monotonic()-start<2)
    finally:b.close()
    result=subprocess.run([str(worker),folder,'--parent-pid','2147483647'],input=b'',capture_output=True,timeout=2);expect(result.returncode!=0)
    source.write_text('return {}')
    # Reject malformed/deep/oversized framed data without a native stack overflow.
    for payload in [b'\x91'*10000+b'\xc0',b'\xdb\xff\xff\xff\xff',b'\xc1']:
        with subprocess.Popen([str(worker),folder],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE) as p:
            expect(receive(p.stdout)['ok']);p.stdin.write(struct.pack('<I',len(payload))+payload);p.stdin.flush()
            expect(not receive(p.stdout)['ok']);p.stdin.close();expect(p.wait(timeout=2)==1)
    source.write_text('return {create=function() miucs.load{type="group",id="test",width=100,height=100,children={{type="image",id="bad",width=100,height=100,source="bad.png"}}} end}')
    (root/'bad.png').write_text('not an image')
    b=Bridge(root)
    try:
        try:b.render('test',100,100);raise AssertionError('corrupt image rendered')
        except RuntimeError:expect(True)
    finally:b.close()
    # A resource symlink must not escape its plugin root.
    source.write_text('return {create=function() miucs.require("escape.lua") end}')
    outside=root.parent/(root.name+'-outside.lua');outside.write_text('return {}')
    try:
        try:(root/'escape.lua').symlink_to(outside)
        except OSError:pass
        else:
            result=subprocess.run([str(worker),folder,'--validate'],capture_output=True,timeout=2);expect(result.returncode!=0)
    finally:outside.unlink()
print(f'{checks} process/transport checks passed')
