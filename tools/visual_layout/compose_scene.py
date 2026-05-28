"""compose_scene.py — ONE-COMMAND text-to-world orchestrator.

Chains the whole hand-assembled pipeline into a single run:

  catalog (stage 2, LLM-authored) + prose
    │  (this tool builds the 4 image prompts from the catalog)
    ├─ 1. HERO reference         openai text→image     (scene_brief + style)
    ├─ 2. ORTHOGRAPHIC top-down  openai /edits on HERO  (hero-conditioned → one art direction)
    ├─ 3. SEMANTIC map           openai /edits on ORTHO (flat palette classification)
    ├─ 4. HEIGHTMAP              openai /edits on ORTHO (grayscale elevation)
    ├─ 5. compose_world          (extract → map: defs, placements, biome ground, water)
    ├─ 6. compose_shell          (presentation: camera, player, input, lighting, .tscn)
    └─ 7. [--assets] yume_assetgen (tier-2 Tripo .glb for asset_source:tripo classes)

Idempotent: image steps skip if the output already exists (unless
--regen). World/terrain params come from the game's scene_config.json
(compose_world reads it); this tool just drives the order.

The catalog is the one LLM-authored input (yume-scene-class-catalog).
Everything downstream is deterministic — so the `/yume-create-scene`
skill is: author the catalog, then call this.

Usage:
    python3 -m tools.visual_layout.compose_scene <game> \\
        --catalog /tmp/_class_catalog.json [--prose "..."] \\
        [--regen] [--skip-gen] [--assets]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA_ROOT = ROOT / "godot" / "data"
sys.path.insert(0, str(ROOT))

from tools.yume_assetgen.backends.openai_images import OpenAIImagesBackend  # noqa: E402

_OPENAI = {"model": "gpt-image-2-2026-04-21", "quality": "high", "timeout": 420}


# --- prompt builders (from the catalog) ---------------------------------

def _hero_prompt(catalog: dict, prose: str | None) -> str:
    brief = prose or catalog.get("scene_brief", "")
    notes = catalog.get("composition_notes", "")
    return (
        f"{brief}. {notes}. Stylized fantasy game environment concept art, "
        "soft cel-shaded, cinematic global illumination, painterly lighting, "
        "bright sky, warm sunlight, atmospheric depth, cozy whimsical aesthetic, "
        "highly polished, clean composition.")


def _ortho_prompt(catalog: dict) -> str:
    brief = catalog.get("scene_brief", "")
    notes = catalog.get("composition_notes", "")
    return (
        "Convert the attached concept into an ORTHOGRAPHIC TOP-DOWN "
        "painterly aerial view of the SAME world. 90-degree bird's-eye, "
        "no horizon, no perspective vanishing point — but otherwise "
        "PRESERVE the attached concept's full painterly richness, brush "
        "texture, palette, warm sunlight, cast shadows, and atmospheric "
        "depth. The attached image IS the visual contract; only the "
        "camera angle changes (top-down instead of cinematic perspective). "
        f"Scene: {brief}. {notes}. "
        "COMPOSITION: one DOMINANT hero focal-anchor structure near the "
        "image center, supporting landmarks scattered around it (NOT a "
        "uniform field, NOT a grid). "
        "LIGHTING: warm directional sunlight casting visible shadows on "
        "the ground (shadows reveal 3D form even top-down). Atmospheric "
        "tint shift from sunlit hills to shaded valleys. "
        "DETAIL: visible painterly grass tonal variation, mossy rock "
        "clusters, dirt path brushwork, water reflections — every "
        "painted stroke from the concept should have a top-down "
        "equivalent. NOT a flat technical game-map; a top-down "
        "PAINTING of the concept's world. 1024x1024.")


def _semantic_prompt(catalog: dict) -> str:
    classes = [c for c in catalog.get("classes", [])
               if c.get("intent_type") in ("terrain_shader", "object_placement")]
    palette = "\n".join(
        f"- {c['hex']} = {c['name']} ({c.get('description', '')[:60]})"
        for c in classes)
    return (
        "Convert the attached top-down map into a FLAT-COLOR SEMANTIC "
        "CLASSIFICATION map. PRESERVE the exact layout + positions, but "
        "replace all detail with perfectly FLAT solid blocks of ONE hex "
        "colour each. Top-down, 1024x1024.\n\n"
        f"Use ONLY these exact hex colours:\n{palette}\n\n"
        "ABSOLUTE RULES: only those hex colours; FLAT solid fills; ZERO "
        "texture/shadow/gradient/outline/text. Looks like an MS-Paint "
        "bucket-fill diagram. Keep every feature at its original position.")


def _ground_paint_prompt(catalog: dict) -> str:
    """Prompt: ground-only sibling of the ortho.

    The full ortho has all object_placement classes (totems, trees,
    rocks, ruins, houses, walls, ... whatever this scene has) painted
    INTO it — using it as ground albedo paints those landmarks onto the
    floor UNDERNEATH the 3D meshes (visible from above + conflicting
    shadows). This prompt removes them, keeping just the painterly
    terrain_shader classes (grass, paths, water, sand, ... whatever
    this scene has). DERIVED from the catalog — works for any scene.
    """
    brief = catalog.get("scene_brief", "")
    objects = [c for c in catalog.get("classes", [])
               if c.get("intent_type") == "object_placement"]
    terrains = [c for c in catalog.get("classes", [])
                if c.get("intent_type") == "terrain_shader"]
    obj_phrase = ", ".join(
        f"{c['name']} ({c.get('description', '')[:50]})" for c in objects
    ) or "(none — nothing to remove)"
    terrain_phrase = ", ".join(
        f"{c['name']} ({c.get('description', '')[:50]})" for c in terrains
    ) or "(none — image has no terrain to preserve)"
    return (
        "Edit the attached top-down painted map. REMOVE every instance "
        "of these DISCRETE OBJECT types: "
        f"{obj_phrase}. "
        "KEEP only the painterly TERRAIN classes: "
        f"{terrain_phrase}. "
        "Preserve the EXACT terrain layout — path positions, water "
        "channel positions, biome boundaries — pixel-aligned with the "
        "source. Where removed objects USED TO BE, paint clean "
        "continuous terrain that seamlessly matches whatever surrounds "
        "those spots — NOT smudge, NOT blur. PRESERVE: same palette, "
        "same art direction, same painterly brushwork, same warm "
        "sunlight (but DROP the object cast shadows since the objects "
        "are gone). The result is a clean playable GROUND for the 3D "
        "scene to put real 3D objects on top of. "
        f"Scene context: {brief}. 1024x1024.")


def _heightmap_prompt(catalog: dict) -> str:
    h = catalog.get("heightmap_hints", {})
    topo = h.get("expected_topography", "mostly_flat")
    lows = ", ".join(h.get("low_regions", []) or ["valleys"])
    highs = ", ".join(h.get("high_regions", []) or ["rises"])
    return (
        "Convert the attached top-down map into a grayscale TERRAIN "
        "HEIGHTMAP, 1024x1024. Brightness = GROUND ELEVATION only: white = "
        f"highest, black = lowest, mid-grey = average. Topography: {topo}. "
        f"High (brighter): {highs}. Low (darker): {lows}. IGNORE + flatten "
        "every building/object/tree to the surrounding ground grey. Smooth "
        "low-frequency gradients only. Grayscale only (R=G=B). NO colour, "
        "NO object bumps.")


# --- gen + orchestration ------------------------------------------------

def _next_version(out: Path) -> Path:
    """Pick the next versioned filename so iterations live side-by-side.

    `orthographic.png` → `orthographic_v1.png` → `orthographic_v2.png` ...
    Skips numbers already taken (so re-runs don't collide).
    """
    n = 1
    while True:
        cand = out.parent / f"{out.stem}_v{n}{out.suffix}"
        if not cand.exists():
            return cand
        n += 1


def _gen(backend, prompt: str, out: Path, refs: list[Path] | None,
         regen: bool) -> None:
    """Generate to a UNIQUE versioned filename, then mirror to `out`
    (canonical). Iterations live side-by-side as `<stem>_v1.png`,
    `_v2.png`, ... — paid artifacts are NEVER overwritten or deleted.

    Behavior:
      - `out` exists, no --regen → skip.
      - `out` exists, --regen → if canonical content isn't already a
        `_vN` sibling (content-hash match), archive it as the next
        free `_vN` first. Then generate to the next-next `_vN` and
        mirror to canonical.
      - `out` doesn't exist → generate into `_v1`, mirror to canonical.
    """
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists() and not regen:
        print(f"  [skip] {out.name} (exists; --regen to force)")
        return
    # Preserve current canonical as a _vN sibling if it isn't already
    # represented (content-hash check to avoid duplicate copies of the
    # same paid artifact).
    if out.exists():
        cur_hash = hashlib.md5(out.read_bytes()).hexdigest()
        already = False
        for v in sorted(out.parent.glob(f"{out.stem}_v*{out.suffix}")):
            try:
                if hashlib.md5(v.read_bytes()).hexdigest() == cur_hash:
                    already = True
                    break
            except OSError:
                continue
        if not already:
            archived = _next_version(out)
            archived.write_bytes(out.read_bytes())
            print(f"  [keep] previous canonical → {archived.name}")
    versioned = _next_version(out)
    refs = [r for r in (refs or []) if r.exists()]
    last = None
    for attempt in range(3):
        try:
            kw = {"size": (1024, 1024)}
            if refs:
                kw["reference_images"] = refs
            backend.generate_texture(prompt, versioned, **kw)
            # Mirror the new version to the canonical path so downstream
            # (compose_world, the engine) keeps working without changes.
            out.write_bytes(versioned.read_bytes())
            print(f"  [gen]  {versioned.name} → {out.name}"
                  + (f" (conditioned on {refs[0].name})" if refs else ""))
            return
        except Exception as e:  # noqa: BLE001
            last = e
            print(f"  [retry {attempt + 1}] {out.name}: {e}")
    raise SystemExit(f"compose_scene: gen failed for {out.name}: {last}")


def _run(cmd: list[str]) -> None:
    print(f"  $ {' '.join(cmd[2:])}")
    r = subprocess.run([sys.executable, "-m", *cmd], cwd=str(ROOT))
    if r.returncode != 0:
        raise SystemExit(f"compose_scene: step failed: {' '.join(cmd)}")


def main() -> int:
    ap = argparse.ArgumentParser(prog="compose_scene")
    ap.add_argument("game")
    ap.add_argument("--catalog", required=True, help="stage-2 class_catalog.json")
    ap.add_argument("--prose", default=None, help="override scene prose for the hero")
    ap.add_argument("--regen", action="store_true", help="regenerate images even if present")
    ap.add_argument("--skip-gen", action="store_true", help="skip image gen (maps already exist)")
    ap.add_argument("--assets", action="store_true", help="also run Tripo asset gen")
    args = ap.parse_args()

    game_dir = DATA_ROOT / args.game
    catalog = json.loads(Path(args.catalog).read_text())
    ref_dir = game_dir / "assets" / "reference"
    hero = ref_dir / "hero_reference.png"
    ortho = ref_dir / "orthographic.png"
    ground = ref_dir / "ground_paint.png"
    sem = game_dir / "assets" / "layouts" / "semantic_map.png"
    hm = game_dir / "assets" / "textures" / "heightmap.png"

    if not args.skip_gen:
        backend = OpenAIImagesBackend(_OPENAI)
        print("[compose_scene] 1-5: image generation (openai, hero-anchored)")
        _gen(backend, _hero_prompt(catalog, args.prose), hero, None, args.regen)
        _gen(backend, _ortho_prompt(catalog), ortho, [hero], args.regen)   # hero-conditioned
        _gen(backend, _semantic_prompt(catalog), sem, [ortho], args.regen)  # ortho-conditioned
        _gen(backend, _heightmap_prompt(catalog), hm, [ortho], args.regen)
        # Ground-paint: ortho with all landmarks (totems/trees/rocks/ruins)
        # removed — used as the ground albedo so the 3D meshes aren't
        # stood on top of painted copies of themselves.
        _gen(backend, _ground_paint_prompt(catalog), ground, [ortho], args.regen)

    print("[compose_scene] 5: compose_world (extract → map)")
    _run(["tools.visual_layout.compose_world", args.game,
          "--catalog", args.catalog, "--semantic-map", str(sem),
          "--heightmap", str(hm)])

    print("[compose_scene] 6: compose_shell (presentation)")
    _run(["tools.visual_layout.compose_shell", args.game])

    if args.assets:
        print("[compose_scene] 7: asset gen (Tripo for asset_source:tripo)")
        _run(["tools.yume_assetgen", args.game])

    print(f"[compose_scene] DONE → {game_dir}")
    print(f"  run it: ./scripts/play.sh {args.game.removeprefix('demo_')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
