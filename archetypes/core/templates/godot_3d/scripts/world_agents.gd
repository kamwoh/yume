class_name WorldAgents
extends RefCounted

## Static helpers for spawning the human-controlled player and AI agents.
## Player config from meta.json.player. Agent config from world_data.agents[].
## Brain script chosen via "brain" field — looks up "res://scripts/brain_<type>.gd".


static func spawn_player(parent: Node3D, world_data: Dictionary, meta_config: Dictionary, asset_config: Dictionary) -> void:
	## Skips the player when world_data.spawn_player == false (lab mode).
	## Always proceeds to spawn AI agents afterward.
	if world_data.get("spawn_player", true) == false:
		print("[SimWorld] Player spawn skipped (world_data.spawn_player=false)")
		spawn_ai_agents(parent, world_data, meta_config, asset_config)
		return

	var spawn: Dictionary = world_data.get("spawn", {})
	var spawn_x: float = spawn.get("x", 0)
	var spawn_z: float = spawn.get("z", 0)

	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://scripts/player_3d.gd"))
	player.position = Vector3(spawn_x, 0.5, spawn_z)
	player.add_to_group("player")

	var pcfg: Dictionary = meta_config.get("player", {})
	var player_model: String = str(pcfg.get("model", "Knight"))
	var scale_map: Dictionary = asset_config.get("prop_scale_map", {})
	var pscale: float = scale_map.get(player_model, 0.4)
	var search_paths: Array = asset_config.get("model_search_paths", [])
	var extensions: Array = asset_config.get("model_extensions", ["glb", "gltf"])

	for base_path in search_paths:
		var found := false
		for ext in extensions:
			var path: String = str(base_path) + player_model + "." + str(ext)
			if ResourceLoader.exists(path):
				var scene: PackedScene = load(path)
				if scene:
					var instance := scene.instantiate()
					instance.name = "PlayerModel"
					instance.scale = Vector3.ONE * pscale
					instance.rotation_degrees.y = pcfg.get("model_rotation_offset", 180)
					player.add_child(instance)
					var anim := ModelHelpers.find_anim_player(instance)
					if anim:
						player.set_meta("anim_player", anim)
					found = true
					break
		if found:
			break

	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = float(pcfg.get("capsule_radius", 0.2))
	capsule.height = float(pcfg.get("capsule_height", 0.9))
	col.shape = capsule
	col.position.y = capsule.height * 0.5
	player.add_child(col)

	var spring := SpringArm3D.new()
	spring.name = "CameraArm"
	spring.position = Vector3(0, float(pcfg.get("camera_height", 2.0)), 0)
	spring.rotation_degrees = Vector3(float(pcfg.get("camera_angle", -30.0)), 0, 0)
	spring.spring_length = float(pcfg.get("camera_distance", 8.0))
	spring.collision_mask = 0
	player.add_child(spring)
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.current = true
	spring.add_child(cam)

	parent.add_child(player)
	print("[SimWorld] Player spawned at (", spawn_x, ",", spawn_z, ")")

	spawn_ai_agents(parent, world_data, meta_config, asset_config)


static func spawn_ai_agents(parent: Node3D, world_data: Dictionary, meta_config: Dictionary, asset_config: Dictionary) -> void:
	## Spawn entity_3d agents from world_data.agents[]. Each:
	##   {name, model, brain, spawn:{x,z}, stats?, starting_items?, capsule_*?}.
	## Brain script: res://scripts/brain_<brain>.gd
	var agents: Array = world_data.get("agents", [])
	if agents.is_empty():
		return

	var entity_script = load("res://scripts/entity_3d.gd")
	var search_paths: Array = asset_config.get("model_search_paths", ["res://models/"])
	var extensions: Array = asset_config.get("model_extensions", ["glb", "gltf"])
	var scale_map: Dictionary = asset_config.get("prop_scale_map", {})
	var pcfg: Dictionary = meta_config.get("player", {})

	for a in agents:
		if not (a is Dictionary):
			continue
		var agent_name: String = str(a.get("name", "Agent"))
		var agent_model: String = str(a.get("model", "Knight"))
		var brain_type: String = str(a.get("brain", "needs_driven"))
		var spawn_d: Dictionary = a.get("spawn", {})
		var ax: float = float(spawn_d.get("x", 0))
		var az: float = float(spawn_d.get("z", 0))

		var entity := CharacterBody3D.new()
		entity.name = "Entity_" + agent_name.replace(" ", "_")
		entity.set_script(entity_script)
		entity.position = Vector3(ax, 0.5, az)
		entity.add_to_group("agent")

		var model_scale: float = scale_map.get(agent_model, scale_map.get("default", 1.0))
		var model_loaded := false
		for base_path in search_paths:
			if model_loaded: break
			for ext in extensions:
				var path: String = str(base_path) + agent_model + "." + str(ext)
				if ResourceLoader.exists(path):
					var scene: PackedScene = load(path)
					if scene:
						var instance := scene.instantiate()
						instance.name = "EntityModel"
						instance.scale = Vector3.ONE * model_scale
						entity.add_child(instance)
						# Attach animations from the rig files (Kenney models have no embedded anims).
						entity.anim_player = ModelHelpers.attach_animations(instance, asset_config)
						model_loaded = true
						break

		var col := CollisionShape3D.new()
		var caps := CapsuleShape3D.new()
		caps.radius = float(a.get("capsule_radius", pcfg.get("capsule_radius", 0.3)))
		caps.height = float(a.get("capsule_height", pcfg.get("capsule_height", 0.9)))
		col.shape = caps
		col.position.y = caps.height * 0.5
		entity.add_child(col)

		parent.add_child(entity)
		entity.init_from_json(a)

		var brain_script_path: String = "res://scripts/brain_" + brain_type + ".gd"
		var brain_script = load(brain_script_path)
		if brain_script:
			var brain_node := Node.new()
			brain_node.name = "Brain"
			brain_node.set_script(brain_script)
			entity.add_child(brain_node)
			entity.brain = brain_node
			if brain_node.has_method("init_config"):
				brain_node.init_config(a)
			print("[SimWorld] Agent spawned: ", agent_name, " brain=", brain_type, " at (", ax, ",", az, ")")
		else:
			push_warning("[SimWorld] Brain script not found: " + brain_script_path)
