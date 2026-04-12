extends Node

## NeedsDrivenBrain — The Sims meets Minecraft.
## Agent has needs (hunger, thirst, energy). Needs decay over time.
## Agent scans nearby elements, evaluates which action best satisfies urgent needs.
## Scoring: urgency(need) × satisfaction(action) → pick best.
## Same decide() interface as all other brains.

# Needs
var needs: Dictionary = {}  # need_id → {current, max, critical_threshold}
var needs_config: Array = []

# Recipes
var known_recipes: Array = []

# Items
var items_config: Array = []

# State
var current_plan: Array = []  # [{action, target, ...}]
var plan_index: int = 0
var action_timer: float = 0.0
var idle_timer: float = 0.0

# Reference to inventory (attached to entity)
var inventory: Node = null


func init_config(config: Dictionary) -> void:
	# Load needs
	var needs_file := FileAccess.open("res://data/sim/needs.json", FileAccess.READ)
	if needs_file:
		var data = JSON.parse_string(needs_file.get_as_text())
		if data is Dictionary:
			needs_config = data.get("needs", [])
			for need in needs_config:
				needs[str(need.get("id", ""))] = {
					"current": need.get("start", 100.0),
					"max": need.get("max", 100.0),
					"critical": need.get("critical_threshold", 10.0),
				}

	# Load recipes
	var recipe_file := FileAccess.open("res://data/sim/recipes.json", FileAccess.READ)
	if recipe_file:
		var data = JSON.parse_string(recipe_file.get_as_text())
		if data is Dictionary:
			known_recipes = data.get("recipes", [])

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

	print("[NeedsBrain] Initialized: ", needs.keys(), " | Recipes: ", known_recipes.size())


func decide(entity: CharacterBody3D, world_state: Dictionary) -> Dictionary:
	var dt: float = entity.get_process_delta_time()
	action_timer -= dt
	idle_timer += dt

	# If executing a plan, follow it
	if current_plan.size() > 0 and plan_index < current_plan.size():
		var step: Dictionary = current_plan[plan_index]
		var result: Dictionary = _execute_step(entity, step, dt)
		if result.get("step_done", false):
			plan_index += 1
			if plan_index >= current_plan.size():
				current_plan = []
				plan_index = 0
		return result

	# No plan — evaluate needs and pick best action
	if idle_timer > 0.5:  # Re-evaluate every 0.5s
		idle_timer = 0.0
		current_plan = _make_plan(entity, world_state)
		plan_index = 0

	return {"action": "idle"}


func get_needs_summary() -> Dictionary:
	return needs.duplicate()


func update_need(need_id: String, amount: float) -> void:
	if needs.has(need_id):
		var n: Dictionary = needs[need_id]
		n["current"] = clamp(n["current"] + amount, 0.0, n["max"])


func _most_urgent_need() -> String:
	var worst_id: String = ""
	var worst_pct: float = 2.0
	for need_id in needs:
		var n: Dictionary = needs[need_id]
		var pct: float = n["current"] / max(n["max"], 0.01)
		if pct < worst_pct:
			worst_pct = pct
			worst_id = need_id
	return worst_id


func _make_plan(entity: CharacterBody3D, _world_state: Dictionary) -> Array:
	## Evaluate all possible actions, score by urgency × satisfaction, pick best.
	var urgent_need: String = _most_urgent_need()
	if urgent_need == "":
		return [{"type": "wander"}]

	var urgency: float = 1.0 - (needs[urgent_need]["current"] / max(needs[urgent_need]["max"], 0.01))

	# If hunger is urgent and we have food → eat
	if urgent_need == "hunger" and inventory:
		if inventory.has_item("cooked_food"):
			return [{"type": "consume", "item": "cooked_food", "need": "hunger", "amount": 60}]
		if inventory.has_item("food_wheat"):
			return [{"type": "consume", "item": "food_wheat", "need": "hunger", "amount": 30}]

	# If thirst is urgent → find water
	if urgent_need == "thirst":
		var water_pos: Vector3 = _find_nearest_element_in_world(entity, "water")
		if water_pos != Vector3.ZERO:
			return [
				{"type": "move_to", "target": water_pos},
				{"type": "interact_element", "need": "thirst", "amount": 50}
			]

	# If energy is urgent → find shelter or just idle
	if urgent_need == "energy":
		var shelter_pos: Vector3 = _find_nearest_element_in_world(entity, "shelter")
		if shelter_pos != Vector3.ZERO:
			return [{"type": "move_to", "target": shelter_pos}]
		else:
			return [{"type": "idle_rest", "duration": 3.0}]

	# If not urgent → gather resources
	if urgency < 0.5:
		# Have axe? Chop tree for wood
		if inventory and inventory.has_item("axe"):
			var tree_pos: Vector3 = _find_nearest_element_in_world(entity, "tree")
			if tree_pos != Vector3.ZERO:
				return [
					{"type": "move_to", "target": tree_pos},
					{"type": "harvest", "tool": "axe", "time": 2.0}
				]

		# Have pickaxe? Mine stone
		if inventory and inventory.has_item("pickaxe"):
			var stone_pos: Vector3 = _find_nearest_element_in_world(entity, "stone")
			if stone_pos != Vector3.ZERO:
				return [
					{"type": "move_to", "target": stone_pos},
					{"type": "harvest", "tool": "pickaxe", "time": 3.0}
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
			action_timer = step.get("time", 2.0)
			# Find nearest element in range and "harvest" it
			var nearest: Node = _find_nearest_harvestable(entity)
			if nearest and nearest.has_method("take_damage"):
				nearest.take_damage(10.0)
				# Collect drops (simplified — add items directly)
				if inventory:
					# Check element's drop config
					var element_data: Dictionary = nearest.get("element_data") if nearest.has_method("get") else {}
					var drops: Array = element_data.get("drop", [])
					for d in drops:
						inventory.add_item(str(d.get("item", "")), d.get("count", 1))
					if drops.is_empty():
						inventory.add_item("wood", 1)  # Fallback
				print("[NeedsBrain] Harvested! Inventory: ", inventory.to_string_summary())
			return {"action": "attack", "step_done": true}

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

	return {"action": "idle", "step_done": true}


func _find_nearest_element_in_world(entity: CharacterBody3D, element_id: String) -> Vector3:
	## Find nearest world element by id
	var nearest_dist: float = 999.0
	var nearest_pos: Vector3 = Vector3.ZERO
	for node in entity.get_tree().get_nodes_in_group("sim_element"):
		if str(node.get("element_id")) == element_id:
			var dist: float = entity.global_position.distance_to(node.global_position)
			if dist < nearest_dist:
				nearest_dist = dist
				nearest_pos = node.global_position
	return nearest_pos


func _find_nearest_harvestable(entity: CharacterBody3D) -> Node:
	var nearest: Node = null
	var nearest_dist: float = 3.0  # Must be close
	for node in entity.get_tree().get_nodes_in_group("sim_element"):
		var dist: float = entity.global_position.distance_to(node.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = node
	return nearest
