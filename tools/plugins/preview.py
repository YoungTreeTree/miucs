#!/usr/bin/env python3
"""Render synthetic input using the production worker, binary transport and Skia CPU renderer."""
import argparse, ctypes as c, json, math, pathlib, struct, time, zlib
from wire import pack
ROOT=pathlib.Path(__file__).resolve().parents[2]

def frame(index, fps=60):
    now=1+index/fps;seq=index+1
    beat=index%30==0;press=index%10==0
    audio={'time':now,'sampleRate':48000,'channelCount':2,'rms':.08,'rmsDBFS':-22.,'peak':.2,'envelope':.1,'isSilent':False,'silenceDuration':0.,'lowEnergy':.003,'midEnergy':.004,'highEnergy':.001,'spectralFlux':.35 if beat else .01,'onsetThreshold':.2,'isOnset':False,'centroidHz':1500.,'bandwidthHz':2200.,'flatness':.2,'displayBands':[.2]*24}
    af={'sessionID':'audio-fixture','sequence':seq,'receivedAt':now,'audio':audio,'melody':{'time':now,'pitchHz':440*2**((math.sin(now)*5)/12),'isMelodic':True,'confidence':.9}}
    event={'sequence':seq,'receivedAt':now,'time':now,'strength':.8}
    keys=['a','f','j','space','returnKey']
    key=keys[(index//10)%len(keys)]
    return {'now':now,'deltaTime':1/fps,'audio':{'sessionID':'audio-fixture','state':'running','frame':af,'frameAge':0.,'onsets':[event] if beat else [],'beats':[dict(event,bpm=120.,confidence=.9)] if beat else [],'spectralFluxPeak':.35 if beat else 0.},'keyboard':{'sessionID':'keys-fixture','sequence':seq,'sampledAt':now,'state':'running','modifiers':0,'pressesPerSecond':6.,'idleDuration':0.,'droppedEventCount':0,'heldKeys':[{'key':key,'duration':0.}] if press else [],'events':[{'sequence':seq,'receivedAt':now,'kind':'pressed','key':key,'modifiers':0}] if press else []}}

class Bridge:
    def __init__(self,plugin,seed=None):
        name='miucs_plugins.dll' if __import__('os').name=='nt' else 'libmiucs_plugins.dylib'
        directory=ROOT/'build/plugins';directory=directory/'Release' if (directory/'Release'/name).exists() else directory
        self.lib=c.CDLL(str(directory/name));l=self.lib
        for name,args,res in [('miucs_plugin_open',[c.c_char_p,c.c_char_p],c.c_void_p),('miucs_plugin_close',[c.c_void_p],None),('miucs_plugin_post',[c.c_void_p,c.c_char_p,c.c_size_t],c.c_int),('miucs_plugin_completed',[c.c_void_p],c.c_uint64),('miucs_plugin_error',[c.c_void_p,c.c_void_p,c.c_size_t],c.c_size_t),('miucs_surface_create',[c.c_void_p,c.c_void_p,c.c_char_p],c.c_void_p),('miucs_surface_pixels',[c.c_void_p,c.c_uint32,c.c_uint32,c.c_void_p,c.c_size_t],c.c_int),('miucs_surface_destroy',[c.c_void_p],None)]:
            fn=getattr(l,name);fn.argtypes=args;fn.restype=res
        worker=directory/('miucs-plugin-worker.exe' if __import__('os').name=='nt' else 'miucs-plugin-worker')
        if seed is None:
            self.handle=l.miucs_plugin_open(str(worker).encode(),str(pathlib.Path(plugin).resolve()).encode())
        else:
            l.miucs_plugin_open_seeded.argtypes=[c.c_char_p,c.c_char_p,c.c_uint64];l.miucs_plugin_open_seeded.restype=c.c_void_p
            self.handle=l.miucs_plugin_open_seeded(str(worker).encode(),str(pathlib.Path(plugin).resolve()).encode(),seed)
        try:self.wait(1)
        except BaseException:self.close();raise
    def error(self):
        b=c.create_string_buffer(2048);self.lib.miucs_plugin_error(self.handle,b,len(b));return b.value.decode()
    def wait(self,count):
        deadline=time.monotonic()+3
        while self.lib.miucs_plugin_completed(self.handle)<count:
            error=self.error()
            if error:raise RuntimeError(error)
            if time.monotonic()>deadline:raise TimeoutError('worker response')
            time.sleep(.001)
    def post(self,op,value):
        count=self.lib.miucs_plugin_completed(self.handle)+1;data=pack({'op':op,'value':value})
        if not self.lib.miucs_plugin_post(self.handle,data,len(data)):raise RuntimeError(self.error())
        self.wait(count)
    def render(self,output,w,h):
        surface=self.lib.miucs_surface_create(self.handle,None,output.encode());b=c.create_string_buffer(w*h*4)
        try:
            if not self.lib.miucs_surface_pixels(surface,w,h,b,len(b)):raise RuntimeError(self.error())
            return b.raw
        finally:self.lib.miucs_surface_destroy(surface)
    def inspect(self):
        fn=self.lib.miucs_plugin_inspect;fn.argtypes=[c.c_void_p,c.c_void_p,c.c_size_t];fn.restype=c.c_size_t
        n=fn(self.handle,None,0)
        if not 0<n<=64*1024*1024:raise RuntimeError('Invalid diagnostic snapshot size')
        data=c.create_string_buffer(n)
        if fn(self.handle,data,n)>n:raise RuntimeError('Snapshot changed during inspection')
        return json.loads(data.value)
    def close(self):
        if self.handle:self.lib.miucs_plugin_close(self.handle);self.handle=None

def png(path,bgra,w,h):
    def chunk(name,data):return struct.pack('>I',len(data))+name+data+struct.pack('>I',zlib.crc32(name+data))
    rows=bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            b,g,r,a=bgra[(y*w+x)*4:(y*w+x+1)*4]
            rows.extend((min(255,round(r*255/a)) if a else 0,min(255,round(g*255/a)) if a else 0,min(255,round(b*255/a)) if a else 0,a))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--plugin',type=pathlib.Path);p.add_argument('--output',type=pathlib.Path,default=ROOT/'build/plugin-preview');p.add_argument('--frames',type=int,default=120);args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    folders=[args.plugin] if args.plugin else sorted(folder.parent for folder in (ROOT/'plugins').glob('*/manifest.json'))
    for folder in folders:
        manifest=json.loads((folder/'manifest.json').read_text(encoding="utf-8"))
        bridge=Bridge(folder)
        try:
            output=manifest['id'];w=int(manifest['layout']['width']);h=int(manifest['layout']['height'])
            bridge.post('activate',{'id':output,'width':w,'height':h,'scale':1.})
            for i in range(args.frames):bridge.post('update',frame(i))
            png(args.output/(output+'.png'),bridge.render(output,w*2,h*2),w*2,h*2)
            print(output,'rendered',flush=True)
        finally:bridge.close()
