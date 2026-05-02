#!/usr/bin/env bash
# Yume game runner — sync framework to YumeTemplate, then launch a game.
#
# Usage:
#   ./scripts/play.sh                # default: tinypond
#   ./scripts/play.sh tinypond
#   ./scripts/play.sh harvestcore
#   ./scripts/play.sh <any data folder under data/demo_*>
#
# Add SKIP_SYNC=1 to skip the rsync step (faster re-runs):
#   SKIP_SYNC=1 ./scripts/play.sh tinypond

set -e

GAME_NAME="${1:-tinypond}"
DATA_FOLDER="demo_${GAME_NAME}"

YUME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_SRC="${YUME_ROOT}/archetypes/core/templates/godot"
TEMPLATE_DST="/mnt/c/Users/kamwoh/Documents/Projects/Godot/YumeTemplate"
GODOT_BIN="/mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64.exe"

# Sanity checks
if [ ! -d "${TEMPLATE_SRC}/data/${DATA_FOLDER}" ]; then
  echo "Error: data folder not found: ${TEMPLATE_SRC}/data/${DATA_FOLDER}"
  echo "Available games:"
  ls "${TEMPLATE_SRC}/data/" | grep '^demo_' | sed 's/^demo_/  - /'
  exit 1
fi
if [ ! -x "${GODOT_BIN}" ]; then
  echo "Error: Godot binary not found at: ${GODOT_BIN}"
  exit 1
fi

# Sync framework into the Godot project (unless SKIP_SYNC=1)
if [ "${SKIP_SYNC}" != "1" ]; then
  echo "[play.sh] syncing ${TEMPLATE_SRC}/. → ${TEMPLATE_DST}/"
  cp -r "${TEMPLATE_SRC}/." "${TEMPLATE_DST}/"
fi

# Try per-game scene first; fall back to universal play.tscn with --game= arg
PER_GAME_SCENE="scenes/${GAME_NAME}_2d.tscn"
if [ -f "${TEMPLATE_DST}/${PER_GAME_SCENE}" ]; then
  echo "[play.sh] launching ${PER_GAME_SCENE}"
  cd "${TEMPLATE_DST}" && "${GODOT_BIN}" --path . "${PER_GAME_SCENE}"
else
  echo "[play.sh] launching scenes/play.tscn -- --game=${DATA_FOLDER}"
  cd "${TEMPLATE_DST}" && "${GODOT_BIN}" --path . scenes/play.tscn -- --game="${DATA_FOLDER}"
fi
