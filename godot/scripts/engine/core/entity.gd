extends Node
class_name Entity

## Primitive #1 — Entity.
##
## Contract: `docs/30_framework_primitives.md` §1
##
## A single, generic node type. Renderer-agnostic — does NOT extend Node2D or
## Node3D. Position lives in `state.position` as Vector2 or Vector3 (pure data).
## Renderer attaches a positioned child node (Sprite2D / MeshInstance3D) and
## syncs from `state.position` each frame.
##
## Why no inheritance from Node2D/Node3D: invariant #3 (no entity-class
## hierarchy). Adding Entity2D vs Entity3D would re-introduce the very
## anti-pattern we deleted (Agent / Item / Projectile classes). One Entity;
## renderer chooses the view. Refactor surfaced by W5.0 review (2026-05-01).
##
## Data layout:
##   properties  — static typed values set at spawn, never mutated by rules
##   state       — dynamic typed values, mutated by rules (hp, hunger, position…)
##   tags        — flat string membership set (no hierarchy, no inheritance)
##   visual      — renderer-specific payload (sprite_2d, model_3d, …); engine
##                 itself ignores this, renderers read it
##
## Reserved state fields (engine-recognized, not hardcoded):
##   position    — Vector2 or Vector3. Engine reads via get_position().
##   velocity    — Vector2 or Vector3. Engine motion phase adds this to position.
##   age         — float, in-game years. ADR 0036 lifecycle director increments
##                 per in-game year + crosses life_stage thresholds. Engine
##                 itself doesn't read; primitive is interpreter-driven.
##   life_stage  — string, one of {"infant", "child", "adult", "elder", "dead"}
##                 by ADR 0036's standard human lifecycle, OR custom values
##                 from a per-game @lib.lifecycles.X template. Engine doesn't
##                 read; renderers may swap mesh on transitions.
##   yaw         — float radians, Y-axis rotation. 3D + 2D renderers apply
##                 if set (per state.yaw commit on 2026-05-09). Idempotent.
##   class_progress — dict {class_id: {level, xp, ...}}. ADR 0030 class
##                 primitive reads/writes; engine itself doesn't recognize.
##   known_techs — Array of tech_id strings. ADR 0033 tech-tree primitive
##                 reads/writes.
##   dynasty_id  — string or null. ADR 0034 dynasty primitive reads. Phase 3
##                 entities default to null for Phase 4 forward-compat.

# ============================================================
# DATA
# ============================================================

var def_id: String = ""             # template definition id from entities.json
var instance_id: String = ""        # unique per spawn; set by world loader
var properties: Dictionary = {}     # static
var state: Dictionary = {}          # dynamic (includes position + velocity)
var tags: Array[String] = []
var visual: Dictionary = {}


# ============================================================
# CONSTRUCTION
# ============================================================

## Factory: build from a loaded definition dict plus optional overrides.
## Overrides can set:
##   state      — merged onto state_init (shallow)
##   properties — merged onto properties (shallow)
##   tags       — appended (deduped)
##   position   — Vector2/Vector3 or [x, y]/[x, y, z] array → goes into state.position
##   visual     — merged (shallow)
static func create(def: Dictionary, inst_id: String, overrides: Dictionary = {}) -> Entity:
	var e := Entity.new()
	e.def_id = str(def.get("id", ""))
	e.instance_id = inst_id
	e.name = inst_id
	e.properties = (def.get("properties", {}) as Dictionary).duplicate(true)
	e.state = (def.get("state_init", {}) as Dictionary).duplicate(true)
	for t in def.get("tags", []):
		e.tags.append(str(t))
	e.visual = (def.get("visual", {}) as Dictionary).duplicate(true)
	# Normalize reserved spatial state fields. JSON loads [0,0] as Array;
	# we want Vector2/Vector3 throughout for math.
	if e.state.has("position"):
		e.state["position"] = _normalize_position(e.state["position"])
	else:
		e.state["position"] = Vector2.ZERO
	if e.state.has("velocity"):
		e.state["velocity"] = _normalize_position(e.state["velocity"])
	if not overrides.is_empty():
		e._apply_overrides(overrides)
	return e


func _apply_overrides(overrides: Dictionary) -> void:
	if overrides.has("state") and overrides["state"] is Dictionary:
		for k in (overrides["state"] as Dictionary):
			var v = overrides["state"][k]
			# Normalize spatial fields from JSON arrays to Vector2/Vector3.
			# Without this, override `state.velocity = [0, -400]` stays an
			# Array and motion integrator skips it (silent bug).
			if (str(k) == "position" or str(k) == "velocity") and v is Array:
				v = _normalize_position(v)
			state[k] = v
	if overrides.has("properties") and overrides["properties"] is Dictionary:
		for k in (overrides["properties"] as Dictionary):
			properties[k] = overrides["properties"][k]
	if overrides.has("tags") and overrides["tags"] is Array:
		for t in overrides["tags"]:
			var ts: String = str(t)
			if not (ts in tags):
				tags.append(ts)
	if overrides.has("visual") and overrides["visual"] is Dictionary:
		for k in (overrides["visual"] as Dictionary):
			var v = (overrides["visual"] as Dictionary)[k]
			# Deep-merge `params` so instances can override individual color
			# slots (e.g. just `wall`) without nuking the def's other params
			# (`roof`, `door`, `window`). Without this, content authors
			# who want a per-instance color tweak have to re-specify ALL of
			# the mesh's params on every instance — bloated and error-prone.
			# Empirical case 2026-05-09: per-district palette discipline
			# in pendrel needed to override 1-2 colors per cottage/forge/
			# tavern; deep-merge makes that one-line per instance.
			if k == "params" and v is Dictionary and visual.get("params", null) is Dictionary:
				for pk in (v as Dictionary):
					(visual["params"] as Dictionary)[pk] = (v as Dictionary)[pk]
			else:
				visual[k] = v
	if overrides.has("position"):
		state["position"] = _normalize_position(overrides["position"])


# ============================================================
# TAGS
# ============================================================

func has_tag(tag: String) -> bool:
	return tag in tags

func add_tag(tag: String) -> void:
	if not has_tag(tag):
		tags.append(tag)

func remove_tag(tag: String) -> void:
	tags.erase(tag)


# ============================================================
# STATE
# ============================================================

func get_state(field: String, default = null):
	return state.get(field, default)

func set_state(field: String, value) -> void:
	state[field] = value

func add_state(field: String, delta: float) -> void:
	state[field] = float(state.get(field, 0)) + delta


# ============================================================
# PROPERTIES (read-only by convention)
# ============================================================

func get_property(field: String, default = null):
	return properties.get(field, default)


# ============================================================
# POSITION (in state, dimension-agnostic — Vector2 or Vector3)
# ============================================================

## Returns whatever's in state.position. Vector2 by default; can be Vector3 in
## 3D scenes. Renderer reads this each frame to update its visual child node.
func get_position() -> Variant:
	return state.get("position", Vector2.ZERO)

func set_position(p) -> void:
	state["position"] = _normalize_position(p)

## Convenience for spatial queries that must reduce to a 2D plane regardless
## of source dimensionality. Convention (W5.0): Vector3(x, y, z) → Vector2(x, z).
## XY in 3D = (x, z); Y is height/decorative.
func get_planar_position() -> Vector2:
	var p = state.get("position", Vector2.ZERO)
	if p is Vector2: return p
	if p is Vector3: return Vector2(p.x, p.z)
	if p is Array and (p as Array).size() >= 2:
		return Vector2(float(p[0]), float(p[1]))
	return Vector2.ZERO


# ============================================================
# VELOCITY (reserved state field, dimension-agnostic)
# ============================================================

func get_velocity() -> Variant:
	return state.get("velocity", Vector2.ZERO)

func set_velocity(v) -> void:
	state["velocity"] = _normalize_position(v)


# ============================================================
# SERIALIZATION (for save/load, replay, tests)
# ============================================================

## Produces a plain-data snapshot. Round-trips through JSON.
func snapshot() -> Dictionary:
	var pos = state.get("position", Vector2.ZERO)
	var pos_serialized: Array
	if pos is Vector2: pos_serialized = [pos.x, pos.y]
	elif pos is Vector3: pos_serialized = [pos.x, pos.y, pos.z]
	else: pos_serialized = [0.0, 0.0]
	return {
		"def": def_id,
		"id": instance_id,
		"properties": properties.duplicate(true),
		"state": state.duplicate(true),
		"tags": tags.duplicate(),
		"visual": visual.duplicate(true),
		"position": pos_serialized,
	}


# ============================================================
# UTIL
# ============================================================

## Normalize a position-shaped value to a Vector2 or Vector3.
## Accepts Vector2/Vector3/Array. Array length 2 → Vector2; length 3 → Vector3.
static func _normalize_position(v) -> Variant:
	if v is Vector2 or v is Vector3: return v
	if v is Array:
		var a := v as Array
		if a.size() == 2: return Vector2(float(a[0]), float(a[1]))
		if a.size() == 3: return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector2.ZERO
