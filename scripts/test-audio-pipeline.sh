#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
mkdir -p build docs/validation
swiftc -swift-version 6 -parse-as-library -O -framework Accelerate \
  "${audio_core[@]}" "${fft_macos[@]}" tests/audio/AudioPipelineTests.swift -o build/audio-pipeline-tests
build/audio-pipeline-tests
