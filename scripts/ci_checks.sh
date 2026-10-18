#!/usr/bin/env bash
# Yume CI: the Python checks (batch G, 2026-10-16). GitHub Actions runs this
# script, and so can you: ./scripts/ci_checks.sh
# The Godot unit and scenario tests run in .github/workflows/ci.yml.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PY="${PYTHON:-python3}"
[ -x "$ROOT/venv/bin/python" ] && [ -z "${PYTHON:-}" ] && PY="$ROOT/venv/bin/python"
failed=()

run() {
  local name="$1"; shift
  echo "=== ${name}"
  if ! "$@"; then failed+=("$name"); fi
}

for v in validate_engine_wiring validate_tag_writes validate_claude_config \
         validate_meshes validate_no_stray_scripts validate_tick_override \
         validate_adr_index validate_host_neutral; do
  run "$v" "$PY" "tools/validators/${v}.py" --strict
done
run check_examples "$PY" tools/validators/check_examples.py --strict
for t in tools/validators/tests/test_*.py; do
  mod="$(echo "${t%.py}" | tr '/' '.')"
  run "$mod" "$PY" -m "$mod"
done
run yume_urdf "$PY" -m tools.yume_urdf.tests.test_urdf
run assetgen_pytest "$PY" -m pytest -q tools/yume_assetgen/tests
run assetgen_smoke "$PY" -m tools.yume_assetgen.tests.test_smoke
run glb_merge "$PY" -m tools.yume_assetgen.tests.test_glb_merge

if [ "${#failed[@]}" -ne 0 ]; then
  echo "[ci] FAILED: ${failed[*]}"
  exit 1
fi
echo "[ci] all Python checks passed"
