#!/usr/bin/env python3
"""Record a SIDE-BY-SIDE video of a client-server net demo (ADR 0063-0065).

One command, no manual steps: sync the framework -> launch a HEADLESS dedicated
server + 2 rendering clients (each driving a character + capturing a real-time
frame sequence) -> ffmpeg-stitch the two sequences side by side into an mp4.
Proves synchronization visually (one walks north, one west; both views show both
characters in step).

Two backends:
  (default / --windows)  Windows Godot binary, real GPU (Intel iGPU) -> fast,
                         smooth, but the 2 client windows are VISIBLE.
  --linux                Linux Godot binary under Xvfb -> TRULY WINDOWLESS
                         (proper for CI / "render a confirmed run to a file").
                         Needs `sudo apt install -y xvfb` once; renders via
                         SOFTWARE GL (llvmpipe — no GPU in WSL), so slower.
                         Falls back to WSLg's display (:0) if Xvfb is absent
                         (works, but then windows are visible).

Usage:
  venv/bin/python scripts/net_video.py [game] [input1] [input2] [--linux]
  venv/bin/python scripts/net_video.py demo_tiny_village move_north move_west
  venv/bin/python scripts/net_video.py demo_tiny_village move_north move_west --linux

Env: PORT, FPS, SECS, DELAY (connect-wait), WIN_W, WIN_H, OUT.
"""
import glob
import datetime
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINUX = "--linux" in sys.argv
# --hidden (Windows backend): spawn the client windows OFF-SCREEN so the GPU still
# renders + we still capture, but nothing shows on the desktop. Effectively
# windowless video output without the Linux/Xvfb setup. (No effect on --linux,
# which is already windowless under Xvfb.)
HIDDEN = "--hidden" in sys.argv
# --smooth (ADR 0066): record the live netcode once (real-time), then RE-RENDER each
# view offline in Movie-Maker mode (--write-movie) → buttery 60fps regardless of GPU
# speed (slow GPU just takes longer to produce). Uses the stock binary → real meshes.
# Views are inherently synced (same recording, same fixed fps → identical frame count).
SMOOTH = "--smooth" in sys.argv
# --offscreen (truly windowless): the custom Godot build's --headless-render
# (--display-driver offscreen) renders via Vulkan with NO window at all — no Xvfb,
# no off-screen-window trick. NOTE: Vulkan here is software (lavapipe) → ~16% of
# real-time, so it's slower than the Windows-iGPU --hidden path; its value is being
# genuinely headless (CI / no display). Uses a separate 4.7 project + import cache.
OFFSCREEN = "--offscreen" in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
OFFSCREEN_PX = 5000  # px beyond the visible desktop (for the --hidden window trick)


def from_play_sh(var):
    txt = open(os.path.join(REPO, "scripts", "play.sh")).read()
    m = re.search(rf'^{var}="\$\{{[^:]+:-([^}}]+)\}}"', txt, re.M)
    return m.group(1) if m else None


GAME = ARGS[0] if len(ARGS) > 0 else "demo_tiny_village"
# Default: an in-place patrol (front/back/left/right cycle) — net_driver holds each
# direction PATTERN_DWELL_TICKS, so the character oscillates around its spawn instead
# of walking off the map. SAME pattern for every client → all characters do the
# identical dance in lockstep (server-tick-driven) = sync is obvious at a glance.
# Square path (N,E,S,W) so consecutive body turns are 90° each — not the 180°
# whip-arounds of N,S,E,W — and the character traces a small square back to start.
PATROL = "move_north,move_east,move_south,move_west"
SHORT = GAME[len("demo_"):] if GAME.startswith("demo_") else GAME

# Number of rendering clients. CLIENTS=4 → a 2x2 grid; 2 → side-by-side. Per-client
# input can be given positionally (after the game); any not given default to PATROL.
CLIENTS = int(os.environ.get("CLIENTS", "2"))
INPUTS = [(ARGS[1 + i] if len(ARGS) > 1 + i else PATROL) for i in range(CLIENTS)]

PORT = os.environ.get("PORT", "7862")
FPS = int(os.environ.get("FPS", "30"))   # OUTPUT video fps (capture grabs every rendered frame)
SECS = int(os.environ.get("SECS", "5"))  # real-time capture / record window
MOVIE_FPS = int(os.environ.get("MOVIE_FPS", "60"))  # --smooth: fixed Movie-Maker fps
CRF = os.environ.get("CRF", "18")  # libx264 quality (lower = better; 14 ≈ near-lossless, 23 = default)
DELAY = int(os.environ.get("DELAY", "20"))
WIN_W = os.environ.get("WIN_W", "700")
WIN_H = os.environ.get("WIN_H", "440")

if OFFSCREEN:
    GODOT = os.environ.get(
        "YUME_GODOT_OFFSCREEN_BIN",
        "/mnt/c/Users/kamwoh/Documents/Projects/Personal/godot/bin/godot.linuxbsd.template_debug.x86_64")
    PROJECT = os.environ.get("YUME_GODOT_OFFSCREEN_PROJECT", os.path.expanduser("~/godot-offscreen/yume"))
    USERDATA = os.path.expanduser("~/.local/share/godot/app_userdata/Yume Framework")
    HAVE_XVFB = False
elif LINUX:
    GODOT = os.environ.get("YUME_GODOT_LINUX_BIN",
                           os.path.expanduser("~/godot-linux/Godot_v4.6.1-stable_linux.x86_64"))
    PROJECT = os.environ.get("YUME_GODOT_LINUX_PROJECT", os.path.expanduser("~/godot-linux/yume"))
    USERDATA = os.path.expanduser("~/.local/share/godot/app_userdata/Yume Framework")
    HAVE_XVFB = shutil.which("xvfb-run") is not None
else:
    GODOT = os.environ.get("YUME_GODOT_BIN") or from_play_sh("GODOT_BIN")
    PROJECT = os.environ.get("YUME_TEMPLATE_DST") or from_play_sh("TEMPLATE_DST")
    USERDATA = os.environ.get(
        "YUME_USERDATA", "/mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume Framework")
    HAVE_XVFB = False

# All per-run scratch (captured frames, .ticks sidecars, the synced copies) lives
# in ONE subfolder of the userdata so the root never fills with loose vid_*.png.
# Wiped at start AND end of every run — so even a crashed run leaves just this one
# folder, cleaned by the next run. On disk: <userdata>/_netcap/; in Godot: user://_netcap/.
NETCAP = os.path.join(USERDATA, "_netcap")

# Each run lands in its own dated folder so recordings don't pile up loose in
# the userdata root: recordings/<game>_<YYYYMMDD_HHMMSS>/<game>.mp4. Override the
# full path with OUT=..., or the recordings root with REC_DIR=...
RUN_STAMP = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
REC_DIR = os.environ.get("REC_DIR", os.path.join(REPO, "recordings"))
RUN_DIR = os.path.join(REC_DIR, f"{SHORT}_{RUN_STAMP}")
OUT = os.environ.get("OUT") or os.path.join(RUN_DIR, f"{SHORT}.mp4")


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, **kw)


def kill_godot():
    if LINUX or OFFSCREEN:
        sh(f"pkill -f {os.path.basename(GODOT)} 2>/dev/null || true")
    else:
        sh('powershell.exe -Command "Get-Process Godot* -ErrorAction SilentlyContinue '
           '| Stop-Process -Force" 2>/dev/null')
    time.sleep(1)


def sync():
    if LINUX or OFFSCREEN:
        # WITH assets — the 3D meshes must be present + imported to render.
        sh(f'rsync -a --delete --exclude=.godot/ "{REPO}/godot/" "{PROJECT}/"')
    else:
        sh(f'cp -r "{REPO}/godot/." "{PROJECT}/"')
    if OFFSCREEN:
        # The 4.7-beta importer stalls on our 4.6.1 assets, so offscreen relies on a
        # PRE-SEEDED .godot import cache (set up out of band). Our changed files are
        # .gd scripts, which load directly (no import needed). Skip the import step.
        return
    env = "DISPLAY=:0 " if LINUX else ""
    sh(f'cd "{PROJECT}" && {env}"{GODOT}" --path . --headless --import >/dev/null 2>&1')


def pick_scene():
    for v in (f"{SHORT}_3d.tscn", f"{SHORT}_2d.tscn", f"{SHORT}.tscn"):
        if os.path.isfile(os.path.join(PROJECT, "scenes", v)):
            return f"scenes/{v}", []
    return "scenes/play.tscn", [f"--game={GAME}"]


def client_cmd(pos_x, pos_y, inp, after, tag):
    """A rendering client. offscreen: --headless-render (Vulkan, no window). Windows:
    a positioned window. Linux: Xvfb (windowless) or WSLg :0 fallback."""
    # --capture-after is now a fallback only: net_driver sets `yume_net_await_go`,
    # so capture_runner holds capture until the server's GO (both spawned) rather
    # than firing at a fixed delay. `after` left at 0.
    # --capture-allframes: grab EVERY rendered frame for SECS real seconds (no
    # sampling → no per-frame jumps), buffered in RAM + written after. We assemble
    # at the ACHIEVED fps (frames / SECS) so playback is real-time + smooth.
    user = ["--", *SCENE_ARGS, "--net-port", PORT, "--net-ticks", "6000", "--net-visual",
            f"--net-join=127.0.0.1:{PORT}", f"--net-input={inp}",
            f"--capture-after={after}", f"--capture-allframes={SECS}",
            f"--capture-output=user://_netcap/vid_{tag}.png"]
    if OFFSCREEN:
        # Truly windowless real render. NO --write-movie (that forces fixed-fps movie
        # mode → would desync the live ENet sim); we keep real-time + capture-allframes.
        cmd = [GODOT, "--headless-render", "--path", ".",
               "--resolution", f"{WIN_W}x{WIN_H}", SCENE] + user
        return cmd, {}
    g = [GODOT, "--path", ".", "--rendering-driver", "opengl3"]
    px = (OFFSCREEN_PX + pos_x) if HIDDEN else pos_x
    py = (OFFSCREEN_PX + pos_y) if HIDDEN else (60 + pos_y)
    win = ["--resolution", f"{WIN_W}x{WIN_H}", "--position", f"{px},{py}"]
    cmd = g + win + [SCENE] + user
    if LINUX and HAVE_XVFB:
        # Each client gets its OWN virtual display (-a auto-picks) → no windows,
        # no contention.
        return ["xvfb-run", "-a", "-s", f"-screen 0 {WIN_W}x{WIN_H}x24"] + cmd, {}
    if LINUX:
        return cmd, {"DISPLAY": ":0"}  # WSLg fallback — windows WILL be visible
    return cmd, {}


def grid_filter(cols, rows, n_inputs):
    """Build an ffmpeg filter_complex string: hstack each row, vstack the rows."""
    filt, rows_lbl = "", []
    for r in range(rows):
        ins = "".join(f"[{r * cols + c}:v]" for c in range(cols))
        filt += (f"{ins}null[row{r}];" if cols == 1
                 else f"{ins}hstack=inputs={cols}[row{r}];")
        rows_lbl.append(f"[row{r}]")
    if rows == 1:
        return filt.replace("[row0];", "[out]")
    return filt + "".join(rows_lbl) + f"vstack=inputs={rows}[out]"


def run_smooth():
    """ADR 0066: record the live sim once, then render each view offline in
    Movie-Maker mode (smooth fixed-fps), then grid-stitch. Stock binary → real
    meshes; views are inherently synced (same recording @ same fps)."""
    if not GODOT or not os.path.exists(GODOT):
        sys.exit(f"Godot binary not found: {GODOT}")
    print(f"[net_video] SMOOTH mode: record {CLIENTS}-player sim, re-render @ {MOVIE_FPS}fps (Movie-Maker)")
    kill_godot()
    print("[net_video] syncing framework + assets ...")
    sync()
    global SCENE, SCENE_ARGS
    SCENE, SCENE_ARGS = pick_scene()
    print(f"[net_video] scene: {SCENE}")
    shutil.rmtree(NETCAP, ignore_errors=True)
    os.makedirs(NETCAP, exist_ok=True)
    rec_user = "user://_netcap/netrec.json"
    rec_disk = os.path.join(NETCAP, "netrec.json")

    # --- Phase 1: record the live networked sim (all headless → fast, no GPU) ----
    procs, logs = {}, {}
    logs["server"] = open("/tmp/net_video_server.log", "w")
    procs["server"] = subprocess.Popen(
        [GODOT, "--path", ".", "--headless", SCENE, "--",
         *SCENE_ARGS, "--net-host", f"--net-port={PORT}", f"--net-clients={CLIENTS}",
         "--net-ticks=6000", f"--net-record={rec_user}", f"--net-record-secs={SECS}"],
        cwd=PROJECT, stdout=logs["server"], stderr=subprocess.STDOUT)
    time.sleep(int(os.environ.get("SERVER_WAIT", "14")))
    gap = int(os.environ.get("CLIENT_GAP", "4"))
    for i in range(CLIENTS):
        logs[f"c{i}"] = open(f"/tmp/net_video_c{i+1}.log", "w")
        procs[f"c{i}"] = subprocess.Popen(
            [GODOT, "--path", ".", "--headless", SCENE, "--",
             *SCENE_ARGS, f"--net-join=127.0.0.1:{PORT}", f"--net-port={PORT}",
             f"--net-input={PATROL}", "--net-ticks=6000"],
            cwd=PROJECT, stdout=logs[f"c{i}"], stderr=subprocess.STDOUT)
        print(f"[net_video] recording client {i+1}/{CLIENTS} ...")
        if i < CLIENTS - 1:
            time.sleep(gap)
    # The server quits after writing the record (SECS post-GO).
    budget = DELAY + SECS + 60 + CLIENTS * 20
    print(f"[net_video] waiting up to {budget}s for the record ...")
    t0 = time.time()
    while time.time() - t0 < budget and procs["server"].poll() is None:
        time.sleep(2)
    kill_godot()
    if not os.path.isfile(rec_disk):
        sys.exit(f"[net_video] ERROR: no record written ({rec_disk}) — see /tmp/net_video_server.log")
    rec = json.load(open(rec_disk))
    roster = [r["id"] for r in rec.get("roster", [])]
    print(f"[net_video] recorded {len(rec.get('frames', []))} frames, roster={roster}")
    if len(roster) < CLIENTS:
        sys.exit(f"[net_video] ERROR: roster has {len(roster)} players, expected {CLIENTS} "
                 f"(a client didn't connect — see /tmp/net_video_c*.log)")

    # --- Phase 2: render each view offline in Movie-Maker mode (smooth) ----------
    # Windowless render: --linux wraps in Xvfb (a VIRTUAL framebuffer → NO window
    # appears at all, genuinely headless). The Windows stock binary has no offscreen
    # driver, so it falls back to an off-screen window (--position 9999,9999).
    if LINUX and HAVE_XVFB:
        prefix = f'xvfb-run -a -s "-screen 0 {WIN_W}x{WIN_H}x24" '
        pos = ""
    else:
        prefix = ""
        pos = "--position 9999,9999 "
    for i, eid in enumerate(roster):
        viewdir = os.path.join(NETCAP, f"view{i}")
        os.makedirs(viewdir, exist_ok=True)
        where = "Xvfb (no window)" if (LINUX and HAVE_XVFB) else "off-screen window"
        print(f"[net_video] rendering view {i+1}/{len(roster)} (follow {eid}) @ {MOVIE_FPS}fps [{where}] ...")
        r = sh(f'cd "{PROJECT}" && {prefix}"{GODOT}" --path . --rendering-driver opengl3 '
               f'{pos}--resolution {WIN_W}x{WIN_H} '
               f'--write-movie "user://_netcap/view{i}/frame.png" --fixed-fps {MOVIE_FPS} '
               f'{SCENE} -- --replay={rec_user} --replay-follow={eid} '
               f'> /tmp/net_video_view{i}.log 2>&1')
        nfr = len(glob.glob(os.path.join(viewdir, "frame*.png")))
        print(f"[net_video]   view {i+1}: {nfr} frames")
        if nfr == 0:
            sys.exit(f"[net_video] ERROR: view {i+1} rendered no frames — see /tmp/net_video_view{i}.log")

    # --- Phase 3: grid-stitch (views share frame count → already aligned) --------
    cols = math.ceil(math.sqrt(len(roster)))
    rows = math.ceil(len(roster) / cols)
    cells = cols * rows
    frame_counts = [len(glob.glob(os.path.join(NETCAP, f"view{i}", "frame*.png"))) for i in range(len(roster))]
    nmin = min(frame_counts)
    # Drop the first few frames of every view: frame 0 is the spawn (T-pose, before
    # the AnimationPlayer seeks anim_phase) and the next 1-2 settle facing/pose. All
    # views drop the SAME count, so they stay synced.
    skip = min(int(os.environ.get("SKIP_FRAMES", "4")), max(0, nmin - 2))
    inputs = []
    for i in range(len(roster)):
        inputs += ["-framerate", str(MOVIE_FPS), "-start_number", str(skip),
                   "-i", f'"{os.path.join(NETCAP, f"view{i}", "frame%08d.png")}"']
    dur = (nmin - skip) / float(MOVIE_FPS)
    for _ in range(cells - len(roster)):
        inputs += ["-f", "lavfi", "-t", f"{dur:.3f}",
                   "-i", f"color=c=black:s={WIN_W}x{WIN_H}:r={MOVIE_FPS}"]
    filt = grid_filter(cols, rows, cells)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    print(f"[net_video] stitching {cols}x{rows} grid @ {MOVIE_FPS}fps crf={CRF} -> {OUT}")
    r = sh(f'ffmpeg -y {" ".join(inputs)} -filter_complex "{filt}" -map "[out]" '
           f'-r {MOVIE_FPS} -c:v libx264 -crf {CRF} -preset slow -pix_fmt yuv420p "{OUT}"',
           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r.returncode != 0 or not os.path.exists(OUT):
        sys.exit(f"[net_video] ffmpeg failed (filter: {filt})")
    shutil.rmtree(NETCAP, ignore_errors=True)
    print(f"[net_video] DONE -> {OUT}")


def main():
    if SMOOTH:
        run_smooth()
        return
    if not GODOT or not os.path.exists(GODOT):
        sys.exit(f"Godot binary not found: {GODOT}")
    if OFFSCREEN:
        backend = "offscreen (--headless-render, Vulkan/software — truly windowless)"
    elif LINUX:
        backend = "linux/" + ("xvfb (windowless)" if HAVE_XVFB else "WSLg :0 (windows visible!)")
    else:
        backend = "windows/GPU (off-screen — windowless)" if HIDDEN else "windows/GPU (windows visible)"
    print(f"[net_video] backend={backend}")
    print(f"[net_video] {GAME}: server + {CLIENTS} clients -> grid mp4")
    if LINUX and not HAVE_XVFB:
        print("[net_video] NOTE: xvfb-run not found — run `sudo apt install -y xvfb` for the "
              "truly-windowless render. Falling back to WSLg :0 (windows will show).")

    kill_godot()
    print("[net_video] syncing framework + assets ...")
    sync()

    global SCENE, SCENE_ARGS
    SCENE, SCENE_ARGS = pick_scene()
    print(f"[net_video] scene: {SCENE}")
    # Fresh scratch folder (also sweeps any legacy loose files from older versions).
    shutil.rmtree(NETCAP, ignore_errors=True)
    os.makedirs(NETCAP, exist_ok=True)
    for f in glob.glob(os.path.join(USERDATA, "vid_c*")) + glob.glob(os.path.join(USERDATA, "net_demo_video.mp4")):
        os.remove(f)

    # Output grid geometry: 4 clients -> 2x2, 2 -> 1x2, 3 -> 2x2 (one black cell), etc.
    cols = math.ceil(math.sqrt(CLIENTS))
    rows = math.ceil(CLIENTS / cols)
    tags = [f"c{i + 1}" for i in range(CLIENTS)]

    # --net-clients=N: the server waits for ALL N clients to join+spawn before it
    # broadcasts GO, so no client starts capturing/walking until everyone exists.
    server_user = ["--", *SCENE_ARGS, "--net-port", PORT, "--net-ticks", "6000",
                   "--net-host", "--net-clients", str(CLIENTS)]
    logs, procs = {}, {}

    print(f"[net_video] launching dedicated server (headless), expecting {CLIENTS} clients ...")
    logs["server"] = open("/tmp/net_video_server.log", "w")
    senv = dict(os.environ)
    procs["server"] = subprocess.Popen(
        [GODOT, "--path", ".", "--headless", SCENE, *server_user],
        cwd=PROJECT, stdout=logs["server"], stderr=subprocess.STDOUT, env=senv)
    # Fixed wait for the heavy 3D server to load before clients connect. (NOT
    # log-polling: Windows stdout is buffered, so the 'loaded' marker never shows
    # up in the file — a poll just times out and blows past the server's own
    # connect-timeout, so NO client connects. A fixed sleep is what actually works.)
    time.sleep(int(os.environ.get("SERVER_WAIT", "14")))
    print("[net_video] server load wait done — launching clients")

    def launch(tag, px, py, inp):
        cmd, extra_env = client_cmd(px, py, inp, 0, tag)
        e = dict(os.environ)
        e.update(extra_env)
        logs[tag] = open(f"/tmp/net_video_{tag}.log", "w")
        procs[tag] = subprocess.Popen(cmd, cwd=PROJECT, stdout=logs[tag],
                                      stderr=subprocess.STDOUT, env=e)

    # Small FIXED gap between clients (not log-polling — buffered) so they don't all
    # race the ENet handshake while loading at once. Each client's net_driver retries
    # the connection while the server loads, so staggering is just politeness.
    gap = int(os.environ.get("CLIENT_GAP", "4"))
    for i, tag in enumerate(tags):
        # Lay windows out in the same grid as the output (cosmetic when --hidden).
        px = (i % cols) * (int(WIN_W) + 20)
        py = (i // cols) * (int(WIN_H) + 40)
        print(f"[net_video] launching client {i + 1}/{CLIENTS} ({tag}) ...")
        launch(tag, px, py, INPUTS[i])
        if i < CLIENTS - 1:
            time.sleep(gap)

    # Every-frame capture: frame COUNT is unknown up front, so wait for ALL clients
    # to EXIT (each quits after writing its buffered PNGs). More clients = slower
    # simultaneous load + lower sim fps, so scale the budget with CLIENTS.
    budget = DELAY + SECS + 60 + CLIENTS * 20 + (120 if (LINUX or OFFSCREEN) else 0)
    print(f"[net_video] waiting up to {budget}s for all {CLIENTS} clients to finish ...")
    t0 = time.time()
    while time.time() - t0 < budget:
        if all(procs[t].poll() is not None for t in tags):
            break
        time.sleep(2)

    def frames(tag):
        return len(glob.glob(os.path.join(NETCAP, f"vid_{tag}_*.png")))

    def read_ticks(tag):
        try:
            return [int(x) for x in open(os.path.join(NETCAP, f"vid_{tag}.ticks")).read().split()]
        except OSError:
            return []

    n = {t: frames(t) for t in tags}
    tk = {t: read_ticks(t) for t in tags}
    fps = {t: max(1.0, n[t] / float(SECS)) for t in tags}
    print("[net_video] captured: " + ", ".join(f"{t}={n[t]}f(~{fps[t]:.1f}fps)" for t in tags))
    kill_godot()

    missing = [t for t in tags if n[t] == 0]
    if missing:
        sys.exit(f"[net_video] ERROR: {missing} captured no frames — see /tmp/net_video_*.log "
                 f"(connection? more clients load slower — bump DELAY / CLIENT_GAP / SERVER_WAIT).")

    # Connection verification — frames alone don't prove a client CONNECTED (a
    # disconnected one still renders an empty fallback). Check the POSITIVE per-client
    # "controls + follows netplayer" line (the client log flushes; the server's
    # doesn't under Windows buffering).
    def connected(tag):
        try:
            return "controls + follows netplayer" in open(f"/tmp/net_video_{tag}.log").read()
        except OSError:
            return False
    bad = [t for t in tags if not connected(t)]
    if bad:
        sys.exit(f"[net_video] ERROR: {bad} never connected (no 'controls + follows netplayer') — "
                 f"capture is the disconnected fallback, not real multiplayer. Bump DELAY / "
                 f"CLIENT_GAP / SERVER_WAIT; {CLIENTS} clients load slowly together.")

    # --- Sync ALL clients by SERVER TICK ------------------------------------
    # Each client wrote a .ticks sidecar (the authoritative tick each frame SHOWS).
    # Drive the timeline from client 1's real-time frames; for each, pair every other
    # client's nearest-tick frame → all cells render the SAME game tick at once.
    def nearest_idx(ticks, target):
        best_i, best_d = 0, None
        for i, t in enumerate(ticks):
            if t <= 0:
                continue  # pre-first-snapshot frames carry no real tick
            d = abs(t - target)
            if best_d is None or d < best_d:
                best_i, best_d = i, d
        return best_i

    pos = {t: [x for x in tk[t] if x > 0] for t in tags}
    sync_dir = os.path.join(NETCAP, "_sync")
    have_ticks = all(pos[t] and len(tk[t]) == n[t] for t in tags)
    if have_ticks:
        lo = max(min(pos[t]) for t in tags)  # shared tick window across ALL clients
        hi = min(max(pos[t]) for t in tags)
        os.makedirs(sync_dir, exist_ok=True)
        for f in glob.glob(os.path.join(sync_dir, "*.png")):
            os.remove(f)
        drv = tags[0]
        k = 0
        for i0 in range(n[drv]):
            if not (lo <= tk[drv][i0] <= hi):
                continue
            for t in tags:
                idx = i0 if t == drv else nearest_idx(tk[t], tk[drv][i0])
                shutil.copyfile(os.path.join(NETCAP, f"vid_{t}_{idx:04d}.png"),
                                os.path.join(sync_dir, f"{t}_{k:04d}.png"))
            k += 1
        rate = max(1.0, fps[drv])
        print(f"[net_video] tick-synced: {k} paired frames/client over ticks {lo}..{hi} "
              f"(playback ~{k / rate:.1f}s @ real-time)")
        srcdir, pat_dir, frame_count = sync_dir, True, k
    else:
        print("[net_video] WARNING: missing .ticks — cells may not be synced (raw assembly)")
        srcdir, pat_dir = NETCAP, False
        frame_count = min(n[t] for t in tags)
        rate = max(1.0, min(fps[t] for t in tags))

    # --- Grid stitch (cols x rows), padding any empty cells with black ------
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    cells = cols * rows
    inputs = []
    for t in tags:
        src = os.path.join(srcdir, (f"{t}_%04d.png" if pat_dir else f"vid_{t}_%04d.png"))
        inputs += ["-framerate", f"{rate:.4f}", "-i", f'"{src}"']  # quote: path has spaces
    dur = frame_count / rate
    for _ in range(cells - CLIENTS):  # black filler for unused grid cells
        inputs += ["-f", "lavfi", "-t", f"{dur:.3f}",
                   "-i", f"color=c=black:s={WIN_W}x{WIN_H}:r={rate:.4f}"]
    # Build each row with hstack, then vstack the rows.
    filt, row_labels = "", []
    for r_ in range(rows):
        ins = "".join(f"[{r_ * cols + c}:v]" for c in range(cols))
        filt += (f"{ins}null[row{r_}];" if cols == 1
                 else f"{ins}hstack=inputs={cols}[row{r_}];")
        row_labels.append(f"[row{r_}]")
    if rows == 1:
        filt = filt.replace("[row0];", "[out]")
    else:
        filt += "".join(row_labels) + f"vstack=inputs={rows}[out]"
    print(f"[net_video] stitching {cols}x{rows} grid @ {FPS}fps crf={CRF} -> {OUT}")
    r = sh(f'ffmpeg -y {" ".join(inputs)} -filter_complex "{filt}" -map "[out]" '
           f'-r {FPS} -c:v libx264 -crf {CRF} -preset slow -pix_fmt yuv420p "{OUT}"',
           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r.returncode != 0 or not os.path.exists(OUT):
        sys.exit(f"[net_video] ffmpeg failed (filter: {filt})")
    # Remove the whole scratch folder — the dated-folder mp4 is the only keeper.
    shutil.rmtree(NETCAP, ignore_errors=True)
    print(f"[net_video] DONE -> {OUT}")


SCENE, SCENE_ARGS = "", []
if __name__ == "__main__":
    main()
