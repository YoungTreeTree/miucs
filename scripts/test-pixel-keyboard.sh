#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
mkdir -p build docs/validation
python3 - <<'PY'
from pathlib import Path
import re
root=Path('modules/visualizations/pixel-keyboard')
a=re.findall(r'"([0-5]{22})"',(root/'core/PixelPawSprite.swift').read_text())
b=re.findall(r'"([0-5]{22})"',(root/'platforms/windows/PixelPawSpriteScene.cs').read_text())
assert a == b and len(a) == 32, 'Native platforms must share the same paw sprite'
print('PASS shared black-cat white-mitten pixel sprite')
PY
swiftc -swift-version 6 -parse-as-library -O "${keyboard_core[@]}" modules/visualizations/staff-note/core/StaffKeyboardLayout.swift modules/visualizations/pixel-keyboard/core/*.swift \
  tests/visualizations/PixelKeyboardTests.swift -o build/pixel-keyboard-tests
build/pixel-keyboard-tests
swiftc -swift-version 6 -parse-as-library -O -framework AppKit -framework Accelerate -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio \
  "${native_libraries[@]}" tests/platforms/macos/PixelKeyboardPlatformTests.swift -o build/pixel-keyboard-platform-tests
build/pixel-keyboard-platform-tests
