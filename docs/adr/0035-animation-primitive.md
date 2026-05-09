# ADR 0035 — Animation primitive

_Date: 2026-05-09_
_Status: proposed_

## Context

Yume has **no animation system**. Every code-drawn mesh in
`data/meshes.json` (composed from box / sphere / cylinder / capsule /
plane / prism / torus / quad primitives via `mesh_lib.gd`) renders
**statically**. Per-entity 3D rendering (`entity_mesh_3d.gd`) syncs
position + yaw from `entity.state.position` and `entity.state.yaw`
each frame, but the mesh's child primitives — head, arms, legs,
torso pieces — are bolted to the parent transform and never move
relative to each other. Glb-imported meshes (Tier 1, ADR 0007) can
play their own AnimationPlayer tracks, but the **vast majority of
Yume's content is code-drawn meshes** and those have nothing.

The empirical symptom: NPCs in every Yume 3D demo (merchant,
doomarena3d, aldenmere prototype) **slide between positions like
chess pieces on ice**. Walk speed updates `state.position`; the
renderer translates the whole mesh; limbs never animate; the world
feels lifeless.

Aldenmere's Phase 1 design (`docs/games/aldenmere/world.md` §
"Phase 1 — Survival") explicitly demands a contemplative aesthetic
of villagers WALKING through their daily routine — sleep at home,
work at fields, eat, socialize, sleep. That aesthetic dies the
moment the player sees a villager glide across the ground without
limb motion. Animation is not polish for Aldenmere — it is the
substrate of "the world feels alive." The merchant game is a
working precedent: feature-complete, soul layers 1+5 wired, but
empirically users describe the NPCs as "cold meshes." Every
soul-bearing GDD with Fellowship / Submission / Discovery aesthetic
hits the same wall (per `.claude/rules/soul.md` — Layer 4 kinetic
juice + Layer 2 visual identity both require limb motion to land).

The Aldenmere engine roadmap (`docs/games/aldenmere/engine_roadmap.md`)
labels this **Phase 1 BLOCKING**. Without it, every villager Phase 1
spawns slides through their schedule and the contemplative aesthetic
collapses into "tech demo with NPCs."

What we need:

1. **Per-piece transforms** — animate a named mesh primitive (the
   "left_arm" cylinder) independently of its siblings. Today every
   primitive in a mesh def is anonymous (positional index only).
2. **Declarative keyframe tracks** — JSON authors specify a track
   like `"rotation_z": [0.0, 0.4, 0.0, -0.4, 0.0]` (5 keyframes
   over the loop's duration), engine interpolates linearly between
   them per frame.
3. **State machine** — the active animation depends on what the
   entity is doing. Walking → "walk" cycle. Chopping wood →
   "chop" cycle. Sleeping → "sleep" pose. State picked from
   declarative conditions over entity velocity / state fields.
4. **Per-frame, not per-tick** — animation must run at render
   framerate (60 fps), not engine tick rate (10 Hz). Tick-rate
   animation looks staccato.
5. **Backwards-compat** — none of the 13 existing demos define
   animations. The new field must be optional; meshes without it
   render exactly as today.
6. **Per ADR 0021** — JSON declarative; no per-game GDScript.
   Engine ships a fixed animation interpreter; games supply data.

## Decision

Add a declarative **animation primitive** to Yume. Three integrated
parts:

### 1. Mesh primitives gain optional `name` field

Extend `mesh_lib.gd::build_primitives_into` to accept and apply a
`name` field on each primitive dict. The primitive's
`MeshInstance3D` child gets its `Node.name` set, enabling
`parent.find_child(piece_name, false, false)` lookup at animation
time. Naming is **optional**; primitives without a name still
render (just not addressable for animation).

```jsonc
// data/meshes.json — primitive gains "name"
{
  "merchant_npc_3d": {
    "primitives": [
      {"op": "box",      "name": "torso",     "pos": [0, 1.0, 0], "size": [0.5, 0.7, 0.3], "color": "#7a4f3c"},
      {"op": "sphere",   "name": "head",      "pos": [0, 1.55, 0], "radius": 0.2,            "color": "#e0c0a0"},
      {"op": "cylinder", "name": "left_arm",  "pos": [-0.32, 1.0, 0], "radius": 0.07, "height": 0.6, "color": "#7a4f3c"},
      {"op": "cylinder", "name": "right_arm", "pos": [0.32, 1.0, 0],  "radius": 0.07, "height": 0.6, "color": "#7a4f3c"},
      {"op": "cylinder", "name": "left_leg",  "pos": [-0.12, 0.4, 0], "radius": 0.09, "height": 0.7, "color": "#3a2a1e"},
      {"op": "cylinder", "name": "right_leg", "pos": [0.12, 0.4, 0],  "radius": 0.09, "height": 0.7, "color": "#3a2a1e"}
    ]
  }
}
```

### 2. Mesh defs gain optional `animations` + `animation_state_rules`

```jsonc
{
  "merchant_npc_3d": {
    "primitives": [...],
    "params": {...},
    "animations": {
      "idle": {
        "duration": 2.0,
        "loop": true,
        "tracks": [
          {"piece": "head", "rotation_y": [0.0, 0.05, 0.0, -0.05, 0.0]}
        ]
      },
      "walk": {
        "duration": 0.6,
        "loop": true,
        "tracks": [
          {"piece": "left_arm",  "rotation_z": [0.0,  0.4, 0.0, -0.4, 0.0]},
          {"piece": "right_arm", "rotation_z": [0.0, -0.4, 0.0,  0.4, 0.0]},
          {"piece": "left_leg",  "rotation_x": [0.0,  0.3, 0.0, -0.3, 0.0]},
          {"piece": "right_leg", "rotation_x": [0.0, -0.3, 0.0,  0.3, 0.0]}
        ]
      },
      "chop": {
        "duration": 0.8,
        "loop": true,
        "tracks": [
          {"piece": "right_arm", "rotation_x": [0.0, -1.4, -1.4, 0.0]},
          {"piece": "torso",     "rotation_x": [0.0, -0.2,  0.0, 0.0]}
        ]
      },
      "sleep": {
        "duration": 4.0,
        "loop": true,
        "tracks": [
          {"piece": "torso", "rotation_x": [-1.5708, -1.5708]},
          {"piece": "head",  "translation_y": [0.0, 0.02, 0.0, -0.02, 0.0]}
        ]
      }
    },
    "animation_state_rules": [
      {"if_velocity_gt": 0.1,                          "state": "walk"},
      {"if_state_eq": {"current_verb": "chop_wood"},   "state": "chop"},
      {"if_state_eq": {"current_verb": "sleep"},       "state": "sleep"},
      {"default": "idle"}
    ]
  }
}
```

### 3. New engine module `animation_director.gd`

Per render frame, for every entity whose mesh def has `animations`:

1. Pick the active state by evaluating `animation_state_rules`
   top-to-bottom; first match wins; `default` is the fallback.
2. Compute `t = (now_seconds % duration) / duration` (with
   loop wrap; non-looping clamps at 1.0 and freezes).
3. For each track in the active state, find the addressed piece
   under the entity's mesh root via `find_child(piece_name)` and
   apply linear interpolation between the two adjacent keyframes
   to the requested transform component.

Hooked into `entity_mesh_3d.gd::_process` (after `_sync_position` +
`_sync_yaw`). Per-entity AnimationDirector instance (cheap
RefCounted holding `mesh_def`, cached piece-node references after
first lookup, and the active-state tracker for hysteresis if
needed later).

### Track types (Phase 1)

| Track field | Applies to | Units |
|---|---|---|
| `rotation_x` | piece's `rotation.x` | radians |
| `rotation_y` | piece's `rotation.y` | radians |
| `rotation_z` | piece's `rotation.z` | radians |
| `translation_x` | piece's `position.x` (relative to authored pos) | mesh units |
| `translation_y` | piece's `position.y` (relative to authored pos) | mesh units |
| `translation_z` | piece's `position.z` (relative to authored pos) | mesh units |
| `scale_x` / `scale_y` / `scale_z` | piece's `scale.<axis>` (multiplicative) | scalar |

Translation tracks add to the primitive's authored `pos` (so
"piece at rest" = primitive's authored `pos`; track values are
deltas). Scale tracks multiply the default `Vector3.ONE` baseline.
Rotation tracks REPLACE any animation-time rotation; the
primitive's authored `rotation_deg` (if any) is the rest pose.

### State condition operators (Phase 1)

| Op | Argument shape | Semantics |
|---|---|---|
| `if_velocity_gt` | float | active if `entity.state.velocity.length() > arg` |
| `if_velocity_lt` | float | active if velocity below threshold |
| `if_state_eq` | `{field: value}` (single key) | active if `entity.state.field == value` |
| `if_state_in` | `{field: [v1, v2, ...]}` | active if value in list |
| `if_tag` | string | active if entity has this tag |
| `default` | (no value) | always-active fallback |

Conditions are evaluated top-to-bottom; **first match wins**.
`default` is required (failure to provide it = error at load time;
the validator below catches it).

### Interpolation

**Linear** between adjacent keyframes (Phase 1). Cubic / spline
interpolation is deferred (would justify a new operator like
`{"piece": "X", "rotation_y": {"keys": [...], "interp": "cubic"}}`
in a future ADR).

For looping animations (`loop: true`), the last keyframe wraps
around to the first — author convention is to place an explicit
return-to-start keyframe so wraparound is implicit. For
non-looping (`loop: false`), the last keyframe is held until the
state changes.

### Backwards-compat

- Mesh def with no `animations` field → `entity_mesh_3d.gd` runs
  exactly as today (sync position + yaw; no per-piece work).
- Mesh primitive with no `name` field → primitive renders, but is
  not addressable; if a track references that piece by name, the
  director logs a one-shot warning (per `EngineError.raise` with
  severity=warning) and skips the track.
- `animation_state_rules` missing `default` → load-time error.

### Operator surface boundary

Animation introduces:
- 1 new mesh-primitive field (`name`)
- 2 new mesh-def fields (`animations`, `animation_state_rules`)
- 1 new engine module (`animation_director.gd`)
- **0 new effect types** — animation is observation-driven (reads
  state), not effect-driven (no `play_animation` effect needed)
- **0 new query operators**
- **0 new triggers**

This is a **rendering-side primitive**, parallel to mesh / shape /
sprite. Per ADR 0021 it EXPOSES Godot's transform composition;
it doesn't reimplement Godot's AnimationPlayer (which is
node-tree-coupled and would force Yume content authors to author
.tscn files — anti-pattern per Invariant #1).

## Consequences

### Positive

- NPCs **walk visibly** instead of sliding. Phase 1 contemplative
  aesthetic becomes achievable.
- **Reusable across all Yume games** — every code-drawn mesh can
  define animations; the primitive doesn't bind to any specific
  game.
- **Cheap per-frame cost** — linear interp + a handful of node
  property writes per visible entity. ADR 0017 spatial-LOD already
  reduces off-camera work; animation director honors the same
  visibility gate.
- **No effect types added** — Invariant #2 (no semantic effects)
  unchanged. Animation reads state; rules don't fire animation
  effects.
- **Composes with ADR 0036 (lifecycle / aging)** — per-stage
  meshes (`infant_3d`, `child_3d`, `adult_3d`, `elder_3d`) each
  define their own animations; mesh swap on stage transition
  carries new animations automatically.
- **Composes with ADR 0029 (schedule)** — `animation_state_rules`
  read `current_verb` (set by schedule_director) without any
  cross-module wiring; both modules share entity state as the
  contract surface.
- **Soul Layer 4 (kinetic juice) + Layer 2 (visual identity) gain
  authoring substrate.** Walk-cycle limbs = silhouette readability
  in motion. Hit reactions on damage = juice. Both currently
  impossible.

### Negative

- **Mesh authoring complexity grows.** Authors who want
  animations must:
  - Name primitives consistently (left_arm vs left-arm vs LeftArm
    is a footgun — convention enforced by skill prompts).
  - Author keyframe arrays carefully (off-by-one in the wraparound
    keyframe = visible glitch every loop boundary).
  - Choose state conditions that don't ping-pong at thresholds
    (a velocity hovering at 0.099–0.101 would flicker idle/walk
    per frame; mitigation deferred but called out in skill).
- **Piece-name-as-string lookup is fragile** — typo "left_arn" =
  silent skip + warning. Validator (below) catches at sync time.
- **Three primitives now have rotation overlap risk**: authored
  `rotation_deg` on a primitive + an animation track touching the
  same axis will overwrite the authored rotation while the state
  is active. Spec choice: tracks REPLACE; baseline = animation's
  first keyframe (authors who want the authored rotation as base
  add it as the keyframe value). Documented loud.

### Neutral

- Existing 13 demos continue to work unchanged (no `animations`
  field = no director attaches).
- No save/load impact (animation is presentational; nothing
  persists).
- No save schema migration needed (no new state fields on entities).
- No ADR 0017 spatial-LOD changes needed; animation director just
  honors `_visible` on the entity_mesh_3d node.

## Alternatives considered

### A) Import `.glb` files with embedded animations

Tier 1 of `entity_mesh_3d.gd` already supports loading PackedScene
or Mesh resources from `.glb` / `.gltf` files (per ADR 0007).
PackedScenes can ship their own AnimationPlayer + tracks authored
in Blender.

**Pros**: industry-standard, sophisticated authoring tools, no new
engine code, no JSON schema growth.

**Cons**:
- Contradicts the **code-drawn aesthetic** — Yume's signature look
  is the composed-from-primitives style. .glb assets pull authoring
  outside the JSON-declarative plane (you'd open Blender to tweak
  a walk cycle).
- Doesn't solve for **the merchant game** or any existing demo —
  none use .glb meshes; all use code-drawn.
- Authoring asymmetry: per-game glb pipelines = per-game DCC
  workflow, contradicting the "LLMs author Yume games end-to-end
  in JSON" pipeline.
- Even with .glb support, we'd still need the **state-rule layer**
  to pick which animation to play per entity-state. So this option
  is incomplete on its own.

Verdict: keep .glb support working as today (tier 1); add the
declarative primitive (this ADR) for the much more common code-drawn
case (tier 2). A future game can use both.

### B) Godot's AnimationPlayer node per entity

Spawn a Godot `AnimationPlayer` node under each entity_mesh_3d,
with `Animation` resources built at load time from the JSON
tracks. Yume's animation_director becomes a thin "pick which
AnimationPlayer.play() to call" layer.

**Pros**: reuses Godot's mature animation runtime, including
non-linear interpolation, signal-on-finish, blend trees if we
ever want them.

**Cons**:
- AnimationPlayer's track addressing uses NodePath — fragile to
  scene-tree shape, expensive to build at load time, opaque to
  debug.
- Building an Animation resource per state per entity at load
  multiplies asset count by N×M (entities × states). For
  Aldenmere's 200-NPC scale = 800+ Animation resources at load.
  Linear-interp-from-JSON-arrays at frame time is cheaper.
- Adds Node-tree complexity. Per ADR 0021 (Yume = JSON layer over
  Godot), we should expose Godot's primitives — but we should
  EXPOSE the cheap primitive (transform writes), not the heavy
  one (full AnimationPlayer).
- Future ADR could promote to AnimationPlayer if we ever need
  blend trees / additive layering / non-linear curves. Today we
  don't.

Verdict: defer. The simple per-frame interp (this ADR) covers
Phase 1 + 2 + 3 needs without paying AnimationPlayer's complexity
cost. A future ADR can promote IF a real need surfaces.

### C) Per-frame full-body re-rendering

Discard the named-piece concept; on every frame, rebuild the
entire mesh with shifted primitive positions per state.

**Pros**: zero name dependency; no piece-lookup overhead.

**Cons**: discards + re-allocates 6+ MeshInstance3D nodes per
entity per frame (200 NPCs × 6 pieces × 60 fps = 72k
allocations/sec). Catastrophic GC pressure. Discards Godot's
material caching. Easily 100x more expensive than per-piece
property writes.

Verdict: rejected.

### D) Defer animation entirely; ship Aldenmere Phase 1 with sliding NPCs

**Pros**: zero engine work this session; fastest path to a
playable Phase 1 prototype.

**Cons**:
- Phase 1's contemplative aesthetic dies on contact with the
  player. The roadmap is explicit: animation is BLOCKING for the
  feel, not optional polish.
- Punts the work to "later" — but Phase 2-4 each layer additional
  NPC behavior on top of motion (occupations, factions, dynasty),
  multiplying the cost of the "cold mesh" complaint over time.
- Contradicts the post-mortem ritual: the merchant game shipped
  feature-complete-but-soulless and got rebuilt with soul layers;
  shipping Aldenmere with the same gap is a known repeat-failure.

Verdict: rejected. Ship animation as a Phase 1 BLOCKING ADR.

## Implementation sketch

### `mesh_lib.gd` — gain `name` field

Single edit in `build_primitives_into` after `parent.add_child(mi)`:

```gdscript
if p.has("name"):
    mi.name = str(p["name"])
```

That's it. Backwards-compat by construction — primitives without
the field get Godot's auto-generated name.

### `animation_director.gd` — new module (~180 LoC)

```gdscript
extends RefCounted
class_name AnimationDirector

## Per-entity animation interpreter (ADR 0035). Reads animations
## block from a mesh def + a parent Node3D containing the mesh's
## primitive children. Applies per-piece transforms each frame
## based on declarative state-machine rules. Cheap: cached piece
## refs; per-frame work is N tracks × linear interp + 1 property
## write each.

var _mesh_def: Dictionary       # mesh def from meshes.json
var _root: Node3D               # parent mesh root (entity_mesh_3d)
var _entity: Node               # Entity (for state reads)
var _animations: Dictionary     # name → animation block
var _state_rules: Array         # animation_state_rules
var _piece_cache: Dictionary    # piece_name → MeshInstance3D ref
var _missing_pieces_warned: Dictionary  # one-shot warning dedup
var _baseline: Dictionary       # piece_name → {pos: Vec3, rot: Vec3} authored rest
var _active_state: String = ""  # currently-playing state
var _state_started_at: float = 0.0  # seconds since this state activated


static func from_mesh_def(mesh_def: Dictionary, root: Node3D, entity: Node, env: Dictionary) -> AnimationDirector:
    if not (mesh_def.get("animations") is Dictionary): return null
    if not (mesh_def.get("animation_state_rules") is Array): return null
    var d := AnimationDirector.new()
    d._mesh_def = mesh_def
    d._root = root
    d._entity = entity
    d._animations = mesh_def["animations"]
    d._state_rules = mesh_def["animation_state_rules"]
    if not d._has_default_rule():
        EngineError.raise(env, EngineError.ANIMATION_NO_DEFAULT,
            "AnimationDirector: animation_state_rules missing 'default' fallback",
            {"mesh": mesh_def.get("_origin", "?")},
            "Add a {default: <state_name>} entry as the LAST rule.")
        return null
    d._cache_baselines()
    return d


func _cache_baselines() -> void:
    # For each piece referenced by any track, snapshot the authored
    # pos + rotation as the rest pose. Animation tracks delta on top.
    for state_name in _animations.keys():
        var anim: Dictionary = _animations[state_name]
        for track in (anim.get("tracks", []) as Array):
            var piece_name := str(track.get("piece", ""))
            if piece_name == "" or _baseline.has(piece_name): continue
            var node := _find_piece(piece_name)
            if node == null: continue
            _baseline[piece_name] = {
                "pos": node.position,
                "rot": node.rotation,
                "scale": node.scale,
            }


func tick(now_seconds: float) -> void:
    # Called from entity_mesh_3d._process. Pick state, advance time.
    var picked := _pick_state()
    if picked != _active_state:
        _active_state = picked
        _state_started_at = now_seconds
    if _active_state == "" or not _animations.has(_active_state): return
    var anim: Dictionary = _animations[_active_state]
    var dur := float(anim.get("duration", 1.0))
    if dur <= 0.0: return
    var elapsed := now_seconds - _state_started_at
    var t: float
    if bool(anim.get("loop", true)):
        t = fposmod(elapsed, dur) / dur
    else:
        t = clamp(elapsed / dur, 0.0, 1.0)
    for track in (anim.get("tracks", []) as Array):
        _apply_track(track, t)


func _pick_state() -> String:
    for rule in _state_rules:
        if not (rule is Dictionary): continue
        if rule.has("default"):
            return str(rule["default"])
        if rule.has("if_velocity_gt") and _vel_len() > float(rule["if_velocity_gt"]):
            return str(rule.get("state", ""))
        if rule.has("if_velocity_lt") and _vel_len() < float(rule["if_velocity_lt"]):
            return str(rule.get("state", ""))
        if rule.has("if_state_eq"):
            var spec: Dictionary = rule["if_state_eq"]
            for k in spec.keys():
                if _entity.get_state(k, null) == spec[k]:
                    return str(rule.get("state", ""))
        if rule.has("if_state_in"):
            var spec2: Dictionary = rule["if_state_in"]
            for k in spec2.keys():
                if (spec2[k] as Array).has(_entity.get_state(k, null)):
                    return str(rule.get("state", ""))
        if rule.has("if_tag") and _entity.has_tag(str(rule["if_tag"])):
            return str(rule.get("state", ""))
    return ""


func _apply_track(track: Dictionary, t: float) -> void:
    var piece_name := str(track.get("piece", ""))
    var node := _find_piece(piece_name)
    if node == null: return
    var base: Dictionary = _baseline.get(piece_name, {})
    var pos: Vector3 = base.get("pos", node.position)
    var rot: Vector3 = base.get("rot", node.rotation)
    var scl: Vector3 = base.get("scale", node.scale)
    for key in track.keys():
        if key == "piece": continue
        var keys = track[key]
        if not (keys is Array) or (keys as Array).size() < 1: continue
        var v := _interp_keys(keys, t)
        match key:
            "rotation_x": rot.x = v
            "rotation_y": rot.y = v
            "rotation_z": rot.z = v
            "translation_x": pos.x = base.get("pos", Vector3.ZERO).x + v
            "translation_y": pos.y = base.get("pos", Vector3.ZERO).y + v
            "translation_z": pos.z = base.get("pos", Vector3.ZERO).z + v
            "scale_x": scl.x = v
            "scale_y": scl.y = v
            "scale_z": scl.z = v
    node.position = pos
    node.rotation = rot
    node.scale = scl


func _interp_keys(keys: Array, t: float) -> float:
    # Linear interpolation across keyframes, t in [0, 1].
    var n := keys.size()
    if n == 1: return float(keys[0])
    var span := 1.0 / float(n - 1)
    var idx_f := t / span
    var idx0 := int(floor(idx_f))
    var idx1 := min(idx0 + 1, n - 1)
    var frac := idx_f - float(idx0)
    return lerp(float(keys[idx0]), float(keys[idx1]), frac)


func _find_piece(piece_name: String) -> Node3D:
    if _piece_cache.has(piece_name):
        return _piece_cache[piece_name]
    var found := _root.find_child(piece_name, true, false)
    if found == null:
        if not _missing_pieces_warned.has(piece_name):
            _missing_pieces_warned[piece_name] = true
            push_warning("AnimationDirector: piece '%s' not found under mesh root" % piece_name)
        return null
    _piece_cache[piece_name] = found
    return found


func _vel_len() -> float:
    var v = _entity.get_state("velocity", null)
    if v is Vector2: return (v as Vector2).length()
    if v is Vector3: return (v as Vector3).length()
    return 0.0


func _has_default_rule() -> bool:
    for rule in _state_rules:
        if rule is Dictionary and rule.has("default"): return true
    return false
```

### `entity_mesh_3d.gd` — wire the director

After `_build_mesh_children()` in tier 2, before `_apply_shadow_only_if_set`:

```gdscript
_animation_director = AnimationDirector.from_mesh_def(mesh_def, self, ent, _env())
```

In `_process`, after `_sync_yaw()`:

```gdscript
if _animation_director != null:
    _animation_director.tick(Time.get_ticks_msec() / 1000.0)
```

Estimated total: **~200 LoC** across both files.

### Validator extension (`tools/validate_meshes.py` or similar)

For each mesh def with `animations`, verify:
1. Every track's `piece` matches a primitive's `name` in the same
   def. Catches typos at sync time.
2. `animation_state_rules` contains a `default` entry.
3. Each rule's `state` (when not `default`) names a state in
   `animations`.
4. `duration > 0` for every animation.
5. Each track has at least one keyframe.

Failure exits 1 in `--strict` mode (matches `validate_screens.py`
pattern, ADR 0011 / `.claude/rules/visual-qa.md`).

## Test plan

New section `test_animation` in `godot/scripts/engine/tests/test_runner.gd`.
~9 unit tests covering the API surface:

| Test | Verifies |
|---|---|
| `test_animation_state_pick_default` | rules list with only `default` returns that state |
| `test_animation_state_pick_velocity` | `if_velocity_gt: 0.1` picks "walk" when velocity.length() = 0.5 |
| `test_animation_state_pick_state_eq` | `if_state_eq: {current_verb: "chop"}` picks "chop" when state.current_verb = "chop" |
| `test_animation_state_pick_priority` | first matching rule wins; later rules ignored |
| `test_animation_interp_at_t_zero` | at t=0, value equals first keyframe |
| `test_animation_interp_at_t_one` | at t=1 (loop), wraps to first keyframe (looping) OR holds last keyframe (non-looping) |
| `test_animation_interp_midpoint` | between two keyframes, value is linear midpoint |
| `test_animation_loop_wraparound` | elapsed time > duration wraps via fposmod |
| `test_animation_missing_default_errors` | `from_mesh_def` returns null + emits ANIMATION_NO_DEFAULT when rules omit default |
| `test_animation_missing_piece_warns_skips` | track referencing nonexistent piece logs warning, doesn't crash, other tracks proceed |
| `test_animation_no_animations_field` | mesh def without `animations` → director returns null; entity renders unchanged |
| `test_animation_multi_track_concurrent` | walk state with 4 tracks → all 4 pieces' transforms updated each frame |

12 tests total (one extra than the roadmap budget — covers all
boundary cases). Standard `_section("animation (ADR 0035)")` in
test_runner.gd.

## Performance budget

Per-frame cost per visible entity with animation:

| Step | Cost |
|---|---|
| `_pick_state` (rule loop) | O(R) where R = rule count, typical R ≤ 5; ~5 dict reads + 1 state field read |
| `tick` outer (mod, lerp setup) | O(1); 2 floats |
| `_apply_track` per track | O(K) where K = keyframes; typical K = 5; 2 array reads + 1 lerp + 3 property writes |
| Track count per entity | typical 4-8 |

Estimate per entity per frame: ~30-50 small operations + ~10
property writes. At 60 fps × 200 NPCs × ~7 tracks each = ~84k
property writes/sec — well within Godot's threshold for 60 fps
on mid-tier hardware (millions of property writes/sec budget).

ADR 0017 spatial-LOD already gates `entity_mesh_3d` visibility for
off-camera entities; the animation director honors that
implicitly (called from `_process`, which Godot stops when
`visible = false` for the parent — verified in pinned 4.6.1).

For Aldenmere Phase 3 scale (200 NPCs visible) + Phase 4 scale
(50-200 visible at any time but 1000+ total in world), spatial-LOD
keeps the render-frame work bounded. No additional throttling
needed.

## Migration / backwards compat

- **Existing 13 demos**: unchanged. Each demo's `meshes.json` lacks
  `animations`; AnimationDirector returns null on construction;
  `entity_mesh_3d._process` skips the directorless branch. Zero
  behavior change.
- **Existing primitives without `name`**: render exactly as today.
  The only change to `build_primitives_into` is the conditional
  `mi.name = str(p["name"])` after the `add_child` call.
- **No save format changes**: animation is presentational only.
- **No content schema migration tooling needed**: animations is
  additive.
- **Skill updates** (separate from engine ADR): yume-asset-designer
  + yume-visual-designer + (new) yume-animation-designer SKILLs
  guide authors on naming conventions, walk-cycle authoring,
  state-rule patterns. Updates land alongside engine
  implementation.

## Visual gate (per `.claude/rules/visual-qa.md`)

Animation is a **rendering-primitive change**. The visual gate is
mandatory before this ADR's implementation is declared done.

Verification protocol (run after engine implementation lands):

1. **Static rest pose check** — capture a 3D demo (doomarena3d or
   merchant) with the new mesh_lib `name` field present but no
   `animations` block. Verify: identical to baseline capture from
   before the change. **Regression tripwire**: any visible
   difference = the `name` field broke primitive layout.
2. **Animated walking NPC** — author a `merchant_npc_3d` mesh with
   the example `walk` animation in this ADR. Author a scenario
   with one NPC walking east at velocity 0.5. Capture frames at
   t=0.0, t=0.15, t=0.3, t=0.45 (full walk cycle = 0.6s). Verify:
   - Frame t=0: limbs at neutral pose
   - Frame t=0.15: left arm forward, right arm back, opposing legs
   - Frame t=0.3: limbs back at neutral
   - Frame t=0.45: left arm back, right arm forward
   - **Fail flag**: if NPC slides without limb motion, director
     not wired
   - **Fail flag**: if all 4 limbs move in phase, track signs
     wrong or director applying same value to all pieces
3. **State transition** — same scenario, but NPC stops walking
   mid-frame (velocity → 0). Capture 1s after stop. Verify:
   - Limbs return to idle pose; head idle-bobs
   - **Fail flag**: limbs frozen mid-walk-cycle = state didn't
     transition
4. **Multi-state** — NPC with `current_verb` set to "chop_wood".
   Capture mid-chop. Verify:
   - Right arm raised, torso slightly bent
   - **Fail flag**: still showing walk cycle = `if_state_eq`
     evaluation broken
5. **Missing-piece graceful** — author a track referencing piece
   "left_hand" (not in mesh def). Run scenario. Verify:
   - Other tracks still apply (left_arm, right_arm, etc. still
     animate)
   - One-shot warning in stderr
   - **Fail flag**: crash or other tracks stop = isolation broken

VQA prompts use the structure mandated by `.claude/rules/visual-qa.md`
(falsifiable criteria + specific fail flags).

## Operator surface declaration

Per the operator-surface boundary discipline established in ADR
0028 (concern #1): **animation introduces zero new effect types,
zero new query operators, zero new triggers**. The only growth is
mesh-def shape (animations + animation_state_rules) + one engine
module that's pure interpreter. The contract surface grows by
**rendering-side primitives only** — parallel to mesh / shape
existing rendering vocabulary.

Future animation features (cubic interp, blend trees, additive
layers, root-motion) require their own ADRs.

## References

- `docs/games/aldenmere/engine_roadmap.md` — Phase 1 BLOCKING
  designation; this ADR is first in the slate.
- `docs/games/aldenmere/world.md` § "Phase 1 — Survival" —
  contemplative aesthetic dependency on visible walking.
- `docs/30_framework_primitives.md` Invariant #1 (JSON-only
  content), #2 (no semantic effects), #8 (engine = primitives +
  interpreter) — animation is content-shape (JSON) + interpreter
  (animation_director.gd); zero effect types added.
- `docs/adr/0007-...` — .glb model loading (alternative A);
  preserved as tier 1 of `entity_mesh_3d.gd`.
- `docs/adr/0017-spatial-lod-rule-scheduling.md` — visibility
  gating; animation director honors it via Godot `_process`
  semantics.
- `docs/adr/0021-yume-as-json-layer-over-platform.md` — exposes
  Godot's transform writes; doesn't reimplement AnimationPlayer.
- `docs/adr/0027-cross-game-json-reuse-system.md` — `@lib.X.Y`
  references; future `@lib.animations.bipedal_walk` parameterized
  template (Phase 2 catalog work, deferred).
- `godot/scripts/engine/mesh_lib.gd` — gains `name` field on
  primitives.
- `godot/scripts/renderer_3d/entity_mesh_3d.gd` — wires
  AnimationDirector into `_process` after position/yaw sync.
- `.claude/rules/engine-scripts.md` § visual gate — mandatory VQA
  before merge.
- `.claude/rules/visual-qa.md` — capture + falsifiable-criteria
  protocol.
- `.claude/rules/soul.md` Layer 4 (kinetic juice) + Layer 2
  (visual identity) — animation is the authoring substrate for
  both layers.

## Cross-ADR dependencies

**None blocking.** This ADR can land independently of every other
proposed Aldenmere ADR (0029 schedule, 0030 class, 0031 zone-state,
0032 faction, 0033 tech-tree, 0034 dynasty, 0036 lifecycle).

**Composes with**:
- ADR 0029 (schedule) — `current_verb` set by schedule_director is
  read by `if_state_eq` rules. No engine cross-wiring; both modules
  meet at entity state.
- ADR 0036 (lifecycle / aging) — per-stage mesh swaps carry their
  own `animations` block. Stage transition replaces the entire
  mesh + animation set in lockstep.
- ADR 0026 (party-member primitive) — leashed NPCs have velocity;
  `if_velocity_gt` walk state fires automatically.

**Implementation can land before**: every Aldenmere ADR (this is
roadmap position #1).

**Implementation must land before**: any Aldenmere phase build.
Phase 1 cannot ship without this; Phase 2-4 inherit the requirement.
