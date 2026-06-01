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
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
OFFSCREEN = 5000  # px beyond the visible desktop


def from_play_sh(var):
    txt = open(os.path.join(REPO, "scripts", "play.sh")).read()
    m = re.search(rf'^{var}="\$\{{[^:]+:-([^}}]+)\}}"', txt, re.M)
    return m.group(1) if m else None


GAME = ARGS[0] if len(ARGS) > 0 else "demo_tiny_village"
# Default: an in-place patrol (front/back/left/right cycle) — net_driver holds each
# direction PATTERN_DWELL_SEC, so the character oscillates around its spawn instead
# of walking off the map. SAME pattern for both clients → the side-by-side shows the
# two characters doing the identical dance in lockstep = sync is obvious at a glance.
PATROL = "move_north,move_south,move_east,move_west"
INPUT1 = ARGS[1] if len(ARGS) > 1 else PATROL
INPUT2 = ARGS[2] if len(ARGS) > 2 else PATROL
SHORT = GAME[len("demo_"):] if GAME.startswith("demo_") else GAME

PORT = os.environ.get("PORT", "7862")
FPS = int(os.environ.get("FPS", "30"))   # OUTPUT video fps (capture grabs every rendered frame)
SECS = int(os.environ.get("SECS", "5"))  # real-time capture window
DELAY = int(os.environ.get("DELAY", "20"))
WIN_W = os.environ.get("WIN_W", "700")
WIN_H = os.environ.get("WIN_H", "440")

if LINUX:
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
    if LINUX:
        sh(f"pkill -f {os.path.basename(GODOT)} 2>/dev/null || true")
    else:
        sh('powershell.exe -Command "Get-Process Godot* -ErrorAction SilentlyContinue '
           '| Stop-Process -Force" 2>/dev/null')
    time.sleep(1)


def sync():
    if LINUX:
        # WITH assets — the 3D meshes must be present + imported to render.
        sh(f'rsync -a --delete --exclude=.godot/ "{REPO}/godot/" "{PROJECT}/"')
    else:
        sh(f'cp -r "{REPO}/godot/." "{PROJECT}/"')
    env = "DISPLAY=:0 " if LINUX else ""
    sh(f'cd "{PROJECT}" && {env}"{GODOT}" --path . --headless --import >/dev/null 2>&1')


def pick_scene():
    for v in (f"{SHORT}_3d.tscn", f"{SHORT}_2d.tscn", f"{SHORT}.tscn"):
        if os.path.isfile(os.path.join(PROJECT, "scenes", v)):
            return f"scenes/{v}", []
    return "scenes/play.tscn", [f"--game={GAME}"]


def client_cmd(pos_x, inp, after, tag):
    """A rendering client. Windows: a positioned window. Linux: Xvfb (windowless)
    or WSLg :0 fallback."""
    g = [GODOT, "--path", ".", "--rendering-driver", "opengl3"]
    py = OFFSCREEN if HIDDEN else 60
    px = (OFFSCREEN + pos_x) if HIDDEN else pos_x
    win = ["--resolution", f"{WIN_W}x{WIN_H}", "--position", f"{px},{py}"]
    # --capture-after is now a fallback only: net_driver sets `yume_net_await_go`,
    # so capture_runner holds capture until the server's GO (both spawned) rather
    # than firing at a fixed delay. `after` left at 0.
    # --capture-allframes: grab EVERY rendered frame for SECS real seconds (no
    # sampling → no per-frame jumps), buffered in RAM + written after. We assemble
    # at the ACHIEVED fps (frames / SECS) so playback is real-time + smooth.
    user = ["--", *SCENE_ARGS, "--net-port", PORT, "--net-ticks", "6000", "--net-visual",
            f"--net-join=127.0.0.1:{PORT}", f"--net-input={inp}",
            f"--capture-after={after}", f"--capture-allframes={SECS}",
            f"--capture-output=user://vid_{tag}.png"]
    cmd = g + win + [SCENE] + user
    if LINUX and HAVE_XVFB:
        # Each client gets its OWN virtual display (-a auto-picks) → no windows,
        # no contention.
        return ["xvfb-run", "-a", "-s", f"-screen 0 {WIN_W}x{WIN_H}x24"] + cmd, {}
    if LINUX:
        return cmd, {"DISPLAY": ":0"}  # WSLg fallback — windows WILL be visible
    return cmd, {}


def main():
    if not GODOT or not os.path.exists(GODOT):
        sys.exit(f"Godot binary not found: {GODOT}")
    backend = "linux/" + ("xvfb (windowless)" if HAVE_XVFB else "WSLg :0 (windows visible!)") \
        if LINUX else ("windows/GPU (off-screen — windowless)" if HIDDEN else "windows/GPU (windows visible)")
    print(f"[net_video] backend={backend}")
    print(f"[net_video] {GAME}: server + 2 clients ({INPUT1} / {INPUT2}) -> side-by-side mp4")
    if LINUX and not HAVE_XVFB:
        print("[net_video] NOTE: xvfb-run not found — run `sudo apt install -y xvfb` for the "
              "truly-windowless render. Falling back to WSLg :0 (windows will show).")

    kill_godot()
    print("[net_video] syncing framework + assets ...")
    sync()

    global SCENE, SCENE_ARGS
    SCENE, SCENE_ARGS = pick_scene()
    print(f"[net_video] scene: {SCENE}")
    for f in glob.glob(os.path.join(USERDATA, "vid_c*_*.png")):
        os.remove(f)

    # --net-clients=2: the server waits for BOTH clients to join+spawn before it
    # broadcasts GO, so neither client starts capturing/walking until both exist.
    server_user = ["--", *SCENE_ARGS, "--net-port", PORT, "--net-ticks", "6000",
                   "--net-host", "--net-clients", "2"]
    logs, procs = {}, {}

    print("[net_video] launching dedicated server (headless) ...")
    logs["server"] = open("/tmp/net_video_server.log", "w")
    senv = dict(os.environ)
    # Dedicated server is headless (correct design; not the connection issue —
    # windowed-offscreen server tested identically). Linux headless ENet is proven
    # (run_linux.sh net). NOTE: net_driver + Windows windowed CLIENTS don't connect
    # in this sandbox (players=0 confirmed via diagnostics) — a quirk distinct from
    # lockstep_demo (windowed, connects) + run_linux net (headless, connects).
    procs["server"] = subprocess.Popen(
        [GODOT, "--path", ".", "--headless", SCENE, *server_user],
        cwd=PROJECT, stdout=logs["server"], stderr=subprocess.STDOUT, env=senv)
    # Fixed wait for the heavy 3D server to load before clients connect. (NOT
    # log-polling: Windows stdout is buffered, so the 'loaded' marker never shows
    # up in the file — a poll just times out and blows past the server's own
    # connect-timeout, so NO client connects. A fixed sleep is what actually works.)
    time.sleep(int(os.environ.get("SERVER_WAIT", "14")))
    print("[net_video] server load wait done — launching clients")

    def launch(tag, pos_x, inp, after):
        cmd, extra_env = client_cmd(pos_x, inp, after, tag)
        e = dict(os.environ)
        e.update(extra_env)
        logs[tag] = open(f"/tmp/net_video_{tag}.log", "w")
        procs[tag] = subprocess.Popen(cmd, cwd=PROJECT, stdout=logs[tag],
                                      stderr=subprocess.STDOUT, env=e)

    # Small FIXED gap between clients (not log-polling — buffered). Enough to keep
    # the two from racing the ENet handshake while loading simultaneously, short
    # enough that both still connect well within the server's connect-timeout.
    gap = int(os.environ.get("CLIENT_GAP", "4"))
    # after=0: capture is GO-gated now (server signals when both spawned), so the
    # fixed per-client delay no longer drives the start.
    print("[net_video] launching client 1 (left) ...")
    launch("c1", 0, INPUT1, 0)
    time.sleep(gap)
    print("[net_video] launching client 2 (right) ...")
    launch("c2", int(WIN_W) + 20, INPUT2, 0)

    # Every-frame capture: the frame COUNT is unknown up front (depends on the
    # achieved render fps), so wait for both client processes to EXIT — each quits
    # right after writing its buffered PNGs — rather than polling for a fixed last
    # frame index.
    budget = DELAY + SECS + (90 if LINUX else 50)  # software GL / RAM-flush needs more time
    print(f"[net_video] waiting up to {budget}s for both clients to finish capture ...")
    t0 = time.time()
    while time.time() - t0 < budget:
        if procs["c1"].poll() is not None and procs["c2"].poll() is not None:
            break
        time.sleep(2)

    n1 = len(glob.glob(os.path.join(USERDATA, "vid_c1_*.png")))
    n2 = len(glob.glob(os.path.join(USERDATA, "vid_c2_*.png")))
    # Achieved fps = frames captured over the SECS real-time window. Assembling each
    # input at its own achieved fps makes both clips exactly SECS long → they align
    # in the side-by-side, and motion plays at true real-time speed (no compression).
    fps1 = max(1.0, n1 / float(SECS))
    fps2 = max(1.0, n2 / float(SECS))
    print(f"[net_video] captured: client1={n1} frames (~{fps1:.1f} fps), "
          f"client2={n2} frames (~{fps2:.1f} fps) over {SECS}s")
    kill_godot()

    if n1 == 0 or n2 == 0:
        sys.exit("[net_video] ERROR: a client captured no frames — see /tmp/net_video_*.log "
                 "(connection? on a slow box bump DELAY).")

    # Connection verification — frames alone don't prove the clients CONNECTED; a
    # disconnected client still renders an empty/oblique fallback. Check the POSITIVE
    # signal each client prints on a successful spawn+assign ("controls + follows
    # netplayer"). The server log can't be trusted here (Windows buffers stdout and
    # the server is killed before flush); the client lines DO flush. Empirical
    # 2026-06-01: the old "absence of connect-timeout" check false-passed because
    # the server hadn't hit its 120s timeout before being killed.
    def _connected(tag):
        try:
            return "controls + follows netplayer" in open(f"/tmp/net_video_{tag}.log").read()
        except OSError:
            return False
    if not (_connected("c1") and _connected("c2")):
        sys.exit("[net_video] ERROR: a client never connected (no 'controls + follows netplayer' "
                 "in its log) — the capture is the disconnected fallback, not real multiplayer. "
                 "See /tmp/net_video_c1.log / c2.log; bump DELAY on a slow box. NOTE: server and "
                 "client --net-port must match — net_driver now accepts both --net-port=N and "
                 "--net-port N forms, so a form mismatch is no longer the cause.")

    # --- Sync the two halves by SERVER TICK ---------------------------------
    # Each client wrote a .ticks sidecar: the authoritative server tick each frame
    # SHOWS. We pair frames by that shared tick so the left/right halves render the
    # same game moment, regardless of per-client render fps or capture-start jitter.
    def read_ticks(tag):
        try:
            lines = open(os.path.join(USERDATA, f"vid_{tag}.ticks")).read().split()
            return [int(x) for x in lines]
        except OSError:
            return []
    tk1, tk2 = read_ticks("c1"), read_ticks("c2")

    def nearest_idx(ticks, target):
        # ticks is monotonic-nondecreasing; linear scan is plenty for ~150 frames.
        best_i, best_d = 0, None
        for i, t in enumerate(ticks):
            if t <= 0:
                continue  # pre-first-snapshot frames carry no real tick
            d = abs(t - target)
            if best_d is None or d < best_d:
                best_i, best_d = i, d
        return best_i

    pos1 = [t for t in tk1 if t > 0]
    pos2 = [t for t in tk2 if t > 0]
    sync_dir = os.path.join(USERDATA, "_sync")
    if pos1 and pos2 and len(tk1) == n1 and len(tk2) == n2:
        # Drive the timeline from client 1's frames — they're already real-time
        # (every captured frame, uniform over the SECS window). For each c1 frame in
        # the shared tick range, pair client 2's nearest-tick frame. This keeps the
        # left half real-time + smooth and locks the right half to the SAME server
        # tick, with NO assumption about the sim's tick rate (which sags under the
        # 3-instance capture load). Assemble at c1's achieved fps → real-time.
        lo, hi = max(min(pos1), min(pos2)), min(max(pos1), max(pos2))
        os.makedirs(sync_dir, exist_ok=True)
        for f in glob.glob(os.path.join(sync_dir, "*.png")):
            os.remove(f)
        k = 0
        for i1 in range(n1):
            if not (lo <= tk1[i1] <= hi):
                continue
            i2 = nearest_idx(tk2, tk1[i1])
            shutil.copyfile(os.path.join(USERDATA, f"vid_c1_{i1:04d}.png"),
                            os.path.join(sync_dir, f"c1_{k:04d}.png"))
            shutil.copyfile(os.path.join(USERDATA, f"vid_c2_{i2:04d}.png"),
                            os.path.join(sync_dir, f"c2_{k:04d}.png"))
            k += 1
        # c1's real fps over the subset = (#paired frames) / (their real-time span).
        # The subset is a contiguous run of c1 frames, so span ≈ k / fps1 seconds;
        # assembling at fps1 plays it back at true real-time speed.
        rate1 = rate2 = max(1.0, fps1)
        print(f"[net_video] tick-synced: {k} paired frames over server ticks {lo}..{hi} "
              f"(playback ~{k / max(1.0, fps1):.1f}s @ real-time)")
        src1 = os.path.join(sync_dir, "c1_%04d.png")
        src2 = os.path.join(sync_dir, "c2_%04d.png")
    else:
        # Fallback (no tick data): assemble each at its achieved fps (un-synced).
        print("[net_video] WARNING: no .ticks sidecars — halves may not be synced "
              "(falling back to per-client fps assembly)")
        src1 = os.path.join(USERDATA, "vid_c1_%04d.png")
        src2 = os.path.join(USERDATA, "vid_c2_%04d.png")
        rate1, rate2 = fps1, fps2

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    print(f"[net_video] stitching side-by-side @ {FPS}fps -> {OUT}")
    r = sh(f'ffmpeg -y -framerate {rate1:.4f} -i "{src1}" -framerate {rate2:.4f} -i "{src2}" '
           f'-filter_complex "[0:v][1:v]hstack=inputs=2" -r {FPS} -pix_fmt yuv420p "{OUT}"',
           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r.returncode != 0 or not os.path.exists(OUT):
        sys.exit("[net_video] ffmpeg failed")
    # Tidy ALL scratch (frames, sidecars, the legacy bare vid_cN.png) out of the
    # userdata root (the messy part) — the finished mp4 in its dated folder is the
    # keeper. OUT lives under recordings/, so it's never matched here.
    for pat in ("vid_c1*", "vid_c2*", "net_demo_video.mp4"):
        for f in glob.glob(os.path.join(USERDATA, pat)):
            os.remove(f)
    if os.path.isdir(sync_dir):
        shutil.rmtree(sync_dir, ignore_errors=True)
    print(f"[net_video] DONE -> {OUT}")


SCENE, SCENE_ARGS = "", []
if __name__ == "__main__":
    main()
