#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
case "${1:---desktop}" in
  --desktop) demo_name=miucs-desktop-demo; demo_options=(--desktop) ;;
  --close-up) demo_name=miucs-demo; demo_options=() ;;
  *) print -u2 "Usage: zsh scripts/render-demo.sh [--desktop|--close-up]"; exit 2 ;;
esac
mkdir -p build/demo-export docs/assets
# A separate exporter never starts the desktop app or its system-audio capture.
swiftc -swift-version 6 -parse-as-library -O \
  -framework AppKit -framework Accelerate -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreAudio -framework ImageIO \
  Miucs/AudioFeatureAnalyzer.swift Miucs/MelodyAnalyzer.swift \
  Miucs/SoundFlightWorld.swift Miucs/PencilPalette.swift Miucs/PencilFlightView.swift Miucs/VisualizerPanel.swift \
  Miucs/AudioEngine.swift Miucs/AudioPCMDecoder.swift Tools/DemoDesktop.swift Tools/RenderDemo.swift \
  -o build/render-demo
build/render-demo "build/demo-export/$demo_name.gif" "${demo_options[@]}"
python3 scripts/prepare-demo.py "build/demo-export/$demo_name.gif" "docs/assets/$demo_name.gif"
