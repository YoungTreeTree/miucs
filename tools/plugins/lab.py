#!/usr/bin/env python3
"""Run deterministic scenarios or open the local Miucs plugin development lab."""

import argparse
import json
import sys
import webbrowser
from pathlib import Path
from preview import ROOT
from lab.scenario import load
from lab.session import Lab
from lab.server import PRESETS, make_server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command", choices=["serve", "run", "gifs"], nargs="?", default="serve"
    )
    parser.add_argument(
        "--plugin",
        type=Path,
        help="Plugin folder to select; built-ins remain available for switching",
    )
    parser.add_argument(
        "--scenario", default="music-typing", help="Preset name or scenario JSON path"
    )
    parser.add_argument("--output", type=Path, default=ROOT / "build/plugin-lab")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--gif-fps", type=int, default=16)
    parser.add_argument(
        "--gif-width", type=int, default=640, help="Maximum GIF side in pixels"
    )
    parser.add_argument(
        "--seconds", type=float, help="GIF duration; defaults to the full scenario"
    )
    args = parser.parse_args()
    path = Path(args.scenario)
    if not path.is_file():
        path = PRESETS / (args.scenario + ".json")
    folders = sorted(p.parent for p in (ROOT / "plugins").glob("*/manifest.json"))
    selected = None
    if args.plugin:
        folder = args.plugin.resolve()
        if folder not in [p.resolve() for p in folders]:
            folders.append(folder)
        selected = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))[
            "id"
        ]
    if args.command == "gifs":
        from lab.gifs import export_gifs

        result = export_gifs(
            folders,
            load(path),
            args.output / "gifs",
            args.gif_fps,
            args.gif_width,
            args.seconds,
        )
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if any("error" in p for p in result["report"]["plugins"]):
            raise RuntimeError("Some plugin previews failed; see manifest.json")
        return
    lab = Lab(folders, load(path), selected)
    try:
        if args.command == "run":
            try:
                while not lab.state()["done"]:
                    lab.step(120)
                report = lab.export(args.output)
            except Exception:
                # Preserve evidence even if the worker has stopped responding.
                args.output.mkdir(parents=True, exist_ok=True)
                (args.output / "failure.json").write_text(
                    json.dumps(
                        {
                            "error": lab.error,
                            "state": lab.state(),
                            "scenario": lab.case,
                        },
                        ensure_ascii=False,
                        indent=2,
                    ),
                    encoding="utf-8",
                )
                raise
            print(json.dumps(report, ensure_ascii=False, indent=2))
        else:
            server = make_server(lab, args.port, args.output)
            url = f"http://127.0.0.1:{server.server_port}/"
            print("Miucs plugin lab: " + url, flush=True)
            if not args.no_browser:
                webbrowser.open(url)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
            finally:
                server.server_close()
    finally:
        lab.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("Plugin lab: " + str(exc), file=sys.stderr)
        sys.exit(1)
