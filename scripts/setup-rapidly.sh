#!/bin/zsh
# Fetch the official evaluation SDK into ignored build/; never vendor binaries or keys.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cache="$root/build/rapidly"
revision=a75155656556b38709fe77a706958dcbe1f13624
base="https://raw.githubusercontent.com/rapidly-labs/rapidly-sdk/$revision"
mkdir -p "$cache"

fetch() {
  local url="$1" destination="$2" checksum="$3"
  if [[ -f "$destination" ]] && [[ "$(shasum -a 256 "$destination" | cut -d ' ' -f 1)" == "$checksum" ]]; then
    return
  fi
  local temporary
  temporary="$(mktemp "$cache/download.XXXXXX")"
  curl --fail --location --retry 2 --max-time 120 --silent --show-error "$url" -o "$temporary"
  if [[ "$(shasum -a 256 "$temporary" | cut -d ' ' -f 1)" != "$checksum" ]]; then
    rm -f "$temporary"
    print -u2 "Rapidly checksum mismatch: $destination"
    exit 1
  fi
  mv "$temporary" "$destination"
}

fetch "https://github.com/rapidly-labs/rapidly-sdk/releases/download/v1.1.0/RapidlyEngine.xcframework.zip" \
  "$cache/RapidlyEngine.xcframework.zip" 7743a827a04ead2b489922328cebefc2f30198a6df214e365cd16268d99dd319
fetch "$base/models/music-stem-separation-96ms.v1.1.rapidly" \
  "$cache/music-stem-separation-96ms.v1.1.rapidly" 584bcd6c2f20c48d4758ff35b6e06b3468cbc0e47ce8209b7031633c9e2ebb04
fetch "$base/LICENSE" "$cache/LICENSE" ae432e06e8bb9d93a20230dc07397c084454ccc1807d42455ae14afb01e731ac
fetch "$base/NOTICE.txt" "$cache/NOTICE.txt" 1bb4ac335ad8085edd8d2fc4774cb8e70c656203e5f2732a2c30bb694611f60a
ditto -x -k "$cache/RapidlyEngine.xcframework.zip" "$cache"
codesign --verify --deep --strict "$cache/RapidlyEngine.xcframework"
print "Rapidly v1.1.0 ready in $cache (without an offline key, output remains watermarked)."
