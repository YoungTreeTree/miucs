#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
zsh scripts/setup-rapidly.sh
source scripts/swift-sources.sh
framework="$root/build/rapidly/RapidlyEngine.xcframework/macos-arm64_x86_64"
swiftc -swift-version 6 -parse-as-library -O -framework Accelerate \
  -F "$framework" -framework RapidlyEngineC -Xlinker -rpath -Xlinker "$framework" \
  "${audio_core[@]}" "${fft_macos[@]}" modules/audio/platforms/macos/RapidlyVocalProcessor.swift \
  tests/platforms/macos/RapidlyVocalTests.swift -o build/rapidly-vocal-tests
build/rapidly-vocal-tests
