#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/scripts/swift-sources.sh"
mkdir -p build docs/validation
python3 scripts/check-boundaries.py
swiftc -swift-version 6 -parse-as-library -O \
  "${audio_core[@]}" "${keyboard_core[@]}" "${visualization_core[@]}" tests/contracts/FeatureChannelTests.swift \
  -o build/contract-tests
build/contract-tests
python3 scripts/validate-contracts.py
