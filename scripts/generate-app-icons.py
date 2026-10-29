#!/usr/bin/env python3
"""Package the existing cat portrait as macOS/Windows application icons (run on macOS)."""
import pathlib, struct, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parents[1]
assets=root/'apps/assets'
with tempfile.TemporaryDirectory() as temp:
    iconset=pathlib.Path(temp)/'Miucs.iconset';iconset.mkdir()
    for size in [16,32,128,256,512]:
        for scale in [1,2]:
            out=iconset/f'icon_{size}x{size}{"@2x" if scale==2 else ""}.png'
            subprocess.run(['sips','-z',str(size*scale),str(size*scale),str(assets/'cat-head.png'),'--out',str(out)],check=True,stdout=subprocess.DEVNULL)
    subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(assets/'Miucs.icns')],check=True)
    payloads=[(size,(iconset/f'icon_{size}x{size}.png').read_bytes()) for size in [16,32,128,256]]
    header=struct.pack('<HHH',0,1,len(payloads));offset=6+16*len(payloads);entries=[]
    for size,data in payloads:
        entries.append(struct.pack('<BBBBHHII',size%256,size%256,0,0,1,32,len(data),offset));offset+=len(data)
    (assets/'Miucs.ico').write_bytes(header+b''.join(entries)+b''.join(data for _,data in payloads))
