"""ADR 0074 Phase C — Infinigen terrain → Yume ground GLB.

Runs in the EXTERNAL Infinigen py3.11+bpy env (YUME_INFINIGEN_PYTHON). Generates
a coarse Infinigen terrain (Ground + LandTiles + WarpedRocks + VoronoiRocks),
bakes its procedural surfaces, and exports a glb the Yume renderer loads as a
native-scale ground (`visual.normalize: false`, ADR 0062).

REQUIRES the terrain build (the minimal install skips it) — see README:
  make terrain                       # SDF kernels (g++)
  + glm headers → SoilMachine.so
  + cythonize marching_cubes as `infinigen.terrain.marching_cubes`
  + pip install landlab              # snowfall sim

Empirical 2026-06-20: generates a 150×150m terrain at ~1.4GB peak (NOT the
16GB that full foliage scenes need). Relief is real (std ~5m, range ~37m) —
use PLANAR decimate, never COLLAPSE (collapse pancakes terrain).
"""
import argparse
import os
import sys
from pathlib import Path
import bpy

from infinigen.core import init
from infinigen.core.util import blender as butil


def log(m):
    sys.stderr.write(m + "\n"); sys.stderr.flush()


def _patch_caves():
    """bpy-module compat: Cave.__init__ uses bpy.ops.mesh.primitive_vert_add,
    an addon-only operator absent in headless bpy-module. Replace with a
    data-API single vertex (trace_string sets its own modes afterward)."""
    import infinigen.terrain.assets.caves.core as cc

    def _cave_init(self, name="Cave"):
        self.modifier_stack = []
        me = bpy.data.meshes.new(name)
        me.from_pydata([(0.0, 0.0, 0.0)], [], []); me.update()
        obj = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(obj)
        bpy.context.view_layer.objects.active = obj; obj.select_set(True)
        cc.trace_string(["f"] * 2 + cc.generate_string(max_len=5000))
    cc.Cave.__init__ = _cave_init


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--scene-type", default="mountain",
                    help="nature scene_type gin (mountain/canyon/coast/desert/...)")
    ap.add_argument("--texres", type=int, default=1024)
    ap.add_argument("--max-faces", type=int, default=150000)
    ap.add_argument("--scatter", action="store_true",
                    help="also extract ecological scatter positions (trees/rocks)")
    ap.add_argument("--tree-density", type=float, default=0.02)
    ap.add_argument("--rock-density", type=float, default=0.015)
    args = init.parse_args_blender(ap)

    configs = [f"scene_types/{args.scene_type}"] if args.scene_type else None
    init.apply_gin_configs(
        ["infinigen_examples/configs_indoor", "infinigen_examples/configs_nature"],
        configs=configs,
        # caves use an addon-only bpy op absent in headless bpy-module; skip them
        overrides=["scene.caves_chance=0.0", "caves.load_assets.on_the_fly_instances=0"],
        skip_unknown=True)
    init.configure_blender()
    from infinigen.terrain.core import Terrain
    _patch_caves()
    butil.clear_scene()

    asset_tmp = Path("/tmp/yume_terrain_assets")
    asset_tmp.mkdir(parents=True, exist_ok=True)
    terrain = Terrain(args.seed, task="coarse", asset_folder="", asset_version="",
                      on_the_fly_asset_folder=asset_tmp)
    terrain.coarse_terrain()

    terr = bpy.data.objects.get("OpaqueTerrain")
    if terr is None:
        raise SystemExit("[YUME-INFINIGEN] no OpaqueTerrain produced")

    # C2: extract Infinigen ECOLOGICAL scatter positions (density + surface
    # selection), positions-only — NO heavy foliage realize. Blender coords
    # (Z up); the driver maps to Yume (Y up) and places Phase-B assets here.
    scatter = {}
    if args.scatter:
        from infinigen.core.placement import placement, density
        density.set_tag_dict(terrain.tag_dict)
        LAND = "landscape,-liquid_covered,-cave,-beach"
        # trees: flatish ground (normal_thresh filters slope); rocks: anywhere
        sel_t = density.placement_mask(scale=0.1, tag=LAND, normal_thresh=0.4)
        sel_r = density.placement_mask(scale=0.15, tag=LAND)
        for role, sel, dens, alt in [("tree", sel_t, args.tree_density, -0.1),
                                     ("rock", sel_r, args.rock_density, 0.0)]:
            locs = placement.placeholder_locs(terr, dens, sel, altitude=alt)
            scatter[role] = [[round(float(c), 3) for c in p] for p in locs.tolist()]
        log(f"[YUME-INFINIGEN] scatter: " + ", ".join(f"{k}={len(v)}" for k, v in scatter.items()))

    for o in list(bpy.data.objects):
        if o is not terr:
            try: bpy.data.objects.remove(o, do_unlink=True)
            except Exception: pass

    cur = len(terr.data.polygons)
    if cur > args.max_faces:
        # PLANAR decimate preserves height; COLLAPSE would flatten the relief.
        m = terr.modifiers.new("d", "DECIMATE")
        m.decimate_type = "PLANAR"; m.angle_limit = 0.04
        bpy.context.view_layer.objects.active = terr
        bpy.ops.object.modifier_apply(modifier=m.name)
    dims = list(terr.dimensions)  # Blender XYZ, Z up = height

    out = Path(args.out); out.parent.mkdir(parents=True, exist_ok=True)
    from infinigen.tools import export
    export.export_curr_scene(out.parent / "_terrbake", format="obj", image_res=args.texres)
    bpy.ops.export_scene.gltf(filepath=str(out), export_format="GLB", use_selection=False)

    import json as _json
    out.with_suffix(".json").write_text(_json.dumps({
        "seed": args.seed, "scene_type": args.scene_type, "terrain": True,
        "faces": len(terr.data.polygons),
        "size_m": [dims[0], dims[1]], "height_m": dims[2],
        "scatter": scatter,  # {role: [[x,y,z]_blender, ...]} — driver maps to Yume
    }, indent=1))
    log(f"[YUME-INFINIGEN] terrain.glb faces={len(terr.data.polygons)} dims={dims}")
    print(f"[YUME-INFINIGEN] wrote {out}", flush=True)
    os._exit(0)  # bpy-as-module segfaults in atexit cleanup; work is done


if __name__ == "__main__":
    main()
