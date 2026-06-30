"""ADR 0074 Phase B — Infinigen asset → decimated GLB, single Blender session.

Runs in the EXTERNAL Infinigen py3.11+bpy env (YUME_INFINIGEN_PYTHON), NOT
Yume's venv. One session: generate -> join -> decimate -> bake -> GLB, so the
raw (multi-million-poly) mesh is reduced BEFORE the export/bake step that
OOM-killed the naive round-trip (empirical 2026-06-19, realized tree).

Usage (from the infinigen repo root):
  $YUME_INFINIGEN_PYTHON tools/yume_infinigen/gen_asset.py \
      --factory ChunkyRock --seed 0 --out /tmp/rock.glb --faces 3000 --texres 512
"""
import argparse
import os
from pathlib import Path
import bpy

from infinigen.core import init
from infinigen.core.util import blender as butil
from infinigen.tools import export

def _resolve_factory_class(name):
    """Find an AssetFactory subclass by name anywhere under
    infinigen.assets.objects — so ALL ~300 factories work without a
    hand-maintained map. GREPs source for `class <name>` to find the
    defining file, then imports ONLY that module (importing the whole
    package took ~63s). The AssetFactory subclass check also rejects
    internal PART factories (CrabClawFactory etc. — not AssetFactory)."""
    import importlib
    import inspect
    import re
    from pathlib import Path

    import infinigen.assets.objects as objects_pkg
    from infinigen.core.placement.factory import AssetFactory

    root = Path(objects_pkg.__path__[0])
    pat = re.compile(r"^class\s+" + re.escape(name) + r"\b")
    for py in root.rglob("*.py"):
        try:
            if not any(pat.match(ln) for ln in py.read_text(errors="ignore").splitlines()):
                continue
            rel = py.relative_to(root).with_suffix("")
            modname = objects_pkg.__name__ + "." + ".".join(rel.parts)
            cls = getattr(importlib.import_module(modname), name, None)
            if inspect.isclass(cls) and issubclass(cls, AssetFactory):
                return cls
        except Exception:
            continue
    return None


def resolve_or_die(name):
    """Resolve a factory class by name once, or exit with a clear message."""
    cls = _resolve_factory_class(name)
    if cls is None:
        raise SystemExit(
            f"[YUME-INFINIGEN] factory '{name}' not found as an AssetFactory under "
            f"infinigen.assets.objects. Check the spelling, or it may be an "
            f"internal part factory (e.g. CrabClawFactory)."
        )
    return cls


def construct(cls, seed, realize=True, season=None):
    """Construct a factory instance. `realize` and `season` are passed only
    where the factory accepts them. realize=True bakes instanced leaves to mesh
    (solid path); realize=False KEEPS them as cheap instances (foliage billboard
    path). season='summer' gives vivid-green foliage (else it randomizes, often
    to a washed autumn). Empirical 2026-06-20."""
    import inspect

    sig = inspect.signature(cls.__init__).parameters
    kwargs = {}
    if "realize" in sig:
        kwargs["realize"] = realize
    if season is not None and "season" in sig:
        kwargs["season"] = season
    return cls(seed, **kwargs)


def collect_meshes(asset):
    """The asset's geometry: the returned object (if a MESH) plus its mesh
    descendants, restricted to SELECTABLE (view-layer) objects so the
    un-linked helper objects ('tree.003' etc.) that can't be joined are
    excluded; falls back to all view-layer meshes if the asset yields none.

    Works for solid + plant + aquatic assets (boulder, cactus, coral, fern).
    KNOWN LIMITATION (2026-06-19): TreeFactory organizes leaves in separate
    collections NOT reachable as `asset` descendants, and its standalone
    twig/leaf realization is unstable (intermittent 21GB OOM — 'twigs are
    typically generated only in coarse'). So trees export trunk-only
    (sculptural, leafless). Leafy trees need Infinigen's full scene-compose
    pipeline (Phase C), not the standalone-asset path — see ADR 0074."""
    vl = bpy.context.view_layer.objects
    out = []
    if asset is not None:
        if getattr(asset, "type", None) == "MESH":
            out.append(asset)
        if hasattr(asset, "children_recursive"):
            out += [o for o in asset.children_recursive if o.type == "MESH"]
    out = [o for o in out if o.name in vl]
    if not out:
        out = [o for o in vl if o.type == "MESH"]
    return out


def join_meshes(meshes):
    if not meshes:
        raise RuntimeError("no selectable mesh geometry after spawn")
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    return bpy.context.view_layer.objects.active


def _apply_collapse(obj, target_faces):
    cur = len(obj.data.polygons)
    if cur <= target_faces:
        return cur
    m = obj.modifiers.new("yume_decimate", "DECIMATE")
    m.decimate_type = "COLLAPSE"
    m.ratio = max(target_faces / cur, 1e-4)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=m.name)
    return len(obj.data.polygons)


def _voxel_remesh(obj):
    """Rebuild the mesh as ONE watertight surface — merges disconnected
    islands (cactus spines, foliage) that COLLAPSE decimate can't touch.
    Voxel size ~ height/96 keeps the silhouette; UVs are lost (export's
    bake re-unwraps). Drops shape keys/extra modifiers first so apply works."""
    obj.data.validate()
    if obj.data.shape_keys:
        obj.shape_key_clear()
    bpy.context.view_layer.objects.active = obj
    for m in list(obj.modifiers):
        if m.name != "_yume_remesh":
            try:
                bpy.ops.object.modifier_apply(modifier=m.name)
            except Exception:
                obj.modifiers.remove(m)
    height = max(obj.dimensions.z, 0.2)
    rm = obj.modifiers.new("_yume_remesh", "REMESH")
    rm.mode = "VOXEL"
    rm.voxel_size = height / 96.0
    bpy.ops.object.modifier_apply(modifier=rm.name)


def reduce_mesh(obj, target_faces, allow_remesh=True):
    """Robust reduce to a face budget across topologies. Stage 1: COLLAPSE
    (great for solid single-surface assets — boulder 916K->5K). Stage 2:
    if collapse couldn't reach budget (multi-island spiky meshes), voxel
    remesh into one surface, then collapse to exact.

    allow_remesh=False for FOLIAGE: voxel remesh fuses thin leaf cards into a
    blob (bare-branch tree), so foliage uses collapse-only at a higher budget
    to keep leaves — even if it can't hit the target exactly."""
    after = _apply_collapse(obj, target_faces)
    if after <= target_faces * 1.5 or not allow_remesh:
        return after
    _voxel_remesh(obj)
    return _apply_collapse(obj, target_faces)


def finalize_mesh(obj):
    """Clean degenerate geometry so the exporter doesn't warn 'Mesh ... is not
    valid' and the glb is tidy: merge doubles, recalc outward normals, validate.
    Empirical 2026-06-19: realized cacti exported with that warning."""
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    try:
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.mesh.remove_doubles(threshold=1e-4)  # merge by distance
        bpy.ops.mesh.normals_make_consistent(inside=False)
        bpy.ops.object.mode_set(mode="OBJECT")
    except Exception:
        if obj.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
    obj.data.validate(verbose=False)


# ============================================================
# Foliage billboard path (ADR 0074 — empirical 2026-06-20)
# ============================================================
# Infinigen leaves are ~14K faces EACH (film density, ~15M faces/tree) and
# SHATTER under decimation. Real-time fix (standard game technique): render
# ONE leaf cluster to an alpha IMPOSTOR card, then place a light crossed-quad
# billboard at each cluster instance transform. Keeps the real baked leaf look
# at game weight; output is a plain alpha-clipped glb the existing Yume mesh
# pipeline loads with NO engine change. realize=False keeps leaves as cheap
# instances (avoids the multi-GB realize that OOM'd a 7GB box).
# is_foliage lives in config.py (bpy-free, testable). Import it explicitly from
# THIS file's dir so Infinigen's sys.path can't shadow it with another `config`.
import sys as _sys  # noqa: E402
_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import is_foliage  # noqa: E402


def _green_fraction(png_path):
    """Fraction of opaque pixels that read as leaf-green (G channel dominant)."""
    img = bpy.data.images.load(str(png_path), check_existing=False)
    px = img.pixels[:]
    bpy.data.images.remove(img)
    green = cov = 0
    for i in range(0, len(px), 4):
        if px[i + 3] > 0.1:
            cov += 1
            r, g, b = px[i], px[i + 1], px[i + 2]
            if g > r * 1.04 and g > b * 1.04:
                green += 1
    return green / max(cov, 1)


def _find_leaf_cluster(dg, tmpdir):
    """Pick the GREENEST instanced cluster, not the biggest. Infinigen has
    several twig/branch variants (some leafy, some bark-dominant); face count
    and material names don't separate them, but a tiny render does. Renders
    each distinct source isolated (rest of tree hidden) and measures the
    leaf-green fraction. Returns (cluster_src, [transforms])."""
    cand = {}
    for inst in dg.object_instances:
        if inst.is_instance and inst.instance_object:
            key = inst.instance_object.name  # distinct variant
            cand.setdefault(key, {"src": inst.instance_object, "mats": []})["mats"].append(
                inst.matrix_world.copy())
    if not cand:
        return None, []
    existing = list(bpy.data.objects)
    best, best_g = None, -1.0
    import sys
    for i, c in enumerate(cand.values()):
        try:
            me = bpy.data.meshes.new_from_object(c["src"].evaluated_get(dg))
            probe = bpy.data.objects.new("probe", me)
            bpy.context.scene.collection.objects.link(probe)
            saved = {o: o.hide_render for o in existing}
            for o in existing:
                o.hide_render = True
            ppng = Path(tmpdir) / f"_probe{i}.png"
            _render_impostor(probe, ppng, res=96)
            for o, h in saved.items():
                o.hide_render = h
            gf = _green_fraction(ppng)
            try: ppng.unlink()
            except Exception: pass
            bpy.data.objects.remove(probe, do_unlink=True)
        except Exception:
            gf = -1.0
        sys.stderr.write(f"[leaf-pick] variant {i}: green={gf:.2f} ({len(c['mats'])} placements)\n")
        sys.stderr.flush()
        if gf > best_g:
            best_g, best = gf, c
    return best["src"], best["mats"]


def _render_impostor(cluster, out_png, res=512):
    """Render a centered cluster front-on to an RGBA alpha card. LIT render
    (not the albedo pass): Infinigen leaves are TRANSLUCENT — their green is in
    transmission, so an albedo pass under-captures leaves + over-captures bark.
    A strong EVEN world light lights AND backlights the leaves so they read
    green. Cycles/CPU for reliable headless (Eevee's GL fails in WSL)."""
    from mathutils import Vector
    scene = bpy.context.scene
    # drop any prior impostor light/camera so repeated calls don't accumulate
    for o in list(bpy.data.objects):
        if o.name.startswith(("yl", "yc")):
            bpy.data.objects.remove(o, do_unlink=True)
    cluster.location = -Vector(cluster.bound_box[0]) - cluster.dimensions / 2
    bpy.context.view_layer.update()
    dim = cluster.dimensions
    # Eevee: its approximate translucency makes the thin leaves GLOW + visually
    # dominate the woody twigs (Cycles renders the opaque bark realistically
    # dominant → barky card). Run under LIBGL_ALWAYS_SOFTWARE=1 so Eevee's GL
    # backend is the reliable llvmpipe software path (ZINK GPU fails in WSL).
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.eevee.taa_render_samples = 32
    scene.render.film_transparent = True
    scene.render.resolution_x = scene.render.resolution_y = res
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.use_nodes = False
    # bright EVEN world fill so the card holds a bright, evenly-lit leaf albedo
    # (sun-only leaves the shadow side dark → dim cards). Yume shades it.
    world = bpy.data.worlds.new("yw"); world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (1, 1, 1, 1); bg.inputs[1].default_value = 1.3
    scene.world = world
    sd = bpy.data.lights.new("yl", "SUN"); sd.energy = 3.0  # key light keeps green saturated
    sun = bpy.data.objects.new("yl", sd); scene.collection.objects.link(sun)
    sun.rotation_euler = (0.9, 0.0, 0.2)  # front-top, lights camera-facing leaves
    cd = bpy.data.cameras.new("yc"); cd.type = "ORTHO"
    cd.ortho_scale = max(dim.x, dim.z) * 1.1
    cam = bpy.data.objects.new("yc", cd); scene.collection.objects.link(cam)
    c = cluster.matrix_world.translation
    cam.location = (c.x, c.y - max(dim.y, 5) - 2, c.z)
    cam.rotation_euler = (1.5708, 0, 0)
    scene.camera = cam
    scene.render.filepath = str(out_png)
    bpy.ops.render.render(write_still=True)
    return max(dim.x, dim.z) * 1.1


def _build_cards(transforms, impostor_png, card_w, max_cards=400):
    """Crossed-quad billboards at the cluster transforms, one shared
    alpha-clipped impostor material."""
    import bmesh
    from mathutils import Vector, Matrix
    step = max(1, len(transforms) // max_cards)
    transforms = transforms[::step]
    sz = card_w * 0.5
    bm = bmesh.new(); uvl = bm.loops.layers.uv.new("UVMap")
    quads = [[(-sz, 0, 0), (sz, 0, 0), (sz, 0, 2*sz), (-sz, 0, 2*sz)],
             [(0, -sz, 0), (0, sz, 0), (0, sz, 2*sz), (0, -sz, 2*sz)]]
    uvs = [(0, 0), (1, 0), (1, 1), (0, 1)]
    for M in transforms:
        place = Matrix.Translation(M.translation) @ M.to_3x3().normalized().to_4x4()
        for q in quads:
            f = bm.faces.new([bm.verts.new(place @ Vector(p)) for p in q])
            for loop, uv in zip(f.loops, uvs):
                loop[uvl].uv = uv
    me = bpy.data.meshes.new("cards"); bm.to_mesh(me); bm.free()
    cards = bpy.data.objects.new("cards", me)
    bpy.context.scene.collection.objects.link(cards)
    mat = bpy.data.materials.new("leafcard"); mat.use_nodes = True
    mat.blend_method = "CLIP"; mat.alpha_threshold = 0.5; mat.use_backface_culling = False
    nt = mat.node_tree; bsdf = nt.nodes.get("Principled BSDF")
    img = nt.nodes.new("ShaderNodeTexImage"); img.image = bpy.data.images.load(str(impostor_png))
    nt.links.new(img.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(img.outputs["Alpha"], bsdf.inputs["Alpha"])
    # Base emission from the leaf texture: vertical leaf billboards catch little
    # light from an overhead sun and render near-black. A modest self-emission
    # (standard real-time foliage technique) keeps them readable at any angle
    # without washing them out at distance. Empirical 2026-06-20.
    if "Emission Color" in bsdf.inputs:               # Blender 4.x
        nt.links.new(img.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = 0.35
    elif "Emission" in bsdf.inputs:                   # older Blender
        nt.links.new(img.outputs["Color"], bsdf.inputs["Emission"])
    me.materials.append(mat)
    return cards, len(transforms)


def build_foliage(cls, factory, seed, out_path, faces, texres, lod_dist=12.0):
    """Foliage → trunk (decimated) + leaf-cluster impostor billboards → glb."""
    import json as _json
    from mathutils import Vector
    out = Path(out_path); out.parent.mkdir(parents=True, exist_ok=True)

    butil.clear_scene()
    # season='summer' → vivid-green leaves (default randomizes, often a washed
    # autumn that the impostor bake then desaturates further). Empirical 2026-06-20.
    fac = construct(cls, seed, realize=False, season="summer")
    fac.spawn_asset(seed, distance=float(lod_dist or 12.0))
    dg = bpy.context.evaluated_depsgraph_get()

    cluster_src, transforms = _find_leaf_cluster(dg, out.parent)
    if cluster_src is None or not transforms:
        raise RuntimeError("no leaf-cluster instances found for foliage")

    me = bpy.data.meshes.new_from_object(cluster_src.evaluated_get(dg))
    cluster = bpy.data.objects.new("cluster", me)
    bpy.context.scene.collection.objects.link(cluster)
    impostor_png = out.with_name(out.stem + "_leaf.png")
    card_w = _render_impostor(cluster, impostor_png, res=min(max(texres, 256) * 2, 512))
    bpy.data.objects.remove(cluster, do_unlink=True)

    real = [o for o in bpy.context.view_layer.objects if o is not None and o.type == "MESH"]
    trunk = join_meshes(real)
    if len(trunk.data.polygons) > 12000:
        _apply_collapse(trunk, 12000)
    trunk.name = "trunk"

    cards, ncards = _build_cards(transforms, impostor_png, card_w)

    for o in list(bpy.data.objects):
        if o not in (trunk, cards):
            try: bpy.data.objects.remove(o, do_unlink=True)
            except Exception: pass
    # real tree height (trunk + canopy) for state.scale
    zs, xs, ys = [], [], []
    for o in (trunk, cards):
        for cnr in o.bound_box:
            w = o.matrix_world @ Vector(cnr); xs.append(w.x); ys.append(w.y); zs.append(w.z)
    dims = [max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)]
    final = len(trunk.data.polygons) + len(cards.data.polygons)
    print(f"[YUME-INFINIGEN] {factory}#{seed} foliage: trunk={len(trunk.data.polygons)} "
          f"cards={ncards} faces={final}")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=str(out), export_format="GLB", use_selection=True)
    try: impostor_png.unlink()  # GLB embeds the texture; drop the temp PNG
    except Exception: pass
    out.with_suffix(".json").write_text(_json.dumps({
        "factory": factory, "seed": seed, "faces": final, "foliage": True,
        "height_m": dims[2], "footprint_m": [dims[0], dims[1]],
    }, indent=1))
    print(f"[YUME-INFINIGEN] wrote {out} ({out.stat().st_size} bytes) + sidecar")


def gen_one(cls, factory, seed, out_path, faces, texres, allow_remesh=True, lod_dist=None):
    """One asset, fresh scene → reduce → bake → GLB + sidecar. Assumes gin +
    blender are already configured (so a batch amortizes that one-time cost).

    Foliage (trees/bushes) → billboard path (build_foliage). Everything else →
    the solid decimate+bake path below. lod_dist: spawn_asset distance/LOD."""
    if is_foliage(factory):
        return build_foliage(cls, factory, seed, out_path, faces, texres, lod_dist or 12.0)

    import json as _json

    butil.clear_scene()
    fac = construct(cls, seed)
    if lod_dist is not None:
        asset = fac.spawn_asset(seed, distance=float(lod_dist))
    else:
        asset = fac.spawn_asset(seed)
    meshes = collect_meshes(asset)
    raw = sum(len(o.data.polygons) for o in meshes)
    obj = join_meshes(meshes)
    final = reduce_mesh(obj, faces, allow_remesh=allow_remesh)
    finalize_mesh(obj)
    dims = list(obj.dimensions)  # Blender XYZ (Z up); glTF maps Z->Y
    print(f"[YUME-INFINIGEN] {factory}#{seed}: {raw} -> {final} faces  dims={dims}")
    # Keep ONLY the final asset so the exporter bakes just our mesh.
    for o in list(bpy.data.objects):
        if o is not obj:
            try:
                bpy.data.objects.remove(o, do_unlink=True)
            except Exception:
                pass
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    export.export_curr_scene(out.parent / ("_bake_%d" % seed), format="obj", image_res=texres)
    bpy.ops.export_scene.gltf(filepath=str(out), export_format="GLB", use_selection=False)
    out.with_suffix(".json").write_text(_json.dumps({
        "factory": factory, "seed": seed, "faces": final,
        "height_m": dims[2], "footprint_m": [dims[0], dims[1]],
    }, indent=1))
    print(f"[YUME-INFINIGEN] wrote {out} ({out.stat().st_size} bytes) + sidecar")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--factory", required=True)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default=None, help="single-asset output .glb")
    ap.add_argument("--seeds", default=None, help="comma list → batch (with --out-dir)")
    ap.add_argument("--out-dir", default=None, help="batch output dir for <factory>_<seed>.glb")
    ap.add_argument("--faces", type=int, default=4000)
    ap.add_argument("--texres", type=int, default=512)
    ap.add_argument("--no-remesh", action="store_true",
                    help="foliage: collapse-only (voxel remesh blobs leaf cards)")
    ap.add_argument("--lod-dist", type=float, default=None,
                    help="spawn_asset distance/LOD — trees need a moderate value for leaves")
    args = init.parse_args_blender(ap)

    # One-time, amortized across all seeds in the batch.
    init.apply_gin_configs(
        ["infinigen_examples/configs_indoor", "infinigen_examples/configs_nature"],
        skip_unknown=True,
    )
    init.configure_blender()
    cls = resolve_or_die(args.factory)  # factory resolve walk happens ONCE
    allow_remesh = not args.no_remesh

    if args.seeds and args.out_dir:
        slug_base = args.factory.lower().replace("factory", "")
        for s in [int(x) for x in args.seeds.split(",") if x.strip() != ""]:
            out = Path(args.out_dir) / f"{slug_base}_{s}.glb"
            try:
                gen_one(cls, args.factory, s, out, args.faces, args.texres, allow_remesh, args.lod_dist)
            except Exception as e:
                print(f"[YUME-INFINIGEN] {args.factory}#{s} FAILED: {e}")
    else:
        gen_one(cls, args.factory, args.seed, args.out, args.faces, args.texres, allow_remesh, args.lod_dist)

    os._exit(0)  # bpy-as-module segfaults in atexit cleanup; work is done


if __name__ == "__main__":
    main()
