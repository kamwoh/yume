#!/usr/bin/env bash
# Yume LINUX runner — drive the native Linux Godot binary for headless work.
#
# Counterpart to play.sh (which uses the WINDOWS binary for play/captures).
# This script is for the headless paths where the Windows-via-WSL build is
# unreliable or impossible: the ADR 0060 stdio env, plus fast headless
# tests/scenarios without the /mnt/c round-trip or WSL-pipe flakiness.
#
# Same build hash as the Windows binary (14d19694e) — no behavioral divergence.
# Shares its project + .godot cache with tools/yume_env/env.py (assets-excluded;
# state-only, so no meshes are imported — 1.7GB -> 19MB, near-instant import).
#
# Usage:
#   ./scripts/run_linux.sh sync                 # rsync source -> linux project + import
#   ./scripts/run_linux.sh test                 # unit suite (scenes/test_main.tscn)
#   ./scripts/run_linux.sh scenario <game>      # scenario_test.tscn -- --game=<game>
#   ./scripts/run_linux.sh envtest              # tools/yume_env/test_env.py (env CI gate)
#   ./scripts/run_linux.sh run <scene> [-- ...] # raw: <bin> --path . --headless <scene> -- ...
#
# Flags:
#   --reimport   force a Godot --import (needed after adding a NEW class_name
#                or new resource; plain .gd edits compile at load, no reimport)
#   --with-assets  include data/*/assets/ in the sync (heavy; only if you need
#                  meshes/textures — e.g. a future pixel/frame channel)
#
# Env overrides (match env.py): YUME_GODOT_LINUX_BIN, YUME_GODOT_LINUX_PROJECT.
set -euo pipefail

YUME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_GODOT="${YUME_ROOT}/godot"
BIN="${YUME_GODOT_LINUX_BIN:-/home/kamwoh/godot-linux/Godot_v4.6.1-stable_linux.x86_64}"
PROJECT="${YUME_GODOT_LINUX_PROJECT:-/home/kamwoh/godot-linux/yume}"

REIMPORT=0
WITH_ASSETS=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --reimport)    REIMPORT=1 ;;
    --with-assets) WITH_ASSETS=1 ;;
    *)             ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]}"

if [ ! -x "${BIN}" ]; then
  echo "Error: Linux Godot binary not found/executable at: ${BIN}" >&2
  echo "Download Godot_v4.6.1-stable_linux.x86_64 or set YUME_GODOT_LINUX_BIN." >&2
  exit 1
fi

sync_project() {
  mkdir -p "${PROJECT}"
  local excludes=(--exclude=.godot/)
  if [ "${WITH_ASSETS}" -eq 0 ]; then
    # heavy per-demo render assets only; KEEP data/lib/assets (small engine
    # test fixtures the unit suite needs — else 2 ground/heightmap assertions
    # silently drop and `test` under-counts vs play.sh).
    excludes+=(--exclude='data/demo_*/assets/')
  fi
  echo "[run_linux] rsync ${SOURCE_GODOT}/ -> ${PROJECT}/ (assets:$([ ${WITH_ASSETS} -eq 1 ] && echo on || echo off))"
  rsync -a --delete "${excludes[@]}" "${SOURCE_GODOT}/" "${PROJECT}/"
  if [ "${REIMPORT}" -eq 1 ] || [ ! -d "${PROJECT}/.godot" ]; then
    echo "[run_linux] importing (first time or --reimport)..."
    "${BIN}" --path "${PROJECT}" --headless --import 2>&1 | tail -3
  fi
}

CMD="${1:-}"
shift || true

case "${CMD}" in
  sync)
    sync_project
    ;;
  test)
    sync_project
    "${BIN}" --path "${PROJECT}" --headless scenes/test_main.tscn 2>&1 | tee /tmp/linux_test.log
    ;;
  scenario)
    GAME="${1:?usage: run_linux.sh scenario <game>}"
    sync_project
    "${BIN}" --path "${PROJECT}" --headless scenes/scenario_test.tscn -- --game="${GAME}" 2>&1 | tee /tmp/linux_scen.log
    ;;
  envtest)
    sync_project
    ( cd "${YUME_ROOT}" && venv/bin/python -m tools.yume_env.test_env )
    ;;
  run)
    SCENE="${1:?usage: run_linux.sh run <scene> [-- <args>]}"
    shift || true
    # Drop a leading `--` so callers can write: run <scene> -- --game=x
    [ "${1:-}" = "--" ] && shift || true
    sync_project
    "${BIN}" --path "${PROJECT}" --headless "${SCENE}" -- "$@" 2>&1 | tee /tmp/linux_run.log
    ;;
  ""|help|-h|--help)
    sed -n '2,30p' "${BASH_SOURCE[0]}"
    ;;
  *)
    echo "Unknown command: ${CMD} (try: sync | test | scenario <game> | envtest | run <scene>)" >&2
    exit 2
    ;;
esac
