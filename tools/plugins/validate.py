#!/usr/bin/env python3
"""Validate source, lifecycle, budgets and resource decoding using the production runtime."""
import argparse,pathlib,subprocess,sys
from preview import Bridge,ROOT,frame
p=argparse.ArgumentParser();p.add_argument('folder',type=pathlib.Path);a=p.parse_args()
worker=ROOT/('build/plugins/Release/miucs-plugin-worker.exe' if sys.platform=='win32' else 'build/plugins/miucs-plugin-worker')
subprocess.run([str(worker),str(a.folder.resolve()),'--validate'],check=True,timeout=5)
import json
manifest=json.loads((a.folder/'manifest.json').read_text())
b=Bridge(a.folder)
try:
    for view in manifest['visualizations']:
        b.post('activate',dict(view['layout'],id=view['id'],scale=1))
        b.post('resize',dict(view['layout'],id=view['id'],scale=2))
        b.post('appearanceChanged',{'ink':'#4f7087','opacity':.9})
        for i in range(60):b.post('update',frame(i))
        b.render(view['id'],128,128);b.post('deactivate',{})
    if 'tray' in manifest:b.render(manifest['tray'],32,32)
    b.post('dispose',{})
    print('Lifecycle, synthetic input and resource validation passed')
finally:b.close()
