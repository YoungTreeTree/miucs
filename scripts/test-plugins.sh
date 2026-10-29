#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cmake --build "$root/build/plugins" --parallel 6
ctest --test-dir "$root/build/plugins" --output-on-failure
swiftc -O -parse-as-library -o "$root/build/plugin-reference" \
  "$root"/modules/audio/core/*.swift "$root"/modules/keyboard/core/*.swift \
  "$root"/modules/visualizations/api/*.swift "$root"/modules/visualizations/staff-note/core/*.swift "$root"/modules/visualizations/pencil-flight/core/*.swift \
  "$root/modules/visualizations/pixel-keyboard/core/PixelHeadScene.swift" "$root/modules/visualizations/pixel-keyboard/core/PixelTailScene.swift" "$root/tests/plugins/reference.swift"
python3 "$root/tests/plugins/replay.py"
python3 "$root/tools/plugins/preview.py"

python3 "$root/tests/plugins/transport_test.py"
python3 "$root/tools/plugins/validate.py" "$root/tools/plugins/template"

python3 "$root/tools/plugins/validate.py" "$root/plugins/niulai-keyboard"
python3 "$root/tests/plugins/niulai_replay.py"
