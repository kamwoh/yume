extends Node

## NeedsDrivenBrain — The Sims meets Minecraft.
## Agent has needs (hunger, thirst, energy). Needs decay over time.
## Agent scans nearby elements, evaluates which action best satisfies urgent needs.
## Scoring: urgency(need) × satisfaction(action) → pick best.
## Same decide() interface as all other brains.
##
## State unification (2026-04-15): need current values live in entity.meta.state
## (same pattern as elements). Brain reads/writes via entity meta. needs_config
## stays brain-local because it has schema (max, critical_threshold, satisfiers).

# Schema (loaded from needs.json) — shared across all agents using this brain.
var needs_config: Array = []
# Quick lookup: need_id → {max, critical, satisfiers}
var _need_schema: Dictionary = {}
# Cached entity reference (parent). Entity's meta.state holds the current values.
var _entity: Node = null

# Recipes
var known_recipes: Array = []

# Items + element definitions
var items_config: Array = []
var elements_config: Array = []  # Loaded from elements.json — used to look up drops, groups, hp

# State
var current_plan: Array = []  # [{action, target, ...}]
var plan_index: int = 0
var action_timer: float = 0.0

# Nodes this brain has claimed (marked meta "claimed_by"=our entity_id).
# Released on replan or when plan completes so other agents can target them.
var _claimed_nodes: Array = []

# Tick-driven re-planning: world_clock sets _should_replan=true on tick.
# Brain replans on next decide() call when no plan is active.
var _should_replan: bool = true  # start with true so first decide makes a plan
var _world_clock: Node = null

# Reference to inventory (attached to entity)
var inventory: Node = null


func _ready() -> void:
	# Subscribe to world clock so we replan once per tick (not every frame).
	_world_clock = get_tree().root.find_child("WorldClock", true, false)
	if _world_clock and _world_clock.has_signal("tick"):
		_world_clock.tick.connect(_on_world_tick)


func _on_world_tick(_n: int) -> void:
	_should_replan = true


func _claim(node: Node, entity: CharacterBody3D) -> void:
	if not is_instance_valid(node):
		return
	node.set_meta("claimed_by", entity.get_instance_id())
	_claimed_nodes.append(node)


func _release_claims() -> void:
	for n in _claimed_nodes:
		if is_instance_valid(n) and n.has_meta("claimed_by"):
			n.remove_meta("claimed_by")
	_claimed_nodes.clear()


func init_config(config: Dictionary) -> void:
	# Need schema (shared). State lives on the entity.
	var needs_file := FileAccess.open("res://data/sim/needs.json", FileAccess.READ)
	if needs_file:
		var data = JSON.parse_string(needs_file.get_as_text())
		if data is Dictionary:
			needs_config = data.get("needs", [])

	_entity = get_parent()
	var state: Dictionary = _entity.get_meta("state", {}) if _entity and _entity.has_meta("state") else {}
	for need in needs_config:
		var nid: String = str(need.get("id", ""))
		if nid == "":
			continue
		_need_schema[nid] = {
			"max": float(need.get("max", 100.0)),
			"critical": float(need.get("critical_threshold", 10.0)),
			"satisfiers": need.get("satisfiers", []),
		}
		# Seed entity state with the starting value unless it already has one
		# (e.g. loaded from a saved game or per-agent override).
		if not state.has(nid):
			state[nid] = float(need.get("start", 100.0))
	if _entity:
		_entity.set_meta("state", state)

	# Load recipes
	var recipe_file := FileAccess.open("res://data/sim/recipes.json", FileAccess.READ)
	if recipe_file:
		var data = JSON.parse_string(recipe_file.get_as_text())
		if data is Dictionary:
			known_recipes = data.get("recipes", [])

	# Load element definitions for drop tables / hp lookup
	var el_file := FileAccess.open("res://data/sim/elements.json", FileAccess.READ)
	if el_file:
		var data = JSON.parse_string(el_file.get_as_text())
		if data is Dictionary:
			elements_config = data.get("elements", [])

	# Load items config
	var items_file := FileAccess.open("res://data/sim/items.json", FileAccess.READ)
	if items_file:
		var data = JSON.parse_string(items_file.get_as_text())
		if data is Dictionary:
			items_config = data.get("items", [])

	# Get or create inventory
	var entity = get_parent()
	if entity:
		inventory = entity.get_node_or_null("Inventory")
		if not inventory:
			var inv_script = load("res://scripts/inventory.gd")
			if inv_script:
				inventory = Node.new()
				inventory.name = "Inventory"
				inventory.set_script(inv_script)
				entity.add_child(inventory)
		# Add starting items
		var starting: Array = config.get("starting_items", [])
		for si in starting:
			if inventory:
				inventory.add_item(str(si.get("item", "")), si.get("count", 1))

	print("[NeedsBrain] Initialized: ", _need_schema.keys(), " | Recipes: ", known_recipes.size())


func decide(entity: CharacterBody3D, world_state: Dictionary) -> Dictionary:
	var dt: float = entity.get_process_delta_time()
	action_timer -= dt

	# If executing a plan, advance step-by-step every frame (movement is continuous).
	if current_plan.size() > 0 and plan_index < current_plan.size():
		var step: Dictionary = current_plan[plan_index]
		var result: Dictionary = _execute_step(entity, step, dt)
		if result.get("step_done", false):
			plan_index += 1
			if plan_index >= current_plan.size():
				current_plan = []
				plan_index = 0
				_release_claims()
		return result

	# No plan — replan only when world_clock has ticked (or first call).
	if _should_replan:
		_should_replan = false
		_release_claims()  # old claims released so we re-evaluate freely
		current_plan = _make_plan(entity, world_state)
		plan_index = 0

	return {"action": "idle"}


func get_needs_summary() -> Dictionary:
	## Synthesize old-shape {need_id: {current, max, critical}} by joining
	## state (current values on entity) with schema (max/critical from JSON).
	var out: Dictionary = {}
	var state: Dictionary = _entity.get_meta("state", {}) if _entity and _entity.has_meta("state") else {}
	for nid in _need_schema:
		var schema: Dictionary = _need_schema[nid]
		out[nid] = {
			"current": float(state.get(nid, 0.0)),
			"max": schema.get("max", 100.0),
			"critical": schema.get("critical", 10.0),
		}
	return out


func get_status_label() -> String:
	## One-line description of what this brain is doing right now. Read by HUD.
	if current_plan.size() > 0 and plan_index < current_plan.size():
		return _step_to_label(current_plan[plan_index])
	return "Idle"


func _step_to_label(step: Dictionary) -> String:
	var t: String = str(step.get("type", "?"))
	match t:
		"move_to":
			var tgt = step.get("target", Vector3.ZERO)
			var x: float = tgt.x if tgt is Vector3 else (float(tgt[0]) if (tgt is Array and tgt.size() >= 1) else 0.0)
			var z: float = tgt.z if tgt is Vector3 else (float(tgt[2]) if (tgt is Array and tgt.size() >= 3) else 0.0)
			return "Walking → (%.1f, %.1f)" % [x, z]
		"interact_element":
			return "Using " + str(step.get("element_id", "?"))
		"harvest":
			return "Harvesting " + str(step.get("element_id", "?"))
		"consume":
			return "Eating " + str(step.get("item", "?"))
		"craft":
			return "Crafting " + str(step.get("recipe", "?"))
		"wander":
			return "Wandering"
		"idle_rest":
			return "Resting"
	return t


func update_need(need_id: String, amount: float) -> void:
	if not _entity or not _need_schema.has(need_id):
		return
	var state: Dictionary = _entity.get_meta("state", {})
	var max_val: float = float(_need_schema[need_id].get("max", 100.0))
	var current: float = float(state.get(need_id, max_val))
	state[need_id] = clamp(current + amount, 0.0, max_val)
	_entity.set_meta("state", state)


func _most_urgent_need() -> String:
	var worst_id: String = ""
	var worst_pct: float = 2.0
	var state: Dictionary = _entity.get_meta("state", {}) if _entity and _entity.has_meta("state") else {}
	for need_id in _need_schema:
		var schema: Dictionary = _need_schema[need_id]
		var max_val: float = float(schema.get("max", 100.0))
		var current: float = float(state.get(need_id, max_val))
		var pct: float = current / max(max_val, 0.01)
		if pct < worst_pct:
			worst_pct = pct
			worst_id = need_id
	return worst_id


func _make_plan(entity: CharacterBody3D, _world_state: Dictionary) -> Array:
	## Try each satisfier listed in needs.json for the most urgent need.
	## First achievable satisfier wins. No need-specific hardcoding here —
	## adding a new need = JSON only.
	var urgent_need: String = _most_urgent_need()
	if urgent_need == "":
		return [{"type": "wander"}]

	var state: Dictionary = _entity.get_meta("state", {}) if _entity and _entity.has_meta("state") else {}
	var schema: Dictionary = _need_schema.get(urgent_need, {})
	var max_val: float = float(schema.get("max", 100.0))
	var current: float = float(state.get(urgent_need, max_val))
	var urgency: float = 1.0 - (current / max(max_val, 0.01))
	print("[Brain] ", entity.name, " urgent=", urgent_need, " urgency=", snapped(urgency, 0.01))

	var need_def: Dictionary = _find_need_def(urgent_need)
	var satisfiers: Array = need_def.get("satisfiers", [])
	for sat in satisfiers:
		if not (sat is Dictionary):
			continue
		var plan: Array = _try_satisfier(entity, urgent_need, sat)
		if plan.size() > 0:
			return plan

	# Not urgent? → prefer planting seeds we have, then gathering.
	# Rationale: seeds in inventory are useless unless planted; planting near
	# water (where growth is fast) closes the food loop.
	if urgency < 0.5 and inventory and inventory.has_item("wheat_seed_item"):
		# Walk to nearest water (so seed grows), plant there.
		var water_pos: Vector3 = _find_nearest_element_in_world(entity, "water")
		if water_pos != Vector3.ZERO:
			# Slight offset from water itself so seed lands beside the pool.
			var plant_pos: Vector3 = water_pos + Vector3(randf_range(-2.0, 2.0), 0, randf_range(-2.0, 2.0))
			return [
				{"type": "move_to", "target": plant_pos},
				{"type": "plant", "item": "wheat_seed_item", "seed_element": "wheat_seed"},
			]
		# No water? Plant near self — seed won't grow without water but
		# we're recycling inventory space.
		return [{"type": "plant", "item": "wheat_seed_item", "seed_element": "wheat_seed"}]

	# If not urgent → gather resources.
	if urgency < 0.5:
		# Tool → (element_id, bare_hands_time, bare_hands_drop_count)
		var tool_table: Dictionary = {
			"axe":     {"target": "tree",  "punch_time": 6.0, "punch_count": 1},
			"pickaxe": {"target": "stone", "punch_time": 9.0, "punch_count": 1},
		}
		# First priority: use tools we own (normal harvest, faster, full drops).
		for tool_name in tool_table:
			if not (inventory and inventory.has_item(tool_name)):
				continue
			var target_id: String = tool_table[tool_name]["target"]
			var node: Node3D = _find_nearest_element_node(entity, target_id)
			if not node:
				continue
			_claim(node, entity)
			var edef: Dictionary = _find_element_def(target_id)
			var drops: Array = edef.get("drop", [])
			var recipe: Dictionary = _find_recipe_for_tool(tool_name, target_id)
			var t: float = float(recipe.get("time", 2.0))
			return [
				{"type": "move_to", "target": node.global_position},
				{"type": "harvest", "element_id": target_id, "time": t, "drops": drops},
			]

		# Bootstrap fallback: no tools yet but can craft one if we had materials.
		# Punch tree/stone by hand — slow, 1 yield, no tool needed.
		for tool_name in tool_table:
			var target_id: String = tool_table[tool_name]["target"]
			var node: Node3D = _find_nearest_element_node(entity, target_id)
			if not node:
				continue
			_claim(node, entity)
			var edef: Dictionary = _find_element_def(target_id)
			var drops_full: Array = edef.get("drop", [])
			# Take just the first drop, count 1 (bare-hands is inefficient).
			var drops: Array = []
			if drops_full is Array and drops_full.size() > 0:
				var d0: Dictionary = drops_full[0]
				drops = [{"item": d0.get("item", ""), "count": tool_table[tool_name]["punch_count"]}]
			return [
				{"type": "move_to", "target": node.global_position},
				{"type": "harvest", "element_id": target_id,
				 "time": float(tool_table[tool_name]["punch_time"]), "drops": drops},
			]

		# Can craft something useful?
		if inventory and inventory.has_items([{"item": "wood", "count": 2}, {"item": "cobblestone", "count": 1}]):
			if not inventory.has_item("axe"):
				return [{"type": "craft", "recipe": "craft_axe"}]

	# Default: wander
	return [{"type": "wander"}]


func _execute_step(entity: CharacterBody3D, step: Dictionary, dt: float) -> Dictionary:
	var step_type: String = str(step.get("type", "idle"))

	match step_type:
		"move_to":
			var target = step.get("target", entity.global_position)
			if target is Vector3:
				var dist: float = entity.global_position.distance_to(Vector3(target.x, entity.global_position.y, target.z))
				if dist > 1.5:
					return {"action": "move_to", "target": target}
				else:
					return {"action": "idle", "step_done": true}
			return {"action": "idle", "step_done": true}

		"consume":
			var item_id: String = str(step.get("item", ""))
			if inventory and inventory.remove_item(item_id):
				var need_id: String = str(step.get("need", "hunger"))
				var amount: float = step.get("amount", 30.0)
				update_need(need_id, amount)
				print("[NeedsBrain] Consumed ", item_id, " → ", need_id, " +", amount)
			return {"action": "idle", "step_done": true}

		"harvest":
			# First call seeds the timer; subsequent calls tick it down.
			# When timer elapses: drop items + remove the target sim_element.
			if not step.has("_started"):
				step["_started"] = true
				action_timer = float(step.get("time", 2.0))
				print("[NeedsBrain] ", entity.name, " started harvesting ", step.get("element_id", "?"))
				return {"action": "attack"}
			action_timer -= dt
			if action_timer > 0:
				return {"action": "attack"}
			# Done — apply drops + remove target
			var target_id: String = str(step.get("element_id", ""))
			var target_node: Node3D = _find_nearest_element_node(entity, target_id) if target_id != "" else null
			var drops = step.get("drops", [])
			if inventory and drops is Array:
				for d in drops:
					inventory.add_item(str(d.get("item", "")), int(d.get("count", 1)))
			print("[NeedsBrain] ", entity.name, " harvested ", target_id, " → ", drops, " | inv: ", inventory.to_string_summary() if inventory else "(no inv)")
			if target_node:
				target_node.queue_free()
			return {"action": "idle", "step_done": true}

		"craft":
			var recipe_id: String = str(step.get("recipe", ""))
			for recipe in known_recipes:
				if str(recipe.get("id", "")) == recipe_id:
					var inputs: Array = recipe.get("inputs", [])
					if inventory and inventory.remove_items(inputs):
						var output: Dictionary = recipe.get("output", {})
						inventory.add_item(str(output.get("item", "")), output.get("count", 1))
						print("[NeedsBrain] Crafted: ", output.get("item", ""))
					break
			return {"action": "idle", "step_done": true}

		"interact_element":
			var need_id: String = str(step.get("need", ""))
			var amount: float = step.get("amount", 0.0)
			if need_id != "":
				update_need(need_id, amount)
				print("[NeedsBrain] Interacted: ", need_id, " +", amount)
			# When remove=true, collect the element's drops (if any) + remove it.
			# Lets agents get seed_items from wheat they eat → enables farming.
			if step.get("remove", false):
				var target_id: String = str(step.get("element_id", ""))
				if target_id != "":
					var target_node: Node3D = _find_nearest_element_node(entity, target_id)
					if target_node:
						var edef: Dictionary = _find_element_def(target_id)
						var drops = edef.get("drop", [])
						if drops is Array and inventory:
							for d in drops:
								# Skip the main food_item if need is hunger (avoids doubling —
								# we already satisfied hunger directly by eating, don't ALSO
								# put food_wheat in inventory). Take only secondary drops (seeds).
								var item_id: String = str(d.get("item", ""))
								if need_id == "hunger" and item_id == "food_wheat":
									continue
								inventory.add_item(item_id, int(d.get("count", 1)))
							print("[NeedsBrain] ", entity.name, " picked up drops from ", target_id, " | inv: ", inventory.to_string_summary())
						print("[NeedsBrain] Removing ", target_id, " at ", target_node.global_position)
						target_node.queue_free()
			return {"action": "idle", "step_done": true}

		"idle_rest":
			var duration: float = step.get("duration", 3.0)
			action_timer -= dt
			if action_timer <= 0:
				action_timer = duration
			if action_timer <= dt:
				return {"action": "idle", "step_done": true}
			return {"action": "idle"}

		"wander":
			# Random target
			var rx: float = entity.global_position.x + randf_range(-8, 8)
			var rz: float = entity.global_position.z + randf_range(-8, 8)
			return {"action": "move_to", "target": Vector3(rx, 0, rz), "step_done": true}

		"plant":
			# Consume one seed_item from inventory, spawn a seed element at
			# agent's feet (with small random offset so agents don't stack seeds
			# on the same exact spot during a farming batch).
			var item_id: String = str(step.get("item", "wheat_seed_item"))
			var seed_id: String = str(step.get("seed_element", "wheat_seed"))
			if inventory and inventory.remove_item(item_id):
				var offset := Vector3(randf_range(-0.8, 0.8), 0, randf_range(-0.8, 0.8))
				var sim = entity.get_tree().current_scene
				if sim and sim.has_method("spawn_element_at"):
					sim.spawn_element_at(seed_id, entity.global_position + offset)
					print("[NeedsBrain] ", entity.name, " planted ", seed_id, " at ", entity.global_position + offset)
			return {"action": "idle", "step_done": true}

	return {"action": "idle", "step_done": true}


func _find_need_def(need_id: String) -> Dictionary:
	for n in needs_config:
		if str(n.get("id", "")) == need_id:
			return n
	return {}


func _find_element_def(element_id: String) -> Dictionary:
	for e in elements_config:
		if str(e.get("id", "")) == element_id:
			return e
	return {}


func _find_recipe_for_tool(tool_name: String, element_id: String) -> Dictionary:
	## Return the recipe whose tool matches AND whose target_group is in the
	## element's groups (e.g. axe + tree's "choppable" group → chop_tree recipe).
	var edef: Dictionary = _find_element_def(element_id)
	var el_groups = edef.get("groups", {})
	for r in known_recipes:
		if str(r.get("tool", "")) != tool_name:
			continue
		var tgt_group: String = str(r.get("target_group", ""))
		if tgt_group != "" and el_groups is Dictionary and el_groups.has(tgt_group):
			return r
	return {}


func _try_satisfier(entity: CharacterBody3D, need_id: String, sat: Dictionary) -> Array:
	## Translate one satisfier descriptor into a concrete plan, or [] if not achievable now.
	var amount: float = float(sat.get("amount", 0))
	var remove: bool = sat.get("remove", false)

	# 1. Inventory item — eat directly
	if sat.has("item") and inventory:
		var item_id: String = str(sat["item"])
		if inventory.has_item(item_id):
			return [{"type": "consume", "item": item_id, "need": need_id, "amount": amount}]

	# 2. World element by id — walk to it, interact (claim so others don't target)
	if sat.has("element_id"):
		var eid: String = str(sat["element_id"])
		var node: Node3D = _find_nearest_element_node(entity, eid)
		if node:
			_claim(node, entity)
			return [
				{"type": "move_to", "target": node.global_position},
				{"type": "interact_element", "element_id": eid,
				 "need": need_id, "amount": amount, "remove": remove},
			]

	# 3. World element by group — walk to first match, interact (claim)
	if sat.has("element_group"):
		var grp: String = str(sat["element_group"])
		var hit: Dictionary = _find_nearest_element_with_group(entity, grp)
		if hit.has("pos"):
			var target_node = hit.get("node", null)
			if target_node is Node3D:
				_claim(target_node, entity)
			# Passive satisfiers (energy near structure): go + idle, world rule restores.
			if sat.get("passive", false):
				return [
					{"type": "move_to", "target": hit["pos"]},
					{"type": "idle_rest", "duration": 4.0},
				]
			return [
				{"type": "move_to", "target": hit["pos"]},
				{"type": "interact_element", "element_id": str(hit.get("id", "")),
				 "need": need_id, "amount": amount, "remove": remove},
			]

	return []


func _is_claimed_by_other(node: Node, entity: CharacterBody3D) -> bool:
	## True if node is claimed by a DIFFERENT agent. Own claims are fine
	## (we replan; same agent can re-pick its own target).
	if not node.has_meta("claimed_by"):
		return false
	var claimer_id = node.get_meta("claimed_by")
	return claimer_id != entity.get_instance_id()


func _find_nearest_element_with_group(entity: CharacterBody3D, group_name: String) -> Dictionary:
	## Returns {pos, id, node} of the nearest un-claimed sim_element whose `groups` meta contains group_name.
	var best_dist: float = 999.0
	var best: Dictionary = {}
	for node in entity.get_tree().get_nodes_in_group("sim_element"):
		if not node.has_meta("groups") or _is_claimed_by_other(node, entity):
			continue
		var grps = node.get_meta("groups")
		if not (grps is Dictionary) or not grps.has(group_name):
			continue
		var d: float = entity.global_position.distance_to(node.global_position)
		if d < best_dist:
			best_dist = d
			best = {"pos": node.global_position, "id": str(node.get_meta("element_id", "")), "node": node}
	return best


func _find_nearest_element_in_world(entity: CharacterBody3D, element_id: String) -> Vector3:
	## Skips elements already claimed by other agents so multiple agents don't
	## all pile onto the same wheat.
	var nearest_dist: float = 999.0
	var nearest_pos: Vector3 = Vector3.ZERO
	for node in entity.get_tree().get_nodes_in_group("sim_element"):
		if not node.has_meta("element_id") or _is_claimed_by_other(node, entity):
			continue
		if str(node.get_meta("element_id")) == element_id:
			var dist: float = entity.global_position.distance_to(node.global_position)
			if dist < nearest_dist:
				nearest_dist = dist
				nearest_pos = node.global_position
	return nearest_pos


func _find_nearest_element_node(entity: CharacterBody3D, element_id: String) -> Node3D:
	## Same logic as above but returns the node. Respects claims.
	var nearest_dist: float = 999.0
	var nearest_node: Node3D = null
	for node in entity.get_tree().get_nodes_in_group("sim_element"):
		if not node.has_meta("element_id") or _is_claimed_by_other(node, entity):
			continue
		if str(node.get_meta("element_id")) == element_id:
			var dist: float = entity.global_position.distance_to(node.global_position)
			if dist < nearest_dist:
				nearest_dist = dist
				nearest_node = node
	return nearest_node


func _find_nearest_harvestable(entity: CharacterBody3D) -> Node:
	var nearest: Node = null
	var nearest_dist: float = 3.0  # Must be close
	for node in entity.get_tree().get_nodes_in_group("sim_element"):
		var dist: float = entity.global_position.distance_to(node.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = node
	return nearest
