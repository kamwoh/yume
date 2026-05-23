#!/usr/bin/env python3
"""
yume-visual-tester implementation (ADR 0057 Phase B.1 + B.2).

Reads a game's GDD + level entities + assertion library + priors library,
emits a visual_test_plan.json that the ADR 0056 runner can execute.

This is a DETERMINISTIC generator (pattern matching, not LLM-driven).
Reasoning: priors are themselves declarative content, so the match
algorithm is straightforward bookkeeping. The LLM-driven path is
reserved for harder cases (semantic plan refinement, novel assertion
composition) that don't yet justify the cost.

Usage:
    python3 tools/visual_qa/generate_plan.py demo_aldenmere
    python3 tools/visual_qa/generate_plan.py demo_aldenmere --level=level_proto_village
    python3 tools/visual_qa/generate_plan.py demo_aldenmere --diff-base=HEAD~5 --max-tests=15
    python3 tools/visual_qa/generate_plan.py demo_aldenmere --no-cache

Output:
    tools/visual_qa/plans/<game>_<level>_<diff_hash>.json   (the plan)
    tools/visual_qa/plans/<game>_<level>_<diff_hash>.md     (report)

Exit code:
    0 — plan written or cache hit
    1 — error (missing inputs, invalid prior, etc.)
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve()
REPO_ROOT = HERE.parents[2]
DATA_ROOT = REPO_ROOT / "godot" / "data"
PRIORS_PATH = DATA_ROOT / "lib" / "visual_qa" / "priors.json"
ASSERTIONS_DIR = DATA_ROOT / "lib" / "visual_qa" / "assertions"
PLANS_DIR = HERE.parent / "plans"


@dataclass
class Entity:
    """Resolved entity instance from a level's initial_instances."""
    id: str
    def_id: str
    tags: set[str]
    properties: dict[str, Any]
    visual: dict[str, Any]
    position: list[float]


@dataclass
class EmittedTest:
    """One test instance ready to write to the plan."""
    id: str
    assertion: str
    params: dict[str, Any]
    priority: str = "medium"
    matched_prior: str = ""
    target_recently_changed: bool = False


def load_priors() -> list[dict[str, Any]]:
    if not PRIORS_PATH.is_file():
        print(f"error: priors not found at {PRIORS_PATH}", file=sys.stderr)
        sys.exit(1)
    return json.loads(PRIORS_PATH.read_text()).get("priors", [])


def load_assertions() -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for fp in sorted(ASSERTIONS_DIR.glob("*.json")):
        d = json.loads(fp.read_text())
        out[d["id"]] = d
    return out


def load_entities(game: str, level: str) -> list[Entity]:
    """Walk the level's initial_instances + resolve each entity's def."""
    lvl_path = DATA_ROOT / game / "levels" / level / "entities.json"
    if not lvl_path.is_file():
        print(f"error: level entities not found at {lvl_path}", file=sys.stderr)
        sys.exit(1)
    lvl = json.loads(lvl_path.read_text())

    defs: dict[str, dict[str, Any]] = {}
    for fp in sorted((DATA_ROOT / game / "entities").glob("*.json")):
        d = json.loads(fp.read_text())
        for ed in d.get("definitions", []):
            defs[ed["id"]] = ed

    entities: list[Entity] = []
    for inst in lvl.get("initial_instances", []):
        def_id = inst.get("def", "")
        d = defs.get(def_id, {})
        entities.append(Entity(
            id=inst.get("id", "?"),
            def_id=def_id,
            tags=set(d.get("tags", [])),
            properties=d.get("properties", {}),
            visual=d.get("visual", {}) or {},
            position=list(inst.get("position", [0, 0, 0])),
        ))
    return entities


def load_gdd_aesthetics(game: str) -> list[str]:
    """Best-effort extraction of aesthetic targets from the GDD."""
    gdd_path = REPO_ROOT / "docs" / "games" / game.replace("demo_", "") / "GDD.md"
    if not gdd_path.is_file():
        # Try a couple other locations
        for alt in [REPO_ROOT / "docs" / "games" / game / "GDD.md"]:
            if alt.is_file():
                gdd_path = alt
                break
        else:
            return []
    text = gdd_path.read_text()
    # Look for the MDA "Aesthetics" line — Bartle / LeBlanc / our taxonomy
    targets: list[str] = []
    for word in ["Fellowship", "Narrative", "Submission", "Discovery",
                 "Sensation", "Challenge", "Fantasy", "Expression"]:
        if word in text:
            targets.append(word)
    return targets


def load_biome_set(game: str) -> set[str]:
    """Inspect scene.json shader_params.albedo_* to see which biomes are
    in play. (A more thorough version would actually sample the biome
    map's pixels; that's a Phase B.2 enhancement.)"""
    scene_path = DATA_ROOT / game / "scene.json"
    if not scene_path.is_file():
        return set()
    scene = json.loads(scene_path.read_text())
    sp = scene.get("ground", {}).get("mesh", {}).get("shader_params", {})
    biomes: set[str] = set()
    for k in sp.keys():
        if k.startswith("albedo_"):
            biomes.add(k[len("albedo_"):])
    return biomes


def recently_changed_def_ids(game: str, diff_base: str) -> set[str]:
    """Run git diff to find which entity def files changed since diff_base."""
    try:
        cmd = ["git", "-C", str(REPO_ROOT), "diff", "--name-only",
               diff_base, "HEAD", "--",
               f"godot/data/{game}/entities/", f"godot/data/{game}/levels/"]
        out = subprocess.check_output(cmd, text=True, timeout=30)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return set()
    # Map changed files → def ids by reading the affected files
    changed_defs: set[str] = set()
    for line in out.strip().splitlines():
        if not line:
            continue
        fp = REPO_ROOT / line
        if not fp.is_file() or fp.suffix != ".json":
            continue
        try:
            d = json.loads(fp.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        for ed in d.get("definitions", []):
            if "id" in ed:
                changed_defs.add(ed["id"])
    return changed_defs


def matches_trigger(ent: Entity, trig: dict[str, Any]) -> bool:
    """Check a single entity against a tag/property/visual trigger spec."""
    if "tags_any" in trig:
        if not (ent.tags & set(trig["tags_any"])):
            return False
    if "tags_all" in trig:
        if not (set(trig["tags_all"]) <= ent.tags):
            return False
    if "tags_none" in trig:
        if ent.tags & set(trig["tags_none"]):
            return False
    if "has_property" in trig:
        if trig["has_property"] not in ent.properties:
            return False
    if "has_visual" in trig:
        hv = trig["has_visual"]
        if "model_3d_contains" in hv:
            m3d = str(ent.visual.get("model_3d", ""))
            if hv["model_3d_contains"] not in m3d:
                return False
    return True


def resolve_tokens(template: str, ctx: dict[str, str]) -> str:
    """Substitute <key> tokens in a string."""
    out = template
    for k, v in ctx.items():
        out = out.replace(f"<{k}>", str(v))
    return out


def emit_tests_for_prior(
    prior: dict[str, Any],
    entities: list[Entity],
    biomes: set[str],
    changed_def_ids: set[str],
    aesthetics: list[str],
) -> list[EmittedTest]:
    """Apply one prior to the game's entities → list of EmittedTest."""
    pid = prior["id"]
    priority = prior.get("priority", "medium")
    out: list[EmittedTest] = []

    # Guard check
    guard = prior.get("guard", {})
    if "gdd_aesthetic_any" in guard:
        if not (set(guard["gdd_aesthetic_any"]) & set(aesthetics)):
            return out

    trig = prior.get("trigger", {})
    emit = prior["emit"]
    max_pairs = int(prior.get("max_pairs", 3))

    def make_test(test_id: str, assertion: str, params: dict[str, Any],
                  touches_change: bool) -> EmittedTest:
        return EmittedTest(
            id=test_id,
            assertion=assertion,
            params=params,
            priority=priority,
            matched_prior=pid,
            target_recently_changed=touches_change,
        )

    # Special case: git_diff_touches_def
    if trig.get("git_diff_touches_def") and changed_def_ids:
        assertion_set = emit.get("assertion_set", [])
        for ent in entities:
            if ent.def_id not in changed_def_ids:
                continue
            for assertion in assertion_set:
                tid = f"recent_{ent.id}_{assertion}"
                params = {"entity": ent.id}
                out.append(make_test(tid, assertion, params, touches_change=True))
        return out

    # Special case: biome_map_has
    if "biome_map_has" in trig:
        biome = trig["biome_map_has"]
        if biome in biomes:
            tid = f"{pid}_{biome}"
            params = dict(emit.get("params", {}))
            out.append(make_test(tid, emit["assertion"], params, touches_change=False))
        return out

    # Always-emit (no trigger but has emit + expand_for_each)
    if not trig and "expand_for_each" in emit:
        for key, values in emit["expand_for_each"].items():
            for v in values:
                tid = f"{pid}_{v}"
                ctx = {key: str(v)}
                params: dict[str, Any] = {}
                for k, pv in emit.get("params", {}).items():
                    params[k] = resolve_tokens(pv, ctx) if isinstance(pv, str) else pv
                out.append(make_test(tid, emit["assertion"], params, touches_change=False))
        return out

    # Single-entity trigger
    if "entity" in trig:
        matches = [e for e in entities if matches_trigger(e, trig["entity"])]
        for ent in matches[:max_pairs]:
            touches = ent.def_id in changed_def_ids
            ctx = {"entity.id": ent.id, "entity.def": ent.def_id}
            params: dict[str, Any] = {}
            for k, pv in emit.get("params", {}).items():
                params[k] = resolve_tokens(pv, ctx) if isinstance(pv, str) else pv
            tid = f"{pid}_{ent.id}"
            out.append(make_test(tid, emit["assertion"], params, touches_change=touches))
        return out

    # Two-entity trigger (entities_a × entities_b)
    if "entities_a" in trig and "entities_b" in trig:
        a_matches = [e for e in entities if matches_trigger(e, trig["entities_a"])]
        b_matches = [e for e in entities if matches_trigger(e, trig["entities_b"])]
        pairs = []
        for a in a_matches:
            for b in b_matches:
                if a.id == b.id:
                    continue
                touches = (a.def_id in changed_def_ids) or (b.def_id in changed_def_ids)
                # Sort: changed-touching first, then alphabetical for determinism
                pairs.append((not touches, a.id, b.id, a, b))
        pairs.sort()
        for _, _, _, a, b in pairs[:max_pairs]:
            touches = (a.def_id in changed_def_ids) or (b.def_id in changed_def_ids)
            ctx = {"a.id": a.id, "a.def": a.def_id, "b.id": b.id, "b.def": b.def_id}
            params: dict[str, Any] = {}
            for k, pv in emit.get("params", {}).items():
                params[k] = resolve_tokens(pv, ctx) if isinstance(pv, str) else pv
            tid = f"{pid}_{a.id}_vs_{b.id}"
            out.append(make_test(tid, emit["assertion"], params, touches_change=touches))
        return out

    return out


def validate_tests(tests: list[EmittedTest], assertions: dict[str, dict[str, Any]],
                   entity_ids: set[str]) -> tuple[list[EmittedTest], list[str]]:
    """Drop invalid tests, return (kept, warnings)."""
    kept: list[EmittedTest] = []
    warnings: list[str] = []
    for t in tests:
        if t.assertion not in assertions:
            warnings.append(f"drop {t.id}: unknown assertion '{t.assertion}'")
            continue
        # Check referenced entity ids exist (where applicable)
        for k, v in t.params.items():
            if not isinstance(v, str):
                continue
            if k in ("entity_a", "entity_b", "entity", "target"):
                # Only validate if it looks like a concrete id, not a biome name
                if v and v not in entity_ids and v != "ground":
                    # Allow well-known special names
                    if v not in ("water", "dirt", "grass", "path", "forest"):
                        warnings.append(f"drop {t.id}: entity '{v}' not in level")
                        break
        else:
            kept.append(t)
    return kept, warnings


def order_and_cap(tests: list[EmittedTest], max_tests: int) -> list[EmittedTest]:
    """Sort by priority + recently_changed flag, then cap.

    Priority order (lowest sort key first):
      0 — touches recently-changed entity
      1 — priority=high
      2 — priority=medium
      3 — priority=low
    """
    PRI = {"high": 1, "medium": 2, "low": 3}

    def key(t: EmittedTest) -> tuple[int, int, str]:
        change_key = 0 if t.target_recently_changed else 1
        return (change_key, PRI.get(t.priority, 2), t.id)

    tests.sort(key=key)
    # Always keep all high+changed; trim low/medium beyond cap
    kept: list[EmittedTest] = []
    for t in tests:
        if len(kept) < max_tests:
            kept.append(t)
        elif t.target_recently_changed or t.priority == "high":
            kept.append(t)  # never drop high/changed
    return kept


def compute_diff_hash(game: str, level: str, diff_base: str) -> str:
    """Cache key — invalidates when entities.json content changes or diff base changes."""
    h = hashlib.sha256()
    h.update(f"{game}|{level}|{diff_base}".encode())
    lvl_path = DATA_ROOT / game / "levels" / level / "entities.json"
    if lvl_path.is_file():
        h.update(lvl_path.read_bytes())
    return h.hexdigest()[:8]


def write_plan(game: str, level: str, tests: list[EmittedTest],
               plan_path: Path, warnings: list[str], diff_base: str) -> None:
    plan = {
        "_comment": (
            f"Auto-generated by yume-visual-tester on "
            f"{time.strftime('%Y-%m-%d %H:%M:%S')}. "
            f"Source: {DATA_ROOT / 'lib' / 'visual_qa' / 'priors.json'}. "
            f"Diff base: {diff_base}."
        ),
        "game": game,
        "level": level,
        "tests": [
            {"id": t.id, "assertion": t.assertion, "params": t.params,
             "_prior": t.matched_prior, "_priority": t.priority,
             "_recently_changed": t.target_recently_changed}
            for t in tests
        ],
    }
    plan_path.write_text(json.dumps(plan, indent=2) + "\n")


def write_report(plan_path: Path, tests: list[EmittedTest],
                 warnings: list[str], stats: dict[str, Any]) -> None:
    rpt = plan_path.with_suffix(".md")
    lines = [
        f"# Visual test plan report",
        f"",
        f"- Plan: `{plan_path}`",
        f"- Tests: {len(tests)}",
        f"- Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"",
        f"## Stats",
        f"",
        f"- Total emitted (pre-cap): {stats['total_emitted']}",
        f"- After validation: {stats['valid']}",
        f"- After cap: {len(tests)}",
        f"- Touches recently-changed: {stats['touches_change']}",
        f"",
        f"## By priority + prior",
        f"",
    ]
    by_prior: dict[str, int] = {}
    by_pri: dict[str, int] = {}
    for t in tests:
        by_prior[t.matched_prior] = by_prior.get(t.matched_prior, 0) + 1
        by_pri[t.priority] = by_pri.get(t.priority, 0) + 1
    for pri in ("high", "medium", "low"):
        n = by_pri.get(pri, 0)
        lines.append(f"- priority `{pri}`: {n} test(s)")
    lines.append("")
    for prior, n in sorted(by_prior.items()):
        lines.append(f"- from `{prior}`: {n}")
    lines.append("")
    if warnings:
        lines.append(f"## Warnings ({len(warnings)})")
        lines.append("")
        for w in warnings:
            lines.append(f"- {w}")
        lines.append("")
    rpt.write_text("\n".join(lines))


def get_starting_level(game: str) -> str:
    """Read flow.json for starting_level, fallback to first level dir."""
    flow_path = DATA_ROOT / game / "game" / "flow.json"
    if flow_path.is_file():
        d = json.loads(flow_path.read_text())
        if "starting_level" in d:
            return d["starting_level"]
    levels_dir = DATA_ROOT / game / "levels"
    if levels_dir.is_dir():
        for sub in sorted(levels_dir.iterdir()):
            if sub.is_dir() and (sub / "entities.json").is_file():
                return sub.name
    return "level_proto_village"


def main() -> int:
    ap = argparse.ArgumentParser(prog="generate_plan.py")
    ap.add_argument("game", help="game folder name (e.g. demo_aldenmere)")
    ap.add_argument("--level", default=None,
                    help="level name (default: read from flow.json starting_level)")
    ap.add_argument("--diff-base", default="HEAD~1",
                    help="git ref to compute recently-changed against")
    ap.add_argument("--max-tests", type=int, default=12,
                    help="soft cap on test count")
    ap.add_argument("--no-cache", action="store_true",
                    help="ignore cached plan, regenerate")
    args = ap.parse_args()

    game = args.game
    level = args.level or get_starting_level(game)
    diff_base = args.diff_base
    max_tests = args.max_tests

    PLANS_DIR.mkdir(parents=True, exist_ok=True)
    diff_hash = compute_diff_hash(game, level, diff_base)
    plan_path = PLANS_DIR / f"{game}_{level}_{diff_hash}.json"

    if plan_path.is_file() and not args.no_cache:
        print(f"[cache hit] {plan_path}")
        return 0

    priors = load_priors()
    assertions = load_assertions()
    entities = load_entities(game, level)
    aesthetics = load_gdd_aesthetics(game)
    biomes = load_biome_set(game)
    changed_def_ids = recently_changed_def_ids(game, diff_base)
    entity_ids = {e.id for e in entities}

    print(f"[generate_plan] {game}/{level}: {len(entities)} entities, "
          f"{len(priors)} priors, aesthetics={aesthetics or '∅'}, "
          f"biomes={sorted(biomes) or '∅'}, "
          f"changed defs={sorted(changed_def_ids)[:5]}{'...' if len(changed_def_ids) > 5 else ''}")

    all_tests: list[EmittedTest] = []
    for p in priors:
        all_tests.extend(emit_tests_for_prior(p, entities, biomes, changed_def_ids, aesthetics))

    valid, warnings = validate_tests(all_tests, assertions, entity_ids)
    capped = order_and_cap(valid, max_tests)

    stats = {
        "total_emitted": len(all_tests),
        "valid": len(valid),
        "touches_change": sum(1 for t in capped if t.target_recently_changed),
    }

    write_plan(game, level, capped, plan_path, warnings, diff_base)
    write_report(plan_path, capped, warnings, stats)

    print(f"[generate_plan] {len(capped)} tests emitted → {plan_path}")
    if warnings:
        print(f"[generate_plan] {len(warnings)} warning(s) — see report")
    return 0


if __name__ == "__main__":
    sys.exit(main())
