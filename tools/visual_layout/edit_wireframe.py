"""edit_wireframe.py — apply a delta instruction to an existing
wireframe via Gemini multimodal (image + text → image).

Different from ui_smoke / map_smoke (which generate FROM SCRATCH).
This tool ITERATES on a previously-generated wireframe: feed the
image back as a reference, give a short delta instruction
("shrink vitals", "swap minimap and day_time", "add a new orange
warning bar"). Costs $0.05 per edit. Output goes alongside the
input for comparison.

Uses gemini-3.1-flash-image-preview with imageConfig.aspectRatio
inherited from the input image's aspect (so 16:9 inputs stay 16:9).

Usage:
    python3 -m tools.visual_layout.edit_wireframe \\
        --input godot/data/demo_aldenmere/assets/layouts/hud_wireframe_10d342ee.png \\
        --instruction "Shrink the salmon vitals panel to occupy only the bottom-left quadrant (not the full left side). Keep everything else exactly the same." \\
        --output godot/data/demo_aldenmere/assets/layouts/hud_wireframe_edit_<tag>.png

    # The --output filename hash is auto-derived if you pass --tag instead:
    python3 -m tools.visual_layout.edit_wireframe \\
        --input ...hud_wireframe_X.png \\
        --instruction "..." \\
        --tag smaller_vitals
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import cv2

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.yume_assetgen.backends.nanobanana import NanobananaBackend  # noqa: E402
from tools.yume_assetgen.ledger import load_ledger, prompt_hash  # noqa: E402


EDIT_PROMPT_TEMPLATE = """\
You are editing an existing UI wireframe diagram. The attached image \
is the CURRENT wireframe.

Apply this change to the layout:
{instruction}

CRITICAL RULES:
- Keep ALL other panels in their current positions, sizes, and colors. \
Only the change above should differ.
- Maintain the "TECHNICAL DIAGRAM" style: solid color rectangles, \
ZERO decoration, ZERO text, ZERO shadows, ZERO outlines, ZERO icons, \
ZERO labels, ZERO illustrations.
- Use the SAME hex colors as the input image for any panels you keep.
- Preserve the input image's aspect ratio.
- Output: a clean flat 2D wireframe with the change applied.
"""


def _infer_aspect(img_path: Path) -> str:
    """Pick a Gemini-supported aspect-ratio enum nearest the input image's."""
    img = cv2.imread(str(img_path))
    if img is None:
        return "16:9"  # default
    h, w = img.shape[:2]
    ratio = w / max(h, 1)
    options = {"1:1": 1.0, "16:9": 16/9, "9:16": 9/16, "4:3": 4/3, "3:4": 3/4}
    return min(options.items(), key=lambda kv: abs(kv[1] - ratio))[0]


def main() -> int:
    ap = argparse.ArgumentParser(prog="edit_wireframe")
    ap.add_argument("--input", required=True, type=Path)
    ap.add_argument("--instruction", required=True,
                    help="The delta to apply, plain English.")
    ap.add_argument("--output", type=Path, default=None,
                    help="Output path. Defaults to <input_dir>/hud_wireframe_edit_<tag>.png")
    ap.add_argument("--tag", type=str, default=None,
                    help="Short tag to embed in output filename. Defaults to instruction hash.")
    ap.add_argument("--model", type=str, default="gemini-3.1-flash-image-preview",
                    help="Gemini image model id. Multimodal-capable.")
    ap.add_argument("--game", type=str, default="demo_aldenmere",
                    help="Game whose ledger we record the edit to.")
    args = ap.parse_args()

    if not args.input.exists():
        print(f"ERROR: --input not found: {args.input}")
        return 2

    # Build the edit prompt
    full_prompt = EDIT_PROMPT_TEMPLATE.format(instruction=args.instruction.strip())

    # Output naming
    if args.output is None:
        tag = args.tag or hashlib.sha256(args.instruction.encode("utf-8")).hexdigest()[:8]
        out_path = args.input.parent / f"hud_wireframe_edit_{tag}.png"
    else:
        out_path = args.output

    # Ledger check + record
    game_dir = ROOT / "godot" / "data" / args.game
    asset_cfg_path = game_dir / "asset_gen.json"
    nano_cfg = {"api_key_env": "GEMINI_API_KEY"}
    if asset_cfg_path.exists():
        nano_cfg.update(
            json.loads(asset_cfg_path.read_text()).get("backend_config", {}).get("nanobanana", {})
        )
    nano_cfg["model"] = args.model
    nano_cfg["aspect_ratio"] = _infer_aspect(args.input)

    cache_key = (
        f"[edit]\n[input:{args.input.name}]\n[model:{args.model}]\n[aspect:{nano_cfg['aspect_ratio']}]\n\n"
        + full_prompt
    )
    p_hash = prompt_hash(cache_key)
    ledger = load_ledger(game_dir)
    hit = ledger.has("nanobanana", "wireframe_edit", p_hash)
    if hit:
        print(f"[edit_wireframe] (ledger cached) prior result: {hit['out_path']}")
        return 0
    if out_path.exists():
        print(f"[edit_wireframe] (file exists, skipping gen) {out_path}")
        return 0

    print(f"[edit_wireframe] model: {args.model}")
    print(f"[edit_wireframe] aspect: {nano_cfg['aspect_ratio']}")
    print(f"[edit_wireframe] input: {args.input.name}")
    print(f"[edit_wireframe] instruction: {args.instruction[:80]}{'...' if len(args.instruction) > 80 else ''}")
    print(f"[edit_wireframe] output: {out_path.name}")
    print(f"[edit_wireframe] calling Gemini (~$0.05)...")

    backend = NanobananaBackend(nano_cfg)
    backend.generate_texture(
        full_prompt,
        out_path,
        reference_images=[args.input],
    )

    ledger.add(
        backend="nanobanana",
        kind="wireframe_edit",
        entity_id="hud_aldenmere",
        prompt=cache_key,
        p_hash=p_hash,
        out_path=str(out_path.relative_to(game_dir)) if out_path.is_relative_to(game_dir) else str(out_path),
    )
    ledger.save()
    print(f"[edit_wireframe] saved {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
