export const entry08 = {
  id: "08",
  date: "2026-04-22",
  type: "build",
  title: "W1 engine — production primitives in eight files",
  summary:
    "W1.3 through W1.9. Seven primitives become typed GDScript modules. Entity is a Node2D " +
    "carrier; Rule, Query, Effect, RelationStore, PhaseScheduler are RefCounted. World ties " +
    "them together as the top-level orchestrator. ~1500 lines total.",
  highlights: [
    "<code>entity.gd</code> — generic Node2D, no subclasses, factory <code>Entity.create(def, id, overrides)</code>",
    "<code>rule.gd</code> — Rule class, <code>from_dict</code> + <code>load_from_file</code> + <code>validate_all</code>; before/after hints, Expression cache slot for W4",
    "<code>query.gd</code> — QueryLib static. <code>matches()</code> single-entity, <code>run()</code> scan. Strict missing-field semantics",
    "<code>effect_apply.gd</code> — 13 effect types dispatched. Target resolution: context binding → literal id fallback",
    "<code>relation_store.gd</code> — directed multigraph, both-direction indexed, dedup at insert, <code>clear_entity</code> for despawn cleanup",
    "<code>phase_scheduler.gd</code> — 4-phase tick loop + write buffer + topo sort via before/after hints",
    "<code>world.gd</code> — top-level Node2D orchestrator, owns entities/defs/relations/scheduler/clock",
    "<code>world_clock.gd</code> — moved to <code>scripts/engine/</code>, programmatic <code>tick_seconds</code> (no global meta.json read)",
    "<code>renderer_2d/entity_sprite_2d.gd</code> — reads <code>entity.visual.sprite_2d</code>, falls back to colored circle",
    "Plus: <code>scenes/world_2d.tscn</code> + <code>project.godot</code> — framework now a runnable Godot 4.6 project",
  ],
  files: [
    "archetypes/core/templates/godot/scripts/engine/*.gd",
    "archetypes/core/templates/godot/scripts/renderer_2d/entity_sprite_2d.gd",
    "archetypes/core/templates/godot/scenes/world_2d.tscn",
    "archetypes/core/templates/godot/project.godot",
  ],
};
