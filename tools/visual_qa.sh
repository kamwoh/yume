#!/bin/bash
# Visual QA helper — temporarily switches to auto_agent brain for capture,
# then restores original settings after.
#
# Usage: bash tools/visual_qa.sh [duration_seconds]

DURATION=${1:-20}
META="/mnt/c/Users/kamwoh/Documents/Projects/Godot/Yume3D/data/meta.json"
CAPTURES="/mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume3D/captures"
GODOT="/mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe"
PROJECT="C:/Users/kamwoh/Documents/Projects/Godot/Yume3D"

# Save original settings
ORIG_BRAIN=$(python3 -c "import json; d=json.load(open('$META')); print(d['player']['brain'])")
ORIG_AUTO=$(python3 -c "import json; d=json.load(open('$META')); print(str(d['capture']['auto']).lower())")

echo "[QA] Saved: brain=$ORIG_BRAIN, auto=$ORIG_AUTO"

# Switch to auto_agent + auto capture
python3 -c "
import json
with open('$META', 'r') as f: d = json.load(f)
d['player']['brain'] = 'auto_agent'
d['capture']['auto'] = True
with open('$META', 'w') as f: json.dump(d, f, indent=2)
print('[QA] Set: brain=auto_agent, auto=true')
"

# Clear old captures
rm -f "$CAPTURES"/frame_000*.png 2>/dev/null

# Run Godot
echo "[QA] Running Godot for ${DURATION}s..."
timeout "$DURATION" "$GODOT" --path "$PROJECT" --rendering-method gl_compatibility 2>&1 | grep -E "\[Grid\]|\[Entity\]|\[Player\]|\[Exit\]|\[Transition\]|\[Camera\]" | head -20

# Count captures
COUNT=$(ls "$CAPTURES"/frame_000*.png 2>/dev/null | wc -l)
echo "[QA] Captured $COUNT frames"

# Restore original settings
python3 -c "
import json
with open('$META', 'r') as f: d = json.load(f)
d['player']['brain'] = '$ORIG_BRAIN'
d['capture']['auto'] = $(echo $ORIG_AUTO | python3 -c "import sys; print(sys.stdin.read().strip().capitalize())")
with open('$META', 'w') as f: json.dump(d, f, indent=2)
print('[QA] Restored: brain=$ORIG_BRAIN, auto=$ORIG_AUTO')
"

echo "[QA] Done. Read captures at: $CAPTURES/frame_000*.png"
