#!/bin/bash
# Visual QA walkthrough for demo_merchant.
# Captures screenshots at key gameplay milestones to verify the build
# is "feels like a game" quality before user wakes up.

YUME_BIN="/mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64.exe"
TEMPLATE="C:/Users/kamwoh/Documents/Projects/Godot/YumeTemplate"
WSL_USERDATA="/mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume Framework"
OUT="/home/kamwoh/yume/captures/merchant_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

# Sync framework first
cp -r /home/kamwoh/yume/godot/. /mnt/c/Users/kamwoh/Documents/Projects/Godot/YumeTemplate/

# 1. Initial state (town, player by shop)
"$YUME_BIN" --path "$TEMPLATE" scenes/play.tscn --rendering-driver opengl3 -- --game=demo_merchant --capture-after=2 --capture-output=user://m_01_initial.png > /dev/null 2>&1
cp "$WSL_USERDATA/m_01_initial.png" "$OUT/01_initial.png"

# 2. Walk into shop
"$YUME_BIN" --path "$TEMPLATE" scenes/play.tscn --rendering-driver opengl3 -- --game=demo_merchant --capture-after=1 --capture-input='move_east,3.5' --capture-output=user://m_02_inshop.png > /dev/null 2>&1
cp "$WSL_USERDATA/m_02_inshop.png" "$OUT/02_inshop.png"

# 3. Stay in shop, sell to customers (10s)
"$YUME_BIN" --path "$TEMPLATE" scenes/play.tscn --rendering-driver opengl3 -- --game=demo_merchant --capture-after=10 --capture-input='move_east,3.5' --capture-output=user://m_03_sales.png > /dev/null 2>&1
cp "$WSL_USERDATA/m_03_sales.png" "$OUT/03_sales.png"

# 4. Walk to dungeon (south)
"$YUME_BIN" --path "$TEMPLATE" scenes/play.tscn --rendering-driver opengl3 -- --game=demo_merchant --capture-after=2 --capture-input='move_south,3.0' --capture-output=user://m_04_indungeon.png > /dev/null 2>&1
cp "$WSL_USERDATA/m_04_indungeon.png" "$OUT/04_indungeon.png"

# 5. Kill an enemy in dungeon
"$YUME_BIN" --path "$TEMPLATE" scenes/play.tscn --rendering-driver opengl3 -- --game=demo_merchant --capture-after=1 --capture-input='move_south,3.0;move_east,1.5' --capture-output=user://m_05_postenemy.png > /dev/null 2>&1
cp "$WSL_USERDATA/m_05_postenemy.png" "$OUT/05_postenemy.png"

# 6. Pause menu (ESC)
"$YUME_BIN" --path "$TEMPLATE" scenes/play.tscn --rendering-driver opengl3 -- --game=demo_merchant --capture-after=1 --capture-input='pause,0.1' --capture-output=user://m_06_pause.png > /dev/null 2>&1
cp "$WSL_USERDATA/m_06_pause.png" "$OUT/06_pause.png"

echo "Captures landed in: $OUT"
ls -la "$OUT/"
