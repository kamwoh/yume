#!/usr/bin/env python3
"""
validate_lifetime_despawn.py — every entity def that carries a `lifetime` state
field MUST have rules that (a) decrement it each tick AND (b) remove the entity
when it expires. Otherwise the entity lives forever.

Why this exists (post-mortem 2026-06-06): this bug class bit doomarena3d TWICE.
Bullets had `state.lifetime` but (pre-fix) no decrement/remove rule, so missed
shots piled up. Then `particle_spark` had `lifetime: 18` and NOTHING acted on
it — death-burst sparks stayed on screen forever (only became visible once a
separate renderer-attach fix landed). A `lifetime` field is a PROMISE that the
thing is ephemeral; this validator makes the engine keep it.

Heuristic (per-tag, conservative — only flags a def when NO rule could plausibly
reach it):
  lifetime_def  = a def whose state_init has a "lifetime" key.
  decrement rule = state_add on field "lifetime" (any amount) whose query
                   tags_all ⊆ the def's tags.
  despawn rule   = a `remove` effect whose query has a lifetime_lt/lte/le state
                   filter AND whose tags_all ⊆ the def's tags.
  A lifetime_def is OK iff it has BOTH a decrement and a despawn rule reaching
  it. Missing either → flag (it can't expire).

Usage:
    python3 tools/validators/validate_lifetime_despawn.py            # all demos
    python3 tools/validators/validate_lifetime_despawn.py demo_X
    python3 tools/validators/validate_lifetime_despawn.py --strict   # exit 1
"""

import json
import sys
from pathlib import Path


def _load(path):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return None


def _defs(game_dir):
    """Every entity def in the game, as (def_dict)."""
    out = []
    ent = game_dir / "entities"
    files = list(ent.rglob("*.json")) if ent.exists() else []
    for f in game_dir.glob("entities.json"):
        files.append(f)
    for f in files:
        d = _load(f)
        if d is None:
            continue
        defs = d.get("definitions", d) if isinstance(d, dict) else d
        if isinstance(defs, list):
            for de in defs:
                if isinstance(de, dict) and de.get("id"):
                    out.append(de)
    return out


def _rule_files(game_dir):
    out = []
    for c in [game_dir / "world" / "rules.json", game_dir / "game" / "goals.json"]:
        if c.exists():
            out.append(c)
    wr = game_dir / "world" / "rules"
    if wr.exists():
        out += sorted(wr.glob("*.json"))
    lv = game_dir / "levels"
    if lv.exists():
        for d in sorted(lv.iterdir()):
            if d.is_dir():
                out += list(d.glob("rules.json"))
    return out


def _rules(game_dir):
    out = []
    for f in _rule_files(game_dir):
        d = _load(f)
        if isinstance(d, dict):
            out += [r for r in d.get("rules", []) if isinstance(r, dict)]
    return out


def _effects(rule):
    e = rule.get("effect", rule.get("effects", []))
    return [e] if isinstance(e, dict) else [x for x in e if isinstance(x, dict)] if isinstance(e, list) else []


def _tags_all(rule):
    q = rule.get("query", {})
    if isinstance(q, dict) and isinstance(q.get("tags_all"), list):
        return set(str(t) for t in q["tags_all"])
    return set()


def _state_filter_keys(rule):
    q = rule.get("query", {})
    st = q.get("state", {}) if isinstance(q, dict) else {}
    return set(st.keys()) if isinstance(st, dict) else set()


def validate_game(game_dir):
    game_dir = Path(game_dir)
    defs = _defs(game_dir)
    lifetime_defs = [d for d in defs if "lifetime" in (d.get("state_init", {}) or {})]
    if not lifetime_defs:
        return []
    rules = _rules(game_dir)

    decrement = []  # (tags_all,) for state_add on lifetime
    despawn = []    # (tags_all,) for remove gated on lifetime_*
    for r in rules:
        tags = _tags_all(r)
        effs = _effects(r)
        if any(e.get("type") == "state_add" and e.get("field") == "lifetime" for e in effs):
            decrement.append(tags)
        if any(e.get("type") == "remove" for e in effs) and any(
            k in ("lifetime_lt", "lifetime_lte", "lifetime_le") for k in _state_filter_keys(r)
        ):
            despawn.append(tags)

    def reached_by(rule_tagsets, def_tags):
        # A rule reaches the def if its query tags_all is a subset of the def's tags.
        return any(rt <= def_tags for rt in rule_tagsets)

    issues = []
    for de in lifetime_defs:
        dtags = set(de.get("tags", []))
        has_dec = reached_by(decrement, dtags)
        has_del = reached_by(despawn, dtags)
        if not (has_dec and has_del):
            missing = []
            if not has_dec:
                missing.append("no rule decrements state.lifetime")
            if not has_del:
                missing.append("no `remove` rule gated on lifetime_lte/lt")
            issues.append({"id": de.get("id"), "tags": sorted(dtags), "missing": missing})
    return issues


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    data_root = Path(__file__).resolve().parent.parent.parent / "godot" / "data"
    targets = ([data_root / args[0]] if args
               else [d for d in sorted(data_root.iterdir())
                     if d.is_dir() and d.name.startswith("demo_")])
    total = 0
    for g in targets:
        if not g.exists():
            print(f"[skip] {g} (not found)")
            continue
        issues = validate_game(g)
        if issues:
            total += len(issues)
            print(f"[FAIL] {g.name}: {len(issues)} lifetime def(s) that never expire:")
            for it in issues:
                print(f"  '{it['id']}' (tags {it['tags']}): {'; '.join(it['missing'])}")
        else:
            print(f"[ok] {g.name}")
    if total:
        print(f"\n{total} ephemeral def(s) can't expire. Add a tick rule decrementing "
              f"state.lifetime + a `remove` rule gated on lifetime_lte:0 for the def's tags "
              f"(see doomarena3d bullet_age/bullet_expire + particle_age/particle_expire).")
        return 1 if strict else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
