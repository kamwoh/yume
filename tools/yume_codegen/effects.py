"""
effects.py — builders for effect JSON dicts.

Schema: docs/engine-reference/api-manifest.json § effects.
Each builder mirrors one effect type's parameter set; engine reads
the dict's "type" field to dispatch.

Schema landmines this prevents:
    - state_add: engine reads `amount`, not `delta` / `factor` /
      `change` — silent no-op on wrong field name.
    - spawn: engine reads `template`, not `def` — silent no-op.
    - Brace-wrapped bindings (`"{world.X}"` instead of `world.X`) —
      pass plain `world.X` strings and the engine evaluates them as
      formulas. Brace wrapping makes the formula evaluator fail.
"""


def _strip_none(d: dict) -> dict:
    return {k: v for k, v in d.items() if v is not None}


# ============================================================
# STATE MUTATIONS (single entity)
# ============================================================


def state_set(target: str, field: str, value) -> dict:
    """Set state.<field> on the target entity. value can be a literal
    or a formula string (`world.day + 1`, `self.state.hp * 0.5`)."""
    return {"type": "state_set", "target": target, "field": field, "value": value}


def state_add(target: str, field: str, amount) -> dict:
    """Add `amount` to state.<field>. Engine reads field named `amount`
    — calling with `delta` or `factor` silently no-ops."""
    return {"type": "state_add", "target": target, "field": field, "amount": amount}


def state_mul(target: str, field: str, amount) -> dict:
    """Multiply state.<field> by `amount`. Engine reads `amount`."""
    return {"type": "state_mul", "target": target, "field": field, "amount": amount}


def state_clamp(target: str, field: str, min=None, max=None) -> dict:
    """Clamp state.<field> into [min, max]. Both bounds optional but
    at least one must be provided (engine no-ops if neither set)."""
    if min is None and max is None:
        raise ValueError("state_clamp: at least one of min/max must be set")
    return _strip_none({
        "type": "state_clamp",
        "target": target,
        "field": field,
        "min": min,
        "max": max,
    })


# ============================================================
# LIFECYCLE
# ============================================================


def spawn(
    template: str,
    id: str | None = None,
    position=None,
    state: dict | None = None,
    tags_add: list[str] | None = None,
) -> dict:
    """Spawn a new entity from a def template.

    Engine reads `template` (NOT `def` — that's a common bug class).
    `position` may be a literal Vector3 (`[x, y, z]`) or a formula
    string evaluated in the rule's context.
    """
    return _strip_none({
        "type": "spawn",
        "template": template,
        "id": id,
        "position": position,
        "state": state,
        "tags_add": tags_add,
    })


def remove(target: str) -> dict:
    """Remove an entity. Despawn rules fire after."""
    return {"type": "remove", "target": target}


# ============================================================
# TAGS
# ============================================================


def tag_add(target: str, tags) -> dict:
    """Add tag(s) to an entity. `tags` is a list or single string."""
    if isinstance(tags, str):
        tags = [tags]
    return {"type": "tag_add", "target": target, "tags": tags}


def tag_remove(target: str, tags) -> dict:
    """Remove tag(s) from an entity. `tags` is a list or single string."""
    if isinstance(tags, str):
        tags = [tags]
    return {"type": "tag_remove", "target": target, "tags": tags}


# ============================================================
# SIGNALS
# ============================================================


def emit(signal: str, payload: dict | None = None) -> dict:
    """Emit a signal — fires any signal rules listening for `signal`.

    Payload values pass through to the receiver's context as bindings.
    To pass an entity id, set the payload value to a formula like
    `"self.id"` or `"a.id"` — DO NOT brace-wrap (`"{self.id}"`).
    """
    return _strip_none({"type": "emit", "signal": signal, "payload": payload})


def emit_shell_event(event: str, **kwargs) -> dict:
    """Emit a shell-layer event (UI / audio / juice). Common events:
        - play_sound: {name: "@cues.X"}
        - flash: {color: "#RRGGBB", duration: <frames>}
        - shake: {intensity: <float>, duration: <frames>}
        - particles: {emitter: "X", count: <int>}
    """
    return _strip_none({"type": "emit_shell_event", "event": event, **kwargs})


# ============================================================
# SCREEN FLOW (per .claude/rules/engine-scripts.md effect-chain gate)
# ============================================================


def transition_screen(target: str) -> dict:
    """Push (or replace) a screen.

    target can be a screen id, `@previous` to pop one level, or
    `@root` to pop to gameplay. Non-destructive — fine mid-chain.
    """
    return {"type": "transition_screen", "target": target}


def transition_level(
    target: str,
    fade_duration: float | None = None,
) -> dict:
    """Swap the active level. DESTRUCTIVE — must be LAST in any
    effect chain (anything queued after is silently dropped at end
    of frame, per the effect-chain validation gate)."""
    return _strip_none({
        "type": "transition_level",
        "target": target,
        "fade_duration": fade_duration,
    })


def screen_fade(alpha: float, duration: float = 0.15) -> dict:
    """Fade the overlay layer to `alpha` (0.0 = transparent, 1.0 =
    opaque). Non-destructive; safely mid-chain.

    PAIRING: every fade to alpha=1.0 must be matched somewhere
    downstream by a fade to alpha=0.0 (otherwise the player ends
    up looking at a permanent black overlay).
    """
    return {"type": "screen_fade", "alpha": alpha, "duration": duration}


def show_toast(text: str, duration: float = 2.0) -> dict:
    """Display a transient text toast on screen."""
    return {"type": "show_toast", "text": text, "duration": duration}


# ============================================================
# PERSISTENCE (DESTRUCTIVE — must be last in chain)
# ============================================================


def save_state(slot: int = 0) -> dict:
    """Write world state to a save slot."""
    return {"type": "save_state", "slot": slot}


def load_state(slot: int = 0) -> dict:
    """Load world state from a save slot. DESTRUCTIVE."""
    return {"type": "load_state", "slot": slot}


def reset_world() -> dict:
    """Reset the world to its initial state. DESTRUCTIVE — must be
    LAST in the effect chain."""
    return {"type": "reset_world"}


# ============================================================
# RELATIONS
# ============================================================


def relate(type: str, from_: str, to: str) -> dict:
    """Create a typed relation `from -> to`. `from_` is named with
    trailing underscore because `from` is a Python keyword."""
    return {"type": "relate", "relation_type": type, "from": from_, "to": to}


def unrelate(type: str, from_: str, to: str) -> dict:
    """Remove a typed relation."""
    return {"type": "unrelate", "relation_type": type, "from": from_, "to": to}


# ============================================================
# ARRAY EFFECTS (multi-slot inventory primitive — #95)
# ============================================================


def array_set_at(target: str, field: str, index, value) -> dict:
    """Set array[index] on the target's state.<field>. index can be
    a literal int or a formula string. The binding name in the
    formula MUST match the rule's available context (validator +
    engine both reject unbound references)."""
    return {
        "type": "array_set_at",
        "target": target,
        "field": field,
        "index": index,
        "value": value,
    }


def array_insert_first_empty(
    target: str,
    field: str,
    value,
    sentinel="",
    result_field: str | None = None,
) -> dict:
    """Insert value into the first slot equal to sentinel.

    `result_field` (optional) gets set to the chosen index so
    downstream effects in the same chain can reference it via
    formulas like `actor.state.<result_field>`.
    """
    return _strip_none({
        "type": "array_insert_first_empty",
        "target": target,
        "field": field,
        "value": value,
        "sentinel": sentinel,
        "result_field": result_field,
    })


def array_sync_to_field(
    target: str,
    array_field: str,
    index_field: str,
    dest_field: str,
    default=None,
) -> dict:
    """Mirror array[index] → dest_field. Use on a tick rule to keep
    derived view fields synced (held_item from inventory[active_slot]).

    Remember: dest_field MUST be pre-initialized in the entity's
    state_init too, or strict-missing filters fail at tick 1 (see
    .claude/rules/data-demo.md § sync-derived fields)."""
    return _strip_none({
        "type": "array_sync_to_field",
        "target": target,
        "array_field": array_field,
        "index_field": index_field,
        "dest_field": dest_field,
        "default": default,
    })


def array_count_matching(
    target: str,
    array_field: str,
    sentinel,
    dest_field: str,
) -> dict:
    """Count elements equal to sentinel; write to dest_field."""
    return {
        "type": "array_count_matching",
        "target": target,
        "array_field": array_field,
        "sentinel": sentinel,
        "dest_field": dest_field,
    }
