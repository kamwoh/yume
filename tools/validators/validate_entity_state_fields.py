#!/usr/bin/env python3
"""Static validator: state field names used in entity defs +
initial_instances must match what the engine actually reads.

Empirical case 2026-05-26: compose_world.py emitted `state.facing`
for the rotation of static buildings (wall_segment, house, etc).
The engine's renderer (multimesh_director.gd:373) reads
`state.yaw`, NOT `state.facing`. `state.facing` is a Yume
movement-rule convention used by WASD-style rules; the renderer
ignores it. Result: 16 wall segments all rendered at yaw=0 (no
rotation applied at all). The PCA-derived rotation was correct;
it just landed in a field the renderer doesn't read.

The bug class: silent ROUTING failures where one part of Yume
writes to field X and another part reads field Y. No parser
error, no runtime crash — entities just sit in their default
orientation.

This validator catches the SPECIFIC field-name landmines:

  - `state.facing` on entities that are NOT actor-tagged → warn
    (probably meant state.yaw — facing is for movement rules,
    yaw is for rendering)
  - `state.rotation` → ERROR (no such engine field; almost
    certainly meant yaw)
  - `state.rotation_y` → ERROR (same)
  - `state.heading` → WARN (informal alias; should be yaw)
  - `state.rotation_deg` → WARN (engine reads radians via yaw)

ACTOR-TAGGED entities (with tag in ACTOR_TAGS) MAY legitimately
use both `state.facing` (movement) and `state.yaw` (rendering).
The validator only flags `state.facing` when no actor-class tag
is present.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


# Movement-rule actors that legitimately use state.facing for
# the WASD/movement-rule "forward direction" convention.
ACTOR_TAGS = {
    "player", "actor", "wolf", "villager", "ambient_walker",
    "prey", "npc", "animal", "mob", "enemy",
}

# Engine-read state fields by the rendering / camera / motion paths.
ENGINE_RENDERED_ROTATION_FIELDS = {"yaw", "pitch"}

# State-field landmines: bad name → (severity, replacement)
LANDMINES = {
    "rotation":     ("error", "yaw"),
    "rotation_y":   ("error", "yaw"),
    "rotation_deg": ("warn",  "yaw (in radians, not degrees)"),
    "heading":      ("warn",  "yaw"),
}


def _is_actor(tags: list[str]) -> bool:
    return any(t in ACTOR_TAGS for t in tags)


def _scan_state(*, state: dict, tags: list[str], path: str,
                inst_id: str) -> list[dict]:
    findings: list[dict] = []
    if not isinstance(state, dict):
        return findings
    for field in state:
        if field in LANDMINES:
            severity, replacement = LANDMINES[field]
            findings.append({
                "severity": severity,
                "file": path,
                "instance": inst_id,
                "field": field,
                "message": (
                    f"state.{field} → use state.{replacement} "
                    f"(engine renderer reads state.yaw via "
                    f"multimesh_director.gd:373)"
                ),
            })
        elif field == "facing":
            if not _is_actor(tags):
                findings.append({
                    "severity": "warn",
                    "file": path,
                    "instance": inst_id,
                    "field": "facing",
                    "message": (
                        f"state.facing on non-actor (tags={tags!r}). "
                        f"state.facing is a movement-rule convention; "
                        f"the renderer reads state.yaw. If this is "
                        f"meant as a rotation, use state.yaw."
                    ),
                })
    return findings


def _scan_definitions(defs_path: Path) -> list[dict]:
    findings: list[dict] = []
    if not defs_path.exists():
        return findings
    try:
        doc = json.loads(defs_path.read_text())
    except json.JSONDecodeError as e:
        return [{
            "severity": "error", "file": str(defs_path),
            "instance": "<file>", "field": "<json>",
            "message": f"parse error: {e}",
        }]
    for d in doc.get("definitions", []):
        if not isinstance(d, dict):
            continue
        tags = list(d.get("tags", []))
        state_init = d.get("state_init", {})
        findings.extend(_scan_state(
            state=state_init, tags=tags,
            path=str(defs_path),
            inst_id=f"def:{d.get('id', '?')}",
        ))
    return findings


def _scan_instances(level_path: Path,
                    def_tags: dict[str, list[str]]) -> list[dict]:
    findings: list[dict] = []
    if not level_path.exists():
        return findings
    try:
        doc = json.loads(level_path.read_text())
    except json.JSONDecodeError as e:
        return [{
            "severity": "error", "file": str(level_path),
            "instance": "<file>", "field": "<json>",
            "message": f"parse error: {e}",
        }]
    for inst in doc.get("initial_instances", []):
        if not isinstance(inst, dict):
            continue
        def_id = inst.get("def", "")
        # Inherit tags from the def to drive the actor check.
        tags = list(def_tags.get(def_id, []))
        tags.extend(inst.get("tags", []))
        state = inst.get("state", {})
        findings.extend(_scan_state(
            state=state, tags=tags,
            path=str(level_path),
            inst_id=inst.get("id", "?"),
        ))
    # patterns[] also carry state overrides for spawned tiles
    for pat in doc.get("patterns", []):
        if not isinstance(pat, dict):
            continue
        def_id = pat.get("def", "")
        tags = list(def_tags.get(def_id, []))
        state = pat.get("state", {})
        findings.extend(_scan_state(
            state=state, tags=tags,
            path=str(level_path),
            inst_id=f"pattern:{pat.get('id_prefix', '?')}",
        ))
    return findings


def _collect_def_tags(game_dir: Path) -> dict[str, list[str]]:
    """Walk every entity def file under entities/ and map def_id → tags."""
    out: dict[str, list[str]] = {}
    for ef in (game_dir / "entities").glob("*.json"):
        try:
            doc = json.loads(ef.read_text())
        except json.JSONDecodeError:
            continue
        for d in doc.get("definitions", []):
            if isinstance(d, dict) and "id" in d:
                out[d["id"]] = list(d.get("tags", []))
    return out


def validate_game(game_dir: Path) -> list[dict]:
    findings: list[dict] = []
    def_tags = _collect_def_tags(game_dir)
    for ef in (game_dir / "entities").glob("*.json"):
        findings.extend(_scan_definitions(ef))
    for lf in (game_dir / "levels").glob("*/entities.json"):
        findings.extend(_scan_instances(lf, def_tags))
    return findings


def _emit_report(findings: list[dict]) -> str:
    if not findings:
        return "[validate_entity_state_fields] OK — no landmines found"
    lines = ["[validate_entity_state_fields] findings:"]
    for f in findings:
        lines.append(
            f"  [{f['severity'].upper():5s}] {f['file']}  "
            f"{f['instance']}  state.{f['field']}: {f['message']}"
        )
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("game", help="data/<game> folder name (with or without demo_)")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if any error OR warning is found "
                         "(default: only on errors)")
    args = ap.parse_args()

    name = args.game if args.game.startswith("demo_") else f"demo_{args.game}"
    game_dir = Path("godot/data") / name
    if not game_dir.exists():
        print(f"[validate_entity_state_fields] game dir not found: {game_dir}",
              file=sys.stderr)
        return 1

    findings = validate_game(game_dir)
    print(_emit_report(findings))

    if not findings:
        return 0
    any_error = any(f["severity"] == "error" for f in findings)
    if args.strict and findings:
        return 1
    if any_error:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
