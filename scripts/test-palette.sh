#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build
source "$root/scripts/swift-sources.sh"
swiftc -swift-version 6 -parse-as-library -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework SwiftUI -framework Accelerate -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreAudio \
  "${native_libraries[@]}" tests/platforms/macos/PencilPaletteTests.swift -o build/pencil-palette-tests
build/pencil-palette-tests "${1:-build/palette-preview}"
