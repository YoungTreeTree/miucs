"""Comparable animated previews: identical virtual input, independent plugin instances."""

import copy
import hashlib
import html
import json
import math
import re
import tempfile
import zipfile
from pathlib import Path

from .scenario import Signals, number, validate
from .session import Lab


def record_bytes(frame, commands):
    return (
        json.dumps(
            {"input": frame, "commands": commands},
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        + "\n"
    ).encode()


def export_gifs(folders, scenario, output, fps=16, width=640, seconds=None):
    try:
        from PIL import Image, ImageOps
    except ImportError as exc:
        raise RuntimeError(
            "GIF export needs Pillow: python -m pip install -r tools/plugins/requirements.txt"
        ) from exc

    number(fps, 1, 30)
    number(width, 32, 1024)
    if int(width) != width or int(fps) != fps:
        raise ValueError("GIF width and FPS must be integers")
    fps, width = int(fps), int(width)
    case = validate(scenario)
    duration = case.get("duration", 10)
    if seconds is not None:
        number(seconds, 0.1, duration)
        duration = seconds
    case["duration"] = duration
    # Each GIF belongs to one skin. Switching would turn all previews into the same skin.
    ignored = [e for e in case["events"] if e["type"] == "switch"]
    case["events"] = [
        e for e in case["events"] if e["type"] != "switch" and e["at"] < duration
    ]
    count = math.ceil(duration * fps - 1e-9)
    delays = [
        round(min((i + 1) / fps, duration) * 100) * 10 - round(i / fps * 100) * 10
        for i in range(count)
    ]
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    catalog = []
    names = set()
    for folder in folders:
        folder = Path(folder).resolve()
        m = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
        identity = m["id"]
        if not isinstance(identity, str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", identity
        ):
            raise ValueError("Plugin ID cannot be used as a GIF filename")
        if identity.lower() in names:
            raise ValueError("Duplicate or case-colliding plugin ID: " + identity)
        names.add(identity.lower())
        catalog.append((folder, m))
    if not catalog:
        raise ValueError("No plugins found")

    def write(path, value):
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
            encoding="utf-8",
        )

    with tempfile.TemporaryDirectory(prefix=".gif-export-", dir=output) as temp:
        stage = Path(temp)
        write(stage / "scenario.json", case)
        signals = Signals(case)
        digest = hashlib.sha256()
        input_times = []
        with (stage / "inputs.ndjson").open("wb") as stream:
            while signals.time < duration - 1e-9:
                frame, commands = signals.tick()
                input_times.append(signals.time)
                raw = record_bytes(frame, commands)
                stream.write(raw)
                digest.update(raw)
        input_hash = digest.hexdigest()
        results = []
        for folder, manifest in catalog:
            identity = manifest["id"]
            result = {
                "id": identity,
                "name": manifest["name"],
                "version": manifest["version"],
            }
            lab = None
            frames = []
            try:
                lab = Lab([folder], copy.deepcopy(case), identity)
                view = lab.viewport
                ratio = min(width / view["width"], width / view["height"])
                size = (
                    max(1, round(view["width"] * ratio)),
                    max(1, round(view["height"] * ratio)),
                )
                if size[0] * size[1] * count > 128 * 1024 * 1024:
                    raise ValueError(
                        "GIF frame budget exceeds 128 MiB; reduce width, FPS or seconds"
                    )
                for i in range(count):
                    target = i / fps
                    # Hold the previous frame during a simulated stall, rather than
                    # displaying a state from the future before its update completes.
                    while (
                        len(lab.trace) < len(input_times)
                        and input_times[len(lab.trace)] <= target + 1e-9
                    ):
                        lab.step()
                    canvas = Image.new("RGBA", size, "#f6f4ef")
                    if not lab.signals.hidden and not lab.signals.suspended:
                        view = lab.viewport
                        fit = min(size[0] / view["width"], size[1] / view["height"])
                        render_size = (
                            max(1, round(view["width"] * fit)),
                            max(1, round(view["height"] * fit)),
                        )
                        w, h, bgra = lab.pixels(render_size)
                        # Skia returns premultiplied BGRA. Unpremultiply before matte composition.
                        rgba = Image.frombytes(
                            "RGBa", (w, h), bgra, "raw", "BGRa"
                        ).convert("RGBA")
                        rgba = ImageOps.contain(rgba, size)
                        canvas.alpha_composite(
                            rgba,
                            ((size[0] - rgba.width) // 2, (size[1] - rgba.height) // 2),
                        )
                    frames.append(
                        canvas.convert("RGB").quantize(
                            colors=256, method=Image.Quantize.MEDIANCUT
                        )
                    )
                while not lab.state()["done"]:
                    lab.step(120)
                actual = hashlib.sha256()
                for row in lab.trace:
                    actual.update(record_bytes(row["input"], row["commands"]))
                if actual.hexdigest() != input_hash:
                    raise RuntimeError(
                        "Plugin replay diverged from the shared input stream"
                    )
                filename = identity + ".gif"
                frames[0].save(
                    stage / filename,
                    format="GIF",
                    save_all=True,
                    append_images=frames[1:],
                    duration=delays,
                    loop=0,
                    disposal=2,
                    optimize=False,
                )
                with Image.open(stage / filename) as decoded:
                    encoded_count = decoded.n_frames
                    encoded_ms = 0
                    for n in range(encoded_count):
                        decoded.seek(n)
                        encoded_ms += decoded.info["duration"]
                if encoded_ms != sum(delays):
                    raise RuntimeError("GIF encoder changed playback duration")
                result.update(
                    file=filename,
                    width=size[0],
                    height=size[1],
                    samples=count,
                    encodedFrames=encoded_count,
                    durationMs=encoded_ms,
                    inputHash=input_hash,
                    inputFrames=len(lab.trace),
                )
            except Exception as exc:
                result["error"] = str(exc)
                (stage / (identity + ".gif")).unlink(missing_ok=True)
            finally:
                if lab:
                    lab.close()
                for image in frames:
                    image.close()
            results.append(result)

        report = {
            "scenario": case["name"],
            "seed": case.get("seed", 1),
            "seconds": duration,
            "gifFPS": fps,
            "maximumSide": width,
            "background": "#f6f4ef",
            "inputHash": input_hash,
            "inputFrames": signals.index,
            "ignoredSwitchEvents": ignored,
            "plugins": results,
        }
        write(stage / "manifest.json", report)
        cards = []
        for r in results:
            title = html.escape(r["name"]) + " / " + html.escape(r["id"])
            body = (
                "<p>" + html.escape(r["error"]) + "</p>"
                if "error" in r
                else '<img src="'
                + r["file"]
                + '" alt="'
                + title
                + '"><p><a href="'
                + r["file"]
                + '" download>下载 GIF</a></p>'
            )
            cards.append("<article><h2>" + title + "</h2>" + body + "</article>")
        (stage / "index.html").write_text(
            '<!doctype html><meta charset="utf-8"><title>Miucs 皮肤动态预览</title>'
            "<style>body{font:16px system-ui;background:#eef0f4;color:#263244;margin:32px}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:24px}article{background:white;border-radius:16px;padding:20px}img{max-width:100%;height:auto}h2{font-size:18px}</style>"
            "<h1>Miucs · 统一输入动态预览</h1><p>"
            + html.escape(case["name"])
            + " · seed "
            + str(case.get("seed", 1))
            + " · "
            + str(duration)
            + " 秒 · "
            + str(fps)
            + " FPS</p><main>"
            + "".join(cards)
            + "</main>",
            encoding="utf-8",
        )
        files = sorted(p.name for p in stage.iterdir())
        with zipfile.ZipFile(
            stage / "previews.zip", "w", zipfile.ZIP_DEFLATED
        ) as archive:
            for name in files:
                archive.write(stage / name, name)
        files.append("previews.zip")
        for result in results:
            if "error" in result:
                (output / (result["id"] + ".gif")).unlink(missing_ok=True)
        for name in files:
            (stage / name).replace(output / name)
    return {"directory": str(output), "files": files, "report": report}
