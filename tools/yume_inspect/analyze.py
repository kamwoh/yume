#!/usr/bin/env python3
"""Derive the coupling graphs from a game's JSON. No rendering here."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from tools.validators.validate_rules import (  # noqa: E402
    GLOBAL_ROOTS,
    compute_context_bindings,
    find_rule_files,
)

DATA = REPO / "godot" / "data"

# A dotted reference in a formula: `self.state.hp`, `world.delve_floor`,
# `actor.properties.role`. Group 1 is the binding root, group 2 the path.
# `(?<![@\w.])` keeps the match off indirection refs. Without it every
# `@strings.contract.accepted` parses as a binding called `strings`, and the
# report fills with 38 phantom unknown-bindings — a tool that cries wolf is a
# tool that gets skipped, so precision here is load-bearing.
REF = re.compile(
    r"(?<![@\w.])([A-Za-z_][\w]*)\.((?:state|properties|props|tags)\.[\w.]+|[\w.]+)"
)

# World-state keys the ENGINE writes, so "no rule writes this" is not a finding.
ENGINE_WRITTEN = {
    "calendar_units",      # advance_time (ADR 0078)
    "_call_args",          # level_call (ADR 0077)
    "_level_call_stack",   # level_call / level_return
    "_fired_rules",        # once / once_per ledger (ADR 0080)
    "current_level", "all_levels_complete", "language", "objective",
}

# Effects that WRITE a named state field, and which key carries the value.
WRITERS = {
    "state_set": "value", "state_add": "amount", "state_mul": "amount",
    "state_clamp": None, "array_set_at": "value", "array_insert_first_empty": None,
    "array_count_matching": None, "array_sync_to_field": None,
}


@dataclass
class Rule:
    id: str
    file: str
    trigger: str
    signal_in: str | None          # signal name this rule triggers on
    signals_out: list[str]         # signals this rule emits
    bindings: set[str]             # what a formula here may reference
    refs: set[tuple[str, str]]     # (binding, path) referenced by formulas
    reads: set[str]                # state fields read via query filters
    writes: set[str]               # state fields written via effects
    world_reads: set[str]
    world_writes: set[str]
    raw: dict = field(repr=False, default_factory=dict)


def _strip_op(key: str) -> str:
    """`hp_gte` -> `hp`. Query filters carry the comparator in the key."""
    for op in ("_gte", "_lte", "_gt", "_lt", "_eq", "_ne", "_neq"):
        if key.endswith(op):
            return key[: -len(op)]
    return key


def _walk_strings(node, out: list[str]) -> None:
    if isinstance(node, str):
        out.append(node)
    elif isinstance(node, dict):
        for k, v in node.items():
            if not str(k).startswith("_"):
                _walk_strings(v, out)
    elif isinstance(node, list):
        for v in node:
            _walk_strings(v, out)


def _query_state_keys(query, out: set[str]) -> None:
    if not isinstance(query, dict):
        return
    st = query.get("state")
    if isinstance(st, dict):
        for k in st:
            if not str(k).startswith("_"):
                out.add(_strip_op(str(k)))
    for k, v in query.items():
        if isinstance(v, dict) and not str(k).startswith("_"):
            _query_state_keys(v, out)


def _queries_engine(rule: dict) -> bool:
    q = rule.get("query")
    return isinstance(q, dict) and "_engine" in (q.get("tags_all") or [])


def _effects(rule: dict) -> list[dict]:
    eff = rule.get("effect", [])
    if isinstance(eff, dict):
        return [eff]
    return [e for e in eff if isinstance(e, dict)] if isinstance(eff, list) else []


def parse_rules(game_dir: Path) -> list[Rule]:
    rules: list[Rule] = []
    for path in find_rule_files(game_dir):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        rel = str(path.relative_to(game_dir))
        for r in doc.get("rules", []):
            if not isinstance(r, dict):
                continue
            trig = r.get("trigger", {}) or {}
            ttype = str(trig.get("type", "?"))
            sig_in = str(trig.get("name", "")) if ttype == "signal" else None

            sigs_out, writes, wworld = [], set(), set()
            for e in _effects(r):
                et = str(e.get("type", ""))
                if et == "emit":
                    n = str(e.get("signal", ""))
                    if n:
                        sigs_out.append(n)
                if et == "level_call":
                    # ADR 0077 fires `return_signal` on the way BACK, so this
                    # rule produces it even though no `emit` appears here. The
                    # tool reported delve_done as consumer-only until this was
                    # added — its first finding was about itself.
                    n = str(e.get("return_signal", ""))
                    if n:
                        sigs_out.append(n)
                if et in WRITERS:
                    fname = str(e.get("field", ""))
                    if fname:
                        tgt = str(e.get("target", "self"))
                        # `target: self` on a rule that QUERIED `_engine` is a
                        # world-state write: per ADR 0047 that entity's state IS
                        # world_state. Missing this made the eight cal_season_N
                        # rules look like they wrote nothing, so `cal_season`
                        # reported as read-with-no-writer.
                        is_world = tgt in ("world", "_engine") or (
                            tgt == "self" and _queries_engine(r))
                        (wworld if is_world else writes).add(fname)

            strings: list[str] = []
            _walk_strings({"effect": r.get("effect"), "query": r.get("query"),
                           "require": r.get("require")}, strings)
            refs: set[tuple[str, str]] = set()
            for s in strings:
                for m in REF.finditer(s):
                    refs.add((m.group(1), m.group(2)))

            reads: set[str] = set()
            _query_state_keys(r.get("query"), reads)
            _query_state_keys(r.get("require"), reads)

            wreads = {p.split(".")[0] for b, p in refs if b == "world"}

            rules.append(Rule(
                id=str(r.get("id", "?")), file=rel, trigger=ttype, signal_in=sig_in,
                signals_out=sigs_out, bindings=compute_context_bindings(r),
                refs=refs, reads=reads, writes=writes,
                world_reads=wreads, world_writes=wworld, raw=r,
            ))
    return rules


def parse_ui_bindings(game_dir: Path) -> dict[str, list[str]]:
    """`binds` / substituted row refs in screens.json + hud.json.

    UI is the reader everyone forgets. `state.facing` and the whole
    `target=world` class shipped because a field's only consumer was a screen,
    or was nobody at all — and no rule file mentions either fact.
    """
    out: dict[str, list[str]] = {}
    for name in ("screens.json", "hud.json", "ui/hud.json"):
        p = game_dir / name
        if not p.exists():
            continue
        strings: list[str] = []
        try:
            _walk_strings(json.loads(p.read_text(encoding="utf-8")), strings)
        except Exception:
            continue
        for s in strings:
            for m in REF.finditer(s):
                root, path = m.group(1), m.group(2)
                out.setdefault(f"{root}.{path}", []).append(name)
    return out


def parse_entities(game_dir: Path) -> dict[str, dict]:
    defs: dict[str, dict] = {}
    for p in sorted(game_dir.glob("entities/*.json")) + [game_dir / "entities.json"]:
        if not p.exists():
            continue
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        for d in doc.get("definitions", []):
            if isinstance(d, dict) and d.get("id"):
                defs[str(d["id"])] = d
    return defs


def world_state_fields(game_dir: Path) -> set[str]:
    p = game_dir / "world" / "state.json"
    if not p.exists():
        return set()
    try:
        st = json.loads(p.read_text(encoding="utf-8")).get("state", {})
    except Exception:
        return set()
    return {k for k in st if not str(k).startswith("_")}


def analyze(game: str) -> dict:
    game_dir = DATA / game
    rules = parse_rules(game_dir)
    ui = parse_ui_bindings(game_dir)
    defs = parse_entities(game_dir)
    ws_declared = world_state_fields(game_dir)

    # ---- signal graph -------------------------------------------------
    producers: dict[str, list[str]] = {}
    consumers: dict[str, list[str]] = {}
    for r in rules:
        for s in r.signals_out:
            producers.setdefault(s, []).append(r.id)
        if r.signal_in:
            consumers.setdefault(r.signal_in, []).append(r.id)

    # Signals a BUTTON emits — a screen is a producer too, and the most common
    # one in a menu-driven game. A signal with only UI producers is normal; one
    # with no consumer at all is the "clicked and nothing happened" bug.
    ui_emits: dict[str, list[str]] = {}
    for name in ("screens.json", "hud.json"):
        p = game_dir / name
        if not p.exists():
            continue
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue

        def _scan(node):
            if isinstance(node, dict):
                if str(node.get("type", "")) == "emit" and node.get("signal"):
                    ui_emits.setdefault(str(node["signal"]), []).append(name)
                for v in node.values():
                    _scan(v)
            elif isinstance(node, list):
                for v in node:
                    _scan(v)
        _scan(doc)

    signals = []
    for s in sorted(set(producers) | set(consumers) | set(ui_emits)):
        signals.append({
            "name": s,
            "rule_producers": sorted(producers.get(s, [])),
            "ui_producers": sorted(set(ui_emits.get(s, []))),
            "consumers": sorted(consumers.get(s, [])),
        })

    # ---- world-state field graph ---------------------------------------
    ws_writers: dict[str, list[str]] = {}
    ws_readers: dict[str, list[str]] = {}
    for r in rules:
        for f in r.world_writes:
            ws_writers.setdefault(f, []).append(r.id)
        for f in r.world_reads:
            ws_readers.setdefault(f, []).append(r.id)
    for ref, where in ui.items():
        if ref.startswith("world."):
            f = ref[len("world."):].split(".")[0]
            ws_readers.setdefault(f, []).extend(where)
    # A query on `_engine` reads WORLD state — but only that query's own state
    # keys. Folding in `require` too (the first version did) misfiled the
    # player's `stamina`, read via require on `actor`, as a world field.
    for r in rules:
        if not _queries_engine(r.raw):
            continue
        own: set[str] = set()
        _query_state_keys(r.raw.get("query"), own)
        for f in own:
            ws_readers.setdefault(f, []).append(r.id)

    wfields = []
    for f in sorted(set(ws_writers) | set(ws_readers) | ws_declared):
        w = sorted(set(ws_writers.get(f, [])))
        rd = sorted(set(ws_readers.get(f, [])))
        wfields.append({
            "name": f, "writers": w, "readers": rd,
            "declared": f in ws_declared,
            "engine_written": f in ENGINE_WRITTEN,
            # Read with no writer is only interesting when the value is expected
            # to CHANGE. A field declared in world/state.json and never written
            # is a tuned constant (trust_gain_drink, cal_display_offset); one the
            # engine writes is not the content's job.
            "orphan_read": bool(rd) and not w and f not in ENGINE_WRITTEN and f not in ws_declared,
            # Written and read by nobody is always worth surfacing: the effect
            # runs, the number moves, and nothing in the game can ever see it.
            "orphan_write": bool(w) and not rd,
        })

    # ---- binding check --------------------------------------------------
    binding_issues = []
    for r in rules:
        unknown = sorted({b for b, _ in r.refs
                          if b not in r.bindings and b not in GLOBAL_ROOTS
                          and b not in defs and not b.startswith("_")})
        if unknown:
            binding_issues.append({"rule": r.id, "file": r.file,
                                   "trigger": r.trigger,
                                   "available": sorted(r.bindings),
                                   "unknown": unknown})

    return {
        "game": game,
        "rules": rules,
        "signals": signals,
        "world_fields": wfields,
        "binding_issues": binding_issues,
        "defs": defs,
        "ui_refs": ui,
    }
