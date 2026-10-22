#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build docs/validation
swiftc -swift-version 6 -parse-as-library -O -framework Accelerate \
  Miucs/AudioFeatureAnalyzer.swift Miucs/MelodyAnalyzer.swift Miucs/SoundFlightWorld.swift \
  Tests/FlightWorldTests.swift -o build/flight-world-tests
build/flight-world-tests
