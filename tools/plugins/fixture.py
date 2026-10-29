#!/usr/bin/env python3
import json,pathlib
from preview import ROOT,frame
output=ROOT/'build/plugin-fixture.json';output.parent.mkdir(exist_ok=True)
output.write_text(json.dumps([frame(i) for i in range(600)]))
print(output)
