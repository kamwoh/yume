"""
yume_codegen — Python-side composable builders for Yume rule / entity / screen JSON.

JSON is canonical (per ADR 0021 + Invariant #1 — the engine reads JSON
authoritatively). This package is an OPTIONAL emitter that helps
authors compose those JSON dicts programmatically with type-checked
keyword arguments + helper functions, then `save(path, value)` writes
them out.

Why this exists (task #101, 2026-05-17):
    Two recurring bug classes motivated this:
      1. Brace-wrapped bindings (`"{world.X}"` instead of `world.X`)
      2. Wrong context-binding names in formulas (`self.foo` in a
         signal rule whose binding is `actor.foo`)
    Both bugs slipped through hand-authored JSON for weeks until the
    user hit them at live play. A typed Python builder catches the
    "obvious" cases at author time + makes the same author keyword
    self-documenting.

Authority hierarchy (per .claude/rules/data-demo.md):
    - JSON is the authoritative format the engine reads
    - validators (tools/validate_rules.py) are the contract gate
    - this package emits JSON that PASSES the validators
    - hand-authored JSON remains fully supported alongside codegen

Top-level imports (also exported below):

    from yume_codegen import (
        # Rules
        rule, tick, contact, signal_trigger, input_trigger, spawn_trigger,
        # Queries / requires
        query, require, pair_query,
        # Effects
        state_set, state_add, state_mul, state_clamp,
        spawn, remove, tag_add, tag_remove, emit, transition_screen,
        relate, unrelate, screen_fade,
        # Entities
        entity, instance, state_init,
        # Screens / HUD
        screen, element, label, panel, progress_bar, slot_grid, item_icon,
        button, image, image_3d, control,
        # Lib refs
        lib_ref, include_lib,
        # IO
        save, save_rules, save_entities, save_screens, load_json,
    )

Each builder returns a plain `dict` so they compose freely with
hand-written JSON. No magic, no runtime dependency beyond stdlib.
"""

# Allow `from tools.yume_codegen import X` AND `from yume_codegen import X`.
# Exporting names here means callers don't need to know which submodule.

from .rules import (
    rule,
    tick,
    contact,
    signal_trigger,
    input_trigger,
    spawn_trigger,
    despawn_trigger,
    query,
    require,
    pair_query,
)
from .effects import (
    state_set,
    state_add,
    state_mul,
    state_clamp,
    spawn,
    remove,
    tag_add,
    tag_remove,
    emit,
    emit_shell_event,
    transition_screen,
    transition_level,
    relate,
    unrelate,
    screen_fade,
    show_toast,
    save_state,
    load_state,
    reset_world,
    array_set_at,
    array_insert_first_empty,
    array_sync_to_field,
    array_count_matching,
)
from .entities import (
    entity,
    instance,
    state_init,
    visual,
    physics,
)
from .screens import (
    screen,
    element,
    label,
    panel,
    progress_bar,
    slot_grid,
    item_icon,
    button,
    image,
    image_3d,
    control,
    minimap,
    global_input,
)
from .lib_refs import (
    lib_ref,
    include_lib,
    cue_ref,
    string_ref,
)
from .io import (
    save,
    save_rules,
    save_entities,
    save_screens,
    load_json,
)

__version__ = "0.1.0"
