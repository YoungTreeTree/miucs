#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
mkdir -p build docs/validation
python3 scripts/check-boundaries.py
swiftc -swift-version 6 -parse-as-library -O \
  "${audio_core[@]}" "${keyboard_core[@]}" "${visualization_core[@]}" tests/contracts/KeyboardChannelTests.swift \
  -o build/keyboard-channel-tests
build/keyboard-channel-tests
swiftc -swift-version 6 -parse-as-library -O -framework AppKit -framework Carbon \
  "${keyboard_core[@]}" "${keyboard_macos[@]}" tests/platforms/macos/KeyboardEngineTests.swift \
  -o build/keyboard-engine-tests
build/keyboard-engine-tests
