#!/usr/bin/env python3
"""A live blueprint server. Edit the JSON, the graph updates.

    python3 -m tools.yume_inspect.server [game] [--port 8777] [--open]

WHY A SERVER AND NOT A REGENERATED FILE
---------------------------------------
The baked file is fine for handing someone a snapshot, and it stays — `render()`
still writes it. What it cannot do is close the loop while you work: every JSON
edit means re-running the generator and reloading the tab, which is exactly long
enough to stop doing it.

Three things only a server can do, in the order they pay off:

  1. LIVE RELOAD (here). Change a rule file; the graph redraws, camera position
     kept. Editing a `require` and watching an edge appear is a different
     activity from reading a static picture.
  2. ACTIONS (here, minimal). Run the validator bank without leaving the page.
  3. LIVE TRACE (not yet — needs an engine hook). Run the game and light up the
     nodes as rules actually fire. THAT is the ComfyUI property: the graph is not
     a diagram of the program, it is the program reporting on itself. It answers
     "why didn't this fire" by showing the signal arriving and no rule lighting
     up. Requires PhaseScheduler to emit a per-tick fired-rule list; see the
     module docstring note at the bottom.

AUTOMATING A SCREENSHOT OF THIS PAGE: point the capture at the BAKED file, not
at the server. An open EventSource keeps a headless browser permanently
"loading", so `--screenshot` never fires and the run dies on its timeout. The
served page and the baked file run the same `initGraph` on the same data, so the
baked one is a faithful capture.

DELIBERATELY ZERO DEPENDENCIES. stdlib `http.server` plus Server-Sent Events.
The push is one-way — the server says "the files changed" — so SSE is the honest
transport; a WebSocket would add a dependency to carry less meaning. File
watching is an mtime poll rather than `watchdog`, which for ~60 files costs
nothing measurable and keeps the tool runnable under any Python on the machine.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from tools.yume_inspect.graph import build          # noqa: E402
from tools.yume_inspect.render import page          # noqa: E402

DATA = REPO / "godot" / "data"
WATCH_GLOBS = ("world/**/*.json", "entities/**/*.json", "levels/**/*.json",
               "screens.json", "hud.json", "scene.json", "game/*.json", "ui/*.json")
POLL_SECONDS = 0.4


class Watcher(threading.Thread):
    """Poll mtimes; bump a revision counter when anything the graph reads moves."""

    daemon = True

    def __init__(self, game: str) -> None:
        super().__init__()
        self.dir = DATA / game
        self.rev = 0
        self._sig = self._snapshot()
        self._stop = threading.Event()

    def _snapshot(self) -> dict[str, float]:
        out: dict[str, float] = {}
        for g in WATCH_GLOBS:
            for p in self.dir.glob(g):
                try:
                    out[str(p)] = p.stat().st_mtime
                except OSError:
                    pass
        return out

    def run(self) -> None:
        while not self._stop.wait(POLL_SECONDS):
            snap = self._snapshot()
            if snap != self._sig:
                self._sig = snap
                self.rev += 1

    def stop(self) -> None:
        self._stop.set()


class Handler(BaseHTTPRequestHandler):
    game = "demo_thousandgate"
    watcher: Watcher | None = None
    protocol_version = "HTTP/1.1"

    # keep the console readable — one line per real request, not per asset
    def log_message(self, fmt: str, *a) -> None:
        if "/api/events" not in self.path:
            sys.stderr.write("  %s %s\n" % (self.command, self.path))

    # ---- helpers ----------------------------------------------------
    def _send(self, body: bytes, ctype: str, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code: int = 200) -> None:
        self._send(json.dumps(obj, ensure_ascii=False).encode(), "application/json; charset=utf-8", code)

    def _q(self) -> dict[str, list[str]]:
        return parse_qs(urlparse(self.path).query)

    def _game(self) -> str:
        return (self._q().get("game") or [self.game])[0]

    # ---- routes -----------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        route = urlparse(self.path).path
        try:
            if route in ("/", "/index.html"):
                # data=None -> the live bootstrap (fetch + SSE), same view as the
                # baked file
                self._send(page(self._game(), None).encode(), "text/html; charset=utf-8")
            elif route == "/api/graph":
                self._json(build(self._game()))
            elif route == "/api/events":
                self._events()
            elif route == "/favicon.ico":
                self._send(b"", "image/x-icon", 204)
            elif route == "/api/validate":
                self._json(self._validate(self._game()))
            else:
                self._json({"error": "no such route", "path": route}, 404)
        except BrokenPipeError:
            pass                                  # browser navigated away mid-stream
        except Exception as e:                    # noqa: BLE001
            # A dev tool that dies on one bad file is worse than one that reports
            # the file: an in-progress JSON edit is transiently invalid by nature.
            self._json({"error": type(e).__name__, "detail": str(e)}, 500)

    def _events(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        seen = self.watcher.rev if self.watcher else 0
        last_ping = time.time()
        while True:
            time.sleep(0.25)
            rev = self.watcher.rev if self.watcher else 0
            if rev != seen:
                seen = rev
                self.wfile.write(b"event: changed\ndata: %d\n\n" % rev)
                self.wfile.flush()
            elif time.time() - last_ping > 15:
                # A comment frame keeps proxies and sleeping tabs from dropping a
                # stream that is legitimately idle.
                last_ping = time.time()
                self.wfile.write(b": ping\n\n")
                self.wfile.flush()

    def _validate(self, game: str) -> dict:
        r = subprocess.run(
            [sys.executable, "tools/validators/run_all.py", game, "--strict"],
            cwd=REPO, capture_output=True, text=True, timeout=180)
        return {"ok": r.returncode == 0, "out": (r.stdout + r.stderr)[-8000:]}


def serve(game: str, port: int, open_browser: bool) -> None:
    Handler.game = game
    Handler.watcher = Watcher(game)
    Handler.watcher.start()
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/?game={game}"
    g = build(game)
    print(f"yume_inspect  {url}")
    print("  " + "  ".join(f"{k} {v}" for k, v in g["stats"].items()))
    for f in g["findings"]:
        print("  ! " + f["why"] + "  <- " + f["node"])
    print(f"  watching {Handler.watcher.dir}  (Ctrl-C 停止)")
    if open_browser:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n停止")
    finally:
        Handler.watcher.stop()
        srv.server_close()


def main() -> int:
    ap = argparse.ArgumentParser(prog="yume_inspect.server")
    ap.add_argument("game", nargs="?", default="demo_thousandgate")
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--open", action="store_true", help="open a browser")
    a = ap.parse_args()
    if not (DATA / a.game).is_dir():
        print(f"没有这个游戏: {DATA / a.game}", file=sys.stderr)
        return 2
    serve(a.game, a.port, a.open)
    return 0


if __name__ == "__main__":
    sys.exit(main())

# STAGE 3 NOTE — the live trace, and the one engine change it needs.
#
# PhaseScheduler already stamps `ctx["_rule_id"]` on every firing and funnels all
# effect commits through one seam (`_fire_effects`, added for ADR 0080). A trace
# is therefore a few lines at that seam: append the rule id to a per-tick list on
# env, and let a debug flag flush it to stdout as one JSON line per tick.
#
# The server then runs `scenario_test.tscn`, reads those lines, and replays them
# onto this graph as a timeline. At that point the page stops being a diagram of
# the program and becomes the program reporting on itself — which is the property
# that makes ComfyUI worth using, and the thing that would have answered "点了没
# 反应" in one glance instead of an hour.
