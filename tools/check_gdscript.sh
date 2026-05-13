#!/usr/bin/env bash
# Yume GDScript style check — gdformat + gdlint.
#
# Usage:
#   tools/check_gdscript.sh                  # check all of godot/scripts/
#   tools/check_gdscript.sh --fix            # auto-format (writes files)
#   tools/check_gdscript.sh <file.gd>        # check one file
#   tools/check_gdscript.sh --fix <file.gd>  # auto-format one file
#
# Exit codes:
#   0 = clean OR --fix succeeded
#   1 = lint/format issues found (in check-only mode)
#   2 = gdtoolkit not installed
#
# Setup once: `venv/bin/pip install gdtoolkit`

set -e

YUME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${YUME_ROOT}/venv"
GDLINT="${VENV}/bin/gdlint"
GDFORMAT="${VENV}/bin/gdformat"
CONFIG="${YUME_ROOT}/gdlintrc"

if [[ ! -x "$GDLINT" ]] || [[ ! -x "$GDFORMAT" ]]; then
    echo "[check_gdscript] gdtoolkit not in venv — run: $VENV/bin/pip install gdtoolkit" >&2
    exit 2
fi

FIX=0
if [[ "${1:-}" == "--fix" ]]; then
    FIX=1
    shift
fi

TARGET="${1:-$YUME_ROOT/godot/scripts}"

cd "$YUME_ROOT"

if [[ $FIX -eq 1 ]]; then
    echo "[check_gdscript] formatting $TARGET ..."
    "$GDFORMAT" "$TARGET"
    echo "[check_gdscript] done. Run again without --fix to lint."
    exit 0
fi

echo "[check_gdscript] format check ($TARGET) ..."
FORMAT_RC=0
"$GDFORMAT" --check "$TARGET" || FORMAT_RC=$?

echo
echo "[check_gdscript] lint ($TARGET, config: gdlintrc) ..."
LINT_RC=0
"$GDLINT" "$TARGET" || LINT_RC=$?

if [[ $LINT_RC -ne 0 || $FORMAT_RC -ne 0 ]]; then
    echo
    if [[ $LINT_RC -ne 0 ]]; then
        echo "[check_gdscript] Lint violations summary by rule:"
        "$GDLINT" "$TARGET" 2>&1 \
            | grep -oE '\([a-z-]+\)$' \
            | sort | uniq -c | sort -rn || true
    fi
    if [[ $FORMAT_RC -ne 0 ]]; then
        echo "[check_gdscript] Format check failed — run --fix to apply."
    fi
    echo
    echo "[check_gdscript] To auto-fix tab/space + spacing issues:"
    echo "  tools/check_gdscript.sh --fix"
    exit 1
fi

echo "[check_gdscript] clean."
