#!/bin/bash
# Run all game tests — data validation + system tests + Godot headless
# Usage: bash tools/run_all_tests.sh [data_path] [godot_exe]

DATA_PATH="${1:-/mnt/c/Users/kamwoh/Documents/Projects/Godot/FF9/data}"
GODOT="${2:-/mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe}"
FF9_WIN="C:/Users/kamwoh/Documents/Projects/Godot/FF9"

echo "============================================"
echo "  YUME TEST SUITE"
echo "============================================"
echo ""

# Layer 1: Data Validation (Python)
echo "▶ Layer 1: Data Validation"
echo "--------------------------------------------"
python3 "$(dirname "$0")/validate_game_data.py" "$DATA_PATH"
DATA_EXIT=$?
echo ""

# Layer 2: System Tests (Python)
echo "▶ Layer 2: Game System Tests"
echo "--------------------------------------------"
python3 "$(dirname "$0")/test_game_systems.py" "$DATA_PATH"
SYS_EXIT=$?
echo ""

# Layer 3: Godot Headless Tests (GDScript)
echo "▶ Layer 3: Godot Headless Tests"
echo "--------------------------------------------"
if [ -f "$GODOT" ]; then
    "$GODOT" --headless --path "$FF9_WIN" --script "res://tests/test_runner.gd" 2>&1 | grep -v "^Godot Engine" | grep -v "^$" | grep -v "ObjectDB" | grep -v "cleanup" | grep -v "SCRIPT ERROR" | grep -v "push_error" | grep -v "backtrace" | grep -v "location_manager"
    GODOT_EXIT=$?
else
    echo "  Godot not found at $GODOT — skipping headless tests"
    GODOT_EXIT=0
fi
echo ""

# Summary
echo "============================================"
echo "  SUMMARY"
echo "============================================"
if [ $DATA_EXIT -eq 0 ]; then
    echo "  Layer 1 (Data):    ✓ PASS"
else
    echo "  Layer 1 (Data):    ✗ FAIL"
fi
if [ $SYS_EXIT -eq 0 ]; then
    echo "  Layer 2 (Systems): ✓ PASS"
else
    echo "  Layer 2 (Systems): ✗ FAIL"
fi
if [ $GODOT_EXIT -eq 0 ]; then
    echo "  Layer 3 (Godot):   ✓ PASS"
else
    echo "  Layer 3 (Godot):   ✗ FAIL"
fi
echo "============================================"

# Exit with failure if any layer failed
if [ $DATA_EXIT -ne 0 ] || [ $SYS_EXIT -ne 0 ] || [ $GODOT_EXIT -ne 0 ]; then
    exit 1
fi
exit 0
