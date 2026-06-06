#!/usr/bin/env python3
"""
Visual test plan runner (ADR 0056 Phase A).

Reads a visual_test_plan.json, executes each test by:
  1. Resolving the test's entities to world coordinates
     (from the level's entities.json)
  2. Computing the camera pose from the assertion's framing.rule
     (using Step 0a/0b math from .claude/rules/visual-qa.md)
  3. Driving Godot once per test: temporarily writes a free_camera
     entity at the computed pose, captures via --capture-input=
     'toggle_freecam,0.3' + --capture-after, then restores.
  4. Rendering the assertion's prompt_template with resolved labels
     and positions.
  5. Writing visual_test_report.md with per-test PNG paths + prompts
     + verdict slots (PASS/FAIL — filled in by the verdict step,
     either human or LLM in a follow-up pass).

Usage:
    python3 tools/visual_qa/run_plan.py <plan.json>
    python3 tools/visual_qa/run_plan.py <plan.json> --dry-run
    python3 tools/visual_qa/run_plan.py <plan.json> --only test_id_1,test_id_2

Exit code:
    0 — plan ran end-to-end (verdicts not yet checked)
    1 — error in plan parsing / entity resolution / capture failure
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
GODOT_DATA = REPO_ROOT / "godot" / "data"
ASSERTIONS_DIR = GODOT_DATA / "lib" / "visual_qa" / "assertions"

TEMPLATE_DST = Path(
    os.environ.get(
        "YUME_TEMPLATE_DST",
        "/mnt/c/Users/kamwoh/Documents/Projects/Godot/YumeTemplate",
    )
)
GODOT_BIN = os.environ.get(
    "YUME_GODOT_BIN",
    "/mnt/c/Users/kamwoh/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64.exe",
)
CAPTURE_USER_DIR = Path(
    os.environ.get(
        "YUME_USERDATA",
        "/mnt/c/Users/kamwoh/AppData/Roaming/Godot/app_userdata/Yume Framework",
    )
)


# Framing rules from .claude/rules/visual-qa.md Step 0b.
# Each rule produces an (offset_x, offset_z, height, pitch) tuple
# relative to a target world position. yaw is computed to look-at
# the target at runtime.
FRAMING_RULES: dict[str, dict[str, Any]] = {
    # Distances tuned so that a human-scale subject (~1.8m tall) at the
    # target occupies ~30-50% of frame height at 75° FOV. Empirical
    # 2026-05-22: prior distances (6-10m) put subjects at ~10% of frame
    # — too small to read for any visual assertion.
    "side_profile": {
        # Eye-level wide for relative_size — both subjects at similar dist
        "height": 1.8,
        "pitch": -0.05,
        "distance": 4.0,
        "approach": "lateral",  # offset perpendicular to A→B axis
        "_subject_spread_factor": 1.5,  # extra distance per meter of subject spread
    },
    "low_angle_oblique": {
        # For no_clipping — frame the interface zone
        "height": 0.8,
        "pitch": 0.05,  # slightly upward
        "distance": 2.5,
        "approach": "radial",
    },
    "top_down_overhead": {
        # For rotation_facing — top-down disambiguates facing
        "height": 12.0,
        "pitch": -1.45,
        "distance": 0.0,  # directly above midpoint
        "approach": "above",
    },
    "low_angle_profile": {
        # For no_floating, pivot_at_foot — base against horizon, CLOSE
        "height": 0.5,
        "pitch": 0.0,
        "distance": 2.5,
        "approach": "radial",
    },
    "eye_level_wide": {
        # For distinct_silhouettes — both subjects readable at glance
        "height": 1.7,
        "pitch": -0.05,
        "distance": 4.5,
        "approach": "lateral",
        "_subject_spread_factor": 1.0,
    },
    "wide_corner": {
        # For no_orphan_cubes — corner vantage, wide capture
        "height": 35.0,
        "pitch": -0.5,
        "distance": 50.0,
        "approach": "corner",
    },
    "oblique_toward_sun": {
        # For specular_response — sun behind/above camera
        "height": 3.0,
        "pitch": -0.35,
        "distance": 5.0,
        "approach": "sun_relative",
    },
}


@dataclass
class ResolvedEntity:
    instance_id: str
    def_id: str
    label: str
    position: list[float]
    yaw: float = 0.0


@dataclass
class TestRun:
    test_id: str
    assertion_id: str
    params: dict[str, Any]
    entities: list[ResolvedEntity]
    camera_pos: list[float]
    camera_yaw: float
    camera_pitch: float
    capture_path: Path
    rendered_prompt: str


def load_assertion(assertion_id: str) -> dict[str, Any]:
    """Read an assertion definition from the library."""
    path = ASSERTIONS_DIR / f"{assertion_id}.json"
    if not path.is_file():
        raise FileNotFoundError(f"unknown assertion: {assertion_id} (looked at {path})")
    with open(path) as f:
        return json.load(f)


def load_level_entities(game: str, level: str) -> dict[str, Any]:
    """Load the level's entities.json (the initial_instances list)."""
    path = GODOT_DATA / game / "levels" / level / "entities.json"
    if not path.is_file():
        raise FileNotFoundError(f"level entities.json not found: {path}")
    with open(path) as f:
        return json.load(f)


def resolve_entity(game: str, level: str, entity_ref: str) -> ResolvedEntity:
    """Resolve an entity_id (or def_id fallback) to its world position.

    Tries: 1) exact match on initial_instances[].id 2) first instance
    where def_id matches 3) raises if neither.
    """
    level_data = load_level_entities(game, level)
    instances = level_data.get("initial_instances", [])

    for inst in instances:
        if inst.get("id") == entity_ref:
            return _make_resolved(inst)

    for inst in instances:
        if inst.get("def") == entity_ref:
            return _make_resolved(inst)

    raise ValueError(
        f"entity '{entity_ref}' not found in {game}/{level}/entities.json "
        f"(checked {len(instances)} initial_instances)"
    )


def _make_resolved(inst: dict[str, Any]) -> ResolvedEntity:
    pos = inst.get("position", [0, 0, 0])
    state = inst.get("state", {})
    yaw = float(state.get("facing", state.get("yaw", 0.0)))
    return ResolvedEntity(
        instance_id=str(inst.get("id", "?")),
        def_id=str(inst.get("def", "?")),
        label=str(inst.get("id", inst.get("def", "?"))),
        position=[float(p) for p in pos],
        yaw=yaw,
    )


def count_nearby_occluders(
    cam_x: float, cam_z: float,
    target_x: float, target_z: float,
    all_instances: list[dict[str, Any]],
    occluder_tags: set[str] = frozenset({"tree", "blocks_motion", "structure", "world_prop"}),
    near_radius: float = 2.5,
    line_radius: float = 1.5,
    def_tags_map: dict[str, set[str]] | None = None,
) -> int:
    """Count entities near the camera position OR along the camera→target
    sight line. Used as a proxy for "is the camera inside / occluded by
    a cluster?" — no Godot raycast needed.

    Returns the count of potential occluders. Camera placements with
    count > some threshold should try alternatives (flip perpendicular,
    shorten distance, etc.).

    `occluder_tags` filters to entities that actually block the view —
    trees, structures, walls. Ignores ground decals, items, characters
    (which are usually the subjects we're framing).

    `def_tags_map` maps def_id → tag set. If provided, the function
    filters by def tags. If None, falls back to "any entity within
    radius counts." (Less accurate but works with no extra inputs.)
    """
    if not all_instances:
        return 0
    count = 0
    dx_seg = target_x - cam_x
    dz_seg = target_z - cam_z
    seg_len_sq = dx_seg * dx_seg + dz_seg * dz_seg
    for inst in all_instances:
        pos = inst.get("position", [0, 0, 0])
        if len(pos) < 3:
            continue
        ix, iz = float(pos[0]), float(pos[2])
        # Tag filter
        if def_tags_map is not None:
            def_id = inst.get("def", "")
            tags = def_tags_map.get(def_id, set())
            if not (tags & occluder_tags):
                continue
        # 1) Inside the near-camera bubble?
        dx_c, dz_c = ix - cam_x, iz - cam_z
        if dx_c * dx_c + dz_c * dz_c <= near_radius * near_radius:
            count += 1
            continue
        # 2) Close to the camera→target segment?
        if seg_len_sq < 0.001:
            continue
        t = ((ix - cam_x) * dx_seg + (iz - cam_z) * dz_seg) / seg_len_sq
        if t <= 0.0 or t >= 1.0:
            continue
        # Distance from point to segment
        perp_x = (cam_x + t * dx_seg) - ix
        perp_z = (cam_z + t * dz_seg) - iz
        if perp_x * perp_x + perp_z * perp_z <= line_radius * line_radius:
            count += 1
    return count


def load_def_tags_map(game: str) -> dict[str, set[str]]:
    """Walk all entity def files, return {def_id: {tags}}."""
    out: dict[str, set[str]] = {}
    defs_dir = GODOT_DATA / game / "entities"
    if not defs_dir.is_dir():
        return out
    for fp in defs_dir.glob("*.json"):
        try:
            d = json.loads(fp.read_text())
        except json.JSONDecodeError:
            continue
        for ed in d.get("definitions", []):
            if "id" in ed:
                out[ed["id"]] = set(ed.get("tags", []))
    return out


def compute_camera_pose(
    rule: str,
    entities: list[ResolvedEntity],
    extra: dict[str, Any] | None = None,
    all_instances: list[dict[str, Any]] | None = None,
    def_tags_map: dict[str, set[str]] | None = None,
) -> tuple[list[float], float, float]:
    """Apply the framing rule to derive (camera_pos, yaw, pitch).

    yaw is computed to look-at the target. If `all_instances` is
    provided, runs an occlusion check after the algebraic placement
    and tries alternatives (flip perpendicular, shorten distance) if
    the candidate camera position sits inside or near a cluster of
    occluding entities (trees, structures, walls).
    """
    if rule not in FRAMING_RULES:
        raise ValueError(f"unknown framing rule: {rule}")
    f = FRAMING_RULES[rule]
    extra = extra or {}

    # Target = midpoint of all involved entities (or single entity)
    n = len(entities)
    if n == 0:
        # Sanity-sweep fallback — assume level center
        target = [0.0, 0.0, 0.0]
    else:
        target = [
            sum(e.position[i] for e in entities) / n
            for i in range(3)
        ]

    approach = f["approach"]
    dist = float(f["distance"])
    height = float(f["height"])
    pitch = float(f["pitch"])

    def place(approach_dist: float, lateral_sign: float = 1.0) -> tuple[float, float]:
        """Compute (cam_x, cam_z) for the given distance + sign flip."""
        if approach == "above":
            return target[0], target[2]
        if approach == "corner":
            shot = extra.get("shot", "wide_NE")
            sx = 1.0 if "E" in shot else -1.0
            sz = -1.0 if "N" in shot else 1.0
            return target[0] + sx * approach_dist, target[2] + sz * approach_dist
        if approach == "lateral":
            if n >= 2:
                ax, az = entities[0].position[0], entities[0].position[2]
                bx, bz = entities[1].position[0], entities[1].position[2]
                dx, dz = bx - ax, bz - az
                length = max(0.001, math.hypot(dx, dz))
                spread_factor = float(f.get("_subject_spread_factor", 1.0))
                adj_dist = approach_dist + length * spread_factor
                px, pz = -dz / length * lateral_sign, dx / length * lateral_sign
                return target[0] + px * adj_dist, target[2] + pz * adj_dist
            return target[0] + approach_dist * lateral_sign, target[2]
        if approach == "radial":
            return target[0], target[2] + approach_dist * lateral_sign
        if approach == "sun_relative":
            return target[0] + approach_dist * 0.7, target[2] + approach_dist * 0.7
        return target[0], target[2] + approach_dist

    # Try candidates in order, pick the least-occluded
    # 1) primary placement
    # 2) flipped lateral / radial direction
    # 3) shortened distance (70%)
    # 4) shortened + flipped
    OCCLUDER_THRESHOLD = 2  # candidate is "blocked" if 2+ occluders nearby
    subject_ids = {e.instance_id for e in entities}
    # Filter occluders to skip the subject entities (they're not blocking themselves)
    occluder_pool: list[dict[str, Any]] = []
    if all_instances is not None:
        for inst in all_instances:
            if inst.get("id") in subject_ids:
                continue
            occluder_pool.append(inst)

    candidates = [
        (dist, 1.0),
        (dist, -1.0),
        (dist * 0.7, 1.0),
        (dist * 0.7, -1.0),
    ]
    best: tuple[float, float, int] | None = None
    for d_try, sign_try in candidates:
        cx, cz = place(d_try, sign_try)
        if all_instances is not None and def_tags_map is not None:
            occ = count_nearby_occluders(
                cx, cz, target[0], target[2],
                occluder_pool, def_tags_map=def_tags_map,
            )
        else:
            occ = 0
        if best is None or occ < best[2]:
            best = (cx, cz, occ)
        if occ < OCCLUDER_THRESHOLD:
            break  # good enough

    assert best is not None
    cam_x, cam_z, _ = best

    # Yaw: look-at target. Engine fwd vector (camera_director.gd):
    #   fwd = (-sin(yaw)*cos(pitch), sin(pitch), -cos(yaw)*cos(pitch))
    yaw = math.atan2(cam_x - target[0], cam_z - target[2])

    return [cam_x, height, cam_z], yaw, pitch


def render_prompt(template: str, ctx: dict[str, Any]) -> str:
    """Best-effort {placeholder} substitution. Missing keys → '?' string."""
    class _D(dict):
        def __missing__(self, k):
            return "?"
    return template.format_map(_D(**ctx))


def write_test_camera(game: str, level: str, cam_pos: list[float], yaw: float, pitch: float) -> str:
    """Author a single free_camera entity 'camera_visual_qa_test' in the
    level's entities.json. Returns the active_camera_id to set on
    world_clock. Caller must restore."""
    path = GODOT_DATA / game / "levels" / level / "entities.json"
    with open(path) as f:
        d = json.load(f)
    d["initial_instances"] = [
        i for i in d["initial_instances"] if i.get("id") != "camera_visual_qa_test"
    ]
    d["initial_instances"].append({
        "_comment": "TRANSIENT visual-qa test camera (tools/visual_qa/run_plan.py). Auto-removed after the test run.",
        "def": "free_camera",
        "id": "camera_visual_qa_test",
        "position": list(cam_pos),
        "state": {
            "position": list(cam_pos),
            "yaw": float(yaw),
            "pitch": float(pitch),
        },
    })
    with open(path, "w") as f:
        f.write(json.dumps(d, indent=2) + "\n")
    return "camera_visual_qa_test"


def restore_camera_state(game: str, level: str, original_active: str) -> None:
    """Remove the test camera + restore world_clock active_camera_id."""
    path = GODOT_DATA / game / "levels" / level / "entities.json"
    with open(path) as f:
        d = json.load(f)
    d["initial_instances"] = [
        i for i in d["initial_instances"] if i.get("id") != "camera_visual_qa_test"
    ]
    with open(path, "w") as f:
        f.write(json.dumps(d, indent=2) + "\n")
    wc_path = GODOT_DATA / game / "entities" / "world_clock.json"
    with open(wc_path) as f:
        wd = json.load(f)
    wd["definitions"][0]["state_init"]["active_camera_id"] = original_active
    with open(wc_path, "w") as f:
        f.write(json.dumps(wd, indent=2) + "\n")


def set_active_camera(game: str, camera_id: str) -> str:
    """Set world_clock.active_camera_id; return the prior value."""
    path = GODOT_DATA / game / "entities" / "world_clock.json"
    with open(path) as f:
        d = json.load(f)
    state_init = d["definitions"][0]["state_init"]
    prior = state_init.get("active_camera_id", "camera_a")
    state_init["active_camera_id"] = camera_id
    with open(path, "w") as f:
        f.write(json.dumps(d, indent=2) + "\n")
    return prior


def sync_to_template() -> None:
    """Sync godot/. → YumeTemplate. Uses `cp -r` rather than shutil
    because shutil.rmtree + copytree races against WSL's mount cache —
    rmtree returns before the FS actually frees the dir, then copytree
    sees the still-existing target. cp -r overlays cleanly."""
    src = REPO_ROOT / "godot"
    if not TEMPLATE_DST.is_dir():
        raise FileNotFoundError(f"YumeTemplate not at {TEMPLATE_DST}")
    proc = subprocess.run(
        ["cp", "-r", f"{src}/.", f"{TEMPLATE_DST}/"],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"sync_to_template cp -r failed: {proc.stderr}")


def reimport_godot() -> None:
    """Run `godot --headless --import` to refresh asset/shader cache.
    Required after shader/PNG/.glb changes — Godot's ResourceLoader uses
    cached metadata and serves null/stale resources otherwise, making
    captures meaningless. Empirical: 2026-05-22 first visual_qa run had
    cubes-everywhere baseline because shader edits from prior tasks
    invalidated the cache and Godot served default fallbacks. See
    [[feedback-always-import-after-new-assets]].

    Also clears stale `valid=false` .import sidecars before re-import.
    Once Godot fails to import a resource (sync race, partial Tripo3D
    write, etc.), the sidecar gets `valid=false` and Godot WILL NOT
    retry on subsequent --import calls without intervention. Each
    visual_qa pass would then silently render every affected entity
    as a tier-3 fallback cube. Empirical 2026-05-23: 10 meshes hit
    this state in aldenmere; cleanup fixed all of them."""
    # Phase 1: nuke stale `valid=false` import sidecars so the next
    # --import retries them
    n_cleaned = 0
    for ext in (".glb.import", ".png.import", ".jpg.import"):
        for fp in TEMPLATE_DST.rglob(f"*{ext}"):
            try:
                if "valid=false" in fp.read_text():
                    fp.unlink()
                    n_cleaned += 1
            except (OSError, UnicodeDecodeError):
                pass
    if n_cleaned > 0:
        print(f"[run_plan] cleared {n_cleaned} stale valid=false .import sidecar(s)")
    # Phase 2: re-import
    cmd = [GODOT_BIN, "--path", ".", "--headless", "--import"]
    proc = subprocess.run(cmd, cwd=TEMPLATE_DST, capture_output=True, text=True, timeout=360)
    if proc.returncode != 0:
        print(f"[run_plan] --import exit={proc.returncode}", file=sys.stderr)
        print(proc.stderr[-500:], file=sys.stderr)


def capture_once(
    game: str,
    capture_filename: str,
    settle: float = 2.0,
) -> Path:
    """Drive Godot once, return the resulting PNG path."""
    output_url = f"user://{capture_filename}"
    cmd = [
        GODOT_BIN,
        "--path", ".",
        "--rendering-driver", "opengl3",
        "scenes/aldenmere_3d.tscn",  # TODO: per-game scene resolution
        "--",
        f"--game={game}",
        f"--capture-after={settle}",
        f"--capture-input=toggle_freecam,0.3",
        f"--capture-output={output_url}",
    ]
    proc = subprocess.run(
        cmd,
        cwd=TEMPLATE_DST,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if proc.returncode != 0:
        print(f"[run_plan] godot exit={proc.returncode}", file=sys.stderr)
        print(proc.stdout[-2000:], file=sys.stderr)
        print(proc.stderr[-2000:], file=sys.stderr)
    return CAPTURE_USER_DIR / capture_filename


def run_test(game: str, level: str, test: dict[str, Any], idx: int,
             all_instances: list[dict[str, Any]] | None = None,
             def_tags_map: dict[str, set[str]] | None = None) -> TestRun:
    """Execute one test: resolve entities, compute pose, sync, capture."""
    test_id = test["id"]
    assertion_id = test["assertion"]
    params = test.get("params", {})
    assertion = load_assertion(assertion_id)

    # Resolve entity references in params
    entities: list[ResolvedEntity] = []
    for k, v in params.items():
        if isinstance(v, str) and (k.startswith("entity") or k == "target"):
            try:
                entities.append(resolve_entity(game, level, v))
            except ValueError as e:
                # Some assertions reference biomes or shots — skip resolution
                print(f"[run_plan] {test_id}: skipping resolution for {k}={v} ({e})")

    # Camera pose (occlusion-aware if all_instances + def_tags_map provided)
    rule = assertion["framing"]["rule"]
    cam_pos, yaw, pitch = compute_camera_pose(
        rule, entities, extra=params,
        all_instances=all_instances, def_tags_map=def_tags_map,
    )

    # Write transient camera, set active, sync, capture, restore
    cam_id = write_test_camera(game, level, cam_pos, yaw, pitch)
    original_active = set_active_camera(game, cam_id)
    try:
        sync_to_template()
        capture_filename = f"_vqa_{idx:02d}_{test_id}.png"
        png_path = capture_once(game, capture_filename)
    finally:
        restore_camera_state(game, level, original_active)

    # Render the prompt
    ctx = {
        "cam_pos": cam_pos,
        "cam_pitch": round(pitch, 3),
        "sun_dir": "[approx +X+Z grazing]",  # TODO: read scene.json
    }
    for i, e in enumerate(entities):
        prefix_options = []
        if i == 0:
            prefix_options.extend(["entity_a", "entity"])
        elif i == 1:
            prefix_options.extend(["entity_b", "target"])
        for p in prefix_options:
            ctx[f"{p}_label"] = e.label
            ctx[f"{p}_def_id"] = e.def_id
            ctx[f"pos_{p[-1] if '_' in p else p[6:]}"] = e.position
        ctx[f"pos_{e.label}"] = e.position
        if i == 0:
            ctx["pos_a"] = e.position
            ctx["entity_a_label"] = e.label
            ctx["entity_a_def_id"] = e.def_id
            ctx["pos_entity"] = e.position
            ctx["entity_label"] = e.label
            ctx["entity_yaw"] = round(e.yaw, 3)
        elif i == 1:
            ctx["pos_b"] = e.position
            ctx["entity_b_label"] = e.label
            ctx["entity_b_def_id"] = e.def_id
            ctx["pos_target"] = e.position
            ctx["target_label"] = e.label
    # Common assertion params (biome, shot, expected, ...)
    for k, v in params.items():
        if not isinstance(v, list):
            ctx[k] = v

    rendered = render_prompt(assertion["prompt_template"], ctx)

    return TestRun(
        test_id=test_id,
        assertion_id=assertion_id,
        params=params,
        entities=entities,
        camera_pos=cam_pos,
        camera_yaw=yaw,
        camera_pitch=pitch,
        capture_path=png_path,
        rendered_prompt=rendered,
    )


def write_report(plan: dict[str, Any], runs: list[TestRun], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    report_md = output_dir / "visual_test_report.md"
    report_json = output_dir / "visual_test_report.json"

    with open(report_md, "w") as f:
        f.write(f"# Visual test report\n\n")
        f.write(f"- Game: `{plan.get('game', '?')}`\n")
        f.write(f"- Level: `{plan.get('level', '?')}`\n")
        f.write(f"- Tests: {len(runs)}\n")
        f.write(f"- Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        f.write("Each test below has the capture, the rendered prompt, and "
                "a slot for the verdict. Fill in PASS/FAIL by reading each "
                "PNG against the prompt.\n\n---\n\n")
        for r in runs:
            f.write(f"## {r.test_id} ({r.assertion_id})\n\n")
            f.write(f"**Capture**: `{r.capture_path}`\n\n")
            f.write(f"**Camera**: pos={r.camera_pos} yaw={r.camera_yaw:.3f} pitch={r.camera_pitch:.3f}\n\n")
            f.write(f"**Entities**:\n")
            for e in r.entities:
                f.write(f"  - `{e.instance_id}` (def: `{e.def_id}`) at {e.position}\n")
            f.write(f"\n**Prompt**:\n\n```\n{r.rendered_prompt}\n```\n\n")
            f.write(f"**Verdict**: ___ (PASS / FAIL)\n\n")
            f.write(f"**Evidence**: ___\n\n---\n\n")

    with open(report_json, "w") as f:
        json.dump({
            "plan": plan,
            "runs": [
                {
                    "test_id": r.test_id,
                    "assertion": r.assertion_id,
                    "params": r.params,
                    "entities": [
                        {"id": e.instance_id, "def": e.def_id, "pos": e.position}
                        for e in r.entities
                    ],
                    "camera": {"pos": r.camera_pos, "yaw": r.camera_yaw, "pitch": r.camera_pitch},
                    "capture": str(r.capture_path),
                    "prompt": r.rendered_prompt,
                }
                for r in runs
            ],
        }, f, indent=2)


def main() -> int:
    ap = argparse.ArgumentParser(prog="run_plan.py")
    ap.add_argument("plan", help="path to visual_test_plan.json")
    ap.add_argument("--dry-run", action="store_true", help="resolve + plan but don't capture")
    ap.add_argument("--only", help="comma-separated test_ids to run (default all)")
    ap.add_argument("--output", default=None, help="report output dir (default: alongside plan)")
    args = ap.parse_args()

    plan_path = Path(args.plan).resolve()
    if not plan_path.is_file():
        print(f"plan not found: {plan_path}", file=sys.stderr)
        return 1
    with open(plan_path) as f:
        plan = json.load(f)

    game = plan["game"]
    level = plan["level"]
    only = set(args.only.split(",")) if args.only else None
    tests = [t for t in plan["tests"] if (only is None or t["id"] in only)]

    output_dir = Path(args.output) if args.output else plan_path.parent / "visual_test_report"

    # Sync + import ONCE at the start. Per-test runs only sync the
    # transient camera change (cheap) and rely on the shared cache.
    if not args.dry_run:
        print(f"[run_plan] syncing godot/. → {TEMPLATE_DST}")
        sync_to_template()
        print(f"[run_plan] refreshing import cache (--headless --import)")
        reimport_godot()

    # Pre-load the level's full instance list + def→tags map for the
    # occlusion-aware camera placement (avoids the "camera inside a
    # tree cluster" bug class).
    all_instances = load_level_entities(game, level).get("initial_instances", [])
    def_tags_map = load_def_tags_map(game)

    runs: list[TestRun] = []
    for idx, test in enumerate(tests):
        print(f"[run_plan] [{idx+1}/{len(tests)}] {test['id']} ({test['assertion']})")
        if args.dry_run:
            # Resolve + compute pose, skip capture
            try:
                assertion = load_assertion(test["assertion"])
                params = test.get("params", {})
                ents = []
                for k, v in params.items():
                    if isinstance(v, str) and (k.startswith("entity") or k == "target"):
                        try:
                            ents.append(resolve_entity(game, level, v))
                        except ValueError as e:
                            print(f"  [dry] skip {k}: {e}")
                cam, yaw, pitch = compute_camera_pose(
                    assertion["framing"]["rule"], ents, extra=params,
                    all_instances=all_instances, def_tags_map=def_tags_map,
                )
                print(f"  [dry] camera pos={cam} yaw={yaw:.3f} pitch={pitch:.3f}")
            except Exception as e:
                print(f"  [dry] FAIL: {e}")
            continue
        try:
            run = run_test(game, level, test, idx,
                           all_instances=all_instances, def_tags_map=def_tags_map)
            runs.append(run)
        except Exception as e:
            import traceback
            traceback.print_exc()
            print(f"[run_plan] FAIL on {test['id']}: {e}", file=sys.stderr)

    if not args.dry_run:
        write_report(plan, runs, output_dir)
        print(f"[run_plan] report: {output_dir}/visual_test_report.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
