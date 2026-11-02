#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
test_app="$root/build/settings-tests.app"
mkdir -p "$test_app/Contents/MacOS" "$test_app/Contents/Resources/Plugins"
swiftc -swift-version 6 -parse-as-library -O \
  -framework AppKit -framework SwiftUI -framework Accelerate -framework ScreenCaptureKit -framework CoreMedia -framework CoreAudio \
  "${native_libraries[@]}" tests/platforms/macos/SettingsTests.swift -o "$test_app/Contents/MacOS/settings-tests"
cp "$root/build/plugins/libmiucs_plugins.dylib" "$root/build/plugins/miucs-plugin-worker" "$test_app/Contents/MacOS/"
# Deliberately include old packages to verify that upgrade leftovers stay unavailable.
cp -R "$root/plugins/pixel-keyboard" "$root/plugins/staff-note" "$root/plugins/pencil-flight" "$test_app/Contents/Resources/Plugins/"
cp "$root/apps/assets/Miucs.icns" "$test_app/Contents/Resources/"
cat > "$test_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>settings-tests</string><key>CFBundleIdentifier</key><string>com.miucs.settings-tests</string><key>CFBundleIconFile</key><string>Miucs.icns</string><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>
PLIST
"$test_app/Contents/MacOS/settings-tests" "$root"
