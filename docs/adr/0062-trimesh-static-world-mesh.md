# ADR 0062 — Trimesh collision for static world meshes

_Date: 2026-05-30_
_Status: accepted_

## Context

Yume composes scenes from primitives (entities extracted from a semantic
map, kit/Tripo props). Each static collider is a box / sphere / capsule /
cylinder fitted to a mesh bbox (physics_body_builder `_create_shape_3d` +
`_build_collision_shape_node`). That's right for discrete props.

It is wrong for a **pre-authored monolithic world mesh** — e.g. an imported
artist-made city or terrain (`.glb`) where streets, sidewalks, building
faces, and steps are all one mesh. A bbox-fitted box collider would be a
single 150×37×165 m block: the player would stand on top of the bounding
box, not walk the streets. There was no way to collide accurately with such
geometry.

This blocked dropping an external environment mesh into a Yume scene as a
walkable world.

## Decision

Two small additions, both pure "expose Godot, don't reimplement" (ADR 0021):

1. **`collision_shape.type: "trimesh"`** in `physics_body_builder._create_shape_3d`.
   Builds a `ConcavePolygonShape3D` (via `PhysicsServer3D.concave_polygon_shape_create`
   + `shape_set_data({"faces": …})`) from a `.glb`'s triangle faces. Faces are
   gathered by walking the glb's `MeshInstance3D` nodes and applying each
   instance's transform relative to the scene root (`_glb_trimesh_faces` /
   `_collect_trimesh_faces`), so the collider matches the mesh's NATIVE local
   space. Concave shapes are static/kinematic-only (never rigid) — matches the
   `body_type: "static"` use.

2. **`visual.normalize: false`** in `entity_mesh_3d._load_glb_mesh`. The static-
   glb path normalizes to unit-height + base-at-origin (so a fitted `state.scale`
   places it like a kit). A world mesh must instead render at its NATIVE scale +
   origin so the trimesh collider (built from the same native faces) aligns 1:1.
   The flag skips normalization. (The `visual.model_3d` Tier-1 path already
   renders native, so a world mesh can use either; `model_3d` is the simplest.)

### Authoring shape

```jsonc
{
  "id": "city",
  "tags": ["world_mesh", "static"],
  "visual": {"model_3d": "res://data/demo_city/assets/meshes/city.glb"},
  "physics": {
    "body_type": "static",
    "collision_shape": {"type": "trimesh",
                        "mesh": "res://data/demo_city/assets/meshes/city.glb"},
    "collision_layer": ["wall", "floor"],
    "collision_mask": "all"
  },
  "state_init": {"position": [0, 0, 0]}
}
```

Visual mesh + trimesh come from the SAME glb at the SAME native coords, both
anchored at `position`, so render and collision align. On `wall`+`floor`
layers the player CharacterBody both collides with buildings and stands on
streets (floor vs wall is decided by collision normal, not layer).

## Walkability: CharacterBody3D floor params (2026-05-30 follow-up)

A walkable trimesh world (stairs, curbs, uneven streets) exposed that
`build_character_3d` created the player CharacterBody3D with **raw Godot floor
defaults**. On stairs that breaks two ways: `floor_block_on_wall=true` (default)
lets a step's vertical riser (a "wall") cancel `is_on_floor()`, so `on_floor`
sticks at 0 → the airborne/jump animation loops and the body wedges; and
`floor_snap_length=0` lets the body float off / bounce down steps. Fix:
`build_character_3d` now sets walkable defaults (all `phys_cfg`-overridable):
`floor_block_on_wall=false`, `floor_snap_length=0.5`, `floor_constant_speed=true`,
`floor_max_angle≈50°`. **Gate**: every character body gets these — we don't ship
raw Godot floor defaults for a walkable world. Empirical case: 2026-05-30, player
stuck + jump-anim looping on demo_city stairs.

**Known limitation**: CharacterBody3D has no built-in step-up. The above keeps
floor-detection correct + makes shallow steps/curbs traversable, but TALL stairs
still block the player (a riser taller than the capsule can ride). True stair-
climbing needs explicit step-up logic — tracked in the backlog, not this ADR.

## Consequences

- Any external environment `.glb` (city, terrain, dungeon) can be a walkable
  Yume world: render-native + trimesh collide, no per-feature authoring.
- Trimesh extraction instantiates the glb once at spawn to read faces — a few
  seconds for a 72 MB city; acceptable for a one-time static spawn. (Could be
  cached if a scene spawns many; not needed yet.)
- Concave colliders are static-only — a world mesh must be `body_type: static`.
- This does NOT change Yume's primitive philosophy: it's a generic Godot-
  capability exposure, reusable across genres, not game-specific code.

## Alternatives considered

- **Bake collision in the `.tscn` via Godot import** (rename nodes `-col`, or
  import-time trimesh): works, but puts geometry+collision in the scene file,
  bypassing the JSON-entity model — a static prop that despawn/relate/query
  can't see. Rejected.
- **Decompose the city into per-building box colliders**: needs the source mesh
  split per building (it isn't — buildings are one mesh) and an extraction step.
  Far more work, worse fit than one trimesh. Rejected.
- **Convex decomposition** (`create_multiple_convex_collisions`): better for
  dynamic bodies, overkill + lossy for a static world. Trimesh is exact and
  cheap for static. Rejected for now.
