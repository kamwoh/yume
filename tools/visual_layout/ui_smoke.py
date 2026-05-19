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
from tools.yume_assetgen.backends.imagen import ImagenBackend  # noqa: E402
from tools.yume_assetgen.backends.nanobanana import NanobananaBackend  # noqa: E402
from tools.yume_assetgen.ledger import load_ledger, prompt_hash  # noqa: E402

GAME = "demo_aldenmere"

# Wireframe prompt for aldenmere's HUD. Strict + machine-readable.
# Per ADR 0054 §Two distinct image flavors: this is a SEMANTIC image,
# NOT a concept image. Flat, color-coded, ugly-on-purpose.
WIREFRAME_PROMPT = """\
TECHNICAL DIAGRAM — solid color rectangles only — like MS Paint with
the bucket fill tool. ZERO decoration. ZERO texture. ZERO shadows.
ZERO outlines. ZERO text. ZERO labels. ZERO icons. ZERO illustrations.

Flat 2D UI wireframe for a survival game HUD where the player's
SURVIVAL VITALS are the most prominent visual element (Dark Souls /
Valheim style — vitals dominate the bottom-left as a large vertical
panel; everything else stays small and out of the way).

Background: dark neutral grey #1a1a1a filling the whole frame.

Panels (each a SOLID FILLED RECTANGLE — NO outlines, NO shadows):

#e08080 — LARGE vertical rectangle in the BOTTOM-LEFT, roughly 22%
of frame WIDTH × 38% of frame HEIGHT. Anchored to the left edge with
a small gap (~2%) and rising up from the bottom edge with a small
gap. This is the vitals panel — survival bars dominate the eye.

#a0c0e0 — SMALL rectangle in the TOP-LEFT, roughly 14% wide × 8%
tall. Day/time/season info.

#60c060 — SMALL square in the TOP-RIGHT, roughly 14% × 14%. Minimap.

#f0e0a0 — narrow horizontal rectangle in TOP-CENTER, roughly 40%
wide × 4% tall. Just under the top edge with a small gap. Objective
text strip.

#c0a060 — narrow horizontal rectangle in BOTTOM-CENTER, roughly 28%
wide × 5% tall. Hotbar — kept SMALL so it doesn't compete with vitals.

#808080 — VERY thin horizontal strip at the very BOTTOM edge,
roughly 70% wide × 1.5% tall. Centered. Controls hint.

#9060c0 — SMALL square in the BOTTOM-RIGHT, roughly 7% × 7%.
Inventory pouch.

ABSOLUTE RULES:
- Use ONLY the 8 hex colors above (the 7 panels + background).
- ZERO text characters anywhere.
- ZERO drop shadows or gradient fills.
- ZERO outline strokes around shapes.
- 16:9 aspect ratio.
- Panels clearly separated, NOT touching each other.
- Vitals rectangle is the LARGEST panel by a clear margin.
- Hotbar is much smaller than vitals (different size class).
"""


def main() -> int:
    game_dir = ROOT / "godot" / "data" / GAME
    layouts_dir = game_dir / "assets" / "layouts"
    layouts_dir.mkdir(parents=True, exist_ok=True)

    # Load nanobanana config from asset_gen.json (same backend setup)
    asset_cfg_path = game_dir / "asset_gen.json"
    asset_cfg = json.loads(asset_cfg_path.read_text(encoding="utf-8"))
    nano_cfg = asset_cfg.get("backend_config", {}).get("nanobanana", {})

    # Ledger reuse — same per-game ledger as asset gen. Wireframes get
    # their own kind so they don't conflict with concept images.
    ledger = load_ledger(game_dir)
    # Suffix the prompt with the backend+aspect so the hash bin is
    # distinct from prior nanobanana 1:1 runs. Keeps both wireframes
    # on disk for comparison.
    cache_key = WIREFRAME_PROMPT + "\n\n[gemini-3.1-flash-image-preview-16:9]"
    p_hash = prompt_hash(cache_key)
    wf_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()[:8]
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
        # Use gemini-3.1-flash-image-preview for UI wireframes —
        # newer Gemini image model that respects strict layout prompts
        # AND accepts imageConfig.aspectRatio (gemini-2.5-flash-image
        # was 1:1 only; imagen-4 doesn't respect "ZERO decoration").
        wireframe_cfg = dict(nano_cfg)
        wireframe_cfg["model"] = "gemini-3.1-flash-image-preview"
        wireframe_cfg["aspect_ratio"] = "16:9"
        gen = NanobananaBackend(wireframe_cfg)
        gen.generate_texture(WIREFRAME_PROMPT, wf_path, size=(1280, 720))
        print(f"[ui_smoke] wireframe saved: {wf_path.name}")
        ledger.add(
            backend="nanobanana",
            kind="visual_layout_wireframe",
            entity_id="hud_aldenmere",
            prompt=cache_key,
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
