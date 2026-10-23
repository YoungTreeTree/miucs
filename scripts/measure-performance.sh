#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
mkdir -p build
swiftc -swift-version 6 -parse-as-library -O \
  -framework AppKit -framework Accelerate -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio \
  "${native_libraries[@]}" tools/macos/PerformanceProbe.swift -o build/performance-probe
if [[ "${1:-}" == --cadence || "${1:-}" == --staff-cadence ]]; then
  build/performance-probe "$1" "${2:-build/performance-cadence.json}" "${@:3}"
else
  build/performance-probe "${1:-build/performance-current}"
fi
