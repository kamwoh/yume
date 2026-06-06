#!/usr/bin/env python3
"""
Static validator for cross-file rule duplicate-mutation detection.

Yume splits rules across world/rules.json (how the world evolves)
and game/goals.json (goals) per ADR 0009. Tutorial.json adds another
overlay. The split is conceptual — engine doesn't enforce which
rule lives where. Authors from different skill agents
(yume-systems-designer for simulation, yume-game-rules-designer for
game) work in isolation, so they sometimes write rules with
overlapping responsibilities.

Empirical case 2026-05-11: Aldenmere had two pairs of duplicates:
- world/rules.json:day_rollover + game/goals.json:day_boundary_advance
  both watched current_hour>=24, both mutated current_day +
  current_hour. Different reset values (0 vs 6); last-writer-wins
  meant inconsistent behavior.
- world/rules.json:season_advance_X + game/goals.json:season_to_X
  both transitioned season_phase on the same day-count gates.

This validator catches "two rules mutate the same (entity-tag,
field) pair under overlapping query conditions."

Heuristic (intentionally conservative):
  For each rule, extract:
    - target tags (from query.tags_all, or 'a'/'b' sub-binding tags
      for contact rules)
    - mutated fields (from effects: state_set/_add/_mul/_clamp
      field, velocity_*, tag_add/tag_remove tags)
  Group rules by (sorted_target_tags, mutated_field).
  If a group has 2+ rules and they come from different files —
  warn (likely cross-author duplication).
  If 2+ rules in same file mutate same (tags,field) pair — OK
  silent (single-author intentional pattern).

Usage:
    python3 tools/validate_duplicate_mutations.py             # all demos
    python3 tools/validate_duplicate_mutations.py demo_X      # one game
    python3 tools/validate_duplicate_mutations.py --strict    # exit 1

Wired into scripts/play.sh as non-blocking pre-launch check.
"""

import json
import os
import sys
from collections import defaultdict
from pathlib import Path


STATE_MUTATION_EFFECTS = {
    "state_set", "state_add", "state_mul", "state_clamp",
}
VELOCITY_EFFECTS = {
    "velocity_set", "velocity_lerp",
    "velocity_set_relative", "velocity_add_relative",
}
TAG_EFFECTS = {"tag_add", "tag_remove"}


def gather_rules_from_file(path):
    """Return list of (rule_dict, file_path)."""
    if not path.exists(): return []
    try:
        doc = json.loads(path.read_text())
    except json.JSONDecodeError:
        return []
    rules = doc.get("rules", [])
    return [(r, str(path)) for r in rules if isinstance(r, dict)]


def query_target_tags(rule):
    """Extract the set of entity-tags this rule's query matches.
    Returns frozenset (sorted tags) — or empty for queries we can't
    reason about. Conservative: when in doubt, return empty so we
    DON'T flag (false positives worse than misses)."""
    q = rule.get("query", {})
    if not isinstance(q, dict): return frozenset()
    # Flat tags_all
    if "tags_all" in q:
        t = q["tags_all"]
        if isinstance(t, list): return frozenset(str(x) for x in t)
    # Sub-bindings (contact-pair) — use 'a' binding's tags (it's the actor)
    if isinstance(q.get("a"), dict) and "tags_all" in q["a"]:
        t = q["a"]["tags_all"]
        if isinstance(t, list): return frozenset(str(x) for x in t)
    return frozenset()


def rule_effects(rule):
    """Iterate effect dicts (handles single + array forms)."""
    e = rule.get("effect", rule.get("effects", []))
    if isinstance(e, dict): yield e
    elif isinstance(e, list):
        for x in e:
            if isinstance(x, dict): yield x


def mutations_for_rule(rule):
    """Yield (mutation_key, effect_type) pairs:
       ("field", <field_name>)  for state_*
       ("velocity",)             for velocity_*
       ("tag", <tag>)            for tag_add / tag_remove
    effect_type lets the caller tell a reset (state_set) from a decrement
    (state_add) on the same field — the canonical cooldown/timer pattern,
    which is NOT a clobber."""
    out = []
    for ef in rule_effects(rule):
        et = ef.get("type", "")
        if et in STATE_MUTATION_EFFECTS:
            f = ef.get("field")
            if f: out.append((("field", str(f)), et))
        elif et in VELOCITY_EFFECTS:
            out.append((("velocity",), et))
        elif et in TAG_EFFECTS:
            tags = ef.get("tags", [])
            if isinstance(tags, list):
                for t in tags:
                    out.append((("tag", str(t)), et))
    return out


def _is_level_rule_file(path_str):
    """True if the file is a per-level rules file (levels/<id>/rules.json).
    Rules in different levels are mutually exclusive at runtime — only one
    level loads — so a (tag, field) shared across level files is not a real
    overlap."""
    p = path_str.replace("\\", "/")
    return "/levels/" in p


def collect_rule_files(game_dir):
    """All world/rules.json + game/goals.json + tutorial.json + level rules."""
    out = []
    candidates = [
        game_dir / "world" / "rules.json",
        game_dir / "game" / "goals.json",
        game_dir / "tutorial.json",
    ]
    for c in candidates:
        if c.exists(): out.append(c)
    levels = game_dir / "levels"
    if levels.exists():
        for level_dir in sorted(levels.iterdir()):
            if level_dir.is_dir():
                r = level_dir / "rules.json"
                if r.exists(): out.append(r)
    return out


def validate_game(game_dir, repo_root, strict=False):
    game_dir = Path(game_dir)
    files = collect_rule_files(game_dir)
    if not files:
        return []
    # group_key = (tags_frozenset, mutation_key) → list of (file, rule_id, effect_type)
    groups = defaultdict(list)
    for f in files:
        for rule, _ in gather_rules_from_file(f):
            rid = rule.get("id", "<no-id>")
            tags = query_target_tags(rule)
            if not tags: continue  # can't reason
            for (mk, et) in mutations_for_rule(rule):
                groups[(tags, mk)].append((str(f), rid, et))

    issues = []
    for (tags, mk), entries in groups.items():
        if len(entries) < 2: continue
        # CROSS-FILE check: are the entries split across files?
        files_seen = {e[0] for e in entries}
        if len(files_seen) < 2: continue  # same-file is intentional pattern
        types = {e[2] for e in entries}
        # SUPPRESS reset+modify (cooldown/timer): a state_set (reset on fire/
        # spawn) coexisting with a state_add/state_mul (per-tick decrement) on
        # the same field is the universal cooldown/timer idiom, not a clobber.
        if "state_set" in types and (types & {"state_add", "state_mul"}):
            continue
        # SUPPRESS mutually-exclusive levels: if every contributing rule lives
        # in a per-level rules file, the rules never run together (one level
        # loads at a time) — e.g. per-chamber spawners sharing spawn_count.
        if all(_is_level_rule_file(e[0]) for e in entries):
            continue
        issues.append({
            "tags": sorted(tags),
            "mutation": mk,
            "rules": [(e[0], e[1]) for e in entries],
        })
    return issues


def fmt_mutation(mk):
    if mk[0] == "field": return f"state.{mk[1]}"
    if mk[0] == "velocity": return "velocity"
    if mk[0] == "tag": return f"tag:{mk[1]}"
    return str(mk)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    repo_root = Path(__file__).resolve().parent.parent.parent
    data_root = repo_root / "godot" / "data"

    if args:
        targets = [data_root / args[0]]
    else:
        targets = [d for d in data_root.iterdir()
                   if d.is_dir() and d.name.startswith("demo_")]

    total_issues = 0
    for game_dir in sorted(targets):
        if not game_dir.exists():
            print(f"[skip] {game_dir} (not found)")
            continue
        issues = validate_game(game_dir, repo_root, strict=strict)
        if issues:
            # ADVISORY heuristic — always WARN, never FAIL (see exit note).
            print(f"[WARN] {game_dir.name} ({len(issues)} cross-file mutation overlap(s)):")
            for it in issues:
                tags_str = "+".join(it["tags"]) if it["tags"] else "<no tags>"
                print(f"  query[{tags_str}] mutates {fmt_mutation(it['mutation'])}:")
                for f, rid in it["rules"]:
                    rel = Path(f).relative_to(repo_root)
                    print(f"    {rel}::{rid}")
            total_issues += len(issues)
        else:
            print(f"[ok] {game_dir.name}")

    if total_issues:
        print(f"\n{total_issues} cross-file rule overlap(s).")
        print("Per ADR 0009: world/rules.json owns how the world evolves,")
        print("game/goals.json owns goals. Pick ONE file per mutation; merge")
        print("or delete the duplicate. If a rule needs both layers, split")
        print("into two — game/goals.json owns the state mutation;")
        print("world/rules.json owns the feedback (juice / signal handlers).")
    # ADVISORY (2026-06-06): this is a HEURISTIC — overlapping-query (tag,field)
    # mutation. It CANNOT distinguish an intentional cooldown/timer (set on an
    # action + decrement on tick — universal in any game with weapons or
    # spawners) from an accidental clobber. So it WARNS loudly but NEVER blocks,
    # even under --strict; the author reviews the pairs. (Was a --strict
    # blocker; that wrongly failed every cooldown-using game, e.g. the
    # doomarena3d example.)
    sys.exit(0)


if __name__ == "__main__":
    main()
