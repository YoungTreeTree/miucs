#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build/hardware-tests
swiftc -swift-version 6 -parse-as-library -O \
  modules/hardware/macos/HardwareFrame.swift modules/hardware/macos/HardwareSerial.swift modules/hardware/macos/HardwareIO.swift apps/macos/HardwarePort.swift tools/macos/HardwareProbe.swift \
  -o build/hardware-tests/hardware-probe
build/hardware-tests/hardware-probe "$@"
