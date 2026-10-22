#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build
swiftc -swift-version 6 -parse-as-library -O -framework Accelerate \
  Miucs/AudioFeatureAnalyzer.swift Miucs/MelodyAnalyzer.swift Tests/MelodyTests.swift -o build/melody-tests
build/melody-tests
