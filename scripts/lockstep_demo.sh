#!/usr/bin/env bash
# ADR 0061 — VISUAL lockstep demo: open TWO windowed Godot instances (host +
# client) on the WINDOWS binary, each driving a walking character, connected
# over localhost ENet. You watch both windows render the same simulation in
# perfect lockstep (input-replicated). The rigorous proof is the hash check
# (scripts/run_linux.sh lockstep <game>); this is the eyeball version.
#
# Usage:
#   ./scripts/lockstep_demo.sh                 # demo_tiny_village, walk north, ~30s
#   ./scripts/lockstep_demo.sh <game> <ticks> <input>
#
# Notes:
# - Uses the WINDOWS binary (lockstep is ENet/UDP, not stdin — so Windows is
#   fine here, and you get real GPU rendering + visible windows).
# - --lockstep-visual keeps the camera/renderer alive (without it the camera is
#   gated for the headless determinism mode and you'd see nothing).
# - Each instance quits itself after <ticks> ticks (~ticks/60 seconds), or close
#   the windows. Ctrl-C this script to kill both.
set -uo pipefail

YUME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' "${YUME_ROOT}/scripts/play.sh")"

GAME="${1:-demo_tiny_village}"
TICKS="${2:-1800}"
INPUT="${3:-move_north}"
PORT=7777

if [ ! -x "${GODOT_BIN}" ]; then
  echo "Error: Windows Godot not found at ${GODOT_BIN}" >&2; exit 1
fi

echo "[lockstep_demo] syncing framework -> template..."
cp -r "${YUME_ROOT}/godot/." "${TEMPLATE_DST}/"
echo "[lockstep_demo] importing (new resources)..."
( cd "${TEMPLATE_DST}" && "${GODOT_BIN}" --path . --headless --import >/dev/null 2>&1 )

cd "${TEMPLATE_DST}"
COMMON=( --path . --rendering-driver opengl3 scenes/play.tscn --
         --game="${GAME}" --lockstep-visual --lockstep-port="${PORT}"
         --lockstep-ticks="${TICKS}" --lockstep-input="${INPUT}" )

echo "[lockstep_demo] launching HOST window..."
"${GODOT_BIN}" "${COMMON[@]}" --lockstep-host &
HOST=$!
sleep 3
echo "[lockstep_demo] launching CLIENT window..."
"${GODOT_BIN}" "${COMMON[@]}" --lockstep-join=127.0.0.1:"${PORT}" &
CLIENT=$!

echo "[lockstep_demo] two windows should be open — watch them walk in lockstep."
echo "[lockstep_demo] (Ctrl-C to kill both; they self-quit after ${TICKS} ticks)"
trap 'kill ${HOST} ${CLIENT} 2>/dev/null' INT TERM
wait ${HOST} ${CLIENT}
