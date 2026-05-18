"""test_glb_merge.py — unit tests for tools.yume_assetgen.glb_merge.

Verifies the 4 unit-test requirements from ADR 0053:
  1. Skeleton-matched 2-GLB merge produces an output with both
     animations addressable by name.
  2. Skeleton-mismatched merge raises ValueError before writing
     any output file.
  3. Single-clip merge degenerates to a copy of the input.
  4. Animation-name collision auto-suffixes (default) or raises.

Note: we don't have a "skeleton-matched second retarget" test asset
on disk. Empirically Tripo retargets that share rig_task_id share
skeleton; here we simulate that by merging cube_anim.glb (2 animations
already baked-in) with itself. The skeleton-match check passes (same
file), and the resulting GLB has 2+2=4 animations with auto-suffixed
duplicate names.

Usage:
    python3 -m tools.yume_assetgen.tests.test_glb_merge
"""

import shutil
import struct
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))

from tools.yume_assetgen.glb_merge import merge  # noqa: E402


def _passed(label: str) -> None:
    print(f"  ✓ {label}")


def _failed(label: str, detail: str) -> None:
    print(f"  ✗ {label}\n      {detail}")


_PASS = 0
_FAIL = 0


def _check(cond: bool, label: str, detail: str = "") -> None:
    global _PASS, _FAIL
    if cond:
        _PASS += 1
        _passed(label)
    else:
        _FAIL += 1
        _failed(label, detail)


def _animations_of(glb_path: Path) -> list[str]:
    """Read GLB JSON chunk, return animation name list."""
    import json
    raw = glb_path.read_bytes()
    if raw[:4] != b"glTF":
        return []
    json_len = struct.unpack_from("<II", raw, 12)[0]
    doc = json.loads(raw[20 : 20 + json_len].decode("utf-8"))
    return [a.get("name", "") for a in doc.get("animations", [])]


def test_degenerate_single_input(tmp: Path, source: Path) -> None:
    print("\n[1] Single-clip merge = copy of input")
    out = tmp / "single.glb"
    merge([source], out)
    _check(out.exists(), "output written")
    _check(out.read_bytes() == source.read_bytes(), "byte-identical to input")
    _check(_animations_of(out) == _animations_of(source), "animations preserved")


def test_skeleton_match_self_merge(tmp: Path, source: Path) -> None:
    print("\n[2] Self-merge (skeleton-matched) appends animations with auto-suffix")
    out = tmp / "self_merged.glb"
    merge([source, source], out, on_name_collision="suffix")
    _check(out.exists(), "output written")
    src_anims = _animations_of(source)
    out_anims = _animations_of(out)
    _check(
        len(out_anims) == 2 * len(src_anims),
        "anim count doubled",
        f"src={len(src_anims)} out={len(out_anims)}",
    )
    # Source anims preserved at the front, duplicates suffixed
    _check(
        out_anims[: len(src_anims)] == src_anims,
        "original animations preserved by name",
        f"got {out_anims[:len(src_anims)]} vs {src_anims}",
    )
    suffixed = out_anims[len(src_anims):]
    expected_suffixed = [f"{n}_2" for n in src_anims]
    _check(
        suffixed == expected_suffixed,
        "duplicate animations suffixed _2",
        f"got {suffixed} expected {expected_suffixed}",
    )


def test_name_collision_raise(tmp: Path, source: Path) -> None:
    print("\n[3] on_name_collision='raise' raises on duplicate names")
    out = tmp / "should_not_exist.glb"
    try:
        merge([source, source], out, on_name_collision="raise")
        _check(False, "merge raised ValueError", "no exception raised")
    except ValueError as e:
        _check("collision" in str(e), "ValueError mentions collision", str(e))
        _check(not out.exists(), "output not written on raise", str(out))


def test_skeleton_mismatch_raises(tmp: Path, source: Path) -> None:
    """Build a fake skeleton-mismatched GLB by editing the cube_anim's
    skin joint names. If pygltflib can write a modified copy, merge
    should reject it."""
    print("\n[4] Skeleton-mismatch raises ValueError")
    try:
        import pygltflib
    except ImportError:
        print("  ⚠ skipped (pygltflib not installed)")
        return
    # Load + perturb joint names in a copy
    g = pygltflib.GLTF2().load(str(source))
    if not g.skins or not g.skins[0].joints:
        print("  ⚠ skipped (source GLB has no skinned skeleton)")
        return
    # Rename the first joint's underlying node so the skeleton fingerprint differs
    joint_idx = g.skins[0].joints[0]
    g.nodes[joint_idx].name = "PERTURBED_JOINT_FOR_TEST"
    mismatch_path = tmp / "mismatch.glb"
    g.save_binary(str(mismatch_path))

    out = tmp / "should_not_exist_2.glb"
    try:
        merge([source, mismatch_path], out)
        _check(False, "merge raised ValueError", "no exception raised")
    except ValueError as e:
        _check("skeleton mismatch" in str(e), "error mentions skeleton mismatch", str(e))
        _check(not out.exists(), "output not written on mismatch", str(out))


def main() -> int:
    source = REPO_ROOT / "godot" / "data" / "test_assets" / "cube_anim.glb"
    if not source.exists():
        print(f"ERROR: test asset not found: {source}")
        return 2

    tmp = Path(tempfile.mkdtemp(prefix="glb_merge_test_"))
    try:
        test_degenerate_single_input(tmp, source)
        test_skeleton_match_self_merge(tmp, source)
        test_name_collision_raise(tmp, source)
        test_skeleton_mismatch_raises(tmp, source)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    total = _PASS + _FAIL
    print(f"\npassed: {_PASS}  failed: {_FAIL}  total: {total}")
    return 0 if _FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
