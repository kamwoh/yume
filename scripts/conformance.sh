#!/usr/bin/env bash
# Run the conformance cases in spec/conformance on both hosts (ADR 0095).
#   ./scripts/conformance.sh            # TypeScript host, then Godot
#   ./scripts/conformance.sh --ts-only  # TypeScript host only (CI has no Godot)
# The Godot host reads each case as data/conf_<case>, next to data/lib.
set -euo pipefail
cd "$(dirname "$0")/.."

cases=()
for d in spec/conformance/*/; do cases+=("${d%/}"); done

echo "=== TypeScript host ==="
node hosts/web/src/cli.ts --lib=godot/data/lib "${cases[@]}"

if [[ "${1:-}" == "--ts-only" ]]; then exit 0; fi

echo "=== Godot host ==="
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' scripts/play.sh)"
cp -r godot/. "$TEMPLATE_DST/"
fail=0
for c in "${cases[@]}"; do
  name="$(basename "$c")"
  rm -rf "$TEMPLATE_DST/data/conf_$name"
  cp -r "$c" "$TEMPLATE_DST/data/conf_$name"
  line="$(cd "$TEMPLATE_DST" && "$GODOT_BIN" --path . --headless scenes/scenario_test.tscn -- --game="conf_$name" 2>/dev/null \
    | grep -E 'passed:|✗' || true)"
  echo "$name: $line"
  grep -q 'failed: 0 ' <<<"$line" || fail=1
done
exit $fail
