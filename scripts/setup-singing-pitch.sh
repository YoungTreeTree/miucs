#!/bin/zsh
# Build-time tools and model assets stay in ignored build/.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
cache="$root/build/singing-pitch"
mkdir -p "$cache"
weights="$cache/crepe-tiny.pth"
checksum=d4993eea36ed1a0ad9ac549c740dae5265b049ce72004f00c2f59e01c0be8432
if [[ ! -f "$weights" ]] || [[ "$(shasum -a 256 "$weights" | cut -d ' ' -f 1)" != "$checksum" ]]; then
  curl --fail --location --retry 3 --max-time 120 --silent --show-error \
    https://raw.githubusercontent.com/maxrmorrison/torchcrepe/19e2ec3d494c0797a5ff2a11408ec5838fba6681/torchcrepe/assets/tiny.pth \
    -o "$weights.download"
  [[ "$(shasum -a 256 "$weights.download" | cut -d ' ' -f 1)" == "$checksum" ]]
  mv "$weights.download" "$weights"
fi
cp "$root/docs/licenses/torchcrepe.txt" "$cache/LICENSE-torchcrepe.txt"
if python3 - <<'PY'
from pathlib import Path
import hashlib, json, sys
p = Path('build/singing-pitch')
try:
    r = json.loads((p / 'conversion.json').read_text())
    current = hashlib.sha256(Path('scripts/export-singing-pitch.py').read_bytes()).hexdigest()
    assert r['exporterSHA256'] == current and r['maxActivationDifference'] < .001
    assert (p / 'SingingPitch.mlmodelc').is_dir()
except (OSError, ValueError, KeyError, AssertionError):
    sys.exit(1)
PY
then
  print "CREPE tiny Core ML model ready (validated conversion cache)."
  exit 0
fi
if [[ ! -x build/pitch-venv/bin/python ]]; then
  python3 -m venv build/pitch-venv
fi
build/pitch-venv/bin/python -m pip install -r scripts/requirements-singing-pitch.txt
build/pitch-venv/bin/python scripts/export-singing-pitch.py
