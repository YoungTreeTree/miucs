#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build docs/validation
swiftc -swift-version 6 -parse-as-library -O \
  -target arm64-apple-macosx14.0 \
  -framework Accelerate -framework CoreAudio -framework CoreMedia -framework AVFoundation \
  Miucs/AudioFeatureAnalyzer.swift Miucs/AudioPCMDecoder.swift Tests/AudioFeatureTests.swift \
  -o build/audio-feature-tests
build/audio-feature-tests "$root/docs/validation/audio-feature-tests.json"
