#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$root/scripts/prepare-plugin-deps.py" --target mac-arm64
cmake -S "$root/modules/plugins" -B "$root/build/plugins" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build "$root/build/plugins" --parallel 6
ctest --test-dir "$root/build/plugins" --output-on-failure
