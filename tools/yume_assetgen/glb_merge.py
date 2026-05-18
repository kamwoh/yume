"""glb_merge.py — combine N retarget GLBs (one clip each) into one
multi-clip GLB, per ADR 0053.

Tripo3D's animate_retarget task emits a separate GLB for each clip
even though all clips share the same skeleton (because all retargets
chain off the same animate_rig task). Yume's engine expects one mesh
per entity, so we merge the per-clip GLBs into one.

The merge:
  1. Loads N GLBs via pygltflib.
  2. Verifies all share the same skeleton (joint indices, names).
     Raises ValueError on mismatch — by ADR invariant, retargets that
     reuse the same rig_task_id MUST produce skeleton-identical GLBs.
  3. Uses GLB 0's mesh + skin + skeleton as base.
  4. Imports each subsequent GLB's `animations` array into base,
     remapping buffer/accessor references.
  5. Writes the merged GLB to out_path.

Output: ONE GLB with len(inputs) animation clips, all addressable by
name through Godot's GLTF importer (which builds an AnimationLibrary
per the GLB's animation list).
"""

from __future__ import annotations

import argparse
import copy
import sys
from pathlib import Path
from typing import Sequence

try:
    import pygltflib
except ImportError as e:
    raise ImportError(
        "glb_merge requires pygltflib. Install with: pip install pygltflib"
    ) from e


def _joint_names(glb: pygltflib.GLTF2) -> list[str]:
    """Extract joint node names from the first skin. Used as a stable
    skeleton fingerprint for the mismatch check."""
    if not glb.skins:
        return []
    skin = glb.skins[0]
    joints = list(skin.joints or [])
    names = []
    for j in joints:
        if 0 <= j < len(glb.nodes):
            names.append(glb.nodes[j].name or f"node_{j}")
        else:
            names.append(f"missing_{j}")
    return names


def _assert_skeletons_match(glbs: list[pygltflib.GLTF2]) -> None:
    if len(glbs) <= 1:
        return
    base = _joint_names(glbs[0])
    for i, g in enumerate(glbs[1:], start=1):
        other = _joint_names(g)
        if other != base:
            raise ValueError(
                f"glb_merge: skeleton mismatch between GLB 0 and GLB {i}.\n"
                f"  GLB 0 joints ({len(base)}): {base[:5]}...\n"
                f"  GLB {i} joints ({len(other)}): {other[:5]}...\n"
                f"All inputs must be retargets of the SAME rig_task_id."
            )


def _animation_names(glb: pygltflib.GLTF2) -> list[str]:
    return [a.name or "" for a in (glb.animations or [])]


def merge(
    inputs: Sequence[Path],
    out_path: Path,
    on_name_collision: str = "suffix",
    rename_animations: Sequence[str] | None = None,
) -> Path:
    """Merge N GLBs (one animation clip each) into one multi-clip GLB.

    Args:
        inputs: sequence of input GLB paths. inputs[0] supplies the
            mesh + skin + skeleton. All inputs must share the same
            skeleton.
        out_path: destination .glb path. Parent dir is created.
        on_name_collision: behavior when two inputs both have an
            animation named e.g. "Walking":
              "suffix" → append "_<i>" to the duplicate (default)
              "raise" → raise ValueError
        rename_animations: optional parallel list to `inputs`. If
            provided, each input's FIRST animation is renamed to the
            matching string (e.g. ["idle", "walk"]). Useful when
            Tripo/Blender export gives clips junk names like
            "NlaTrack" / "Action.001" — engine-side state names need
            to be stable + author-controlled.

    Returns: out_path.
    """
    if not inputs:
        raise ValueError("glb_merge: empty inputs")
    if len(inputs) == 1:
        # Degenerate case: just copy.
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(Path(inputs[0]).read_bytes())
        return out_path

    glbs = [pygltflib.GLTF2().load(str(p)) for p in inputs]
    _assert_skeletons_match(glbs)

    # Apply rename_animations BEFORE merge so collision-detection sees
    # the new names. Each input's FIRST animation is renamed in-memory
    # (we don't write back to disk).
    if rename_animations is not None:
        if len(rename_animations) != len(glbs):
            raise ValueError(
                f"rename_animations length {len(rename_animations)} != "
                f"inputs length {len(glbs)}"
            )
        for g, new_name in zip(glbs, rename_animations):
            if new_name and g.animations:
                g.animations[0].name = new_name

    base = glbs[0]
    # Deep-copy so we don't mutate the on-disk base when merging.
    merged = copy.deepcopy(base)

    # Track current sizes so we can offset accessor / buffer-view refs
    # from each appended GLB into merged's index space.
    n_accessors = len(merged.accessors or [])
    n_buffer_views = len(merged.bufferViews or [])
    n_buffers = len(merged.buffers or [])
    # Animation channels reference node indices for the target. Across
    # retargets of the SAME rig, joint node indices are stable — so we
    # do NOT need to remap channel.target.node.
    seen_names = set(_animation_names(merged))

    # We need to keep BIN payload bytes contiguous. pygltflib serializes
    # one GLB with one BIN chunk; we concatenate input BINs in order.
    base_bin = base.binary_blob() or b""
    merged._glb_data = base_bin  # internal pygltflib field for save_to_bytes
    base_buffer_byte_lengths = [b.byteLength for b in (merged.buffers or [])]

    for i, g in enumerate(glbs[1:], start=1):
        g_bin = g.binary_blob() or b""
        offset_into_merged_bin = len(base_bin)

        # 1) Append buffers (and remember their old→new index)
        buf_map: dict[int, int] = {}
        for j, b in enumerate(g.buffers or []):
            new_b = copy.deepcopy(b)
            # uri may be None for the embedded GLB buffer
            buf_map[j] = len(merged.buffers)
            merged.buffers.append(new_b)

        # 2) Append bufferViews with remapped buffer index + offset
        view_map: dict[int, int] = {}
        for j, bv in enumerate(g.bufferViews or []):
            new_bv = copy.deepcopy(bv)
            new_bv.buffer = buf_map[bv.buffer]
            # If this bufferView pointed into the embedded GLB buffer
            # (buffer index 0 in the source), its offset must be shifted
            # to account for prior input BINs. For non-embedded buffers
            # (those with their own uri), no shift needed.
            if bv.buffer == 0 and not (g.buffers[bv.buffer].uri):
                new_bv.byteOffset = (new_bv.byteOffset or 0) + offset_into_merged_bin
            view_map[j] = len(merged.bufferViews)
            merged.bufferViews.append(new_bv)

        # 3) Append accessors with remapped bufferView index
        acc_map: dict[int, int] = {}
        for j, acc in enumerate(g.accessors or []):
            new_acc = copy.deepcopy(acc)
            if new_acc.bufferView is not None:
                new_acc.bufferView = view_map[new_acc.bufferView]
            acc_map[j] = len(merged.accessors)
            merged.accessors.append(new_acc)

        # 4) Append animations with remapped accessor + sampler refs.
        # Animation.target.node is left unchanged because we asserted
        # the skeleton is identical across inputs.
        for anim in g.animations or []:
            new_anim = copy.deepcopy(anim)
            for sampler in new_anim.samplers:
                if sampler.input is not None:
                    sampler.input = acc_map[sampler.input]
                if sampler.output is not None:
                    sampler.output = acc_map[sampler.output]
            # Channel target.node refs are joint indices, stable across
            # same-rig retargets → no remap.
            # Handle name collision
            n = new_anim.name or ""
            if n in seen_names:
                if on_name_collision == "raise":
                    raise ValueError(
                        f"glb_merge: animation name collision: {n!r}"
                    )
                # auto-suffix
                base_n = n or "anim"
                k = 2
                while f"{base_n}_{k}" in seen_names:
                    k += 1
                new_anim.name = f"{base_n}_{k}"
            seen_names.add(new_anim.name or "")
            merged.animations.append(new_anim)

        # 5) Concatenate input BIN onto merged BIN
        base_bin = base_bin + g_bin
        merged._glb_data = base_bin

    # Reset embedded buffer[0]'s byteLength to match the concatenated BIN.
    if merged.buffers:
        merged.buffers[0].byteLength = len(base_bin)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    merged.save_binary(str(out_path))
    return out_path


# ============================================================
# CLI
# ============================================================


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Merge N retarget GLBs into one multi-clip GLB")
    ap.add_argument("inputs", nargs="+", type=Path, help="Input .glb files (one per clip)")
    ap.add_argument("-o", "--out", required=True, type=Path, help="Output merged .glb")
    ap.add_argument(
        "--on-collision",
        choices=("suffix", "raise"),
        default="suffix",
        help="Behavior when two inputs share an animation name",
    )
    args = ap.parse_args(argv)

    try:
        out = merge(args.inputs, args.out, on_name_collision=args.on_collision)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    print(f"[glb_merge] wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
