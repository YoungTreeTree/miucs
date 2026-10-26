#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
output="${1:-$root/build/staff-continuity-current}"
mkdir -p "$output"
swiftc -swift-version 6 -parse-as-library -O \
  -framework AppKit -framework Accelerate -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio \
  "${native_libraries[@]}" tools/macos/StaffContinuityProbe.swift -o "$output/probe"
"$output/probe" tests/fixtures/melody/tong-hua.json "${2:-$root/build/pop-benchmark/current}" "$output"
