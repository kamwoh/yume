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

# Pick the per-game scene the SAME way play.sh does — the universal
# scenes/play.tscn is the 2D launcher (Camera2D + entity_sprite_2d renderer);
# launching a 3D game through it renders grey (3D meshes fall back, no Camera3D).
# The per-game <short>_3d.tscn bakes in data_root + the 3D renderer + a Camera3D,
# so it needs NO --game= arg. Fall back to play.tscn + --game only if no per-game
# scene exists. (Empirical 2026-05-31: the demo hardcoded play.tscn → grey.)
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
  echo "[lockstep_demo] WARNING: no per-game scene for '${GAME}' — using play.tscn (2D)."
fi
echo "[lockstep_demo] scene: ${SCENE}"

COMMON=( --path . --rendering-driver opengl3 "${SCENE}" --
         "${SCENE_ARGS[@]}" --lockstep-visual --lockstep-port="${PORT}"
         --lockstep-ticks="${TICKS}" --lockstep-input="${INPUT}" )

echo "[lockstep_demo] launching HOST window..."
"${GODOT_BIN}" "${COMMON[@]}" --lockstep-host &
HOST=$!
# The HOST must finish loading the 3D scene (meshes, ground, lighting) before the
# CLIENT connects — while the main loop is blocked loading, ENet isn't pumped, so
# a too-early client times out (CONNECT_TIMEOUT_SEC=10). 6s clears a warm load.
# Empirical 2026-05-31: a 3s gap → client "connect timeout (no peer)"; 6s connects.
sleep 6
echo "[lockstep_demo] launching CLIENT window..."
"${GODOT_BIN}" "${COMMON[@]}" --lockstep-join=127.0.0.1:"${PORT}" &
CLIENT=$!

echo "[lockstep_demo] two windows should be open — watch them walk in lockstep."
echo "[lockstep_demo] (Ctrl-C to kill both; they self-quit after ${TICKS} ticks)"
trap 'kill ${HOST} ${CLIENT} 2>/dev/null' INT TERM
wait ${HOST} ${CLIENT}
