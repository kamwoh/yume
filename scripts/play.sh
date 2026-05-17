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
#   --record          : screen-record entire session to AVI (default path
#                       under user://recordings/<game>_<timestamp>.avi).
#                       Uses Godot's --write-movie (Movie Maker mode):
#                       deterministic 60fps, audio muxed into the AVI
#                       container. Convert with
#                       `ffmpeg -i out.avi -c:v libx264 -crf 22 out.mp4`.
#   --record=PATH     : record to a specific path (Windows or user:// path).
#                       For PNG-sequence mode, use a .png path — Godot will
#                       write image-XXXXX.png + a separate .wav for audio.
#   SKIP_SYNC=1       : skip rsync step (env var; for faster re-runs)

set -e

# Parse positional + flags
GAME_NAME=""
CAPTURE_DELAY=""
OUTPUT_PATH=""
RECORD_PATH=""
RECORD_DEFAULT=0
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
    --record)
      RECORD_DEFAULT=1
      ;;
    --record=*)
      RECORD_PATH="${arg#*=}"
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
TEMPLATE_SRC="${YUME_ROOT}/godot"
# Override via env vars: YUME_TEMPLATE_DST, YUME_GODOT_BIN.
TEMPLATE_DST="${YUME_TEMPLATE_DST:-/mnt/c/Users/kamwoh/Documents/Projects/Godot/YumeTemplate}"
GODOT_BIN="${YUME_GODOT_BIN:-/mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64.exe}"

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

# Pre-launch screen-flow validation (non-blocking; prints WARN lines for
# dangling transition_screen targets). Catches the bug class where a button
# fires `transition_screen target='_close'` (or any other unknown id) which
# silently warns at runtime instead of dismissing the modal. See
# .claude/rules/visual-qa.md § screen-flow gate. Skip with SKIP_VALIDATE=1.
if [ "${SKIP_VALIDATE}" != "1" ] && command -v python3 >/dev/null 2>&1; then
  python3 "${YUME_ROOT}/tools/validate_screens.py" "${DATA_FOLDER}" || true
  # Spawn-template static check (added 2026-05-10). Catches the bug class
  # where a `spawn` effect references a `template` whose def id doesn't
  # exist in entities/*.json (runtime fires [effect.spawn_no_def] error).
  # Empirical case: Aldenmere had 7 `"template": "wolf"` refs while the
  # def was `"animal_wolf"` — every wolf-spawn rule erroring at tick time.
  python3 "${YUME_ROOT}/tools/validate_spawn_templates.py" "${DATA_FOLDER}" || true
  # Scene-director static check (added 2026-05-11). Catches the bug class
  # where entity defs reference a subsystem (schedule, party, faction)
  # but the matching director Node isn't mounted in the per-game .tscn.
  # Empirical case: Aldenmere shipped without ScheduleDirector mounted;
  # all 8 villagers sat motionless despite their schedule blocks.
  python3 "${YUME_ROOT}/tools/validate_scene_directors.py" "${DATA_FOLDER}" || true
  # Duplicate-mutation cross-file check (added 2026-05-11). Catches the
  # bug class where two rules across physics.json + game/rules.json
  # mutate the same (entity-tag, field) pair under overlapping queries.
  # Empirical case: Aldenmere shipped with day_rollover (physics) +
  # day_boundary_advance (game/rules) both mutating current_hour with
  # different reset values (0 vs 6). WARN by default — authors decide
  # if each overlap is intentional (physics sim baseline + game story
  # override) or a real bug.
  python3 "${YUME_ROOT}/tools/validate_duplicate_mutations.py" "${DATA_FOLDER}" || true
  # Player-perspective static check (added 2026-05-08). Catches
  # undiscoverable keybinds + objective text referencing unlabeled
  # landmarks. See .claude/skills/yume-game-reviewer/SKILL.md Axis 15.
  python3 "${YUME_ROOT}/tools/validate_player_perspective.py" "${DATA_FOLDER}" || true
  # ADR 0027 cross-game lib-ref check (added 2026-05-08). Verifies every
  # @lib.X.Y reference resolves through data/lib/manifest.json.
  python3 "${YUME_ROOT}/tools/validate_lib_refs.py" "${DATA_FOLDER}" || true
  # ADR 0043 universal-input check (added 2026-05-11). After moving WASD
  # bindings out of project.godot into data/lib/input/universal.json,
  # gates against a game silently omitting the `$include
  # @lib.input.universal.actions` line — bug class: WASD doesn't fire,
  # engine code polling move_north no-ops at runtime.
  python3 "${YUME_ROOT}/tools/validate_input_universal.py" "${DATA_FOLDER}" || true
  # No-stray-scripts check (added 2026-05-15). Catches stale .gd files
  # under data/ that shadow engine classes via Godot's global class_name
  # registry. Empirical case: data/demo_aldenmere/effect_apply.gd (May 10
  # leftover) shadowed the real EffectApply, dispatching velocity_add_relative
  # to a dead match-arm. WASD player motion silently no-op'd for 5+ days.
  python3 "${YUME_ROOT}/tools/validate_no_stray_scripts.py" || true
  # Tick-rate contract check (added 2026-05-16). Per CLAUDE.md § Tick
  # rate is the engine's heartbeat: tick_seconds defaults to 60Hz;
  # per-game overrides must include `_comment_tick` with the reason.
  # Empirical case: yume-code-reviewer's first session review flagged
  # sokoban (10Hz) + doomarena3d (20Hz) overriding silently.
  python3 "${YUME_ROOT}/tools/validate_tick_override.py" || true
  # Rule-contract enforcer (added 2026-05-16, task #100). Catches the
  # recurring bug class where a formula references a binding the rule
  # doesn't bind ("self can't be used because instance is null" at
  # runtime). Also: empty-effect rules, 2-binding non-contact queries,
  # state_add/spawn schema field-name landmines, engine_injected marker
  # for keyless input actions. Non-blocking; --strict for CI/agents.
  python3 "${YUME_ROOT}/tools/validate_rules.py" "${DATA_FOLDER}" || true
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

# Resolve --record default path (user://recordings/<game>_<timestamp>.avi)
if [ "$RECORD_DEFAULT" = "1" ] && [ -z "$RECORD_PATH" ]; then
  TS=$(date +%Y%m%d_%H%M%S)
  RECORD_PATH="user://recordings/${GAME_NAME}_${TS}.avi"
fi

# Build Godot pre-`--` flags array
GODOT_FLAGS=()
if [ -n "$RECORD_PATH" ]; then
  # Pre-create parent dir — Godot's MovieWriter doesn't mkdir, fails with
  # "Condition f.is_null() is true. Returning: ERR_UNCONFIGURED" if missing.
  REC_PARENT_WSL=""
  if [[ "$RECORD_PATH" == user://* ]]; then
    REL="${RECORD_PATH#user://}"
    REC_PARENT_WSL="/mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume Framework/$(dirname "${REL}")"
  elif [[ "$RECORD_PATH" == /mnt/* ]]; then
    REC_PARENT_WSL="$(dirname "$RECORD_PATH")"
  fi
  if [ -n "$REC_PARENT_WSL" ]; then
    mkdir -p "$REC_PARENT_WSL"
  fi
  GODOT_FLAGS+=("--write-movie" "$RECORD_PATH")
fi

echo "[play.sh] launching ${SCENE}${CAPTURE_DELAY:+ (capture ${CAPTURE_DELAY}s)}${RECORD_PATH:+ (recording → ${RECORD_PATH})}"
cd "${TEMPLATE_DST}"
if [ ${#USER_ARGS[@]} -gt 0 ]; then
  "${GODOT_BIN}" --path . "${GODOT_FLAGS[@]}" "${SCENE}" -- "${USER_ARGS[@]}"
else
  "${GODOT_BIN}" --path . "${GODOT_FLAGS[@]}" "${SCENE}"
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

# Locate + report recording output. AVI mode muxes audio into the container;
# PNG-sequence mode writes a sibling .wav.
if [ -n "$RECORD_PATH" ]; then
  REAL_REC="$RECORD_PATH"
  if [[ "$REAL_REC" == user://* ]]; then
    REL="${REAL_REC#user://}"
    REAL_REC="/mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume Framework/${REL}"
  fi
  if [ -f "$REAL_REC" ]; then
    SIZE=$(du -h "$REAL_REC" | cut -f1)
    echo "[play.sh] recorded: ${REAL_REC} (${SIZE})"
    EXT="${REAL_REC##*.}"
    if [ "$EXT" = "avi" ]; then
      MP4="${REAL_REC%.avi}.mp4"
      echo "[play.sh] convert:  ffmpeg -i \"${REAL_REC}\" -c:v libx264 -crf 22 -c:a aac \"${MP4}\""
    elif [ "$EXT" = "png" ]; then
      WAV="${REAL_REC%.png}.wav"
      [ -f "$WAV" ] && echo "[play.sh] audio:    ${WAV}"
    fi
  else
    echo "[play.sh] WARN: expected recording at ${REAL_REC} (not found)"
  fi
fi

exit ${RC}
