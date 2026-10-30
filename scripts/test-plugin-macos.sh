#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source scripts/swift-sources.sh
bundle="$root/build/PluginReloadTests.app"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"
rm -rf "$bundle/Contents/Resources/Plugins"
cp -R plugins "$bundle/Contents/Resources/Plugins"
cp apps/assets/cat-head.png "$bundle/Contents/Resources/PixelCatHead.png"
cp build/plugins/libmiucs_plugins.dylib build/plugins/miucs-plugin-worker "$bundle/Contents/MacOS/"
swiftc -O -parse-as-library -swift-version 6 -framework AppKit -framework Accelerate -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio \
  "${native_libraries[@]}" tests/plugins/mac_reload.swift -o "$bundle/Contents/MacOS/PluginReloadTests"
"$bundle/Contents/MacOS/PluginReloadTests"
