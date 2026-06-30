"""Infinigen → Yume asset-library driver (ADR 0074, Phase B).

Runs in Yume's NORMAL python (no bpy). For each seed: shell out to
gen_asset.py inside the infinigen env (YUME_INFINIGEN_PYTHON, cwd =
YUME_INFINIGEN_REPO), copy the resulting .glb into the game's assets,
read the metadata sidecar, and emit a Yume entity def with a derived
collider (ADR 0072), natural-size scale, and tags.

  python -m tools.yume_infinigen demo_foo --factory BoulderFactory \
      --seeds 0,1,2 --faces 2500 --texres 512

Each seed is a distinct species → one entity def each. Placement is left
to Yume's own scatter/patterns (this tool owns defs + .glb, not layout —
that's Phase C).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections import OrderedDict
from pathlib import Path

from .catalog import format_catalog, list_factories, looks_like_part
from .config import (
    RECOMMENDED_NATURE,
    InfinigenUnavailable,
    default_collider,
    infinigen_python,
    infinigen_repo,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"
GEN_SCRIPT = Path(__file__).resolve().parent / "gen_asset.py"
TERRAIN_SCRIPT = Path(__file__).resolve().parent / "gen_terrain.py"


def _entity_def(slug: str, factory: str, mesh_res: str, height_m: float, collider: str) -> OrderedDict:
    """Build a Yume entity def. Collider from_visual_mesh derives the real
    size at runtime (ADR 0072); the size/offset here are fallbacks scaled
    off the asset's natural height."""
    h = max(height_m, 0.1)
    state = OrderedDict([("scale", round(h, 3)), ("yaw", 0.0)])
    visual = OrderedDict([
        ("_comment", f"Infinigen {factory} (ADR 0074): decimated + baked PBR via tools/yume_infinigen."),
        ("mesh", mesh_res),
    ])
    if collider != "none":
        if collider == "base":
            size, off = [h * 0.3, h, h * 0.3], [0.0, round(h / 2, 3), 0.0]
        else:  # full
            size, off = [h, h, h], [0.0, round(h / 2, 3), 0.0]
        visual["_physics_note"] = "collider from_visual_mesh; size/offset are fallbacks"
        return OrderedDict([
            ("id", slug), ("tags", ["decor"]), ("properties", OrderedDict()),
            ("state_init", state),
            ("visual", visual),
            ("physics", OrderedDict([
                ("$extends", "@lib.physics.bodies.static_wall"),
                ("collision_shape", OrderedDict([
                    ("type", "box"),
                    ("from_visual_mesh", collider if collider == "base" else True),
                    ("size", [round(v, 3) for v in size]),
                    ("offset", off),
                ])),
            ])),
        ])
    return OrderedDict([
        ("id", slug), ("tags", ["decor"]), ("properties", OrderedDict()),
        ("state_init", state), ("visual", visual),
    ])


def _generate_batch(py: Path, repo: Path, factory: str, seeds: list[int],
                    faces: int, texres: int, out_dir: Path) -> dict[int, dict]:
    """One Blender process for ALL seeds (amortizes gin init + factory
    resolve). Returns {seed: sidecar_meta} for the seeds that succeeded."""
    cmd = [str(py), str(GEN_SCRIPT), "--factory", factory,
           "--seeds", ",".join(str(s) for s in seeds), "--out-dir", str(out_dir),
           "--faces", str(faces), "--texres", str(texres)]
    # Foliage renders a leaf impostor with Eevee — force Mesa's llvmpipe
    # software GL so it's reliable headless (ZINK GPU init fails in WSL).
    genv = dict(os.environ, LIBGL_ALWAYS_SOFTWARE="1", GALLIUM_DRIVER="llvmpipe")
    r = subprocess.run(cmd, cwd=str(repo), capture_output=True, text=True, env=genv)
    if r.returncode != 0:
        sys.stderr.write(f"[yume_infinigen] generation process rc={r.returncode}\n")
        sys.stderr.write("\n".join(r.stderr.strip().splitlines()[-8:]) + "\n")
    # Surface per-seed failures — gen_one catches each and prints a FAILED line
    # to stdout, but the process still exits 0 (os._exit), so without this the
    # caller only sees "0/N assets" with no reason (e.g. an upstream Infinigen
    # error like CreatureGenome.postprocess_func on creatures, v1.19.1).
    for ln in r.stdout.splitlines():
        if "FAILED" in ln:
            sys.stderr.write(ln.strip() + "\n")
    slug_base = factory.lower().replace("factory", "")
    out: dict[int, dict] = {}
    for s in seeds:
        sidecar = out_dir / f"{slug_base}_{s}.json"
        glb = out_dir / f"{slug_base}_{s}.glb"
        if glb.exists() and sidecar.exists():
            out[s] = json.loads(sidecar.read_text())
    return out


def _terrain_def(mesh_res: str) -> OrderedDict:
    """A native-scale ground (visual.normalize=False, ADR 0062) with a trimesh
    collider matching the terrain 1:1 so the player walks on the real surface."""
    return OrderedDict([
        ("id", "terrain"),
        ("tags", ["terrain", "ground"]),
        ("properties", OrderedDict()),
        ("state_init", OrderedDict([("scale", 1.0)])),
        ("visual", OrderedDict([("mesh", mesh_res), ("normalize", False)])),
        ("physics", OrderedDict([
            ("$extends", "@lib.physics.bodies.static_wall"),
            # trimesh wants the glb path explicitly (native local space; the
            # visual renders the same glb with normalize:false → aligns 1:1)
            ("collision_shape", OrderedDict([("type", "trimesh"), ("mesh", mesh_res)])),
        ])),
    ])


def _generate_terrain_into_game(py: Path, repo: Path, args) -> int:
    game_dir = DATA_ROOT / args.game
    asset_dir = game_dir / "assets" / "infinigen"
    asset_dir.mkdir(parents=True, exist_ok=True)
    seed = args.seeds.split(",")[0].strip() or "0"
    with tempfile.TemporaryDirectory() as td:
        tmp_glb = Path(td) / "terrain.glb"
        cmd = [str(py), str(TERRAIN_SCRIPT), "--seed", seed, "--out", str(tmp_glb),
               "--scene-type", args.scene_type, "--texres", str(args.texres), "--scatter"]
        r = subprocess.run(cmd, cwd=str(repo), capture_output=True, text=True)
        if not tmp_glb.exists():
            sys.stderr.write(f"[yume_infinigen] terrain generation FAILED (rc={r.returncode})\n")
            sys.stderr.write("\n".join(r.stderr.strip().splitlines()[-12:]) + "\n")
            return 1
        sc = tmp_glb.with_suffix(".json")
        meta = json.loads(sc.read_text()) if sc.exists() else {}
        (asset_dir / "terrain.glb").write_bytes(tmp_glb.read_bytes())
    mesh_res = f"res://data/{args.game}/assets/infinigen/terrain.glb"
    defs_path = game_dir / "entities" / "infinigen_terrain.json"
    doc = json.loads(defs_path.read_text(), object_pairs_hook=OrderedDict) if defs_path.exists() \
        else OrderedDict([("definitions", []), ("initial_instances", [])])
    doc["definitions"] = [d for d in doc.get("definitions", []) if d.get("id") != "terrain"]
    doc["definitions"].append(_terrain_def(mesh_res))
    instances = [{"def": "terrain", "id": "terrain", "position": [0.0, 0.0, 0.0]}]
    instances += _scatter_instances(game_dir, meta.get("scatter") or {})
    doc["initial_instances"] = instances
    defs_path.write_text(json.dumps(doc, indent=1))
    sz = (meta.get("size_m") or ["?"])[0]
    print(f"[yume_infinigen] terrain ({args.scene_type}, {meta.get('faces','?')} faces, ~{sz}m) "
          f"+ {len(instances)-1} scattered assets -> {defs_path.relative_to(REPO_ROOT)}")
    print("  NOTE: clear scene.json ground.mesh so this terrain IS the ground.")
    return 0


def _scatter_instances(game_dir: Path, scatter: dict) -> list:
    """Place existing Phase-B asset defs at Infinigen's ecological scatter
    positions. Maps Blender (x,y,z up) → Yume (x, z, -y up). Cycles candidate
    defs per role for variety; varies yaw by index."""
    if not scatter:
        return []
    # candidate def ids per role, from the game's generated asset library
    assets_path = game_dir / "entities" / "infinigen_assets.json"
    ids = []
    if assets_path.exists():
        ids = [d.get("id", "") for d in json.loads(assets_path.read_text()).get("definitions", [])]
    role_defs = {
        "tree": [i for i in ids if any(k in i for k in ("tree", "bush", "fern", "cactus"))],
        "rock": [i for i in ids if any(k in i for k in ("boulder", "rock", "coral"))],
    }
    out, n = [], 0
    for role, positions in scatter.items():
        cands = role_defs.get(role) or []
        if not cands:
            print(f"  scatter: no Phase-B asset for role '{role}' "
                  f"({len(positions)} positions skipped — generate assets first)", file=sys.stderr)
            continue
        for bx, by, bz in positions:
            n += 1
            out.append({"def": cands[n % len(cands)], "id": f"sc{n}",
                        "position": [round(bx, 2), round(bz, 2), round(-by, 2)],
                        "state": {"yaw": round((n * 2.39996) % 6.283, 3)}})
        print(f"  scatter: {len(positions)} {role} -> {cands}", file=sys.stderr)
    return out


def main(argv=None) -> int:
    epilog = "recommended nature factories (any factory name also works):\n" + "\n".join(
        f"  {cat:14s} {', '.join(facs)}" for cat, facs in RECOMMENDED_NATURE.items()
    )
    ap = argparse.ArgumentParser(
        prog="yume_infinigen", epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("game", nargs="?", help="game folder name (e.g. demo_foo)")
    ap.add_argument("--factory",
                    help="any Infinigen object factory (resolved dynamically); "
                         "see the recommended list below or --list-factories")
    ap.add_argument("--list-factories", action="store_true",
                    help="print the full factory catalog and exit")
    ap.add_argument("--seeds", default="0", help="comma list, one species per seed")
    ap.add_argument("--faces", type=int, default=4000, help="decimate target")
    ap.add_argument("--texres", type=int, default=512, help="baked texture resolution")
    ap.add_argument("--collider", choices=["base", "full", "none"], default=None,
                    help="default: base for top-heavy props, full for solid (ADR 0072)")
    ap.add_argument("--terrain", action="store_true",
                    help="generate an Infinigen TERRAIN ground (Phase C) instead of an asset")
    ap.add_argument("--scene-type", default="mountain",
                    help="terrain scene_type (mountain/canyon/coast/desert/...)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    try:
        py, repo = infinigen_python(), infinigen_repo()
    except InfinigenUnavailable as e:
        print(f"[yume_infinigen] unavailable — {e}", file=sys.stderr)
        return 2

    if args.list_factories:
        print(format_catalog(str(repo)))
        return 0

    if args.terrain:
        if not args.game:
            print("error: GAME is required for --terrain", file=sys.stderr)
            return 1
        game_dir = DATA_ROOT / args.game
        if not game_dir.exists():
            print(f"error: {game_dir} does not exist", file=sys.stderr)
            return 1
        if args.dry_run:
            print(f"would generate {args.scene_type} terrain -> {game_dir}")
            return 0
        return _generate_terrain_into_game(py, repo, args)

    if not args.game or not args.factory:
        print("error: GAME and --factory are required (or use --list-factories)", file=sys.stderr)
        return 1
    game_dir = DATA_ROOT / args.game
    if not game_dir.exists():
        print(f"error: {game_dir} does not exist", file=sys.stderr)
        return 1

    # Fail fast on typos BEFORE the slow Blender launch (the resolver is the
    # authoritative spawnable check; this just catches misspellings cheaply).
    known = list_factories(str(repo))
    if args.factory not in known:
        import difflib
        hint = difflib.get_close_matches(args.factory, known.keys(), n=4)
        print(f"error: '{args.factory}' is not an Infinigen factory.", file=sys.stderr)
        if hint:
            print(f"  did you mean: {', '.join(hint)}?", file=sys.stderr)
        print("  see --list-factories for the full catalog.", file=sys.stderr)
        return 1
    if looks_like_part(args.factory):
        print(f"[yume_infinigen] note: '{args.factory}' looks like an internal PART "
              f"factory — it may not spawn standalone; the generator will reject it "
              f"if so.", file=sys.stderr)

    seeds = [int(s) for s in args.seeds.split(",") if s.strip() != ""]
    collider = args.collider or default_collider(args.factory)
    asset_dir = game_dir / "assets" / "infinigen"
    defs_path = game_dir / "entities" / "infinigen_assets.json"

    if args.dry_run:
        print(f"would generate {args.factory} seeds={seeds} faces={args.faces} "
              f"texres={args.texres} collider={collider} -> {defs_path}")
        return 0

    asset_dir.mkdir(parents=True, exist_ok=True)
    doc = OrderedDict([("definitions", []), ("initial_instances", [])])
    if defs_path.exists():
        doc = json.loads(defs_path.read_text(), object_pairs_hook=OrderedDict)
        doc.setdefault("definitions", [])
    by_id = {d["id"]: d for d in doc["definitions"]}

    made = 0
    slug_base = args.factory.lower().replace("factory", "")
    with tempfile.TemporaryDirectory() as td:
        metas = _generate_batch(py, repo, args.factory, seeds, args.faces, args.texres, Path(td))
        for seed in seeds:
            meta = metas.get(seed)
            if meta is None:
                continue
            slug = f"{slug_base}_{seed}"
            dest = asset_dir / f"{slug}.glb"
            dest.write_bytes((Path(td) / f"{slug}.glb").read_bytes())
            mesh_res = f"res://data/{args.game}/assets/infinigen/{slug}.glb"
            edef = _entity_def(slug, args.factory, mesh_res, float(meta.get("height_m", 1.0)), collider)
            by_id[slug] = edef  # replace-or-add
            made += 1
            print(f"  + {slug}  ({meta.get('faces','?')} faces, h={meta.get('height_m',0):.2f}m) -> {dest.name}")

    doc["definitions"] = list(by_id.values())
    defs_path.write_text(json.dumps(doc, indent=1))
    print(f"[yume_infinigen] {made}/{len(seeds)} assets -> {defs_path.relative_to(REPO_ROOT)}")
    return 0 if made else 1


if __name__ == "__main__":
    sys.exit(main())
