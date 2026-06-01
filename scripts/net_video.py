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
INPUT1 = ARGS[1] if len(ARGS) > 1 else "move_north"
INPUT2 = ARGS[2] if len(ARGS) > 2 else "move_west"
SHORT = GAME[len("demo_"):] if GAME.startswith("demo_") else GAME

PORT = os.environ.get("PORT", "7862")
FPS = int(os.environ.get("FPS", "10"))
SECS = int(os.environ.get("SECS", "5"))
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

OUT = os.environ.get("OUT", os.path.join(USERDATA, "net_demo_video.mp4"))


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
    user = ["--", *SCENE_ARGS, "--net-port", PORT, "--net-ticks", "6000", "--net-visual",
            f"--net-join=127.0.0.1:{PORT}", f"--net-input={inp}",
            f"--capture-after={after}", f"--capture-sequence={FPS},{SECS}",
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

    server_user = ["--", *SCENE_ARGS, "--net-port", PORT, "--net-ticks", "6000", "--net-host"]
    logs, procs = {}, {}

    print("[net_video] launching dedicated server (headless) ...")
    logs["server"] = open("/tmp/net_video_server.log", "w")
    senv = dict(os.environ)
    procs["server"] = subprocess.Popen(
        [GODOT, "--path", ".", "--headless", SCENE, *server_user],
        cwd=PROJECT, stdout=logs["server"], stderr=subprocess.STDOUT, env=senv)
    # Wait until the server has FINISHED loading the scene before launching clients
    # — a heavy 3D scene takes >9s, and while the main thread loads it can't pump
    # ENet, so an early client gets connection_failed (empirically: client 1 always
    # failed on a fixed 9s sleep). Poll the log for the load marker.
    logs["server"].flush()
    t0 = time.time()
    while time.time() - t0 < 45:
        try:
            if "loaded:" in open("/tmp/net_video_server.log").read():
                break
        except OSError:
            pass
        time.sleep(1)
    time.sleep(2)  # small margin after load
    print("[net_video] server ready (loaded) — launching clients")

    def launch(tag, pos_x, inp, after):
        cmd, extra_env = client_cmd(pos_x, inp, after, tag)
        e = dict(os.environ)
        e.update(extra_env)
        logs[tag] = open(f"/tmp/net_video_{tag}.log", "w")
        procs[tag] = subprocess.Popen(cmd, cwd=PROJECT, stdout=logs[tag],
                                      stderr=subprocess.STDOUT, env=e)

    def wait_connected(tag, secs=40):
        # SEQUENCE the launches: a client's ENet handshake fails (connection_failed,
        # no retry) if it races a second client loading at the same time on one
        # box. So wait for this client to actually connect (its driver logs "this
        # window controls") before starting the next. Empirically fixes the
        # always-client-1-fails symptom.
        t0 = time.time()
        while time.time() - t0 < secs:
            try:
                if "this window controls" in open(f"/tmp/net_video_{tag}.log").read():
                    return True
            except OSError:
                pass
            time.sleep(1)
        return False

    print("[net_video] launching client 1 (left) ...")
    launch("c1", 0, INPUT1, DELAY)
    if not wait_connected("c1"):
        print("[net_video] WARNING: client 1 didn't report connect; launching client 2 anyway")
    print("[net_video] launching client 2 (right) ...")
    launch("c2", int(WIN_W) + 20, INPUT2, DELAY)

    last1 = os.path.join(USERDATA, f"vid_c1_{FPS*SECS-1:04d}.png")
    last2 = os.path.join(USERDATA, f"vid_c2_{FPS*SECS-1:04d}.png")
    budget = DELAY + SECS + (90 if LINUX else 40)  # software GL needs more time
    print(f"[net_video] waiting up to {budget}s for {FPS*SECS} frames per client ...")
    t0 = time.time()
    while time.time() - t0 < budget:
        if os.path.exists(last1) and os.path.exists(last2):
            break
        time.sleep(2)

    n1 = len(glob.glob(os.path.join(USERDATA, "vid_c1_*.png")))
    n2 = len(glob.glob(os.path.join(USERDATA, "vid_c2_*.png")))
    print(f"[net_video] captured: client1={n1} frames, client2={n2} frames")
    kill_godot()

    if n1 == 0 or n2 == 0:
        sys.exit("[net_video] ERROR: a client captured no frames — see /tmp/net_video_*.log "
                 "(connection? on a slow box bump DELAY).")

    print(f"[net_video] stitching side-by-side -> {OUT}")
    c1 = os.path.join(USERDATA, "vid_c1_%04d.png")
    c2 = os.path.join(USERDATA, "vid_c2_%04d.png")
    r = sh(f'ffmpeg -y -framerate {FPS} -i "{c1}" -framerate {FPS} -i "{c2}" '
           f'-filter_complex "[0:v][1:v]hstack=inputs=2" -r {FPS} -pix_fmt yuv420p "{OUT}"',
           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r.returncode != 0 or not os.path.exists(OUT):
        sys.exit("[net_video] ffmpeg failed")
    print(f"[net_video] DONE -> {OUT}")


SCENE, SCENE_ARGS = "", []
if __name__ == "__main__":
    main()
