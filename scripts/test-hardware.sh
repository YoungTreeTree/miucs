#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build/hardware-tests
clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined \
  -I hardware/esp32-display/main hardware/esp32-display/main/protocol.c tests/hardware/protocol_test.c \
  -o build/hardware-tests/protocol-tests
build/hardware-tests/protocol-tests
swiftc -swift-version 6 -parse-as-library -O \
  modules/hardware/macos/HardwareFrame.swift modules/hardware/macos/HardwareSerial.swift modules/hardware/macos/HardwareIO.swift apps/macos/HardwarePort.swift tests/hardware/TransportTests.swift \
  -o build/hardware-tests/transport-tests
build/hardware-tests/transport-tests
python3 tests/hardware/transport_test.py
