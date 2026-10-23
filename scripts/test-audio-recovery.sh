#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build docs/validation
swiftc -swift-version 6 -parse-as-library -O \
  -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio -framework Accelerate \
  Miucs/AudioEngine.swift Miucs/AudioFeatureAnalyzer.swift Miucs/MelodyAnalyzer.swift Miucs/AudioPCMDecoder.swift \
  Tests/AudioRecoveryTests.swift -o build/audio-recovery-tests
build/audio-recovery-tests
