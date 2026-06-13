# ADR 0073 — Editor-time scene preview (read-only)

_Date: 2026-06-13_
_Status: accepted_

## Context

Yume's `.tscn` files are thin launchers: a `World` node + a Camera3D.
Everything visible — entities, ground, lighting — is built at RUNTIME
by WorldBoot/WorldLoader from JSON. Open a `.tscn` in the Godot editor
and the viewport is empty; the only way to see a scene's layout is to
run it (`play.sh` + free-cam) or read a capture.

This is correct for the JSON-is-truth invariant but costs authoring
ergonomics: you can't eyeball entity placement, spot a floating prop,
or judge spacing without a full launch cycle.

## Decision

A `@tool` node, `YumeScenePreview` (`scripts/engine/editor/
yume_scene_preview.gd`), added as a child of `World` in the `.tscn`
stub. In the editor (`Engine.is_editor_hint()`) it reads the sibling
`World.data_root`'s JSON and builds a **read-only** preview:

- ground plane from `scene.json` `ground.mesh` (size + color)
- entity meshes from `entities/*.json` + `entities.json` (defs merged
  by id; `initial_instances` + `patterns` via the SAME
  `InstancePatterns.expand` the runtime uses), skipping
  `visual.hidden` entities (cameras, logical singletons)
- a NEUTRAL editor sun + ambient (NOT the game's lighting mood — this
  is for seeing layout; a night scene must still be visible)

**Three hard guarantees:**

1. **Never persists.** Every built node has `owner = null`, so saving
   the `.tscn` never bakes preview geometry into it. All preview nodes
   live under one `_PreviewRoot` child (also `owner = null`) — one
   extra entry in the Scene dock, gone on close.
2. **Runtime no-op.** When the game runs (`is_editor_hint()` false) the
   node does nothing; World builds the real scene. The empty Node3D
   child is harmless.
3. **No runtime-class contagion.** The preview does NOT make `World` /
   `Entity` / `EntityMesh3D` `@tool`. It reuses only STATIC helpers
   (`MeshLib.build_primitives_into`, `InstancePatterns.expand`) — safe
   to call from a tool script without tooling the whole engine. The
   small slice it must replicate (`.glb` normalize, placement) is
   commented as "mirrors entity_mesh_3d.gd".

A `refresh_preview` exported bool (toggle) rebuilds after JSON edits
without reopening the scene.

## Consequences

- Open any wired `.tscn` → see the layout. Author placement, catch
  floaters/clustering, judge spacing without a launch.
- The preview is BEST-EFFORT for layout, not a pixel match: it uses
  neutral light (not the game mood), skips per-entity `visual.light`,
  textures beyond `albedo_texture`, animation, and shaders. The
  authoritative render is still the running game + captures (the
  visual-qa gate is unchanged).
- Drift risk: the `.glb` normalize + placement slice is duplicated. If
  the renderer's convention changes, the preview can lag — flagged by
  the "mirrors entity_mesh_3d.gd" comment contract. Prims/kits reuse
  `MeshLib` exactly, so the common case never drifts.
- New stubs (compose_shell / scene generation) should add the node;
  existing demos are wired opt-in.

## Alternatives considered

- **`@tool` on World itself** (full-fidelity in-editor boot): rejected
  — tool contagion forces `@tool` + `is_editor_hint()` guards onto
  every engine class the boot touches; one unguarded line runs while
  you edit. High fidelity, high risk.
- **EditorPlugin with a dock button**: viable, more robust (one
  install, all scenes), but heavier (plugin.cfg lifecycle, open-scene
  detection) and button-triggered rather than the "open → see it" the
  request asked for. The `@tool` node is the lighter match; a plugin
  can wrap it later for write-back (drag-to-place → JSON) — the
  ambitious phase 2 this explicitly defers.
- **Status quo (play.sh + captures)**: the working baseline; this ADR
  adds inspection convenience without replacing the authoritative
  render path.
