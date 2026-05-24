"""compose_screen.py — fit-fit SCREEN pipeline harness (Tier 2.7v).

╔══════════════════════════════════════════════════════════════════════╗
║  STABLE — 2D fit-fit pipeline (see compose_hud.py for full banner)   ║
║  Confirmed 2026-05-24. ADR required to modify the harness.           ║
╚══════════════════════════════════════════════════════════════════════╝



Sibling of compose_hud.py for modal/full-cover UIs (inventory, pause,
settings, title, ...). Wraps gen + preprocess + hand-off:

    prompt (or --edit-from)
        ↓ gemini-3.1-flash-image-preview (16:9, ~$0.05)
    wireframe PNG
        ↓ wireframe_to_screen.py preprocess <game> <wireframe> <screen_id>
    /tmp/_screen_author_context.json
        ↓ [LLM step] yume-screen-author reads context + wireframe
        ↓ writes /tmp/_screen_draft.json
        ↓ wireframe_to_screen.py postprocess (validates + splices into
        ↓                                     screens.json with .bak)
    screens.json with the new/replaced screen entry

Usage:
    # Generate + preprocess (stops at LLM hand-off):
    python3 -m tools.visual_layout.compose_screen demo_aldenmere \\
        --screen inventory --preset inventory

    # Then invoke /yume-screen-author in chat.

    # Iterate on the most-recent wireframe for this screen:
    python3 -m tools.visual_layout.compose_screen demo_aldenmere \\
        --screen inventory --edit "Move the close button to bottom-right"

Presets:
    inventory — survival-RPG inventory: title bar, big slot grid,
                detail panel, close button
    pause     — pause menu: Resume, Settings, Quit buttons centered
    settings  — settings menu: 3-4 sliders + checkboxes + Back button
    title     — title screen: title text, New Game / Continue / Quit
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
TECHNICAL DIAGRAM — solid color rectangles only — like MS Paint with
the bucket fill tool. ZERO decoration. ZERO texture. ZERO shadows.
ZERO outlines except where layout REQUIRES a button-border. ZERO
icons. ZERO illustrations of any kind.

This is a UI WIREFRAME, NOT a finished mockup. Each region is a
perfectly FLAT solid block of ONE hex color. Plain rectangles or
simple rounded rectangles only.

LAYOUT INTENT (use ONLY the hex colors listed below; place each
region as described relative to the 1376×768 16:9 canvas):
{intent}

ABSOLUTE RULES:
- Use ONLY the hex colors listed above.
- ZERO text glyphs except as solid color bands (the AUTHOR will
  decide text content; you just place the band).
- ZERO icons, ZERO illustrations.
- ZERO drop shadows, gradient fills, lighting effects.
- 16:9 output at full canvas.
"""

EDIT_TEMPLATE = """\
You are editing an existing UI wireframe. The attached image is the
CURRENT wireframe.

Apply this change:
{instruction}

CRITICAL RULES:
- Keep ALL other regions in their current positions, sizes, colors.
- Maintain the strict TECHNICAL DIAGRAM style: solid color blocks,
  ZERO decoration, ZERO text, ZERO shadows.
- Use the SAME hex colors as the input image.
- Preserve the input's 16:9 aspect ratio.
"""


PRESETS: dict[str, str] = {
    "inventory": (
        "Inventory modal screen (semi-transparent dark backdrop over the world).\n"
        "#0e0c0a — solid dark backdrop covering 90% of the canvas (centered). Modal background.\n"
        "#e8d8a0 — solid tan horizontal band at top-center, ~320px wide × 36px tall, ~50px from top. Inventory title.\n"
        "#1c1812 — solid dark-brown LARGE rectangle in the center of the canvas, ~700px wide × 380px tall, centered horizontally + vertically. Slot-grid background block.\n"
        "#ffd040 — five solid yellow vertical bands INSIDE the slot-grid rectangle, equally spaced, each ~110px wide × ~340px tall. These represent the 4-cell inventory grid + active-cell highlight. Author will interpret as slot_grid.\n"
        "#c0a070 — solid tan smaller rectangle at right-side of canvas, ~240px wide × 380px tall, ~80px from right edge, vertically centered. Item-detail panel.\n"
        "#a04020 — solid red-brown rectangle ~120px wide × 40px tall at bottom-right, ~40px in from each edge. Close button.\n"
        "#807060 — solid grey thin horizontal band at bottom-center, ~600px wide × 20px tall, ~30px from bottom. Controls hint."
    ),
    "pause": (
        "Pause menu modal (centered button stack).\n"
        "#0e0c0a — solid dark backdrop covering 90% of the canvas. Modal background.\n"
        "#e8d8a0 — solid tan horizontal band at top-center, ~320px wide × 40px tall, ~140px from top. PAUSED title.\n"
        "#a04020 — three solid red-brown rectangles vertically stacked at center, each ~280px wide × 56px tall, ~16px gap between. Resume / Settings / Quit buttons. Top button ~50px below the title."
    ),
    "settings": (
        "Settings menu modal.\n"
        "#0e0c0a — solid dark backdrop covering 90% of the canvas.\n"
        "#e8d8a0 — solid tan horizontal band at top-center, ~320px wide × 40px tall, ~80px from top. SETTINGS title.\n"
        "#7a7068 — four solid grey horizontal bars centered, each ~600px wide × 24px tall, vertically spaced ~80px apart, top one ~170px from top. Slider tracks.\n"
        "#ffd040 — small yellow square (~24px × 24px) on each grey bar at varying positions. Slider handles.\n"
        "#807060 — solid grey label band ~200px wide × 18px tall above each slider (4 of them). Slider labels.\n"
        "#a04020 — solid red-brown rectangle ~140px wide × 44px tall at bottom-center, ~40px from bottom. Back button."
    ),
    "title": (
        "Title screen (full cover, not a modal).\n"
        "#0a0c08 — solid very-dark backdrop filling the entire canvas. Background.\n"
        "#e8d8a0 — solid tan horizontal band at top-center, ~560px wide × 80px tall, ~120px from top. Game title.\n"
        "#a04020 — three solid red-brown rectangles vertically stacked at center, each ~280px wide × 56px tall, ~20px gap. New Game / Continue / Quit buttons. Top button ~80px below title.\n"
        "#807060 — small grey label band ~200px wide × 18px tall at bottom-center, ~30px from bottom. Version label."
    ),
    "dialog": (
        "NPC dialog modal (semi-transparent dark backdrop over the world).\n"
        "#0e0c0a — solid dark backdrop covering the lower 40% of the canvas (full width, bottom-anchored). Dialog panel background.\n"
        "#e8d8a0 — solid tan horizontal band at the TOP of the panel, ~280px wide × 36px tall, ~30px from left + ~30px below the panel top. NPC name label.\n"
        "#d8cba0 — solid lighter-tan large rectangle filling most of the panel interior, ~85% width × ~140px tall, centered inside the dialog backdrop. Dialog text area.\n"
        "#a04020 — three solid red-brown rectangles vertically stacked at right-bottom of the panel, each ~200px wide × 36px tall, ~10px gap. Player response choices (1-3 options).\n"
        "#807060 — small grey indicator at bottom-right ~40px square. 'Press E to continue' affordance."
    ),
    "save_slot": (
        "Save slot picker modal — pick a slot to save into or load from.\n"
        "#0e0c0a — solid dark backdrop covering 90% of canvas. Modal background.\n"
        "#e8d8a0 — solid tan horizontal band at top-center, ~360px wide × 40px tall, ~80px from top. 'SAVE GAME' or 'LOAD GAME' title.\n"
        "#1c1812 — solid dark-brown large rectangle centered, ~680px wide × 440px tall. Slot list container.\n"
        "#c0a070 — three solid tan horizontal bands stacked vertically inside the slot list, each ~640px wide × 110px tall, ~10px gap between. Each represents one save slot row (thumbnail + name + timestamp).\n"
        "#7a7068 — small grey square ~96px on the left of each slot row. Save thumbnail placeholder.\n"
        "#a04020 — solid red-brown rectangle ~140px wide × 44px tall at bottom-center, ~30px from bottom. Cancel button."
    ),
    "level_select": (
        "Level / chapter selector — campaign progress with locked + unlocked entries.\n"
        "#0a0c08 — solid very-dark backdrop covering full canvas.\n"
        "#e8d8a0 — solid tan horizontal band at top-center, ~440px wide × 48px tall, ~60px from top. 'CHAPTERS' title.\n"
        "#1c1812 — solid dark-brown grid container centered, ~960px wide × 420px tall. Chapter grid background.\n"
        "#c0a070 — six solid tan rectangles in a 3×2 grid inside the container, each ~280px wide × 180px tall, ~20px gap. Each represents one chapter. UNLOCKED chapters are filled tan; LOCKED chapters use #555 grey overlay.\n"
        "#ffd040 — small yellow dot ~16px diameter at top-right of one chapter card. 'CURRENT' marker.\n"
        "#a04020 — solid red-brown rectangle ~140px wide × 44px tall at bottom-left, ~40px from edges. Back button.\n"
        "#807060 — small grey progress band ~600px wide × 20px tall at bottom-center, ~30px from bottom. Campaign progress label/bar."
    ),
    "ending": (
        "End-of-game screen (success or failure variant). Full-cover, not a modal.\n"
        "#0a0c08 — solid very-dark backdrop covering full canvas. Background.\n"
        "#e8d8a0 — solid tan horizontal band at top-center, ~720px wide × 80px tall, ~120px from top. End-state title (e.g. 'You Survived' or 'The Forest Claims You').\n"
        "#d8cba0 — solid lighter-tan large rectangle centered, ~720px wide × 240px tall, ~40px below the title. Body text — game summary / epilogue.\n"
        "#7a7068 — four small grey horizontal bands stacked vertically below the body, each ~480px wide × 22px tall, ~14px gap. Stat lines (days survived / villagers saved / etc.).\n"
        "#a04020 — solid red-brown rectangle ~280px wide × 56px tall at bottom-center, ~40px from bottom. 'Continue' / 'Return to title' button."
    ),
}


def _resolve_recent_wireframe(layouts_dir: Path, screen_id: str) -> Path | None:
    if not layouts_dir.exists():
        return None
    cands = sorted(
        layouts_dir.glob(f"screen_{screen_id}_*.png"),
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

    sid = args.screen

    intent = args.prompt
    if args.preset:
        if args.preset not in PRESETS:
            print(f"ERROR: unknown preset '{args.preset}'. "
                  f"Options: {list(PRESETS)}")
            return 2
        intent = PRESETS[args.preset]

    edit_input: Path | None = None
    if args.edit:
        edit_input = (
            Path(args.edit_from) if args.edit_from
            else _resolve_recent_wireframe(layouts_dir, sid)
        )
        if edit_input is None or not edit_input.exists():
            print(f"ERROR: --edit requires a previous wireframe for "
                  f"screen='{sid}' (or --edit-from path)")
            return 2
        full_prompt = EDIT_TEMPLATE.format(instruction=args.edit.strip())
        kind = "visual_layout_screen_edit"
    else:
        if not intent:
            print("ERROR: provide --prompt, --preset, or --edit")
            return 2
        full_prompt = STRICT_TEMPLATE_PREFIX.format(intent=intent.strip())
        kind = "visual_layout_screen"

    # === Stage 1: image gen ===
    print(f"\n[compose_screen] === Stage 1: gemini-3.1 (16:9) ===")
    asset_cfg_path = game_dir / "asset_gen.json"
    nano_cfg: dict = {"api_key_env": "GEMINI_API_KEY"}
    if asset_cfg_path.exists():
        nano_cfg.update(
            json.loads(asset_cfg_path.read_text())
            .get("backend_config", {})
            .get("nanobanana", {})
        )
    nano_cfg["model"] = "gemini-3.1-flash-image-preview"
    nano_cfg["aspect_ratio"] = "16:9"

    cache_key = (
        f"[compose_screen][model:{nano_cfg['model']}][aspect:16:9]"
        f"[screen:{sid}]"
        f"{'[edit:' + edit_input.name + ']' if edit_input else ''}\n\n"
        + full_prompt
    )
    p_hash = prompt_hash(cache_key)
    wf_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()[:8]
    wf_name = (
        f"screen_{sid}_edit_{wf_hash}.png" if edit_input
        else f"screen_{sid}_{wf_hash}.png"
    )
    wf_path = layouts_dir / wf_name

    ledger = load_ledger(game_dir)
    hit = ledger.has("nanobanana", kind, p_hash)
    if hit:
        wf_path = game_dir / hit["out_path"]
        print(f"[compose_screen] (cached) {wf_path.name}")
    elif wf_path.exists():
        print(f"[compose_screen] (file exists, skipping) {wf_path.name}")
    else:
        backend = NanobananaBackend(nano_cfg)
        kwargs = {"reference_images": [edit_input]} if edit_input else {}
        backend.generate_texture(full_prompt, wf_path, size=(1280, 720), **kwargs)
        print(f"[compose_screen] saved {wf_path.name}")
        ledger.add(
            backend="nanobanana", kind=kind,
            entity_id=f"screen_{args.game}_{sid}",
            prompt=cache_key, p_hash=p_hash,
            out_path=str(wf_path.relative_to(game_dir)),
        )
        ledger.save()

    # === Stage 2: preprocess ===
    print(f"\n[compose_screen] === Stage 2: preprocess ===")
    from tools.visual_layout.wireframe_to_screen import cmd_preprocess  # local import

    class _PreprocessArgs:
        pass

    pa = _PreprocessArgs()
    pa.game = args.game
    pa.wireframe = str(wf_path)
    pa.screen_id = sid
    pa.out = None
    rc = cmd_preprocess(pa)
    if rc != 0:
        return rc

    ctx_path = Path("/tmp/_screen_author_context.json")

    # === Stage 3: hand off ===
    print()
    print("=" * 70)
    print("[compose_screen] WIREFRAME READY — hand off to /yume-screen-author")
    print("=" * 70)
    print()
    print(f"  wireframe:  {wf_path.relative_to(ROOT)}")
    print(f"  context:    {ctx_path}")
    print(f"  screen_id:  {sid}")
    print()
    print(f"Next step — in your Claude session, invoke:")
    print(f"  /yume-screen-author game={args.game} screen_id={sid} \\")
    print(f"      wireframe={wf_path.relative_to(ROOT)} context={ctx_path}")
    print()
    print(f"The skill will:")
    print(f"  1. Read the context + wireframe")
    print(f"  2. Author screens.json's '{sid}' entry fit-fit to the wireframe")
    print(f"  3. Run postprocess (validates + backs up + splices)")
    print()
    if args.play:
        print(f"After the skill applies, run:")
        print(f"  ./scripts/play.sh {args.game}")
        print()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="compose_screen")
    ap.add_argument("game")
    ap.add_argument("--screen", required=True,
                    help="Target screen id (e.g. 'inventory', 'pause')")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--prompt")
    g.add_argument("--preset", choices=list(PRESETS))
    g.add_argument("--edit")
    ap.add_argument("--edit-from")
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
