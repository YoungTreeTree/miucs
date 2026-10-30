"""Loopback-only, token-authenticated developer UI; all native work is serialized."""

import json
import secrets
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from .scenario import load

PRESETS = Path(__file__).parent / "scenarios"
EXPORTS = {"scenario.json", "scene.json", "frames.ndjson", "preview.png", "report.json"}


def make_server(lab, port, output):
    token = secrets.token_urlsafe(32)
    output = Path(output).resolve()
    gif_files = set()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, status, data, content_type="application/json; charset=utf-8"):
            if not isinstance(data, bytes):
                data = json.dumps(data, ensure_ascii=False, allow_nan=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
            )
            self.end_headers()
            self.wfile.write(data)

        def authorized(self):
            expected = f"127.0.0.1:{self.server.server_port}"
            if self.headers.get("Host") != expected:
                self.send(403, {"error": "Invalid Host"})
                return False
            origin = self.headers.get("Origin")
            if origin and origin != "http://" + expected:
                self.send(403, {"error": "Invalid Origin"})
                return False
            if self.path != "/" and self.headers.get("X-Miucs-Lab") != token:
                self.send(403, {"error": "Missing session token"})
                return False
            return True

        def do_GET(self):
            if not self.authorized():
                return
            try:
                route = urlsplit(self.path).path
                if route == "/":
                    page = (Path(__file__).parent / "index.html").read_text(
                        encoding="utf-8"
                    )
                    self.send(
                        200,
                        page.replace("__SESSION_TOKEN__", token).encode(),
                        "text/html; charset=utf-8",
                    )
                elif route == "/api/catalog":
                    self.send(
                        200,
                        {
                            "plugins": [x["manifest"] for x in lab.catalog.values()],
                            "presets": [
                                load(p) | {"preset": p.stem}
                                for p in sorted(PRESETS.glob("*.json"))
                            ],
                        },
                    )
                elif route == "/api/state":
                    self.send(200, lab.state(with_pixels=True))
                elif route == "/api/scene":
                    self.send(200, lab.bridge.inspect())
                elif route == "/api/scenario":
                    self.send(200, lab.case)
                elif (
                    route.startswith("/api/gif/")
                    and route.removeprefix("/api/gif/") in gif_files
                ):
                    name = route.removeprefix("/api/gif/")
                    self.send(
                        200,
                        (output / "gifs" / name).read_bytes(),
                        "image/gif"
                        if name.endswith(".gif")
                        else "application/octet-stream",
                    )
                elif (
                    route.startswith("/api/download/")
                    and route.rsplit("/", 1)[-1] in EXPORTS
                ):
                    name = route.rsplit("/", 1)[-1]
                    self.send(
                        200,
                        (output / name).read_bytes(),
                        "image/png"
                        if name.endswith(".png")
                        else "application/octet-stream",
                    )
                else:
                    self.send(404, {"error": "Not found"})
            except Exception as exc:
                self.send(400, {"error": str(exc)})

        def do_POST(self):
            if not self.authorized():
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 1024 * 1024:
                    raise ValueError("Request must be 1 byte..1 MiB")
                data = json.loads(self.rfile.read(length))
                if not isinstance(data, dict):
                    raise ValueError("Expected JSON object")
                route = self.path
                if route == "/api/reset":
                    lab.reset(data["scenario"], data.get("plugin"))
                elif route == "/api/step":
                    lab.step(data.get("count", 1))
                elif route == "/api/seek":
                    lab.seek(data["time"])
                elif route == "/api/event":
                    lab.add_event(data["type"], data.get("value", {}))
                elif route == "/api/reload":
                    lab.reload()
                elif route == "/api/watch":
                    lab.watch()
                elif route == "/api/gifs":
                    from .gifs import export_gifs

                    result = export_gifs(
                        [p["directory"] for p in lab.catalog.values()],
                        lab.case,
                        output / "gifs",
                        data.get("fps", 16),
                        data.get("width", 640),
                        data.get("seconds"),
                    )
                    gif_files.clear()
                    gif_files.update(result["files"])
                    self.send(200, result)
                    return
                elif route == "/api/export":
                    report = lab.export(output)
                    self.send(
                        200,
                        {
                            "directory": str(output),
                            "files": sorted(EXPORTS),
                            "report": report,
                        },
                    )
                    return
                else:
                    self.send(404, {"error": "Not found"})
                    return
                self.send(200, lab.state(with_pixels=True))
            except Exception as exc:
                self.send(400, {"error": str(exc)})

    server = HTTPServer(("127.0.0.1", port), Handler)
    server.timeout = 0.5
    return server
