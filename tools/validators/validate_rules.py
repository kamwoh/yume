#!/usr/bin/env python3
"""
Static contract enforcer for rule JSON (#100, 2026-05-16).

Walks every world/rules.json + game/goals.json + levels/*/rules.json under
a game's data folder and checks rules against the contract that today
lives only in prose in `.claude/rules/data-demo.md`. Catches at sync time
the bug classes that previously only surfaced at live-play.

Checks implemented in v1:

  (1) FORMULA-BINDING MISMATCH — a formula like `actor.state.X` in a rule
      whose context doesn't bind `actor`. Empirical: incident-1 of the
      2026-05-16 gather_pickup crash. The formula evaluator can't soft-
      fail on an unbound identifier; it crashes with the misleading
      "self can't be used because instance is null" message.

  (4) EMPTY-EFFECT RULE — `"effect": []` is a hard load-time error in
      the engine. Empirical: Aldenmere bgm_proto_village placeholder.

  (6) ENGINE-INJECTED INPUT MARKER — actions in ui/input.json without a
      `key` (engine queues them internally) MUST set
      `"engine_injected": true` or InputRegistrar warns + skips.

  (7) 2-BINDING NON-CONTACT QUERIES — query `{a: {...}, b: {...}, radius}`
      is only pair-matched on `trigger: "contact"`. Tick / signal / input
      rules with the same shape fire as a single-entity scan; the second
      binding never resolves. Empirical: 15 Aldenmere rules from
      systems-designer's first pass.

  (8) SCHEMA FIELD-NAME LANDMINES — `state_add` / `state_mul` must use
      `amount` (not `delta` / `factor`). `spawn` must use `template`
      (not `def`). Engine silently no-ops on the wrong field name.

  (9) REQUIRED EFFECT FIELDS — `tag_add` / `tag_remove` need `tag`,
      `state_*` need `field` (and `amount`), `spawn` needs `template`.
      Empirical 2026-10-16: aldenmere used `"tags": [...]`.

  (10) UNKNOWN EFFECT FIELDS — a key that the effect's handler never
      reads (schema from api-manifest.json). Empirical 2026-10-16:
      aldenmere `formula_x` on velocity_set, `state` on spawn.

  (11) QUERY FIELD NOBODY DEFINES — a query `state` or `properties` key
      names a field that no def, instance, spawn or effect in the game
      defines. Queries are strict (missing field = no match), so the
      clause never matches. The engine's operator suffixes come from
      query.gd. Empirical 2026-10-16: demo_lanterns `collected_ge` (the
      suffix is `_gte`), so the win rule never fired.


Future v2 additions (deferred per data-demo.md):
  - Destructive effect-chain ordering (transition_level / reload_scene
    must be LAST in chain).
  - Modal-pop screen_fade pairing (alpha=1.0 must pair with alpha=0.0
    somewhere downstream).
  - Sync-derived field state_init coverage (tick rules writing X that
    is later used as a filter must have X in entity state_init).

Usage:
    python3 tools/validate_rules.py                 # all demos
    python3 tools/validate_rules.py demo_aldenmere  # one game
    python3 tools/validate_rules.py --strict        # exit 1 on any fail

Exit code:
    0 — clean (or only warnings in non-strict mode)
    1 — at least one violation in --strict mode

Wired into scripts/play.sh as a pre-launch gate (non-blocking by default;
SKIP_VALIDATE=1 to bypass). Agents + CI should pass --strict.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from content import resolver, rule_files  # noqa: E402

# ============================================================
# CONTEXT BINDING RESOLUTION — what bindings does each trigger expose?
# ============================================================

# Roots that are always available in formula context regardless of trigger.
GLOBAL_ROOTS = {
    "world",        # env.world_state dict
    "zone",         # ADR 0031 zone snapshot
    "signal",       # legacy/payload alias for signal-rule payload (some rules use it)
    "_phase",       # phase scheduler tag
    "_rule_id",     # rule attribution
}

# Math/lib symbols that look like dotted paths but aren't bindings —
# the formula evaluator handles them via Godot's Expression engine.
# These never appear as ROOT.X paths; they're standalone function calls.
# We don't need to list them because the regex only matches a root
# followed by `.field` — `clamp(...)` doesn't trip it.

# Per-trigger default bindings (when query/require don't override).
TRIGGER_DEFAULTS = {
    "tick":            {"self"},          # query.tags_all → self bound to each match
    "input":           {"self", "actor"}, # input_registrar sets actor=player_id
    "signal":          set(),             # bindings come from require or query
    "contact":         {"a", "b"},        # engine pair-matches
    "overlap":         {"a", "b"},        # ADR 0070 — physics area pair (a=area, b=body)
    "spawn":           {"self"},
    "despawn":         {"self"},
    "relation_changed": {"from", "to"},
}


# Bindings that the engine populates implicitly per trigger type.
# require: keys MUST come from this set ∪ query's named bindings — otherwise
# the require validates against a binding the engine never sets, which
# means require ALWAYS fails and the rule never fires (silent no-op).
#
# Signal is the exception: require's keys DECLARE which payload fields to
# bind, so any name is acceptable. Empirical anti-pattern documented in
# .claude/rules/data-demo.md § query vs require — they are NOT
# interchangeable.
REQUIRE_ENGINE_BINDINGS = {
    "tick":             {"self"},
    "input":            {"self", "actor"},
    "contact":          {"a", "b", "self"},
    "overlap":          {"a", "b", "self"},
    "spawn":            {"self"},
    "despawn":          {"self"},
    "relation_changed": {"from", "to", "self"},
    # "signal" intentionally omitted — see _check_require_bindings.
}


def collect_query_bindings(query):
    """Given a `query:` dict, return the set of named sub-bindings.

    Flat queries (`{tags_all: [...]}`, `{state: {...}}`, etc.) → `{self}`.
    Multi-binding queries (`{a: {...}, b: {...}, radius: N}`) → `{a, b}`.

    The distinguisher is whether any top-level key is a FILTER STATEMENT
    (tags_all/tags_none/state/props/tags_any/near) — those mean the query
    operates on `self` directly. If only NAMED sub-binding dicts plus
    pair-modifiers (radius/order_by/limit/once_per_a/etc.) are present,
    it's a multi-binding query.
    """
    if not isinstance(query, dict):
        return set()
    # These keys signal a FLAT query — direct filters on `self`.
    flat_filter_keys = {"tags_all", "tags_none", "tags_any", "state",
                        "props", "props_none", "near"}
    if any(k in flat_filter_keys for k in query.keys()):
        return {"self"}
    # Otherwise: top-level keys are either NAMED sub-bindings (a, b,
    # actor, target, ...) OR pair-modifiers (radius, order_by, limit,
    # once_per_a, etc.). Filter the modifiers out.
    pair_modifiers = {"radius", "order_by", "limit", "once_per_a",
                      "once_per_b", "chance"}
    return {k for k in query.keys()
            if not k.startswith("_") and k not in pair_modifiers}


def collect_require_bindings(require):
    """Require: dict has top-level keys that are binding names."""
    if not isinstance(require, dict):
        return set()
    return {k for k in require.keys() if not k.startswith("_")}


def compute_context_bindings(rule):
    """Return the set of binding names a formula in this rule can use."""
    bindings = set(GLOBAL_ROOTS)

    trigger = rule.get("trigger", {})
    if isinstance(trigger, dict):
        t_type = str(trigger.get("type", ""))
        # Default bindings for this trigger type
        bindings |= TRIGGER_DEFAULTS.get(t_type, set())

    # query: may override (flat → self, named → a/b/etc.)
    query = rule.get("query")
    if query is not None:
        q_bindings = collect_query_bindings(query)
        # If named query, drop the default `self` — only the named
        # bindings are valid in this case.
        if q_bindings and q_bindings != {"self"}:
            bindings.discard("self")
        bindings |= q_bindings

    # require: adds bindings for signal-driven rules
    require = rule.get("require")
    if require is not None:
        bindings |= collect_require_bindings(require)

    return bindings


# ============================================================
# FORMULA EXTRACTION — find dotted-path bindings inside effect dicts
# ============================================================

# Mirror Formula.looks_like_formula heuristic (godot/scripts/engine/core/
# formula.gd): starts with lowercase/digit/_/@/(/+/- AND contains an
# operator char (./+/-/*/// ( )). For binding-root extraction we only
# care about strings with `.` and a lowercase-start root.
#
# Capture ONLY the LEADING root of a FULL dotted chain, and consume the
# WHOLE chain (one-or-more `.field`) so we don't re-match mid-path. 2026-06-06:
# the old `(root)\.(field)` pair-regex matched `self.state` THEN `position.x`
# on `self.state.position.x`, flagging the middle segment `position` as an
# unbound binding (68 false positives on doomarena3d's projectile formulas;
# every demo using `self.state.position.x` tripped it). Only the leading
# token is a binding root; the rest are field accesses.
FORMULA_ROOT_RE = re.compile(r"\b([a-z_][A-Za-z0-9_]*)(?:\.[A-Za-z0-9_]+)+")


def is_formula_str(s):
    """Mirror Formula.looks_like_formula's start-char + operator check."""
    if not isinstance(s, str) or not s:
        return False
    first = s[0]
    if not (first.islower() or first.isdigit() or first in "_+-(@"):
        return False
    # `@cues.X` / `@strings.X` are indirection refs, not formulas.
    if first == "@":
        return False
    # Must contain a dotted path OR an operator.
    return any(ch in s for ch in ".+-*/()")


# Keys whose VALUES are literal text, not formulas — skip when scanning
# for formula references. Comment keys (_*) are skipped wholesale. Text-
# style fields (show_toast text, display strings, ids, tag lists) carry
# human prose that may incidentally look formula-shaped.
LITERAL_TEXT_KEYS = {
    "text", "message", "name", "id", "tags", "tags_all", "tags_none",
    "tags_any", "signal", "action", "screen", "target_screen", "event",
    "icon", "color", "bg_color", "bg_active_color", "border_color",
    "border_active_color", "text_color", "index_color", "cell_format",
    "empty_text", "index_format", "format",
}


def find_formula_roots(value, key=None):
    """Yield (root_binding_name, formula_string) for every formula
    reference in `value`. Recurses into dicts + lists. Skips:
      - keys starting with `_` (comment convention)
      - values under known literal-text keys
    Returns nothing for non-formula strings.
    """
    if key is not None and isinstance(key, str):
        if key.startswith("_"):
            return
        if key in LITERAL_TEXT_KEYS:
            return
    if isinstance(value, str):
        if is_formula_str(value):
            for m in FORMULA_ROOT_RE.finditer(value):
                yield m.group(1), value
    elif isinstance(value, dict):
        for k, v in value.items():
            yield from find_formula_roots(v, key=k)
    elif isinstance(value, list):
        for v in value:
            yield from find_formula_roots(v, key=key)


# ============================================================
# CHECKS
# ============================================================


def check_formula_bindings(rule, errors):
    """(1) Every formula's root binding must be in the rule's context."""
    bindings = compute_context_bindings(rule)
    rule_id = rule.get("id", "<unnamed>")
    effects = rule.get("effect", [])
    if isinstance(effects, dict):
        effects = [effects]
    if not isinstance(effects, list):
        return
    for i, eff in enumerate(effects):
        if not isinstance(eff, dict):
            continue
        for root, formula in find_formula_roots(eff):
            if root in bindings:
                continue
            errors.append((
                rule_id,
                f"effect[{i}]",
                f"formula references unbound `{root}` in '{formula}'. "
                f"Rule's available bindings: {sorted(bindings)}. "
                f"Check trigger type vs query/require shape.",
            ))


def check_empty_effects(rule, errors):
    """(4) `effect: []` crashes _load_rules_file with rule.effect_empty."""
    rule_id = rule.get("id", "<unnamed>")
    eff = rule.get("effect", None)
    if eff is None:
        errors.append((rule_id, "effect", "rule has no `effect` field"))
    elif isinstance(eff, list) and len(eff) == 0:
        errors.append((
            rule_id, "effect",
            "rule has empty `effect: []` — engine will error at load. "
            "Delete the rule if it's a no-op, or add a placeholder effect.",
        ))


def check_effect_read_after_write(rule, errors):
    """(2026-05-27) Order hazard: an effect whose `value` formula reads
    `self.state.X` while ANOTHER state_set in the SAME effect list writes
    field X. Effect-resolution order can evaluate the formula AFTER the
    write, so it reads the just-written value, not the prior one.

    Empirical: the free-cam toggle saved
      previous_camera_mode = "self.state.camera_mode"
    in the same list that set camera_mode = "free_cam". previous got
    saved as "free_cam" → exit restored free_cam → stuck in free-cam.
    Fix: save a LITERAL value, not a formula reading a CO-written field.

    EXCEPTION (2026-06-09): an effect reading its OWN field is SAFE — a
    self-referential toggle like `state_set cam_ortho = "1 - self.state.
    cam_ortho"` evaluates the value BEFORE the write (effect_core.state_set:
    value = EffectResolution.value(...) THEN set_state(...)). So this is the
    canonical single-key on/off toggle, NOT a hazard. Only flag a formula
    reading a field that a DIFFERENT effect in the list writes.
    """
    rule_id = rule.get("id", "<unnamed>")
    eff = rule.get("effect", None)
    effects = eff if isinstance(eff, list) else ([eff] if isinstance(eff, dict) else [])
    # Field each effect writes (parallel to `effects`; None if it writes none).
    writes = [
        str(e.get("field")) if (isinstance(e, dict)
            and e.get("type") in ("state_set", "state_add", "state_mul")
            and "field" in e) else None
        for e in effects
    ]
    if not any(w is not None for w in writes):
        return
    for idx, e in enumerate(effects):
        if not isinstance(e, dict):
            continue
        val = e.get("value")
        if not (isinstance(val, str) and is_formula_str(val)):
            continue
        # Fields written by OTHER effects in the list (NOT this one — reading
        # your own field is computed pre-write, hence the self-toggle is safe).
        written_by_others = {writes[j] for j in range(len(effects))
                             if j != idx and writes[j] is not None}
        for f in written_by_others:
            # match `<binding>.state.<f>` (self.state.f, actor.state.f, …)
            if re.search(r"\.state\." + re.escape(f) + r"\b", val):
                errors.append((
                    rule_id, e.get("field", "?"),
                    f"value formula '{val}' reads .state.{f} while another "
                    f"effect in the same list writes '{f}' — order-dependent. "
                    f"Use a literal value (the just-written value may be read "
                    f"instead of the prior one). See free-cam toggle "
                    f"post-mortem 2026-05-27.",
                ))


def check_require_bindings(rule, errors):
    """(7b — 2026-05-20) `require:` keys MUST match a binding the engine
    actually populates for this trigger type, OR a named sub-binding in
    `query`. Otherwise the require validates ctx[name] which is null →
    require ALWAYS fails → rule never fires (silent no-op).

    Empirical case 2026-05-20: `player_jump` rule shipped with
        require: {clock: {tags_all: [world_clock], state: {camera_mode_in: ...}}}
    The intent was to filter on world_clock's camera_mode. But the
    engine never binds ctx["clock"] for input triggers (it binds
    "actor", and the query's `self`). require failed every time;
    Space pressed → nothing happened. User caught it.

    The fix-pattern: put the world_clock check in `query` (which makes
    self=world_clock), and use require for ACTOR-state filters (since
    `actor` IS bound by input_registrar).

    Signal triggers are exempt — `require: {<payload_field>: ...}`
    DECLARES bindings from the signal's payload, so any key is legal.
    """
    rule_id = rule.get("id", "<unnamed>")
    trigger = rule.get("trigger", {})
    t_type = trigger.get("type", "") if isinstance(trigger, dict) else ""
    require = rule.get("require")
    if not isinstance(require, dict):
        return
    # Signal: require KEYS declare payload bindings — anything goes.
    if t_type == "signal":
        return
    allowed_from_engine = REQUIRE_ENGINE_BINDINGS.get(t_type, set())
    allowed_from_query = collect_query_bindings(rule.get("query", {}))
    allowed = allowed_from_engine | allowed_from_query
    for key in require.keys():
        if key.startswith("_"):
            continue
        if key in allowed:
            continue
        errors.append((
            rule_id, "require",
            f"`require: {{{key}: ...}}` — binding `{key}` is never set "
            f"by the engine for trigger `{t_type}` and is not a named "
            f"sub-binding in this rule's `query`. The require will "
            f"validate ctx['{key}']=null and ALWAYS FAIL → rule never "
            f"fires (silent no-op). Allowed bindings for `{t_type}`: "
            f"{sorted(allowed) or '(none — check trigger type)'}. To "
            f"filter on a singleton's state, move it to `query` (e.g. "
            f"`query: {{tags_all: ['world_clock'], state: {{X_eq: Y}}}}` "
            f"makes `self`=world_clock). See .claude/rules/data-demo.md "
            f"§ query vs require — they are NOT interchangeable.",
        ))


def check_2binding_non_contact(rule, errors):
    """(7) `{a: {...}, b: {...}}` queries fire as scan rules on non-contact
    triggers, leaving `b` unbound. Only `contact` does pair-matching."""
    rule_id = rule.get("id", "<unnamed>")
    trigger = rule.get("trigger", {})
    t_type = trigger.get("type", "") if isinstance(trigger, dict) else ""
    query = rule.get("query")
    if not isinstance(query, dict):
        return
    if t_type in ("contact", "overlap"):
        return
    sub_bindings = collect_query_bindings(query)
    if len(sub_bindings) >= 2 and sub_bindings != {"self"}:
        errors.append((
            rule_id, "query",
            f"trigger `{t_type}` has multi-binding query "
            f"({sorted(sub_bindings)}) — only `contact` triggers pair-match. "
            f"Collapse to single-binding query OR change trigger to contact.",
        ))


def check_schema_field_landmines(rule, errors):
    """(8) state_add/state_mul use `amount`; spawn uses `template`."""
    rule_id = rule.get("id", "<unnamed>")
    effects = rule.get("effect", [])
    if isinstance(effects, dict):
        effects = [effects]
    if not isinstance(effects, list):
        return
    for i, eff in enumerate(effects):
        if not isinstance(eff, dict):
            continue
        t = str(eff.get("type", ""))
        if t in ("state_add", "state_mul"):
            if "amount" not in eff and ("delta" in eff or "factor" in eff):
                wrong = "delta" if "delta" in eff else "factor"
                errors.append((
                    rule_id, f"effect[{i}]",
                    f"{t} effect uses `{wrong}` — engine reads `amount`. "
                    f"Rename `{wrong}` → `amount`.",
                ))
        elif t == "spawn":
            if "template" not in eff and "def" in eff:
                errors.append((
                    rule_id, f"effect[{i}]",
                    "spawn effect uses `def` — engine reads `template`. "
                    "Rename `def` → `template`.",
                ))
        # ADR 0075 — relation state. Same landmine class as state_add: the
        # engine reads `amount`, and a `delta` silently applies nothing.
        # `relation` (not `type`/`rel`) names the edge type, matching the
        # existing relate/unrelate/transfer_relation effects.
        elif t in ("relation_set", "relation_add", "relation_clamp"):
            if "relation" not in eff:
                wrong = next((k for k in ("type_name", "rel", "relation_type") if k in eff), None)
                hint = f" Rename `{wrong}` → `relation`." if wrong else ""
                errors.append((
                    rule_id, f"effect[{i}]",
                    f"{t} effect has no `relation` field — engine reads `relation` "
                    f"to name the edge type (same as relate/unrelate).{hint}",
                ))
            if "field" not in eff:
                errors.append((
                    rule_id, f"effect[{i}]",
                    f"{t} effect has no `field` — nothing on the edge would be written.",
                ))
            if t == "relation_add" and "amount" not in eff and "delta" in eff:
                errors.append((
                    rule_id, f"effect[{i}]",
                    "relation_add effect uses `delta` — engine reads `amount`. "
                    "Rename `delta` → `amount`.",
                ))
            if t == "relation_clamp" and "min" not in eff and "max" not in eff:
                errors.append((
                    rule_id, f"effect[{i}]",
                    "relation_clamp effect has neither `min` nor `max` — it is a no-op.",
                ))


# (9) Fields without which an effect does nothing. The engine reads one
# name only, so another name (or a list form) is a silent no-op.
# Empirical 2026-10-16: 12 aldenmere tag_add/tag_remove effects used
# `"tags": [...]`. The engine reads `tag`, so the warmth, fire and
# building chains never changed a tag.
REQUIRED_EFFECT_FIELDS = {
    "tag_add": ("tag",),
    "tag_remove": ("tag",),
    "state_set": ("field",),
    "state_add": ("field", "amount"),
    "state_mul": ("field", "amount"),
    "spawn": ("template",),
}
WRONG_FIELD_NAMES = {"tag": ("tags",), "amount": ("delta", "factor"), "template": ("def",)}


def check_required_effect_fields(rule, errors):
    """(9) Each effect type in REQUIRED_EFFECT_FIELDS has its fields."""
    rule_id = rule.get("id", "<unnamed>")
    effects = rule.get("effect", [])
    if isinstance(effects, dict):
        effects = [effects]
    if not isinstance(effects, list):
        return
    for i, eff in enumerate(effects):
        if not isinstance(eff, dict):
            continue
        t = str(eff.get("type", ""))
        for field in REQUIRED_EFFECT_FIELDS.get(t, ()):
            if field in eff:
                continue
            wrong = next((w for w in WRONG_FIELD_NAMES.get(field, ()) if w in eff), None)
            if wrong is not None and t in ("state_add", "state_mul", "spawn"):
                continue  # check (8) already reports this rename
            hint = f" Rename `{wrong}` to `{field}`." if wrong else ""
            if wrong == "tags":
                hint = " Use one effect per tag, each with one `tag` string."
            errors.append((
                rule_id, f"effect[{i}]",
                f"{t} effect has no `{field}`. The engine reads `{field}`, "
                f"so the effect does nothing.{hint}",
            ))


# (10) Fields the engine never reads (batch G, 2026-10-16). The schema
# comes from docs/engine-reference/api-manifest.json, which
# gen_api_manifest.py derives from the effect handlers. An effect with an
# open field set (it passes the dict on) is skipped.
# Empirical 2026-10-16: aldenmere used `formula_x` / `formula_z` on
# velocity_set (the engine reads `x` / `z`) and `state` on spawn (the
# engine reads `overrides.state`). Rabbits never fled, deer never walked,
# and spawned carcasses had no food.
_MANIFEST = Path(__file__).resolve().parents[2] / "docs" / "engine-reference" / "api-manifest.json"
try:
    EFFECT_SCHEMA = {
        e["type"]: e for e in json.loads(_MANIFEST.read_text(encoding="utf-8")).get("effects", [])
    }
except (OSError, json.JSONDecodeError):
    EFFECT_SCHEMA = {}


def check_unknown_effect_fields(rule, errors):
    """(10) Each effect key is one its handler reads."""
    rule_id = rule.get("id", "<unnamed>")
    effects = rule.get("effect", [])
    if isinstance(effects, dict):
        effects = [effects]
    if not isinstance(effects, list):
        return
    for i, eff in enumerate(effects):
        if not isinstance(eff, dict):
            continue
        spec = EFFECT_SCHEMA.get(str(eff.get("type", "")))
        if spec is None or spec.get("open", True):
            continue
        known = set(spec.get("fields", []))
        for k in eff:
            if k == "type" or str(k).startswith("_") or k in known:
                continue
            errors.append((
                rule_id, f"effect[{i}]",
                f"{eff['type']} effect has `{k}`, which the engine never reads, so it "
                f"does nothing. The engine reads: {', '.join(sorted(known)) or 'no fields'}.",
            ))


_QUERY_GD = Path(__file__).resolve().parents[2] / "godot" / "scripts" / "engine" / "core" / "query.gd"
_SUFFIX_BLOCK = re.search(r"OPERATOR_SUFFIXES: Array = \[(.*?)\]", _QUERY_GD.read_text(encoding="utf-8"), re.S)
QUERY_SUFFIXES = re.findall(r'"(_\w+)"', _SUFFIX_BLOCK.group(1)) + ["_has", "_in"]
# Fields the engine itself writes on entities (core/entity.gd, physics runners).
ENGINE_STATE_FIELDS = {"position", "velocity", "age", "facing", "pitch", "y_velocity", "on_floor"}
STATE_EFFECTS = ("state_set", "state_add", "state_mul", "state_clamp", "state_toggle")


def _strip_suffix(key: str) -> str:
    """The field a query key reads, as core/query.gd::_match_fields parses it."""
    for suffix in QUERY_SUFFIXES:
        if key.endswith(suffix):
            return key[: -len(suffix)]
    return key


def collect_defined_fields(game_dir: Path) -> dict:
    """Every state and property field that some file in the game (or a
    bundle it includes) defines. Returns {"state": set, "properties": set}."""
    out = {"state": set(ENGINE_STATE_FIELDS), "properties": set()}
    res = resolver()

    def walk(node, parent_key=""):
        if isinstance(node, dict):
            for k, v in node.items():
                if k in ("state_init", "overrides") or (k == "state" and parent_key != "query_spec"):
                    if isinstance(v, dict):
                        out["state"].update(v.get("state", {}).keys() if k == "overrides" else v.keys())
                if k == "properties" and parent_key != "query_spec" and isinstance(v, dict):
                    out["properties"].update(v.keys())
                if k == "field" and isinstance(v, str) and node.get("type") in STATE_EFFECTS:
                    out["state"].add(v.split(".", 1)[0])
                # Query specs read fields. They never define them.
                child_key = "query_spec" if k in ("query", "a", "b", "when", "match") else k
                walk(v, child_key)
        elif isinstance(node, list):
            for item in node:
                walk(item, parent_key)

    for f in sorted(game_dir.rglob("*.json")):
        if "_snapshots" in f.parts or f.name == "tests.json":
            continue
        try:
            walk(res.resolve(json.loads(f.read_text(encoding="utf-8"))))
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
    return out


def check_query_fields_defined(rule, errors, defined):
    """(11) Each query state/properties key names a field the game defines."""
    rule_id = rule.get("id", "<unnamed>")

    def visit(spec, where):
        if not isinstance(spec, dict):
            return
        for clause in ("state", "properties"):
            fields = spec.get(clause)
            if not isinstance(fields, dict):
                continue
            for key in fields:
                if str(key).startswith("_"):
                    continue
                field = _strip_suffix(str(key))
                if field not in defined[clause]:
                    hint = ""
                    if field == key and "_" in key:
                        hint = f" If `_{key.rsplit('_', 1)[1]}` is an operator, use one of: {', '.join(QUERY_SUFFIXES)}."
                    errors.append((
                        rule_id, f"{where}.{clause}.{key}",
                        f"the query reads `{field}`, but no def, instance, spawn or effect "
                        f"in this game defines it, so this clause never matches.{hint}",
                    ))
        for sub in ("a", "b"):
            visit(spec.get(sub), f"{where}.{sub}")

    visit(rule.get("query"), "query")
    effects = rule.get("effect", [])
    for i, eff in enumerate(effects if isinstance(effects, list) else [effects]):
        if isinstance(eff, dict):
            visit(eff.get("query"), f"effect[{i}].query")


def check_once_fields(rule, errors):
    """ADR 0080 — the one-shot quantifiers.

    (a) `once` + `once_per` together is meaningless; the engine raises
        rule.once_conflict at load, and catching it here moves the failure
        to author time.
    (b) `once_per` must name a binding the TRIGGER actually populates. If it
        doesn't, `_claim_once` finds an empty subject and degrades to
        always-fire — i.e. the author writes a one-shot rule and silently
        gets an every-tick rule. Same binding table the formula check uses.
    """
    rule_id = rule.get("id", "<unnamed>")
    once = bool(rule.get("once", False))
    once_per = str(rule.get("once_per", "") or "")

    if once and once_per:
        errors.append((
            rule_id, "once_per",
            "rule has both `once` and `once_per` — pick one. `once` = at most "
            "once per world lifetime; `once_per: <binding>` = at most once per "
            "distinct entity bound to that name.",
        ))
        return

    if once_per:
        available = compute_context_bindings(rule)
        if once_per not in available:
            errors.append((
                rule_id, "once_per",
                f"`once_per: {once_per}` names a binding this trigger never "
                f"populates (available: {sorted(available)}). The engine finds "
                f"no subject and falls back to firing EVERY time — the rule "
                f"silently stops being one-shot.",
            ))


def check_scope_vs_presentation(rule, errors):
    """ADR 0079 — a rule scoped `abstract` must not use presentation effects.

    An abstract-tier entity is defined as one that does not need a body.
    Driving `velocity_*` / `pathfind_to` / `raycast_hit` on it is therefore
    incoherent, and it fails QUIETLY: the effect applies to state nothing is
    reading, so the author sees no movement and no error.

    Also catches an unrecognised `scope` value, which falls back to firing on
    both tiers — i.e. the author intends a tier filter and silently gets none.
    """
    rule_id = rule.get("id", "<unnamed>")
    scope = str(rule.get("scope", "") or "")
    if not scope:
        return
    if scope not in ("abstract", "embodied"):
        errors.append((
            rule_id, "scope",
            f"`scope: {scope}` is not a tier — use \"abstract\" or \"embodied\". "
            f"An unrecognised value falls back to firing on BOTH tiers, so the "
            f"filter the author intended silently does nothing.",
        ))
        return
    if scope != "abstract":
        return

    presentation = {
        "velocity_set", "velocity_lerp", "velocity_set_relative",
        "velocity_add_relative", "pathfind_to", "raycast_hit",
    }
    effects = rule.get("effect", [])
    if isinstance(effects, dict):
        effects = [effects]
    if not isinstance(effects, list):
        return
    for i, eff in enumerate(effects):
        if not isinstance(eff, dict):
            continue
        t = str(eff.get("type", ""))
        if t in presentation:
            errors.append((
                rule_id, f"effect[{i}]",
                f"`{t}` is a presentation effect but this rule is "
                f"`scope: \"abstract\"` — abstract-tier entities are defined as "
                f"not needing a body, so this applies to state nothing reads and "
                f"fails silently. Scope it \"embodied\", or express the movement "
                f"as a state change.",
            ))


def check_edge_state_clause(rule, errors):
    """ADR 0075 — the reserved `_edge` key inside a `relations` query clause
    must be a dict of field filters. A non-dict `_edge` is silently ignored by
    Query._check_single_relation, so the rule matches MORE entities than the
    author intended (the edge filter just vanishes) — exactly the silent-widen
    failure mode this validator bank exists to catch.
    """
    rule_id = rule.get("id", "<unnamed>")

    def walk(node, path):
        if isinstance(node, dict):
            rels = node.get("relations")
            if isinstance(rels, dict):
                for rel_type, target in rels.items():
                    if isinstance(target, dict) and "_edge" in target:
                        if not isinstance(target["_edge"], dict):
                            errors.append((
                                rule_id, f"{path}.relations.{rel_type}._edge",
                                "`_edge` must be a dict of field filters "
                                "(e.g. {\"trust_gte\": 60}); a non-dict is "
                                "silently ignored and the edge filter vanishes.",
                            ))
            for k, v in node.items():
                walk(v, f"{path}.{k}")
        elif isinstance(node, list):
            for idx, v in enumerate(node):
                walk(v, f"{path}[{idx}]")

    walk(rule.get("query"), "query")
    walk(rule.get("require"), "require")


# ============================================================
# INPUT VALIDATION (separate, for ui/input.json)
# ============================================================



def check_emit_signal_fields(rule, errors):
    """(2026-06-10, autorace post-mortem) Two silent-no-op field landmines in
    the emit/signal pipeline, both empirically shipped:

    1. The `emit` EFFECT reads `e["signal"]` (effect_core.emit) — an emit
       authored with `"event":` silently no-ops (name="" -> return). The
       signal TRIGGER reads `trigger["name"]` — authored `"event":` never
       matches. Asymmetric field names; both wrong forms ship without any
       runtime error. Empirical: autorace lap/finish chain dead until fixed;
       demo_lanterns shipped the same latent bug.

    2. Signal-rule consumers: _fire_payload_rule FLATTENS payload keys into
       ctx (binding is bare `name`), so a formula reading `signal.X` errors
       at runtime with a cryptic "self can't be used because instance is
       null" (unknown identifier falls back to a null base instance).
    """
    rule_id = rule.get("id", "<unnamed>")
    eff = rule.get("effect", None)
    effects = eff if isinstance(eff, list) else ([eff] if isinstance(eff, dict) else [])
    for e in effects:
        if not isinstance(e, dict):
            continue
        if e.get("type") == "emit":
            if "signal" not in e:
                got = "event" if "event" in e else "(none)"
                errors.append((rule_id, "emit",
                    f"emit effect must use the `signal:` key (engine reads "
                    f"e['signal']); got `{got}` — this emit silently no-ops."))
        # formulas reading the never-existing `signal.` binding
        for k, v in e.items():
            if isinstance(v, str) and re.search(r"\bsignal\.", v):
                errors.append((rule_id, str(k),
                    "formula reads `signal.X` but payload keys are FLATTENED "
                    "into ctx by _fire_payload_rule — bind the bare payload "
                    "key (e.g. `name`), not `signal.name` (errors at runtime "
                    "with a null-self Expression fallback)."))
    trig = rule.get("trigger", {})
    if isinstance(trig, dict) and trig.get("type") == "signal" and "name" not in trig:
        got = "event" if "event" in trig else "(none)"
        errors.append((rule_id, "trigger",
            f"signal trigger must use the `name:` key (engine matches "
            f"trigger['name']); got `{got}` — this rule never fires."))


def check_input_actions(input_json, errors):
    """(6) Actions without a `key` MUST set engine_injected: true.

    Exception: an action that re-declares ONLY name+edge (no key, no
    other authoring fields) is treated as an edge-override of a
    $include'd universal action — the key is inherited from the lib.
    Empirical case 2026-05-17: sokoban's `{name: move_north,
    edge: press}` rows that override @lib.input.universal's default
    `edge: hold`. The lib carries the W/Up keys through.
    """
    actions = input_json.get("actions", [])
    if not isinstance(actions, list):
        return
    for i, action in enumerate(actions):
        if not isinstance(action, dict):
            continue
        # Skip $include shells
        if "$include" in action:
            continue
        name = action.get("name", f"action[{i}]")
        # Any concrete binding source — key, keys, mouse_button,
        # mouse_buttons — satisfies the gate. `mouse_button` support
        # added 2026-05-20 alongside scroll-wheel zoom.
        has_binding = (
            "key" in action
            or "keys" in action
            or "mouse_button" in action
            or "mouse_buttons" in action
            or action.get("engine_injected")
        )
        if has_binding:
            continue
        # Override-edge pattern: only name + edge (no other auth fields).
        # The lib's key inheritance covers this case.
        keys = set(action.keys()) - {"_comment"}
        if keys.issubset({"name", "edge"}):
            continue
        errors.append((
            f"input.{name}", "key",
            "action has no `key` / `keys` / `mouse_button` / `mouse_buttons` "
            "AND no `engine_injected: true` marker. Keyless engine-injected "
            "actions (stop_x / stop_y) need the marker or InputRegistrar "
            "warns + skips at load.",
        ))


# ============================================================
# DRIVER
# ============================================================


def find_rule_files(game_dir):
    """The rule files the engine loads (content.rule_files)."""
    return rule_files(game_dir)


def validate_game(game_dir):
    """Return list of (file, rule_id, field, message) violations."""
    game_dir = Path(game_dir)
    errors = []
    defined = collect_defined_fields(game_dir)

    # ---- world + game + levels rules ----
    for rules_file in find_rule_files(game_dir):
        try:
            doc = json.loads(rules_file.read_text())
        except json.JSONDecodeError as e:
            errors.append((str(rules_file), "<root>", "json",
                           f"parse error: {e}"))
            continue
        # Resolve @lib refs as the engine does, so bundle rules are checked
        # in the game's context (batch G, 2026-10-16).
        rules = resolver().resolve(doc.get("rules", []))
        if not isinstance(rules, list):
            continue
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            r_errors = []
            check_formula_bindings(rule, r_errors)
            check_empty_effects(rule, r_errors)
            check_require_bindings(rule, r_errors)
            check_2binding_non_contact(rule, r_errors)
            check_schema_field_landmines(rule, r_errors)
            check_required_effect_fields(rule, r_errors)
            check_unknown_effect_fields(rule, r_errors)
            check_effect_read_after_write(rule, r_errors)
            check_emit_signal_fields(rule, r_errors)
            check_edge_state_clause(rule, r_errors)
            check_once_fields(rule, r_errors)
            check_scope_vs_presentation(rule, r_errors)
            check_query_fields_defined(rule, r_errors, defined)
            for rid, field, msg in r_errors:
                errors.append((str(rules_file), rid, field, msg))

    # ---- ui/input.json ----
    input_file = game_dir / "ui" / "input.json"
    if input_file.exists():
        try:
            input_doc = json.loads(input_file.read_text())
            i_errors = []
            check_input_actions(input_doc, i_errors)
            for rid, field, msg in i_errors:
                errors.append((str(input_file), rid, field, msg))
        except json.JSONDecodeError as e:
            errors.append((str(input_file), "<root>", "json",
                           f"parse error: {e}"))

    return errors


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

    total_errors = 0
    for game_dir in sorted(targets):
        if not game_dir.exists():
            print(f"[skip] {game_dir} (not found)")
            continue
        errors = validate_game(game_dir)
        if errors:
            label = "FAIL" if strict else "WARN"
            print(f"[{label}] {game_dir.name} "
                  f"({len(errors)} violation(s)):")
            for file_path, rid, field, msg in errors:
                rel = Path(file_path).relative_to(repo_root)
                print(f"  {rel}::{rid}.{field}")
                print(f"    {msg}")
            total_errors += len(errors)
        else:
            print(f"[ok] {game_dir.name}")

    if total_errors:
        print(f"\n{total_errors} rule contract violation(s).")
        print("See .claude/rules/data-demo.md for the contract docs.")
        if strict:
            sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
