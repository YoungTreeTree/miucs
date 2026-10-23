#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if (( $# != 2 )); then
  print -u2 "Usage: zsh scripts/analyze-audio-file.sh <input-audio> <output.json>"
  exit 2
fi
mkdir -p "$root/build"
source "$root/scripts/swift-sources.sh"
swiftc -swift-version 6 -parse-as-library -O \
  -target arm64-apple-macosx14.0 -framework Accelerate -framework AVFoundation \
  "${audio_core[@]}" "${fft_macos[@]}" "$root/tools/macos/AudioFileProbe.swift" \
  -o "$root/build/audio-file-probe"
"$root/build/audio-file-probe" "$1" "$2"
