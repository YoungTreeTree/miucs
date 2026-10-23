#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build
sources=(Miucs/*.swift)
sources=(${sources:#Miucs/App.swift})
swiftc -swift-version 6 -parse-as-library -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework SwiftUI -framework Accelerate -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreAudio \
  "${sources[@]}" Tests/PencilPaletteTests.swift -o build/pencil-palette-tests
build/pencil-palette-tests "${1:-build/palette-preview}"
