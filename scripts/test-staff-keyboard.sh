#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
mkdir -p build docs/validation
swiftc -swift-version 6 -parse-as-library -O \
  "${audio_core[@]}" "${keyboard_core[@]}" "${visualization_core[@]}" tests/visualizations/StaffKeyboardTests.swift \
  -o build/staff-keyboard-tests
build/staff-keyboard-tests
swiftc -swift-version 6 -parse-as-library -O \
  -framework AppKit -framework Accelerate -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio \
  "${native_libraries[@]}" tests/platforms/macos/StaffKeyboardPlatformTests.swift -o build/staff-keyboard-platform-tests
build/staff-keyboard-platform-tests
