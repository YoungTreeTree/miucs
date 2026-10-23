#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
mkdir -p build docs/validation
swiftc -swift-version 6 -parse-as-library -O \
  "${audio_core[@]}" tests/audio/SingingPitchTests.swift -o build/singing-pitch-tests
build/singing-pitch-tests
