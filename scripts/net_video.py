#!/usr/bin/env python3
"""Record a SIDE-BY-SIDE video of a client-server net demo (ADR 0063-0065).

One command, no manual steps: kill leftovers -> sync the framework to the Windows
template -> launch a headless dedicated server + 2 client windows (each driving a
character and capturing a real-time frame sequence) -> ffmpeg-stitch the two
sequences side by side into an mp4. Proves synchronization visually (left window
walks one way, right window another; both show both characters in step).

Usage:
    venv/bin/python scripts/net_video.py [game] [input1] [input2]
    venv/bin/python scripts/net_video.py demo_tiny_village move_north move_west

Env overrides: PORT, FPS, SECS, DELAY (connect-wait before capture), WIN_W, WIN_H,
YUME_USERDATA (the Godot user:// dir), OUT (output mp4 path).

Why a script: orchestrating server + 2 clients + ffmpeg by hand is fragile and not
reusable. This is the reusable, reproducible version.
"""
import glob
import os
import re
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def from_play_sh(var):
    """Read GODOT_BIN / TEMPLATE_DST out of scripts/play.sh (single source of truth)."""
    txt = open(os.path.join(REPO, "scripts", "play.sh")).read()
    m = re.search(rf'^{var}="\$\{{[^:]+:-([^}}]+)\}}"', txt, re.M)
    return m.group(1) if m else None


GAME = sys.argv[1] if len(sys.argv) > 1 else "demo_tiny_village"
INPUT1 = sys.argv[2] if len(sys.argv) > 2 else "move_north"
INPUT2 = sys.argv[3] if len(sys.argv) > 3 else "move_west"
SHORT = GAME[len("demo_"):] if GAME.startswith("demo_") else GAME

GODOT = os.environ.get("YUME_GODOT_BIN") or from_play_sh("GODOT_BIN")
TEMPLATE = os.environ.get("YUME_TEMPLATE_DST") or from_play_sh("TEMPLATE_DST")
USERDATA = os.environ.get(
    "YUME_USERDATA",
    "/mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume Framework",
)
PORT = os.environ.get("PORT", "7862")
FPS = int(os.environ.get("FPS", "10"))
SECS = int(os.environ.get("SECS", "5"))
DELAY = int(os.environ.get("DELAY", "20"))  # seconds to wait for clients to connect
WIN_W = os.environ.get("WIN_W", "700")
WIN_H = os.environ.get("WIN_H", "440")
OUT = os.environ.get("OUT", os.path.join(USERDATA, "net_demo_video.mp4"))


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, **kw)


def kill_godot():
    sh("powershell.exe -Command \"Get-Process Godot* -ErrorAction SilentlyContinue "
       "| Stop-Process -Force\" 2>/dev/null")
    time.sleep(1)


def pick_scene():
    for v in (f"{SHORT}_3d.tscn", f"{SHORT}_2d.tscn", f"{SHORT}.tscn"):
        if os.path.isfile(os.path.join(TEMPLATE, "scenes", v)):
            return f"scenes/{v}", []
    return "scenes/play.tscn", [f"--game={GAME}"]


def main():
    if not GODOT or not os.path.exists(GODOT):
        sys.exit(f"Godot binary not found: {GODOT}")
    print(f"[net_video] {GAME}: server + 2 clients ({INPUT1} / {INPUT2}) -> side-by-side mp4")

    kill_godot()
    print("[net_video] syncing framework -> template ...")
    sh(f'cp -r "{REPO}/godot/." "{TEMPLATE}/"')
    sh(f'cd "{TEMPLATE}" && "{GODOT}" --path . --headless --import >/dev/null 2>&1')

    scene, scene_args = pick_scene()
    print(f"[net_video] scene: {scene}")
    for f in glob.glob(os.path.join(USERDATA, "vid_c1_*.png")) + \
            glob.glob(os.path.join(USERDATA, "vid_c2_*.png")):
        os.remove(f)

    common_user = ["--", *scene_args, "--net-port", PORT, "--net-ticks", "6000"]

    logs = {}
    procs = {}

    # 1) Dedicated server — headless (no window, no GPU).
    print("[net_video] launching dedicated server (headless) ...")
    logs["server"] = open("/tmp/net_video_server.log", "w")
    procs["server"] = subprocess.Popen(
        [GODOT, "--path", ".", "--headless", scene, *common_user, "--net-host"],
        cwd=TEMPLATE, stdout=logs["server"], stderr=subprocess.STDOUT,
    )
    time.sleep(9)  # let the server load before clients connect

    # 2) Two client windows, side by side, each capturing a frame sequence.
    def client(tag, pos_x, inp, after):
        logs[tag] = open(f"/tmp/net_video_{tag}.log", "w")
        procs[tag] = subprocess.Popen(
            [GODOT, "--path", ".", "--rendering-driver", "opengl3",
             "--resolution", f"{WIN_W}x{WIN_H}", "--position", f"{pos_x},60", scene,
             *common_user, "--net-visual", f"--net-join=127.0.0.1:{PORT}",
             f"--net-input={inp}", f"--capture-after={after}",
             f"--capture-sequence={FPS},{SECS}", f"--capture-output=user://vid_{tag}.png"],
            cwd=TEMPLATE, stdout=logs[tag], stderr=subprocess.STDOUT,
        )

    print("[net_video] launching client 1 (left) + client 2 (right) ...")
    client("c1", 0, INPUT1, DELAY)
    time.sleep(2)
    client("c2", int(WIN_W) + 20, INPUT2, DELAY - 2)

    # 3) Wait for both sequences to finish (last frame written), with a budget.
    last1 = os.path.join(USERDATA, f"vid_c1_{FPS*SECS-1:04d}.png")
    last2 = os.path.join(USERDATA, f"vid_c2_{FPS*SECS-1:04d}.png")
    budget = DELAY + SECS + 40
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
        print("[net_video] ERROR: a client captured no frames — likely it didn't connect "
              "(see /tmp/net_video_*.log). On a slower box bump DELAY.", file=sys.stderr)
        sys.exit(1)

    # 4) ffmpeg: stitch the two sequences side by side.
    print(f"[net_video] stitching side-by-side -> {OUT}")
    c1 = os.path.join(USERDATA, "vid_c1_%04d.png")
    c2 = os.path.join(USERDATA, "vid_c2_%04d.png")
    r = sh(
        f'ffmpeg -y -framerate {FPS} -i "{c1}" -framerate {FPS} -i "{c2}" '
        f'-filter_complex "[0:v][1:v]hstack=inputs=2" -r {FPS} -pix_fmt yuv420p "{OUT}"',
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if r.returncode != 0 or not os.path.exists(OUT):
        sys.exit("[net_video] ffmpeg failed")
    win = OUT.replace("/mnt/c/", "C:\\\\").replace("/", "\\\\")
    print(f"[net_video] DONE -> {OUT}\n[net_video] (Windows path: {win})")


if __name__ == "__main__":
    main()
