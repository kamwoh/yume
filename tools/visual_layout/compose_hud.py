"""compose_hud.py — one-command HUD pipeline (ADR 0054 §S4 follow-up).

Wraps the full chain in a single call:

    prompt (or --edit-from existing wireframe)
        ↓ gemini-3.1-flash-image-preview ($0.05)
    semantic wireframe PNG
        ↓ extract_ui (opencv k-means)
    layout.json
        ↓ compile_ui
    hud skeleton json
        ↓ merge_hud (preserves rich existing elements)
    merged hud.json (alongside or in-place)

Optionally syncs to YumeTemplate + launches the game.

Usage:
    # Generate from scratch (writes preview, doesn't modify canonical):
    python3 -m tools.visual_layout.compose_hud demo_aldenmere \\
        --prompt "Survival HUD: big vitals dominate left, minimap top-right, ..."

    # Generate + apply in-place (backs up canonical to .bak):
    python3 -m tools.visual_layout.compose_hud demo_aldenmere \\
        --prompt "..." --apply

    # Iterate on the most recent wireframe:
    python3 -m tools.visual_layout.compose_hud demo_aldenmere \\
        --edit "Shrink vitals to bottom-left only" --apply

    # Full apply + launch:
    python3 -m tools.visual_layout.compose_hud demo_aldenmere \\
        --prompt "..." --apply --play

Preset library (for convenience):
    python3 -m tools.visual_layout.compose_hud demo_aldenmere \\
        --preset survival --apply
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.visual_layout.compile_ui import compile_layout_to_hud  # noqa: E402
from tools.visual_layout.extract_ui import extract_ui_layout, layout_to_dict  # noqa: E402
from tools.visual_layout.extractor_common import Legend  # noqa: E402
from tools.visual_layout.merge_hud import merge_layouts  # noqa: E402
from tools.yume_assetgen.backends.nanobanana import NanobananaBackend  # noqa: E402
from tools.yume_assetgen.ledger import load_ledger, prompt_hash  # noqa: E402


# ============================================================
# PROMPT BUILDING
# ============================================================


STRICT_TEMPLATE_PREFIX = """\
TECHNICAL DIAGRAM — solid color rectangles only — like MS Paint with
the bucket fill tool. ZERO decoration. ZERO texture. ZERO shadows.
ZERO outlines. ZERO text. ZERO labels. ZERO icons. ZERO illustrations.

Flat 2D UI wireframe layout. Dark neutral grey background (#1a1a1a).

Use ONLY these solid color rectangles (no other colors):
- WARM YELLOW (#f0e0a0) for objective text
- COOL LIGHT-BLUE (#a0c0e0) for day/time/season
- BRIGHT GREEN (#60c060) for minimap
- SALMON PINK (#e08080) for vitals
- WARM BROWN (#c0a060) for hotbar
- NEUTRAL GREY (#808080) for controls hint
- PURPLE (#9060c0) for inventory pouch

LAYOUT INTENT:
{intent}

ABSOLUTE RULES:
- Use ONLY the hex colors above.
- ZERO text characters anywhere.
- ZERO drop shadows or gradient fills.
- 16:9 aspect ratio.
- Panels clearly separated, NOT touching each other.
"""

EDIT_TEMPLATE = """\
You are editing an existing UI wireframe diagram. The attached image
is the CURRENT wireframe.

Apply this change to the layout:
{instruction}

CRITICAL RULES:
- Keep ALL other panels in their current positions, sizes, and colors.
  Only the change above should differ.
- Maintain the "TECHNICAL DIAGRAM" style: solid color rectangles,
  ZERO decoration, ZERO text, ZERO shadows.
- Use the SAME hex colors as the input image.
- Preserve the input image's aspect ratio.
"""


PRESETS = {
    "survival": (
        "Survival game HUD. The vitals panel (SALMON PINK) DOMINATES the "
        "left side — large vertical rectangle ~22% wide × 40% tall, anchored "
        "to the bottom-left with small gap. Everything else stays small: "
        "day/time tiny in top-left, objective narrow strip at top-center, "
        "minimap small square at top-right, hotbar narrow strip at bottom-"
        "center, controls hint very thin at very bottom edge, inventory "
        "tiny square at bottom-right. The eye should land on vitals FIRST."
    ),
    "minimal": (
        "Minimal HUD. Only 3 elements: objective text strip at top-center, "
        "small minimap square at top-right, controls hint thin strip at the "
        "very bottom edge. NO vitals panel. NO hotbar. NO inventory. The "
        "center 70% of the screen is empty so the game world is unobstructed. "
        "Aim: cinematic exploration mode where the world dominates."
    ),
    "dense": (
        "Information-dense HUD. Day/time top-left, weather strip just under "
        "it (treat as second top-left widget). Objective top-center. Quest "
        "log strip below the objective. Minimap top-right with a status "
        "ribbon below it. Vitals bottom-left, medium size. Hotbar bottom-"
        "center. Inventory bottom-right. Aim for a deep-systems-game density "
        "where lots of state is visible at once. 7-8 panels total."
    ),
    "compact": (
        "Compact distributed HUD. Tiny day/time top-left, narrow objective "
        "top-center, small minimap top-right, vitals stack bottom-left "
        "(medium size, not dominant), hotbar bottom-center, inventory pouch "
        "bottom-right. Generous breathing room between panels. Standard "
        "survival-RPG layout."
    ),
}


def _build_full_prompt(intent: str) -> str:
    return STRICT_TEMPLATE_PREFIX.format(intent=intent.strip())


# ============================================================
# LIVE PIPELINE
# ============================================================


def _resolve_recent_wireframe(layouts_dir: Path) -> Path | None:
    """Find the most-recent wireframe (by mtime)."""
    if not layouts_dir.exists():
        return None
    cands = sorted(
        layouts_dir.glob("hud_wireframe_*.png"),
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
        print(f"[compose] preset '{args.preset}' selected")

    edit_input: Path | None = None
    if args.edit:
        edit_input = (
            Path(args.edit_from) if args.edit_from else _resolve_recent_wireframe(layouts_dir)
        )
        if edit_input is None or not edit_input.exists():
            print("ERROR: --edit requires a previous wireframe (or --edit-from path)")
            return 2
        full_prompt = EDIT_TEMPLATE.format(instruction=args.edit.strip())
        kind = "wireframe_edit"
        print(f"[compose] edit mode: source={edit_input.name}")
    else:
        if not intent:
            print("ERROR: provide --prompt, --preset, or --edit")
            return 2
        full_prompt = _build_full_prompt(intent)
        kind = "visual_layout_wireframe"

    # === Stage 1: image gen ===
    print(f"\n[compose] === Stage 1: gemini-3.1-flash-image-preview (16:9) ===")
    asset_cfg_path = game_dir / "asset_gen.json"
    nano_cfg: dict = {"api_key_env": "GEMINI_API_KEY"}
    if asset_cfg_path.exists():
        nano_cfg.update(
            json.loads(asset_cfg_path.read_text()).get("backend_config", {}).get("nanobanana", {})
        )
    nano_cfg["model"] = "gemini-3.1-flash-image-preview"
    nano_cfg["aspect_ratio"] = "16:9"

    cache_key = (
        f"[compose][model:{nano_cfg['model']}][aspect:16:9]"
        f"{'[edit:' + edit_input.name + ']' if edit_input else ''}\n\n"
        + full_prompt
    )
    p_hash = prompt_hash(cache_key)
    wf_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()[:8]
    wf_name = (
        f"hud_wireframe_edit_{wf_hash}.png" if edit_input
        else f"hud_wireframe_{wf_hash}.png"
    )
    wf_path = layouts_dir / wf_name

    ledger = load_ledger(game_dir)
    hit = ledger.has("nanobanana", kind, p_hash)
    if hit:
        wf_path = game_dir / hit["out_path"]
        print(f"[compose] (cached) {wf_path.name}")
    elif wf_path.exists():
        print(f"[compose] (file exists, skipping) {wf_path.name}")
    else:
        backend = NanobananaBackend(nano_cfg)
        kwargs = {"reference_images": [edit_input]} if edit_input else {}
        backend.generate_texture(full_prompt, wf_path, size=(1280, 720), **kwargs)
        print(f"[compose] saved {wf_path.name}")
        ledger.add(
            backend="nanobanana",
            kind=kind,
            entity_id=f"hud_{args.game}",
            prompt=cache_key,
            p_hash=p_hash,
            out_path=str(wf_path.relative_to(game_dir)),
        )
        ledger.save()

    # === Stage 2: extract ===
    print(f"\n[compose] === Stage 2: extract ===")
    legend = Legend.from_file(ROOT / "tools" / "visual_layout" / "legends" / "ui_default.json")
    layout = extract_ui_layout(wf_path, legend, random_state=42)
    print(f"[compose] {len(layout.components)} components")
    for c in layout.components:
        print(f"  - {c.name:18s} anchor={c.anchor:14s} bbox={c.bbox_px}")
    if layout.warnings:
        print(f"  warnings: {layout.warnings}")
    layout_dict = layout_to_dict(layout)
    layout_json = layouts_dir / f"hud_layout_{wf_hash}.layout.json"
    layout_json.write_text(
        json.dumps(layout_dict, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    # === Stage 3: compile ===
    print(f"\n[compose] === Stage 3: compile ===")
    compiled_hud = compile_layout_to_hud(layout_dict, target_screen_size=(1280, 720))
    compiled_path = layouts_dir / f"hud_generated_{wf_hash}.json"
    compiled_path.write_text(
        json.dumps(compiled_hud, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    # === Stage 4: merge with canonical hud.json ===
    print(f"\n[compose] === Stage 4: merge ===")
    canonical = game_dir / "hud.json"
    if not canonical.exists():
        print(f"WARNING: canonical hud.json not found; writing compiled directly")
        merged = compiled_hud
        summary = {"matched": [], "appended": [p["_source_component"] for p in compiled_hud["panels"]], "preserved": []}
    else:
        existing = json.loads(canonical.read_text(encoding="utf-8"))
        merged = merge_layouts(compiled_hud, existing)
        summary = merged.pop("_merge_summary")
        print(f"  matched   ({len(summary['matched'])}): {summary['matched']}")
        print(f"  appended  ({len(summary['appended'])}): {summary['appended']}")
        print(f"  preserved ({len(summary['preserved'])}): {summary['preserved']}")

    # === Stage 5: apply or preview ===
    if args.apply:
        backup = canonical.with_suffix(canonical.suffix + ".bak")
        if canonical.exists():
            shutil.copy(canonical, backup)
        canonical.write_text(
            json.dumps(merged, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"\n[compose] APPLIED → {canonical.name}")
        print(f"  backup: {backup.name}")
        print(f"  revert: cp {backup.name} {canonical.name}")
    else:
        preview = game_dir / "hud.preview.json"
        preview.write_text(
            json.dumps(merged, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"\n[compose] PREVIEW → {preview.name} (not applied)")
        print(f"  apply later: cp {preview.name} {canonical.name}")
        print(f"  OR re-run with --apply")

    # === Stage 6 (optional): sync + play ===
    if args.play:
        play_sh = ROOT / "scripts" / "play.sh"
        if not play_sh.exists():
            print(f"WARNING: scripts/play.sh not found; can't auto-launch")
        else:
            print(f"\n[compose] launching ./scripts/play.sh {args.game}...")
            os.execvp("bash", ["bash", str(play_sh), args.game])
            # exec doesn't return

    return 0


# ============================================================
# CLI
# ============================================================


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="compose_hud",
        description="One-command HUD pipeline: prompt → gemini → opencv → merge → optionally apply + play.",
    )
    ap.add_argument("game", help="Game id, e.g. demo_aldenmere")
    group = ap.add_mutually_exclusive_group()
    group.add_argument("--prompt", help="Layout intent in natural language.")
    group.add_argument("--preset", choices=list(PRESETS),
                       help="Use a named preset prompt.")
    group.add_argument("--edit", help="Delta instruction to apply to the most recent wireframe.")
    ap.add_argument("--edit-from", help="Specific wireframe path for --edit (defaults to most recent).")
    ap.add_argument("--apply", action="store_true",
                    help="Write merged into canonical hud.json (with .bak backup). Otherwise saves to hud.preview.json.")
    ap.add_argument("--play", action="store_true",
                    help="After applying, launch ./scripts/play.sh <game>.")
    args = ap.parse_args()

    if not (args.prompt or args.preset or args.edit):
        ap.print_help()
        print("\nERROR: provide --prompt, --preset, or --edit", file=sys.stderr)
        return 2

    return cmd_compose(args)


if __name__ == "__main__":
    sys.exit(main())
