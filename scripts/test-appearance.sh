#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
mkdir -p build docs/validation
swiftc -swift-version 6 -parse-as-library -O \
  -framework AppKit -framework SwiftUI -framework Accelerate -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio \
  "${native_libraries[@]}" tests/platforms/macos/VisualizationAppearanceTests.swift -o build/visualization-appearance-tests
build/visualization-appearance-tests
