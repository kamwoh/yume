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

# ============================================================
# CONTEXT BINDING RESOLUTION — what bindings does each trigger expose?
# ============================================================

# Roots that are always available in formula context regardless of trigger.
GLOBAL_ROOTS = {
    "world",        # env.world_state dict
    "zone",         # ADR 0031 zone snapshot
    "faction",      # ADR 0032 faction snapshot
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
    if t_type == "contact":
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


# ============================================================
# INPUT VALIDATION (separate, for ui/input.json)
# ============================================================


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
    """Yield every rules.json / goals.json the game ships.

    Mirrors WorldLoader.load_rules_files_for (#109): directory form
    (world/rules/*.json) wins over single-file form (world/rules.json)
    when present. Validator must check the same set of files the engine
    will actually load.
    """
    game_dir = Path(game_dir)
    base_paths = [
        game_dir / "world" / "rules.json",
        game_dir / "world" / "physics.json",  # legacy name
        game_dir / "game" / "goals.json",
        game_dir / "game" / "rules.json",  # legacy name
    ]
    for p in base_paths:
        # Directory form: world/rules.json → world/rules/
        dir_form = p.parent / p.stem
        if dir_form.is_dir():
            for child in sorted(dir_form.glob("*.json")):
                yield child
        elif p.exists():
            yield p
    levels_dir = game_dir / "levels"
    if levels_dir.exists():
        for level_dir in levels_dir.iterdir():
            if level_dir.is_dir():
                p = level_dir / "rules.json"
                p_dir = level_dir / "rules"
                if p_dir.is_dir():
                    for child in sorted(p_dir.glob("*.json")):
                        yield child
                elif p.exists():
                    yield p


def expand_includes(node):
    """The engine's LibResolver expands @lib.X.Y refs at load. The
    validator doesn't follow them — referenced rules live in data/lib/
    and are validated separately. Skip rules that are pure `$include`
    placeholders or `$extends` references."""
    if not isinstance(node, dict):
        return False
    if "$include" in node or "$extends" in node:
        return True
    return False


def validate_game(game_dir):
    """Return list of (file, rule_id, field, message) violations."""
    game_dir = Path(game_dir)
    errors = []

    # ---- world + game + levels rules ----
    for rules_file in find_rule_files(game_dir):
        try:
            doc = json.loads(rules_file.read_text())
        except json.JSONDecodeError as e:
            errors.append((str(rules_file), "<root>", "json",
                           f"parse error: {e}"))
            continue
        rules = doc.get("rules", [])
        if not isinstance(rules, list):
            continue
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            if expand_includes(rule):
                continue  # $include / $extends — validated separately in lib
            r_errors = []
            check_formula_bindings(rule, r_errors)
            check_empty_effects(rule, r_errors)
            check_require_bindings(rule, r_errors)
            check_2binding_non_contact(rule, r_errors)
            check_schema_field_landmines(rule, r_errors)
            check_effect_read_after_write(rule, r_errors)
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
