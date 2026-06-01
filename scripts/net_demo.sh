#!/usr/bin/env bash
# ADR 0063 — VISUAL client-server demo: a DEDICATED server (headless, no player,
# the only authority) + TWO client windows (each a player). Each client sends its
# input to the server; the server computes the outcome and sends state back; both
# clients render the server's authoritative state. Players are SPAWNED on join
# (not pre-placed). Each client window follows its own character.
#
# Usage:
#   ./scripts/net_demo.sh                       # interactive, demo_tiny_village
#   ./scripts/net_demo.sh <game> <ticks> <input>
#
# Notes:
# - Windows binary for the CLIENT windows (GPU rendering); the SERVER runs HEADLESS
#   (no window, no GPU cost) so the only GPU load is the 2 client windows.
# - Headless correctness proof: `scripts/run_linux.sh net <game>` (server + both
#   clients agree on the spawned roster). This is the eyeball version.
# - If a Windows Firewall dialog appears on first run, click Allow (localhost ENet).
set -uo pipefail

YUME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' "${YUME_ROOT}/scripts/play.sh")"

GAME="${1:-demo_tiny_village}"
TICKS="${2:-30000}"
# INTERACTIVE by default (empty input → drive with the keyboard). Pass a 3rd arg
# (e.g. move_north) to auto-walk every player instead (scripted).
INPUT="${3:-}"
PORT=7803

if [ ! -x "${GODOT_BIN}" ]; then
  echo "Error: Windows Godot not found at ${GODOT_BIN}" >&2; exit 1
fi

# Kill any leftover Godot instances FIRST — a lingering headless server from a
# previous run holds the ENet port (invisible: no window), so a new server fails
# with "Couldn't create an ENet host" and the clients silently fall back to the
# scene's pre-placed players (both showed marken). Empirical 2026-06-01.
echo "[net_demo] clearing any leftover Godot processes (frees the ENet port)..."
powershell.exe -Command "Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force" >/dev/null 2>&1 || true
sleep 1

echo "[net_demo] syncing framework -> template..."
cp -r "${YUME_ROOT}/godot/." "${TEMPLATE_DST}/"
echo "[net_demo] importing (new resources)..."
( cd "${TEMPLATE_DST}" && "${GODOT_BIN}" --path . --headless --import >/dev/null 2>&1 )

cd "${TEMPLATE_DST}"

# Per-game 3D scene (NOT the 2D universal play.tscn — see lockstep_demo.sh note).
SHORT="${GAME#demo_}"
SCENE=""
SCENE_ARGS=()
for variant in "${SHORT}_3d.tscn" "${SHORT}_2d.tscn" "${SHORT}.tscn"; do
  if [ -f "${TEMPLATE_DST}/scenes/${variant}" ]; then
    SCENE="scenes/${variant}"
    break
  fi
done
if [ -z "${SCENE}" ]; then
  SCENE="scenes/play.tscn"
  SCENE_ARGS=( --game="${GAME}" )
  echo "[net_demo] WARNING: no per-game scene for '${GAME}' — using play.tscn (2D)."
fi
echo "[net_demo] scene: ${SCENE}"

USER_ARGS=( -- "${SCENE_ARGS[@]}" --net-port="${PORT}" --net-ticks="${TICKS}" )
if [ -n "${INPUT}" ]; then
  USER_ARGS+=( --net-input="${INPUT}" )
  echo "[net_demo] scripted input: ${INPUT} (every player auto-walks)"
else
  echo "[net_demo] INTERACTIVE: focus a client window, WASD to move + mouse to look."
  echo "[net_demo]   (each window controls ITS OWN character; click a window to drive it.)"
fi

# Two client windows, side by side. --resolution/--position are Godot ENGINE flags
# (before `--`). Override geometry with WIN_W/WIN_H/GAP/TOP env vars.
WIN_W="${WIN_W:-900}"
WIN_H="${WIN_H:-540}"
TOP="${TOP:-60}"
GAP="${GAP:-20}"
C2_X=$(( WIN_W + GAP ))

# 1) DEDICATED SERVER — headless (no window, no GPU), the only authority.
echo "[net_demo] launching DEDICATED SERVER (headless)..."
"${GODOT_BIN}" --path . --headless "${SCENE}" "${USER_ARGS[@]}" --net-host >/tmp/net_demo_server.log 2>&1 &
SERVER=$!
# Server must finish loading before clients connect (its main thread can't pump
# ENet while loading). Headless loads faster than a window, but give it margin.
sleep 6

# Loud failure if the server didn't come up — otherwise the clients connect to
# nothing and silently fall back to the scene's pre-placed players (the confusing
# "both windows show marken" symptom). Empirical 2026-06-01.
if grep -q "net\] FAIL" /tmp/net_demo_server.log 2>/dev/null; then
  echo "[net_demo] ERROR: dedicated server failed to start — see /tmp/net_demo_server.log" >&2
  echo "[net_demo]   Most likely the ENet port ${PORT} is held by a leftover process." >&2
  echo "[net_demo]   This run already killed leftovers; if it persists, set PORT=<other>." >&2
  kill ${SERVER} 2>/dev/null || true
  exit 1
fi

echo "[net_demo] launching CLIENT 1 window — left..."
"${GODOT_BIN}" --path . --rendering-driver opengl3 --resolution "${WIN_W}x${WIN_H}" \
  --position "0,${TOP}" "${SCENE}" "${USER_ARGS[@]}" --net-visual --net-join=127.0.0.1:"${PORT}" \
  >/tmp/net_demo_c1.log 2>&1 &
C1=$!
sleep 2
echo "[net_demo] launching CLIENT 2 window — right..."
"${GODOT_BIN}" --path . --rendering-driver opengl3 --resolution "${WIN_W}x${WIN_H}" \
  --position "${C2_X},${TOP}" "${SCENE}" "${USER_ARGS[@]}" --net-visual --net-join=127.0.0.1:"${PORT}" \
  >/tmp/net_demo_c2.log 2>&1 &
C2=$!

echo "[net_demo] server (headless) + 2 client windows — each controls its own player,"
echo "[net_demo] both render the server's authoritative state. (Ctrl-C to kill all.)"
trap 'kill ${SERVER} ${C1} ${C2} 2>/dev/null' INT TERM
wait ${C1} ${C2}
kill ${SERVER} 2>/dev/null || true
