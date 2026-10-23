#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
mkdir -p build
swiftc -swift-version 6 -parse-as-library -O -framework Accelerate \
  "${audio_core[@]}" "${fft_macos[@]}" tests/audio/MelodyTests.swift -o build/melody-tests
build/melody-tests
