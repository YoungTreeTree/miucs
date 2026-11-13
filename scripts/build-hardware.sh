#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${IDF_PATH:-}" || ! -f "$IDF_PATH/export.sh" ]]; then
  print -u2 "Set IDF_PATH to ESP-IDF v5.5.6 and IDF_TOOLS_PATH if tools are installed outside ~/.espressif."
  exit 1
fi
source "$IDF_PATH/export.sh" >/dev/null
idf.py -C "$root/hardware/esp32-display" build
