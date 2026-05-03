#!/usr/bin/env bash
# Yume game runner — sync framework to YumeTemplate, then launch a game.
#
# Usage:
#   ./scripts/play.sh                  # default: tinypond
#   ./scripts/play.sh tinypond         # play a specific game
#   ./scripts/play.sh harvestcore
#
# Visual QA mode (Tier 2.6r):
#   ./scripts/play.sh fpsgarden --capture
#       → runs ~3s, captures viewport to PNG, quits, prints output path.
#
# Other flags:
#   --capture         : auto-capture mode (3s delay)
#   --capture-after=N : capture after N seconds (implies --capture)
#   --output=PATH     : capture output path (Godot user:// resolves to
#                       %APPDATA%/Godot/app_userdata/Yume Framework/)
#   SKIP_SYNC=1       : skip rsync step (env var; for faster re-runs)

set -e

# Parse positional + flags
GAME_NAME=""
CAPTURE_DELAY=""
OUTPUT_PATH=""
for arg in "$@"; do
  case "$arg" in
    --capture)
      CAPTURE_DELAY="${CAPTURE_DELAY:-3}"
      ;;
    --capture-after=*)
      CAPTURE_DELAY="${arg#*=}"
      ;;
    --output=*)
      OUTPUT_PATH="${arg#*=}"
      ;;
    -*)
      echo "Unknown flag: $arg"
      exit 1
      ;;
    *)
      if [ -z "$GAME_NAME" ]; then
        GAME_NAME="$arg"
      fi
      ;;
  esac
done
GAME_NAME="${GAME_NAME:-tinypond}"
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

# Build cmdline args for Godot's user-args section (after `--`)
USER_ARGS=()
if [ -n "$CAPTURE_DELAY" ]; then
  USER_ARGS+=("--capture-after=${CAPTURE_DELAY}")
  if [ -n "$OUTPUT_PATH" ]; then
    USER_ARGS+=("--capture-output=${OUTPUT_PATH}")
  fi
fi

# Try per-game scenes in order: <name>_2d.tscn, <name>_3d.tscn, <name>.tscn.
# Fall back to universal play.tscn with --game= arg if none found.
SCENE=""
for variant in "${GAME_NAME}_2d.tscn" "${GAME_NAME}_3d.tscn" "${GAME_NAME}.tscn"; do
  if [ -f "${TEMPLATE_DST}/scenes/${variant}" ]; then
    SCENE="scenes/${variant}"
    break
  fi
done
if [ -z "$SCENE" ]; then
  SCENE="scenes/play.tscn"
  USER_ARGS+=("--game=${DATA_FOLDER}")
fi

echo "[play.sh] launching ${SCENE}${CAPTURE_DELAY:+ (capture ${CAPTURE_DELAY}s)}"
cd "${TEMPLATE_DST}"
if [ ${#USER_ARGS[@]} -gt 0 ]; then
  "${GODOT_BIN}" --path . "${SCENE}" -- "${USER_ARGS[@]}"
else
  "${GODOT_BIN}" --path . "${SCENE}"
fi
RC=$?

# Locate + report the capture output if we did one
if [ -n "$CAPTURE_DELAY" ]; then
  REAL_OUTPUT="${OUTPUT_PATH}"
  if [ -z "$REAL_OUTPUT" ]; then
    REAL_OUTPUT="user://_capture.png"
  fi
  # Resolve user:// → %APPDATA% on Windows
  if [[ "$REAL_OUTPUT" == user://* ]]; then
    REL="${REAL_OUTPUT#user://}"
    REAL_OUTPUT="/mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume Framework/${REL}"
  fi
  if [ -f "$REAL_OUTPUT" ]; then
    echo "[play.sh] captured: ${REAL_OUTPUT}"
  fi
fi

exit ${RC}
