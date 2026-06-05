"""
rules.py — builders for rule JSON dicts.

Schema reference: docs/guideline/30_framework_primitives.md § Rule.
Validator: tools/validate_rules.py.

The canonical rule shape:

    {
      "id": "<unique>",
      "trigger": {<trigger_dict>},
      "query": {<query_dict>}      | null,
      "require": {<require_dict>}  | null,
      "chance": <0..1>             | omitted (default 1.0),
      "effect": [<effect_dict>]    | {<effect_dict>},
      "before": ["<other_rule>"]   | omitted,
      "after":  ["<other_rule>"]   | omitted,
    }

This module exposes one factory per shape. Each returns a plain dict.
None-valued kwargs are stripped so the emitted JSON stays clean.
"""

from typing import Any


def _strip_none(d: dict) -> dict:
    """Remove keys whose value is None — keeps emitted JSON tidy."""
    return {k: v for k, v in d.items() if v is not None}


# ============================================================
# RULE TOP-LEVEL
# ============================================================


def rule(
    id: str,
    trigger: dict,
    effect,
    query: dict | None = None,
    require: dict | None = None,
    chance: float | None = None,
    before: list[str] | None = None,
    after: list[str] | None = None,
    comment: str | None = None,
) -> dict:
    """Build a rule dict.

    Effect may be a single effect dict or a list; the engine accepts
    both forms. Empty effect lists are forbidden (validator + engine
    both reject). Comment becomes `_comment` (engine-ignored).
    """
    if isinstance(effect, dict):
        effect_value: Any = effect
    elif isinstance(effect, list):
        if not effect:
            raise ValueError(
                f"rule '{id}': effect list cannot be empty "
                "(see .claude/rules/data-demo.md § effect_empty)"
            )
        effect_value = effect
    else:
        raise TypeError(
            f"rule '{id}': effect must be a dict or list of dicts, got {type(effect)}"
        )
    return _strip_none({
        "_comment": comment,
        "id": id,
        "trigger": trigger,
        "query": query,
        "require": require,
        "chance": chance,
        "effect": effect_value,
        "before": before,
        "after": after,
    })


# ============================================================
# TRIGGERS — one factory per trigger.type
# ============================================================


def tick(interval: int = 1, phase: str = "decide") -> dict:
    """Sim-tick trigger. `interval` is in ticks (60 = 1s at 60Hz default)."""
    return {"type": "tick", "interval": interval, "phase": phase} if phase != "decide" \
        else {"type": "tick", "interval": interval}


def contact() -> dict:
    """Contact trigger — fires on pair-matched entities (a, b)."""
    return {"type": "contact"}


def signal_trigger(name: str) -> dict:
    """Signal trigger — fires when an `emit` effect fires this signal name."""
    if not name:
        raise ValueError("signal_trigger: name is required")
    return {"type": "signal", "name": name}


def input_trigger(action: str) -> dict:
    """Input trigger — fires when an input action is queued this tick."""
    if not action:
        raise ValueError("input_trigger: action is required")
    return {"type": "input", "action": action}


def spawn_trigger() -> dict:
    """Spawn trigger — fires when an entity is spawned (`self` is bound)."""
    return {"type": "spawn"}


def despawn_trigger() -> dict:
    """Despawn trigger — fires when an entity is removed."""
    return {"type": "despawn"}


# ============================================================
# QUERIES
# ============================================================


def query(
    tags_all: list[str] | None = None,
    tags_none: list[str] | None = None,
    state: dict | None = None,
    radius: float | None = None,
    once_per_a: bool | None = None,
    order_by: dict | None = None,
    limit: int | None = None,
) -> dict:
    """Flat single-entity query (binds `self`).

    state is a dict of `{<field>_<op>: <value>}` filters — `op` is one of
    eq, ne, lt, lte, gt, gte, in. For example:
        state={"hp_lt": 50, "tier_gte": 3}
    """
    return _strip_none({
        "tags_all": tags_all,
        "tags_none": tags_none,
        "state": state,
        "radius": radius,
        "once_per_a": once_per_a,
        "order_by": order_by,
        "limit": limit,
    })


def pair_query(
    a: dict,
    b: dict,
    radius: float,
    once_per_a: bool | None = None,
) -> dict:
    """2-binding query (binds `a` + `b`) — ONLY valid on contact triggers.

    Validator + engine both reject pair queries on tick / signal / input
    triggers (the second binding never resolves). Empirical: 15 broken
    rules in Aldenmere's first pass.
    """
    return _strip_none({
        "a": a,
        "b": b,
        "radius": radius,
        "once_per_a": once_per_a,
    })


def require(**bindings: dict) -> dict:
    """Named sub-binding `require` clause.

    Validates each named binding (`actor`, `target`, etc.) matches a
    filter spec. Used with signal rules whose payload carries entity
    ids; the binding names BECOME the available formula context.

    Empirical case 2026-05-16: `gather_pickup` rule whose require:
    {actor, target} had its effects use `self.foo` (unbound) instead
    of `actor.foo`. Use this helper + the binding names line up.

    Example:
        require(
            actor={"tags_all": ["player"], "state": {"hp_gt": 0}},
            target={"tags_all": ["forageable"]},
        )
    """
    if not bindings:
        return {}
    return dict(bindings)
