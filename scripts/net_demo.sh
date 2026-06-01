#!/usr/bin/env bash
# ADR 0063 — VISUAL client-server demo: open TWO windowed Godot instances on the
# WINDOWS binary. The HOST is the authoritative server (runs the sim with normal
# physics); the CLIENT applies replicated state — its OWN character is predicted
# locally (responsive) and the REMOTE character is interpolated (smooth). You
# watch both windows; each follows its own character (host=marken, client=morwen
# in demo_tiny_village).
#
# Usage:
#   ./scripts/net_demo.sh                 # demo_tiny_village, walk north
#   ./scripts/net_demo.sh <game> <ticks> <input>
#
# Notes:
# - Windows binary (ENet/UDP works fine; you get GPU rendering + visible windows).
# - The headless correctness proof is `scripts/run_linux.sh net <game>`
#   (client's applied state == server authority); this is the eyeball version.
# - If a Windows Firewall dialog appears on first run, click Allow (localhost ENet).
set -uo pipefail

YUME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' "${YUME_ROOT}/scripts/play.sh")"

GAME="${1:-demo_tiny_village}"
TICKS="${2:-30000}"
# INTERACTIVE by default (empty input → you drive with the keyboard). Pass a 3rd
# arg (e.g. move_north) to auto-walk both characters instead (the old scripted demo).
INPUT="${3:-}"
PORT=7803

if [ ! -x "${GODOT_BIN}" ]; then
  echo "Error: Windows Godot not found at ${GODOT_BIN}" >&2; exit 1
fi

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

# Side-by-side windows. --resolution / --position are Godot ENGINE flags (before
# the `--`): the demo places the host on the left, the client on the right so you
# watch both at once. Override the geometry with WIN_W/WIN_H/GAP/TOP env vars.
WIN_W="${WIN_W:-900}"
WIN_H="${WIN_H:-540}"
TOP="${TOP:-60}"
GAP="${GAP:-20}"
CLIENT_X=$(( WIN_W + GAP ))
ENGINE_COMMON=( --path . --rendering-driver opengl3 --resolution "${WIN_W}x${WIN_H}" )
USER_ARGS=( -- "${SCENE_ARGS[@]}" --net-visual --net-port="${PORT}" --net-ticks="${TICKS}" )
if [ -n "${INPUT}" ]; then
  USER_ARGS+=( --net-input="${INPUT}" )
  echo "[net_demo] scripted input: ${INPUT} (both characters auto-walk)"
else
  echo "[net_demo] INTERACTIVE: focus a window, then WASD to move + mouse to look."
  echo "[net_demo]   (one keyboard drives the FOCUSED window's character; click the"
  echo "[net_demo]    other window to drive the other. Both see both, in sync.)"
fi

echo "[net_demo] launching HOST (authoritative server) window — left..."
"${GODOT_BIN}" "${ENGINE_COMMON[@]}" --position "0,${TOP}" "${SCENE}" "${USER_ARGS[@]}" --net-host &
HOST=$!
# Host must finish loading the 3D scene before the client connects (its main
# thread can't pump ENet while loading). Same rationale as lockstep_demo.sh.
sleep 6
echo "[net_demo] launching CLIENT window — right..."
"${GODOT_BIN}" "${ENGINE_COMMON[@]}" --position "${CLIENT_X},${TOP}" "${SCENE}" "${USER_ARGS[@]}" --net-join=127.0.0.1:"${PORT}" &
CLIENT=$!

echo "[net_demo] two windows should be open — host = authority, client predicts+interpolates."
echo "[net_demo] (Ctrl-C to kill both; they self-quit after ${TICKS} server ticks)"
trap 'kill ${HOST} ${CLIENT} 2>/dev/null' INT TERM
wait ${HOST} ${CLIENT}
