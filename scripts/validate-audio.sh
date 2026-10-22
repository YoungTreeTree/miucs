#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--live" ]]; }; then
  print -u2 "Usage: zsh scripts/validate-audio.sh [--live]"
  exit 2
fi
zsh scripts/test-audio-features.sh
zsh scripts/analyze-audio-file.sh "$root/build/system-audio-fixture.wav" "$root/build/offline-features.json"
python3 scripts/verify-audio-reference.py \
  build/system-audio-fixture.wav build/offline-features.json docs/validation/numpy-reference.json
if (( $# == 1 )); then
  zsh build.sh
  "$root/dist/Miucs.app/Contents/MacOS/Miucs" --diagnose-audio --isolate-fixture \
    --fixture "$root/build/system-audio-fixture.wav" --output "$root/build/system-audio-isolated.json"
  python3 scripts/verify-system-audio.py \
    build/system-audio-isolated.json build/system-audio-fixture.json docs/validation/system-audio.json
fi
