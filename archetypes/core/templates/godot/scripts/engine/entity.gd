extends Node2D
class_name Entity

## Primitive #1 — Entity.
##
## Contract: `docs/30_framework_primitives.md` §1
##
## A single, generic node type. No subclasses. Agent / Item / Projectile / Square
## distinctions emerge from tags and property combinations, never from a class.
##
## Data layout:
##   properties  — static typed values set at spawn, never mutated by rules
##   state       — dynamic typed values, mutated by rules (hp, hunger, temperature…)
##   tags        — flat string membership set (no hierarchy, no inheritance)
##   visual      — renderer-specific payload (sprite_2d, model_3d, …); engine
##                 itself ignores this, renderers read it
##
## Reserved state fields (engine-recognized, not hardcoded):
##   position  — Node2D.position (engine reads/writes directly, not via state)
##   velocity  — Vector2; engine's motion phase applies to position each tick
##   age       — convention: tick-incrementable; nothing special-cases it

# ============================================================
# DATA
# ============================================================

var def_id: String = ""             # template definition id from entities.json
var instance_id: String = ""        # unique per spawn; set by world loader
var properties: Dictionary = {}     # static
var state: Dictionary = {}          # dynamic
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
##   position   — Vector2 or [x, y] array
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
	if not overrides.is_empty():
		e._apply_overrides(overrides)
	return e


func _apply_overrides(overrides: Dictionary) -> void:
	if overrides.has("state") and overrides["state"] is Dictionary:
		for k in (overrides["state"] as Dictionary):
			state[k] = overrides["state"][k]
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
			visual[k] = overrides["visual"][k]
	if overrides.has("position"):
		position = _as_vec2(overrides["position"])


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
# VELOCITY (reserved state field; position is Node2D.position)
# ============================================================

func get_velocity() -> Vector2:
	var v = state.get("velocity", null)
	if v == null: return Vector2.ZERO
	if v is Vector2: return v
	return _as_vec2(v)

func set_velocity(v: Vector2) -> void:
	state["velocity"] = v


# ============================================================
# SERIALIZATION (for save/load, replay, tests)
# ============================================================

## Produces a plain-data snapshot. Round-trips through JSON.
func snapshot() -> Dictionary:
	return {
		"def": def_id,
		"id": instance_id,
		"properties": properties.duplicate(true),
		"state": state.duplicate(true),
		"tags": tags.duplicate(),
		"visual": visual.duplicate(true),
		"position": [position.x, position.y],
	}


# ============================================================
# UTIL
# ============================================================

func _as_vec2(v) -> Vector2:
	if v is Vector2: return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO
