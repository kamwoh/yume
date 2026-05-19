"""ui_smoke.py — end-to-end Phase 1 live test (ADR 0054).

Targets aldenmere's HUD. Generates a wireframe via nanobanana, runs
the full extract → validate → compile pipeline, diffs against the
current hand-authored hud.json. Proves the pipeline on a real example.

Cost: ~$0.05 per run (nanobanana). Ledger-cached so re-runs with the
same prompt skip re-pay.

Usage:
    python3 -m tools.visual_layout.ui_smoke
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.visual_layout.compile_ui import compile_layout_to_hud  # noqa: E402
from tools.visual_layout.extract_ui import extract_ui_layout, layout_to_dict  # noqa: E402
from tools.visual_layout.extractor_common import Legend  # noqa: E402
from tools.yume_assetgen.backends.nanobanana import NanobananaBackend  # noqa: E402
from tools.yume_assetgen.ledger import load_ledger, prompt_hash  # noqa: E402

GAME = "demo_aldenmere"

# Wireframe prompt for aldenmere's HUD. Strict + machine-readable.
# Per ADR 0054 §Two distinct image flavors: this is a SEMANTIC image,
# NOT a concept image. Flat, color-coded, ugly-on-purpose.
WIREFRAME_PROMPT = """\
A clean flat 2D UI wireframe layout for a first-person survival game HUD.

Strict requirements for machine extraction:
- flat 2D layout only, no perspective
- dark neutral grey background (#1a1a1a)
- each UI panel is a solid-color filled rectangle
- NO shadows, NO gradients, NO textures, NO decorative illustrations
- NO labels, NO text, NO icons, NO handwritten characters
- clean rectangular boundaries between panels
- panels clearly separated from each other (visible gaps)
- centered composition, 16:9 aspect ratio

UI panels to include, each as a SOLID FILLED RECTANGLE with the \
specified color:
- TOP-CENTER: long narrow horizontal rectangle in WARM YELLOW (#f0e0a0) \
for objective text
- TOP-LEFT: small rectangle in COOL LIGHT-BLUE (#a0c0e0) for \
day/time/season
- TOP-RIGHT: square panel in BRIGHT GREEN (#60c060) for minimap
- BOTTOM-LEFT: vertical rectangle in SALMON PINK (#e08080) for \
vitals bars (hunger/health/warmth/energy)
- BOTTOM-CENTER: long narrow horizontal rectangle in WARM BROWN \
(#c0a060) for hotbar
- BOTTOM thin strip just above bottom edge: very thin rectangle in \
NEUTRAL GREY (#808080) for controls hint
- BOTTOM-RIGHT: small rectangle in PURPLE (#9060c0) for inventory \
quickslots

The output must look like a flat colored block layout for a UI \
compiler, NOT a finished game UI. Use ONLY the exact hex colors \
specified above. NO text characters anywhere in the image.
"""


def main() -> int:
    game_dir = ROOT / "godot" / "data" / GAME
    layouts_dir = game_dir / "layouts"
    layouts_dir.mkdir(parents=True, exist_ok=True)

    # Load nanobanana config from asset_gen.json (same backend setup)
    asset_cfg_path = game_dir / "asset_gen.json"
    asset_cfg = json.loads(asset_cfg_path.read_text(encoding="utf-8"))
    nano_cfg = asset_cfg.get("backend_config", {}).get("nanobanana", {})

    # Ledger reuse — same per-game ledger as asset gen. Wireframes get
    # their own kind so they don't conflict with concept images.
    ledger = load_ledger(game_dir)
    p_hash = prompt_hash(WIREFRAME_PROMPT)
    wf_hash = hashlib.sha256(WIREFRAME_PROMPT.encode("utf-8")).hexdigest()[:8]
    wf_path = layouts_dir / f"hud_wireframe_{wf_hash}.png"

    print(f"[ui_smoke] target: {GAME}")
    print(f"[ui_smoke] prompt_hash: {p_hash}")
    print(f"[ui_smoke] output: {wf_path.name}")

    # === Stage 1: wireframe image (nanobanana) ===
    print("\n[ui_smoke] === Stage 1: generate wireframe ===")
    hit = ledger.has("nanobanana", "visual_layout_wireframe", p_hash)
    if hit:
        print(f"[ui_smoke] (ledger cached) prior wireframe: {hit['out_path']}")
        wf_path = game_dir / hit["out_path"]
    elif wf_path.exists():
        print(f"[ui_smoke] (file exists, skipping gen) {wf_path.name}")
    else:
        nano = NanobananaBackend(nano_cfg)
        nano.generate_texture(WIREFRAME_PROMPT, wf_path, size=(1280, 720))
        print(f"[ui_smoke] wireframe saved: {wf_path.name}")
        ledger.add(
            backend="nanobanana",
            kind="visual_layout_wireframe",
            entity_id="hud_aldenmere",
            prompt=WIREFRAME_PROMPT,
            p_hash=p_hash,
            out_path=str(wf_path.relative_to(game_dir)),
        )
        ledger.save()

    # === Stage 2: extract ===
    print("\n[ui_smoke] === Stage 2: extract ===")
    legend = Legend.from_file(ROOT / "tools" / "visual_layout" / "legends" / "ui_default.json")
    layout = extract_ui_layout(wf_path, legend, random_state=42)
    print(f"[ui_smoke] extracted {len(layout.components)} components")
    for c in layout.components:
        print(f"  - {c.name:18s} anchor={c.anchor:14s} bbox={c.bbox_px}")
    if layout.warnings:
        print(f"  warnings: {layout.warnings}")
    layout_dict = layout_to_dict(layout)
    layout_json_path = layouts_dir / f"hud_layout_{wf_hash}.layout.json"
    layout_json_path.write_text(
        json.dumps(layout_dict, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"[ui_smoke] layout saved: {layout_json_path.name}")

    # === Stage 3: compile to hud.json ===
    print("\n[ui_smoke] === Stage 3: compile to hud.json (alongside, not overwrite) ===")
    compiled_hud = compile_layout_to_hud(layout_dict, target_screen_size=(1280, 720))
    # Save side-by-side, do NOT overwrite the existing hud.json
    compiled_path = layouts_dir / f"hud_generated_{wf_hash}.json"
    compiled_path.write_text(
        json.dumps(compiled_hud, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"[ui_smoke] compiled hud saved: {compiled_path.name}")

    # === Stage 4: diff against existing hud.json ===
    print("\n[ui_smoke] === Stage 4: diff vs existing hud.json ===")
    existing_hud_path = game_dir / "hud.json"
    if existing_hud_path.exists():
        existing = json.loads(existing_hud_path.read_text(encoding="utf-8"))
        existing_anchors = sorted({p.get("anchor", "?") for p in existing.get("panels", [])})
        compiled_anchors = sorted({p.get("anchor", "?") for p in compiled_hud["panels"]})
        print(f"  existing anchors: {existing_anchors}")
        print(f"  compiled anchors: {compiled_anchors}")
        only_existing = set(existing_anchors) - set(compiled_anchors)
        only_compiled = set(compiled_anchors) - set(existing_anchors)
        if only_existing:
            print(f"  ONLY in existing: {only_existing}")
        if only_compiled:
            print(f"  ONLY in compiled: {only_compiled}")

    print(f"\n[ui_smoke] DONE — outputs in {layouts_dir.relative_to(ROOT)}")
    print(f"  wireframe:    {wf_path.name}")
    print(f"  layout.json:  {layout_json_path.name}")
    print(f"  hud.json:     {compiled_path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
