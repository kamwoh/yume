"""compose_map.py — fit-fit level pipeline harness (Tier 2.7v, 2026-05-20).

Sibling of compose_hud.py / compose_screen.py. Wraps gen + preprocess +
hand-off for procedural level generation:

    prompt (or --edit-from existing map)
        ↓ gemini-3.1-flash-image-preview (1:1 top-down semantic map)
    semantic map PNG (1024x1024)
        ↓ wireframe_to_map.py preprocess <game> <map> <level_id>
    /tmp/_map_author_context.json
        ↓ [LLM step] yume-map-author reads context + map via vision
        ↓ writes /tmp/_map_draft.json with initial_instances + patterns
        ↓ wireframe_to_map.py postprocess (validates + splices into
        ↓                                  levels/<level_id>/entities.json
        ↓                                  with .bak backup)
    Level loadable via in-game K-picker (already registered).

Usage:
    # Generate + preprocess (stops at LLM hand-off):
    python3 -m tools.visual_layout.compose_map demo_aldenmere \\
        --preset camp --level-id level_camp_v2

    # Then invoke /yume-map-author in your Claude session.

    # Iterate on most-recent map for this level_id:
    python3 -m tools.visual_layout.compose_map demo_aldenmere \\
        --level-id level_camp_v2 --edit "Move the fire pit west"
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.yume_assetgen.backends.nanobanana import NanobananaBackend  # noqa: E402
from tools.yume_assetgen.ledger import load_ledger, prompt_hash  # noqa: E402


STRICT_TEMPLATE_PREFIX = """\
TECHNICAL DIAGRAM — solid color regions only — like MS Paint with the
bucket fill tool. ZERO decoration. ZERO texture. ZERO shadows. ZERO
outlines. ZERO text. ZERO labels. ZERO icons. ZERO illustrated trees
as separate shapes. ZERO illustrations of any kind.

This is a CSS color palette test, NOT an illustration. Top-down 2D
layout. Each region is a perfectly FLAT solid block of ONE hex color.
Plain rectangles or simple rounded rectangles only.

LAYOUT INTENT (use ONLY the hex colors listed below):
{intent}

ABSOLUTE RULES:
- Use ONLY the hex colors listed above.
- ZERO text characters anywhere.
- ZERO illustrated trees, leaves, foliage, grass blades, brick
  patterns, wood grain, water ripples.
- ZERO drop shadows or gradient fills.
- ZERO outline strokes around shapes.
- 1024x1024 square output (top-down map).
"""

EDIT_TEMPLATE = """\
You are editing an existing top-down semantic map. The attached image
is the CURRENT map.

Apply this change:
{instruction}

CRITICAL RULES:
- Keep ALL other regions in their current positions, sizes, and colors.
- Maintain the strict TECHNICAL DIAGRAM style: solid color blocks,
  ZERO decoration, ZERO text, ZERO shadows.
- Use the SAME hex colors as the input image.
- Preserve the input image's aspect ratio.
"""


PRESETS = {
    "camp": (
        "Top-down forest-clearing survival camp.\n"
        "#2a5a2a — solid dark green forest. Fills the outer 25% border of the image as a frame.\n"
        "#a0d870 — solid light green grass clearing. Fills the central 50% of the image.\n"
        "#f0c020 — solid yellow circle ~8% of image width, at the exact center. Fire pit.\n"
        "#a04020 — solid red-brown square ~8% wide, west of the yellow circle. Hut.\n"
        "#e08040 — solid orange square ~8% wide, east of the yellow circle. Drying rack.\n"
        "#9060c0 — solid purple square ~6% wide, lower-right. Storage.\n"
        "#3070c0 — solid blue rectangle filling the bottom 12% of the image. River.\n"
        "#704020 — solid dark brown rectangle ~10% wide × 4% tall at bottom-center crossing the river. Bridge.\n"
        "#c8a878 — solid tan thin lines connecting the bridge upward to the yellow circle, then short branches to hut/rack/storage. Paths.\n"
        "#e040a0 — three small pink circles ~3% wide each, upper-left of clearing. Berry bushes.\n"
        "#808080 — three small grey circles ~3% wide each, upper-right of clearing. Rocks."
    ),
    "wilderness": (
        "Sparse top-down wilderness — no camp, no buildings. ALL anchors absent except natural landmarks.\n"
        "#2a5a2a — solid dark green forest. Covers most of the image (~70%) with irregular boundary.\n"
        "#a0d870 — light green meadow patches breaking up the forest. Several small irregular ovals.\n"
        "#3070c0 — solid blue irregular pond ~10% wide in mid-left of image. Water.\n"
        "#c8a878 — solid tan path winding through the image from one edge to another. Thin meandering line.\n"
        "#e040a0 — five small pink circles scattered through the meadow patches. Berry bushes.\n"
        "#808080 — five small grey circles scattered along the forest edge. Rocks."
    ),
    "minimal_test": (
        "Minimal test scene.\n"
        "#a0d870 — solid light green filling the central 70% of the image. Grass.\n"
        "#2a5a2a — solid dark green border around the edges. Forest.\n"
        "#f0c020 — solid yellow circle ~10% wide at the exact center. Fire pit. ONE."
    ),
}


# ============================================================
# PIPELINE
# ============================================================


def _resolve_recent_map(layouts_dir: Path) -> Path | None:
    if not layouts_dir.exists():
        return None
    cands = sorted(
        layouts_dir.glob("camp_map_*.png"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return cands[0] if cands else None


def cmd_compose(args) -> int:
    game_dir = ROOT / "godot" / "data" / args.game
    if not game_dir.exists():
        print(f"ERROR: game dir not found: {game_dir}")
        return 2
    layouts_dir = game_dir / "assets" / "layouts"
    layouts_dir.mkdir(parents=True, exist_ok=True)

    # Determine prompt + mode
    intent = args.prompt
    if args.preset:
        if args.preset not in PRESETS:
            print(f"ERROR: unknown preset '{args.preset}'. Options: {list(PRESETS)}")
            return 2
        intent = PRESETS[args.preset]

    edit_input: Path | None = None
    if args.edit:
        edit_input = Path(args.edit_from) if args.edit_from else _resolve_recent_map(layouts_dir)
        if edit_input is None or not edit_input.exists():
            print("ERROR: --edit requires a previous map (or --edit-from path)")
            return 2
        full_prompt = EDIT_TEMPLATE.format(instruction=args.edit.strip())
        kind = "visual_layout_map_edit"
    else:
        if not intent:
            print("ERROR: provide --prompt, --preset, or --edit")
            return 2
        full_prompt = STRICT_TEMPLATE_PREFIX.format(intent=intent.strip())
        kind = "visual_layout_semantic_map"

    # === Stage 1: image gen ===
    print(f"\n[compose_map] === Stage 1: gemini-3.1-flash-image-preview (1:1) ===")
    asset_cfg_path = game_dir / "asset_gen.json"
    nano_cfg: dict = {"api_key_env": "GEMINI_API_KEY"}
    if asset_cfg_path.exists():
        nano_cfg.update(
            json.loads(asset_cfg_path.read_text()).get("backend_config", {}).get("nanobanana", {})
        )
    nano_cfg["model"] = "gemini-3.1-flash-image-preview"
    nano_cfg["aspect_ratio"] = "1:1"

    cache_key = (
        f"[compose_map][model:{nano_cfg['model']}][aspect:1:1]"
        f"{'[edit:' + edit_input.name + ']' if edit_input else ''}\n\n"
        + full_prompt
    )
    p_hash = prompt_hash(cache_key)
    map_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()[:8]
    map_name = f"camp_map_edit_{map_hash}.png" if edit_input else f"camp_map_{map_hash}.png"
    map_path = layouts_dir / map_name

    ledger = load_ledger(game_dir)
    hit = ledger.has("nanobanana", kind, p_hash)
    if hit:
        map_path = game_dir / hit["out_path"]
        print(f"[compose_map] (cached) {map_path.name}")
    elif map_path.exists():
        print(f"[compose_map] (file exists) {map_path.name}")
    else:
        backend = NanobananaBackend(nano_cfg)
        kwargs = {"reference_images": [edit_input]} if edit_input else {}
        backend.generate_texture(full_prompt, map_path, size=(1024, 1024), **kwargs)
        print(f"[compose_map] saved {map_path.name}")
        ledger.add(
            backend="nanobanana",
            kind=kind,
            entity_id=f"map_{args.game}",
            prompt=cache_key,
            p_hash=p_hash,
            out_path=str(map_path.relative_to(game_dir)),
        )
        ledger.save()

    # === Stage 2: preprocess for the fit-fit author ===
    # Rewired 2026-05-20 — the CV chain (extract_map_layout +
    # _compile_with_resolution) below is now an LLM-as-parser handoff,
    # matching what compose_hud + compose_screen do.
    print(f"\n[compose_map] === Stage 2: preprocess (yume-map-author harness) ===")
    from tools.visual_layout.wireframe_to_map import cmd_preprocess  # local import

    class _PreprocessArgs:
        pass

    pa = _PreprocessArgs()
    pa.game = args.game
    pa.map = str(map_path)
    pa.level_id = args.level_id if hasattr(args, "level_id") and args.level_id else f"layout_{map_hash}"
    pa.out = None  # use default /tmp/_map_author_context.json
    rc = cmd_preprocess(pa)
    if rc != 0:
        return rc

    ctx_path = Path("/tmp/_map_author_context.json")

    # === Stage 3: hand off ===
    print()
    print("=" * 70)
    print("[compose_map] MAP READY — hand off to /yume-map-author")
    print("=" * 70)
    print()
    print(f"  map:        {map_path.relative_to(ROOT)}")
    print(f"  context:    {ctx_path}")
    print(f"  level_id:   {pa.level_id}")
    print()
    print(f"Next step — in your Claude session, invoke:")
    print(f"  /yume-map-author game={args.game} level_id={pa.level_id} \\")
    print(f"      map={map_path.relative_to(ROOT)} context={ctx_path}")
    print()
    print(f"The skill will:")
    print(f"  1. Read context + map via vision")
    print(f"  2. Author levels/{pa.level_id}/entities.json fit-fit to the map")
    print(f"  3. Run postprocess (validates def_ids + bounds + caps, "
          f"backs up + applies)")
    print()
    if args.play:
        print(f"After the skill applies, run:")
        print(f"  ./scripts/play.sh {args.game}")
        print()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="compose_map")
    ap.add_argument("game")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--prompt")
    g.add_argument("--preset", choices=list(PRESETS))
    g.add_argument("--edit")
    ap.add_argument("--edit-from")
    ap.add_argument("--level-id", help="Target level id (default: layout_<hash>)")
    ap.add_argument("--play", action="store_true",
                    help="Hint at the play command in the hand-off message.")
    args = ap.parse_args()
    if not (args.prompt or args.preset or args.edit):
        ap.print_help()
        print("\nERROR: provide --prompt, --preset, or --edit", file=sys.stderr)
        return 2
    return cmd_compose(args)


if __name__ == "__main__":
    sys.exit(main())
