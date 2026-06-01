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
#   ./scripts/run_linux.sh lockstep [game] [ticks] [input]
#                                               # ADR 0061: 2 ENet peers (host+client),
#                                               # compare per-tick hashes → IN SYNC / DESYNC.
#                                               # default: demo_tiny_village 30 move_north
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
  lockstep)
    # ADR 0061: launch a host + a client (two ENet peers on loopback), each
    # driving a walking character, and compare their per-tick canonical hashes.
    # Identical hashes + no desync = the two instances ran in perfect lockstep.
    GAME="${1:-demo_tiny_village}"
    TICKS="${2:-30}"
    INPUT="${3:-move_north}"
    sync_project
    pkill -f "$(basename "${BIN}")" 2>/dev/null || true  # no-match is fine (set -e)
    sleep 1
    rm -f /tmp/ls_host.json /tmp/ls_client.json
    echo "[run_linux] lockstep ${GAME}: host + client × ${TICKS} ticks, input='${INPUT}'"
    "${BIN}" --path "${PROJECT}" --headless scenes/play.tscn -- \
      --game="${GAME}" --lockstep-host --lockstep-port=7799 \
      --lockstep-ticks="${TICKS}" --lockstep-input="${INPUT}" \
      --lockstep-out=/tmp/ls_host.json >/tmp/ls_host.log 2>&1 &
    HOST=$!
    sleep 2.5
    "${BIN}" --path "${PROJECT}" --headless scenes/play.tscn -- \
      --game="${GAME}" --lockstep-join=127.0.0.1:7799 --lockstep-port=7799 \
      --lockstep-ticks="${TICKS}" --lockstep-input="${INPUT}" \
      --lockstep-out=/tmp/ls_client.json >/tmp/ls_client.log 2>&1 &
    CLIENT=$!
    wait "${HOST}" "${CLIENT}" 2>/dev/null
    venv/bin/python - <<'PY'
import json, sys
try:
    h = json.load(open("/tmp/ls_host.json")); c = json.load(open("/tmp/ls_client.json"))
except Exception as e:
    print("FAIL: no result (see /tmp/ls_host.log /tmp/ls_client.log) —", e); sys.exit(1)
print("host  :", json.dumps(h))
print("client:", json.dumps(c))
ok = bool(h.get("final_hash")) and h["final_hash"] == c["final_hash"] \
     and h["desync_tick"] == -1 and c["desync_tick"] == -1
print("\nLOCKSTEP:", "IN SYNC ✓ — identical hashes, no desync" if ok
      else "DESYNC ✗ — hashes differ / desync_tick set")
sys.exit(0 if ok else 1)
PY
    ;;
  net)
    # ADR 0063: client-server, DEDICATED server + spawn-on-join. 3 instances:
    # 1 server (no player) + 2 clients (each spawns a player on join). Correctness:
    # the server's authoritative roster must equal BOTH clients' applied state.
    GAME="${1:-demo_tiny_village}"
    TICKS="${2:-300}"
    INPUT="${3:-move_north}"
    sync_project
    pkill -f "$(basename "${BIN}")" 2>/dev/null || true
    sleep 1
    rm -f /tmp/net_host.json /tmp/net_c1.json /tmp/net_c2.json
    echo "[run_linux] net ${GAME}: dedicated server + 2 clients × ${TICKS} ticks, input='${INPUT}'"
    "${BIN}" --path "${PROJECT}" --headless scenes/play.tscn -- \
      --game="${GAME}" --net-host --net-port=7801 \
      --net-ticks="${TICKS}" --net-input="${INPUT}" \
      --net-out=/tmp/net_host.json >/tmp/net_host.log 2>&1 &
    HOST=$!
    sleep 2.5
    "${BIN}" --path "${PROJECT}" --headless scenes/play.tscn -- \
      --game="${GAME}" --net-join=127.0.0.1:7801 --net-port=7801 \
      --net-ticks="${TICKS}" --net-input="${INPUT}" \
      --net-out=/tmp/net_c1.json >/tmp/net_c1.log 2>&1 &
    C1=$!
    sleep 1
    "${BIN}" --path "${PROJECT}" --headless scenes/play.tscn -- \
      --game="${GAME}" --net-join=127.0.0.1:7801 --net-port=7801 \
      --net-ticks="${TICKS}" --net-input="${INPUT}" \
      --net-out=/tmp/net_c2.json >/tmp/net_c2.log 2>&1 &
    C2=$!
    wait "${HOST}" "${C1}" "${C2}" 2>/dev/null
    venv/bin/python - <<'PY'
import json, sys
try:
    h = json.load(open("/tmp/net_host.json"))
    c1 = json.load(open("/tmp/net_c1.json")); c2 = json.load(open("/tmp/net_c2.json"))
except Exception as e:
    print("FAIL: no result (see /tmp/net_host.log /tmp/net_c1.log /tmp/net_c2.log) —", e); sys.exit(1)
print("server  :", json.dumps(h))
print("client1 :", json.dumps(c1))
print("client2 :", json.dumps(c2))
sp = h.get("actor_positions", {})
# 2 players spawned (one per client), all three instances agree on both.
ok = len(sp) == 2 and sp == c1.get("actor_positions", {}) == c2.get("actor_positions", {})
print("\nCLIENT-SERVER:", "REPLICATED ✓ — 2 players, server + both clients agree"
      if ok else "MISMATCH ✗ — rosters/positions differ (or != 2 players)")
sys.exit(0 if ok else 1)
PY
    ;;
  ""|help|-h|--help)
    sed -n '2,33p' "${BASH_SOURCE[0]}"
    ;;
  *)
    echo "Unknown command: ${CMD} (try: sync | test | scenario <game> | envtest | run <scene> | lockstep <game>)" >&2
    exit 2
    ;;
esac
