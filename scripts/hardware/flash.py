#!/usr/bin/env python3
"""Back up and replace the factory app, keeping this board's working bootloader."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="CH343 programming port, not the Miucs display USB port")
    parser.add_argument("--firmware", type=Path, default=root / "hardware/esp32-display/build/miucs_display.bin")
    parser.add_argument("--backup-dir", type=Path, default=root / "build/hardware-backups")
    args = parser.parse_args()
    firmware = args.firmware.resolve()
    content = firmware.read_bytes()
    if not content or content[0] != 0xE9:
        raise SystemExit("Not an ESP application image")
    backup = args.backup_dir / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup.mkdir(parents=True, exist_ok=False)
    command = [sys.executable, "-m", "esptool", "--chip", "esp32p4", "--port", args.port,
               "--baud", "115200", "--no-stub"]

    def run(*arguments):
        subprocess.run(command + list(arguments), check=True)

    table_file = backup / "partition-table.bin"
    run("read-flash", "0x8000", "0x1000", str(table_file))
    table = table_file.read_bytes()
    factory = []
    for offset in range(0, len(table), 32):
        magic, kind, subtype, address, size, label, flags = struct.unpack("<HBBII16sI", table[offset:offset + 32])
        if magic == 0x50AA and kind == 0 and subtype == 0:
            factory.append((address, size))
    if factory != [(0x10000, 0x100000)]:
        raise SystemExit(f"Unexpected app layout {factory}; nothing written. This helper only supports the verified factory layout.")
    if len(content) > factory[0][1]:
        raise SystemExit("Firmware exceeds factory partition; nothing written")
    run("read-flash", "0x10000", "0x100000", str(backup / "previous-app.bin"))
    manifest = {"port": args.port, "firmware": str(firmware), "sha256": hashlib.sha256(content).hexdigest(),
                "app_offset": "0x10000", "previous_app": str(backup / "previous-app.bin"), "flashed": False}
    (backup / "manifest.json").write_text(json.dumps(manifest, indent=2))
    run("write-flash", "0x10000", str(firmware))
    manifest["flashed"] = True
    (backup / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"Flashed and verified. Previous application: {backup / 'previous-app.bin'}")


if __name__ == "__main__":
    main()
