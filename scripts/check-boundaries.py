#!/usr/bin/env python3
"""Keep shared Swift independent of native frameworks and platform implementations."""
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
failures = []
shared = [*root.glob("modules/audio/core/*.swift"), *root.glob("modules/keyboard/core/*.swift"), *root.glob("modules/visualizations/api/*.swift"),
          *root.glob("modules/visualizations/*/core/*.swift")]
native_names = r"\b(?:NSView|NSColor|NSWindow|CMSampleBuffer|SCStream|CGColor|CGPath|CGEvent|AudioEngine|KeyboardEngine|KeyboardEventTap|AccelerateSpectrumTransform|vDSP_\w+)\b"
for path in shared:
    code = re.sub(r"//[^\n]*|/\*[\s\S]*?\*/", "", path.read_text())
    imports = re.findall(r"^import\s+(\w+)", code, re.M)
    if set(imports) - {"Foundation"}:
        failures.append(f"{path.relative_to(root)}: shared import {imports}")
    if re.search(native_names, code):
        failures.append(f"{path.relative_to(root)}: native type in shared source")
    if any(path.is_relative_to(root / f"modules/{source}") for source in ("audio", "keyboard")) and re.search(r"\b(?:SoundFlightWorld|Pencil\w+|Visualization\w+)\b", code):
        failures.append(f"{path.relative_to(root)}: input source depends on visualization")

for platform in ("macos", "windows"):
    opposite = "windows" if platform == "macos" else "macos"
    native_files = [*root.glob(f"modules/**/platforms/{platform}/**/*.swift"), *root.glob(f"apps/{platform}/**/*.swift")]
    for path in native_files:
        if re.search(rf"(?:platforms|apps)/{opposite}/", path.read_text()):
            failures.append(f"{path.relative_to(root)}: cross-platform reference")

for path in root.glob("modules/visualizations/**/*.swift"):
    code = re.sub(r"//[^\n]*|/\*[\s\S]*?\*/", "", path.read_text())
    if re.search(r"\b(?:AudioEngine|KeyboardEngine|KeyboardEventTap|SCStream|AudioPCMDecoder|AccelerateSpectrumTransform)\b", code):
        failures.append(f"{path.relative_to(root)}: visualization depends on capture or analysis backend")

for path in (root / "scripts").glob("*"):
    if path.suffix in {".sh", ".py"} and path.name != "check-boundaries.py":
        if re.search(r"(?:Miucs|Tests|Tools)/[\w-]+\.swift", path.read_text()):
            failures.append(f"{path.relative_to(root)}: obsolete source path")

required = ["contracts/audio-features/frame.schema.json", "contracts/audio-features/input.schema.json",
            "contracts/visualization/README.md", "modules/audio/platforms/windows/README.md",
            "modules/visualizations/pencil-flight/platforms/windows/README.md", "apps/windows/README.md",
            "modules/visualizations/staff-note/platforms/windows/README.md",
            "CONTRIBUTING.md", "docs/architecture.md"]
for name in required:
    path = root / name
    if not path.is_file() or not path.read_text().strip():
        failures.append(f"Missing documented boundary: {name}")

if failures:
    raise SystemExit("\n".join(failures))
print(f"PASS Dependency boundaries ({len(shared)} shared source files; no Apple UI/capture/FFT imports)")
