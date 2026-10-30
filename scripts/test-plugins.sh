#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cmake --build "$root/build/plugins" --parallel 6
ctest --test-dir "$root/build/plugins" --output-on-failure
python3 "$root/tests/plugins/replay.py"
python3 "$root/tools/plugins/preview.py"

python3 "$root/tests/plugins/transport_test.py"
python3 "$root/tools/plugins/validate.py" "$root/tools/plugins/template"

python3 "$root/tools/plugins/validate.py" "$root/plugins/niulai-keyboard"
python3 "$root/tests/plugins/niulai_replay.py"

python3 "$root/tests/plugins/lab_test.py"
python3 "$root/tests/plugins/gif_test.py"

python3 "$root/tools/plugins/validate.py" "$root/plugins/muffin-puppies"
python3 "$root/tests/plugins/muffin_replay.py"
