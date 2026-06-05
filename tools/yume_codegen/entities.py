"""
entities.py — builders for entity def + instance JSON dicts.

Schema: docs/guideline/30_framework_primitives.md § Entity.
Entities live in two shapes:
    - `definition`: the template (id, tags, properties, state_init)
    - `initial_instances`: per-game placements that reference a def

Each entity file under data/<game>/entities/*.json has the shape:
    {"definitions": [<entity_def>...], "initial_instances": [<inst>...]}
"""


def _strip_none(d: dict) -> dict:
    return {k: v for k, v in d.items() if v is not None}


# ============================================================
# ENTITY DEFINITION
# ============================================================


def entity(
    id: str,
    tags: list[str] | None = None,
    properties: dict | None = None,
    state_init: dict | None = None,
    visual: dict | None = None,
    physics: dict | None = None,
    comment: str | None = None,
    **extra,
) -> dict:
    """Build an entity definition.

    Standard fields:
        id          — unique def id (referenced by initial_instances + spawn.template)
        tags        — string membership labels (no class hierarchy)
        properties  — STATIC fields (read-only after spawn)
        state_init  — DYNAMIC fields (mutable via state_set / state_add)
        visual      — renderer hints (mesh, color, animation_state_rules)
        physics     — body_type / aabb_extents (ADR 0045)
        **extra     — any other authoring fields (mesh-specific, etc.)

    Common bug-class gate: when state_init declares fields that other
    rules will read via filters (e.g. `held_item_eq: ""`), the
    derived sync field MUST be pre-initialized here. Empirical case:
    inventory_empty_count silently absent → first input rule with
    `inventory_empty_count_gt: 0` filter never fires at tick 1.
    """
    return _strip_none({
        "_comment": comment,
        "id": id,
        "tags": tags,
        "properties": properties,
        "state_init": state_init,
        "visual": visual,
        "physics": physics,
        **extra,
    })


# ============================================================
# INSTANCE PLACEMENT
# ============================================================


def instance(
    def_id: str,
    id: str,
    position=None,
    state: dict | None = None,
    tags_add: list[str] | None = None,
    comment: str | None = None,
    **extra,
) -> dict:
    """Build an initial-instance placement.

    Engine reads `def` (the template name) and `id` (the unique
    instance id). `def_id` here maps to JSON key `def` (Python
    keyword conflict).

        instance(def_id="wheat_seed", id="w1", position=[10, 0, 5])
        →
        {"def": "wheat_seed", "id": "w1", "position": [10, 0, 5]}

    state overrides start values per-instance without changing the
    template. position is optional — if absent, the engine uses
    the def's state_init.position.
    """
    return _strip_none({
        "_comment": comment,
        "def": def_id,
        "id": id,
        "position": position,
        "state": state,
        "tags_add": tags_add,
        **extra,
    })


# ============================================================
# COMMON SUB-DICTS
# ============================================================


def state_init(**fields) -> dict:
    """Build the state_init dict. Use kwargs for readable authoring:

        state_init(
            hp=100,
            hunger=0,
            inventory=["", "", "", ""],
            active_slot=0,
            held_item="",          # MUST pre-init derived sync fields
            inventory_empty_count=4,
        )
    """
    return dict(fields)


def visual(
    mesh: str | None = None,
    shape: str | None = None,
    model_3d: str | None = None,
    color=None,
    animation_state_rules: list | None = None,
    animation_blend_seconds: float | None = None,
    material_overrides: dict | None = None,
    params: dict | None = None,
    **extra,
) -> dict:
    """Build the visual block for an entity def.

    For code-drawn meshes: set `mesh` to a name from meshes.json or
    `shape` for 2D shapes.json.
    For .glb-backed meshes (ADR 0046 Phase B): set `mesh` to
    `"res://path/to/foo.glb"` (suffix detection routes to the
    .glb loader) + add `animation_state_rules` with
    `clip_alias` entries to map state names to .glb clip names.
    """
    return _strip_none({
        "mesh": mesh,
        "shape": shape,
        "model_3d": model_3d,
        "color": color,
        "animation_state_rules": animation_state_rules,
        "animation_blend_seconds": animation_blend_seconds,
        "material_overrides": material_overrides,
        "params": params,
        **extra,
    })


def physics(
    body_type: str = "kinematic",
    aabb_extents: list | None = None,
    collision_layer: int | None = None,
    collision_mask: int | None = None,
    **extra,
) -> dict:
    """Build the physics block (ADR 0045).

    body_type:
        - "kinematic" — moved by motion integrator (default)
        - "character" — CharacterBody3D, _physics_process owned by engine
        - "static"   — never moves (walls, props with blocks_motion)
        - "rigid"    — RigidBody3D (force-driven)
    """
    return _strip_none({
        "body_type": body_type,
        "aabb_extents": aabb_extents,
        "collision_layer": collision_layer,
        "collision_mask": collision_mask,
        **extra,
    })
