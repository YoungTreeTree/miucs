#!/usr/bin/env python3
"""Optimize an offline UI demo using a fresh palette and no inherited metadata."""
import json
import os
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageStat


def main():
    source, output = map(Path, sys.argv[1:])
    frames = []
    with Image.open(source) as image:
        size = image.size
        assert size in ((640, 416), (960, 600), (1200, 240)) and image.n_frames == 250
        desktop = size == (960, 600)
        first = image.convert("RGB")
        palette = first.quantize(colors=128 if desktop else 64, method=Image.Quantize.MEDIANCUT)
        for index in range(image.n_frames):
            image.seek(index)
            frame = image.convert("RGB").quantize(palette=palette, dither=Image.Dither.NONE)
            frame.info.clear()
            frames.append(frame)
    background_match = None
    if desktop:
        with Image.open(source.with_suffix(".background.png")) as image:
            background = image.convert("RGB")
        region = (508, 264, 908, 524)
        with Image.open(source.with_suffix(".first.png")) as image:
            # Check before GIF palette quantization: unchanged pixels are exactly equal.
            difference = ImageChops.difference(background.crop(region), image.convert("RGB").crop(region)).tobytes()
        pixels = len(difference) // 3
        background_match = sum(difference[i:i + 3] == b"\0\0\0" for i in range(0, len(difference), 3)) / pixels
        assert background_match > 0.85, "Widget must leave most desktop pixels unchanged"
        static_region = (0, 28, 400, 264)
        static_background = frames[0].convert("RGB").crop(static_region)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    frames[0].save(temporary, format="GIF", save_all=True, append_images=frames[1:],
                   duration=40, loop=0, disposal=1 if desktop else 2, optimize=True)
    review = source.parent / "review" / source.stem
    review.mkdir(parents=True, exist_ok=True)
    durations, changes = [], []
    with Image.open(temporary) as image:
        assert image.n_frames == 250 and image.size == size
        assert image.info.get("loop") == 0
        previous = None
        for index in range(image.n_frames):
            image.seek(index)
            # Only format/animation fields are allowed. No comments, EXIF, XMP or text.
            assert set(image.info) <= {"version", "background", "loop", "duration", "extension", "transparency"}, image.info.keys()
            if "extension" in image.info:
                assert image.info["extension"][0] == b"NETSCAPE2.0"
            durations.append(image.info["duration"])
            rgb = image.convert("RGB")
            assert ImageChops.difference(rgb, frames[index].convert("RGB")).getbbox() is None, f"Frame {index} changed during encoding"
            if desktop:
                assert ImageChops.difference(rgb.crop(static_region), static_background).getbbox() is None, "Desktop background flickers"
            if previous is not None:
                changes.append(sum(ImageStat.Stat(ImageChops.difference(rgb, previous)).mean))
            previous = rgb
            if index in (0, 62, 125, 187, 249):
                rgb.save(review / f"frame-{index:03d}.png")
    assert set(durations) == {40} and sum(durations) == 10_000
    assert min(changes) > 0 and temporary.stat().st_size < 5_000_000
    os.replace(temporary, output)
    report = {"frames": len(frames), "size": list(size), "durationSeconds": 10,
              "fps": 25, "bytes": output.stat().st_size, "loop": "infinite",
              "metadata": "format and animation fields only; inherited metadata removed",
              "allFramesChange": True, "allFramesMatchQuantizedSource": True, "source": "offline generated PCM and application renderer"}
    if desktop:
        report["desktopBackgroundStable"] = True
        report["unchangedDesktopFractionInsideWidget"] = background_match
        report["cursorAndSelection"] = "generated illustration, no input events"
    source.with_name(source.stem + "-verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Verified GIF: {len(frames)} frames, 10 s, {output.stat().st_size / 1_000_000:.2f} MB")


if __name__ == "__main__":
    main()
