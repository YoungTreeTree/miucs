#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
mkdir -p build docs/validation
swiftc -swift-version 6 -parse-as-library -O \
  -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio -framework Accelerate \
  "${audio_core[@]}" "${audio_macos[@]}" tests/platforms/macos/AudioRecoveryTests.swift -o build/audio-recovery-tests
build/audio-recovery-tests
