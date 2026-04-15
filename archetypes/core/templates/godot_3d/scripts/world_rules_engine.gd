extends Node

## World Rules Engine — reads data_root/world_rules.json, ticks each rule on
## its own Timer, applies effects to matching targets.
##
## MVP scope: agent need rules (need_decay, need_restore, damage).
## Deferred: element rules (advance_stage, spread, transform, remove) — Task #56.
##
## Rule schema reminder (from world_rules.json):
##   { id, targets, interval, chance, conditions?, effect:{type, ...} }
##
## Targets:
##   "_agent"                    → all nodes in group "agent"
##   ["wheat_seed", "water", …]  → sim_element nodes with matching element_id
##
## Effects (MVP):
##   need_decay   {need, amount}   → brain.update_need(need, amount)
##   need_restore {need, amount}   → same with positive amount
##   damage       {amount}         → entity.take_damage(amount)
##
## Conditions (MVP — agent-targeted):
##   need_below         {need, threshold}          → agent's need < threshold
##   agent_near_group   {group, radius}            → element w/ that group in radius

var rules: Array = []
var data_root: String = "res://data/sim/"

# Set by sim_world before _ready so we can spawn new elements (advance_stage,
# transform, spread effects). Read directly from sim_world's state.
var world_root: Node3D = null
var terrain_node: Node = null
var elements_config: Array = []
var asset_config: Dictionary = {}


func _ready() -> void:
	# Resolve data_root from meta.json (same pattern as sim_world.gd).
	var meta_file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if meta_file:
		var meta = JSON.parse_string(meta_file.get_as_text())
		if meta is Dictionary:
			var dr: String = str(meta.get("data_root", data_root))
			if not dr.ends_with("/"):
				dr += "/"
			data_root = dr

	# Load world_rules.json from data_root (fall back to res://data/sim/).
	var path: String = data_root + "world_rules.json"
	if not FileAccess.file_exists(path):
		path = "res://data/sim/world_rules.json"
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		push_warning("[Rules] world_rules.json not found")
		return
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return
	rules = data.get("rules", [])

	# Subscribe to the world clock — every tick we evaluate which rules fire.
	var clock: Node = get_node_or_null("/root/SimWorld/WorldClock")
	if not clock:
		# Fallback search anywhere in the tree
		clock = get_tree().root.find_child("WorldClock", true, false)
	if clock and clock.has_signal("tick"):
		clock.tick.connect(_on_world_tick)
		print("[Rules] ", rules.size(), " rules registered, listening to WorldClock")
	else:
		push_warning("[Rules] WorldClock not found — rules engine inactive")


func _on_world_tick(tick_count: int) -> void:
	## Global rules (world_rules.json): fire on (tick % interval == 0).
	## Interval is in TICKS (not seconds).
	for rule in rules:
		if not (rule is Dictionary):
			continue
		var interval: int = int(rule.get("interval", 1))
		if interval <= 0:
			continue
		if tick_count % interval == 0:
			_fire_rule(rule)

	# Per-entity rules (defined on each element in elements.json under "rules").
	# Each sim_element can carry its own lifecycle rules (e.g. campfire fuel decay).
	_fire_entity_rules(tick_count)


func _fire_entity_rules(tick_count: int) -> void:
	# Build element_id → def lookup once per tick for O(1) access
	var el_defs: Dictionary = {}
	for edef in elements_config:
		el_defs[str(edef.get("id", ""))] = edef

	for node in get_tree().get_nodes_in_group("sim_element"):
		if not is_instance_valid(node) or not node.has_meta("element_id"):
			continue
		var eid: String = str(node.get_meta("element_id"))
		var edef: Dictionary = el_defs.get(eid, {})
		var local_rules = edef.get("rules", [])
		if not (local_rules is Array):
			continue
		for rule in local_rules:
			if not (rule is Dictionary):
				continue
			var interval: int = int(rule.get("interval", 1))
			if interval <= 0 or tick_count % interval != 0:
				continue
			var chance: float = float(rule.get("chance", 1.0))
			if randf() > chance:
				continue
			if not _conditions_met(node, rule.get("conditions", null)):
				continue
			var effect: Dictionary = rule.get("effect", {})
			var effect_type: String = str(effect.get("type", ""))
			_apply_effect(node, effect_type, effect, str(rule.get("id", "?")))


func _fire_rule(rule: Dictionary) -> void:
	var rule_id: String = str(rule.get("id", "?"))
	var chance: float = float(rule.get("chance", 1.0))
	var effect: Dictionary = rule.get("effect", {})
	var effect_type: String = str(effect.get("type", ""))
	var targets_spec = rule.get("targets", [])
	if not (targets_spec is Array):
		return

	var candidates: Array = _resolve_targets(targets_spec)
	print("[Rules:tick] ", rule_id, " candidates=", candidates.size(), " effect=", effect_type)
	for c in candidates:
		# Roll per-candidate so different agents get different decay outcomes
		# (for future randomness; for decay with chance=1.0 this is a no-op).
		if randf() > chance:
			continue
		if not _conditions_met(c, rule.get("conditions", null)):
			continue
		_apply_effect(c, effect_type, effect, rule.get("id", ""))


func _resolve_targets(spec: Array) -> Array:
	var out: Array = []
	for t in spec:
		var name: String = str(t)
		if name == "_agent":
			for a in get_tree().get_nodes_in_group("agent"):
				out.append(a)
		else:
			# Element targets — deferred to Task #56.
			# For now, scan sim_element nodes whose element_id matches.
			for e in get_tree().get_nodes_in_group("sim_element"):
				if e.has_meta("element_id") and str(e.get_meta("element_id")) == name:
					out.append(e)
	return out


func _conditions_met(candidate: Node, conds) -> bool:
	if not (conds is Dictionary) or conds.is_empty():
		return true

	# need_below — candidate must be an agent whose brain tracks needs
	if conds.has("need_below"):
		var nb: Dictionary = conds["need_below"]
		var need_id: String = str(nb.get("need", ""))
		var threshold: float = float(nb.get("threshold", 0))
		var brain: Node = candidate.get("brain") if candidate.has_method("get") else null
		if brain and brain.has_method("get_needs_summary"):
			var summary: Dictionary = brain.get_needs_summary()
			if summary.has(need_id):
				var cur: float = float(summary[need_id].get("current", 999))
				if not (cur < threshold):
					return false
			else:
				return false
		else:
			return false

	# agent_near_group — any sim_element with that group within radius of agent
	if conds.has("agent_near_group"):
		var ang: Dictionary = conds["agent_near_group"]
		var group_name: String = str(ang.get("group", ""))
		var radius: float = float(ang.get("radius", 3))
		var agent_pos: Vector3 = candidate.global_position if candidate is Node3D else Vector3.ZERO
		var found := false
		for e in get_tree().get_nodes_in_group("sim_element"):
			if not (e is Node3D):
				continue
			var groups = e.get_meta("groups") if e.has_meta("groups") else null
			if groups is Dictionary and groups.has(group_name):
				if e.global_position.distance_to(agent_pos) <= radius:
					found = true
					break
		if not found:
			return false

	# nearby_element — element-rule version: candidate is a sim_element, check
	# for another sim_element with given id within radius.
	if conds.has("nearby_element"):
		var ne: Dictionary = conds["nearby_element"]
		var target_id: String = str(ne.get("id", ""))
		var radius: float = float(ne.get("radius", 5))
		if not (candidate is Node3D):
			return false
		var origin: Vector3 = candidate.global_position
		var found := false
		for e in get_tree().get_nodes_in_group("sim_element"):
			if not (e is Node3D) or e == candidate:
				continue
			if str(e.get_meta("element_id", "")) == target_id:
				if e.global_position.distance_to(origin) <= radius:
					found = true
					break
		if not found:
			return false

	# state_below / state_above — check candidate's own meta.state field value
	if conds.has("state_below"):
		var sb: Dictionary = conds["state_below"]
		var field: String = str(sb.get("field", ""))
		var threshold: float = float(sb.get("threshold", 0))
		var state: Dictionary = candidate.get_meta("state", {}) if candidate.has_meta("state") else {}
		if field == "" or float(state.get(field, 0)) >= threshold:
			return false
	if conds.has("state_above"):
		var sa: Dictionary = conds["state_above"]
		var field: String = str(sa.get("field", ""))
		var threshold: float = float(sa.get("threshold", 0))
		var state: Dictionary = candidate.get_meta("state", {}) if candidate.has_meta("state") else {}
		if field == "" or float(state.get(field, 0)) <= threshold:
			return false

	# neighbor_group — for spread rules: candidate has a flammable neighbor in radius
	if conds.has("neighbor_group"):
		# Two schemas seen: legacy "neighbor_group: G" with sibling "radius",
		# and dict form {group, radius}. Handle both.
		var ng = conds["neighbor_group"]
		var grp: String = ""
		var radius: float = 2.0
		if ng is Dictionary:
			grp = str(ng.get("group", ""))
			radius = float(ng.get("radius", radius))
		else:
			grp = str(ng)
			radius = float(conds.get("radius", radius))
		if not (candidate is Node3D):
			return false
		var origin: Vector3 = candidate.global_position
		var found := false
		for e in get_tree().get_nodes_in_group("sim_element"):
			if not (e is Node3D) or e == candidate:
				continue
			var groups = e.get_meta("groups") if e.has_meta("groups") else null
			if groups is Dictionary and groups.has(grp):
				if e.global_position.distance_to(origin) <= radius:
					found = true
					break
		if not found:
			return false

	return true


func _apply_effect(candidate: Node, effect_type: String, effect: Dictionary, rule_id: String) -> void:
	match effect_type:
		"need_decay", "need_restore":
			var need_id: String = str(effect.get("need", ""))
			var amount: float = float(effect.get("amount", 0))
			var brain: Node = candidate.get("brain") if candidate.has_method("get") else null
			if brain and brain.has_method("update_need"):
				brain.update_need(need_id, amount)
				if brain.has_method("get_needs_summary"):
					var s: Dictionary = brain.get_needs_summary()
					if s.has(need_id):
						var cur: float = float(s[need_id].get("current", 0))
						print("[Rules] ", rule_id, " → ", candidate.name, " ", need_id, "=", snapped(cur, 0.1))
		"damage":
			var amount: float = float(effect.get("amount", 0))
			if candidate.has_method("take_damage"):
				candidate.take_damage(amount)
				print("[Rules] ", rule_id, " → ", candidate.name, " took ", amount, " damage")
		"remove":
			# Element rule: just remove the candidate from the world.
			if candidate is Node3D:
				print("[Rules] ", rule_id, " → remove ", candidate.name, " at ", candidate.global_position)
			candidate.queue_free()
		"transform":
			# Replace candidate with a different element_id at the same position.
			var to_id: String = str(effect.get("transform_to", ""))
			if to_id == "" or not (candidate is Node3D):
				return
			var pos: Vector3 = candidate.global_position
			candidate.queue_free()
			_spawn_element(to_id, pos, rule_id, "transform")
		"advance_stage":
			# Move candidate to next stage in the stages array, replacing it.
			var stages = effect.get("stages", [])
			if not (stages is Array) or stages.is_empty() or not (candidate is Node3D):
				return
			var current_id: String = str(candidate.get_meta("element_id", ""))
			var idx: int = stages.find(current_id)
			if idx < 0 or idx >= stages.size() - 1:
				return  # already at final stage or not found
			var next_id: String = str(stages[idx + 1])
			var pos: Vector3 = candidate.global_position
			candidate.queue_free()
			_spawn_element(next_id, pos, rule_id, "advance_stage→" + next_id)
		"spread":
			# Spawn a new element of spread_element near the candidate.
			var spread_id: String = str(effect.get("spread_element", ""))
			if spread_id == "" or not (candidate is Node3D):
				return
			var origin: Vector3 = candidate.global_position
			var angle: float = randf() * TAU
			var dist: float = 1.5 + randf()
			var pos: Vector3 = origin + Vector3(cos(angle) * dist, 0, sin(angle) * dist)
			_spawn_element(spread_id, pos, rule_id, "spread")
		"state_add", "state_set":
			# Per-entity mutable state. Used by element lifecycle rules
			# (e.g. campfire fuel decay: state_add field=fuel amount=-1).
			if not candidate.has_meta("state"):
				candidate.set_meta("state", {})
			var state: Dictionary = candidate.get_meta("state")
			var field: String = str(effect.get("field", ""))
			var amount: float = float(effect.get("amount", 0))
			if field == "":
				return
			var old: float = float(state.get(field, 0))
			if effect_type == "state_add":
				state[field] = old + amount
			else:
				state[field] = amount
			candidate.set_meta("state", state)
			print("[Rules] ", rule_id, " → ", candidate.name, " ", field, "=", state[field])
		_:
			pass


func _spawn_element(element_id: String, pos: Vector3, rule_id: String, kind: String) -> void:
	if not world_root:
		push_warning("[Rules] Cannot spawn — world_root not set")
		return
	var node := WorldElements.spawn_one(world_root, element_id, pos, terrain_node, elements_config, asset_config)
	if node:
		print("[Rules] ", rule_id, " → ", kind, " spawned ", element_id, " at ", pos)
