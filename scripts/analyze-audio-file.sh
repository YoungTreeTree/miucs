#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if (( $# != 2 )); then
  print -u2 "Usage: zsh scripts/analyze-audio-file.sh <input-audio> <output.json>"
  exit 2
fi
mkdir -p "$root/build"
swiftc -swift-version 6 -parse-as-library -O \
  -target arm64-apple-macosx14.0 -framework Accelerate -framework AVFoundation \
  "$root/Miucs/AudioFeatureAnalyzer.swift" "$root/Tests/AudioFileProbe.swift" \
  -o "$root/build/audio-file-probe"
"$root/build/audio-file-probe" "$1" "$2"
