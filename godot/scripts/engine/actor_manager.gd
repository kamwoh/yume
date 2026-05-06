extends RefCounted
class_name ActorManager

## ADR 0016 — Multi-actor framework.
##
## Promotes the singleton actor concept to a first-class binding:
## `world.active_actor_id` identifies the currently-controlled entity.
## Multiple actor profiles can exist; the active one receives input.
##
## Per TD condition #1: SINGLE CODE PATH. At load, if `actors.json` is
## absent, the engine SYNTHESIZES a default config pointing at the
## legacy `actor_tag` entity. Engine code only ever reads from the
## actors registry — no special-cased "legacy" branch.
##
## Phase A scope: synthesized default + switch_actor effect + binding.
## Phase B (later):
##   - Multi-input-device routing (gamepad_2 → player_alt)
##   - Per-actor input_actions_press lists
##   - AI policy hookup (ADR 0018)
##   - camera.mode: "follow_active_actor"


# ============================================================
# STATE
# ============================================================

var _actors: Array = []                 # array of {id, starting_entity_tag, input_device, control_mode}
var _by_id: Dictionary = {}              # id → actor dict
var active_actor_id: String = ""


# ============================================================
# LOADING
# ============================================================

## Load actors from <data_root>/actors.json if present; else synthesize
## default from the World's actor_tag. Always produces a valid config —
## no dual code paths.
##
## actor_tag_fallback: World.actor_tag (default "player"). Used to build
## the synthesized default actor when actors.json is absent.
static func load_or_synthesize(data_root: String, actor_tag_fallback: String) -> ActorManager:
	var am := ActorManager.new()
	var root := data_root.rstrip("/")
	var path := root + "/actors.json"
	if FileAccess.file_exists(path):
		am._load_from_file(path)
	if am._actors.is_empty():
		# No file OR file empty → synthesize default. Single actor whose
		# starting_entity_tag = legacy actor_tag. Behaves identically to
		# pre-ADR-0016 single-player flow.
		am._actors = [{
			"id": "default_player",
			"input_device": "keyboard",
			"control_mode": "human",
			"starting_entity_tag": actor_tag_fallback,
		}]
		am.active_actor_id = "default_player"
	# Index
	for a in am._actors:
		if a is Dictionary and (a as Dictionary).has("id"):
			am._by_id[str((a as Dictionary)["id"])] = a
	return am


func _load_from_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary): return
	var actors_arr = (data as Dictionary).get("actors", [])
	if actors_arr is Array:
		_actors = actors_arr
	active_actor_id = str((data as Dictionary).get("active_actor_id", ""))
	# If file specifies actors but no active_actor_id, default to first
	if active_actor_id == "" and not _actors.is_empty():
		active_actor_id = str((_actors[0] as Dictionary).get("id", ""))


# ============================================================
# ACTOR LOOKUP
# ============================================================

## Find the entity controlled by the given actor_id. Returns "" if no
## matching entity exists. Uses the actor's `starting_entity_tag` to
## locate via env.entities (first entity matching the tag).
func resolve_actor_entity(actor_id: String, entities: Dictionary) -> String:
	var actor: Dictionary = _by_id.get(actor_id, {})
	if actor.is_empty(): return ""
	var tag := str(actor.get("starting_entity_tag", ""))
	if tag == "": return ""
	for inst_id in entities.keys():
		var ent = entities[inst_id]
		if ent != null and ent.has_method("has_tag") and ent.has_tag(tag):
			return str(inst_id)
	return ""


## Resolve the active actor's controlled entity id. Convenience for
## input dispatch + camera follow.
func resolve_active_entity(entities: Dictionary) -> String:
	if active_actor_id == "": return ""
	return resolve_actor_entity(active_actor_id, entities)


## Set a new active actor. Returns false if actor_id unknown (no change).
## Used by world.gd when processing a deferred switch_actor effect.
func set_active(actor_id: String) -> bool:
	if not _by_id.has(actor_id):
		push_warning("ActorManager: switch_actor target '%s' not in registry" % actor_id)
		return false
	active_actor_id = actor_id
	return true


# ============================================================
# DIAGNOSTICS
# ============================================================

func actor_ids() -> Array:
	return _by_id.keys()


func get_actor(actor_id: String) -> Dictionary:
	return _by_id.get(actor_id, {})
