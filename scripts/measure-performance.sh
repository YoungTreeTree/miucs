#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build
swiftc -swift-version 6 -parse-as-library -O \
  -framework AppKit -framework Accelerate -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio \
  Miucs/AudioFeatureAnalyzer.swift Miucs/MelodyAnalyzer.swift Miucs/AudioPCMDecoder.swift \
  Miucs/AudioEngine.swift Miucs/SoundFlightWorld.swift Miucs/PencilPalette.swift Miucs/PencilFlightView.swift Miucs/VisualizerPanel.swift \
  Tools/PerformanceProbe.swift -o build/performance-probe
if [[ "${1:-}" == --cadence ]]; then
  build/performance-probe --cadence "${2:-build/performance-cadence.json}"
else
  build/performance-probe "${1:-build/performance-current}"
fi
