extends Node

## Population Manager — keeps agent count stable so the sim keeps running
## even when individuals die of starvation / combat / age.
##
## Saves the initial agent list at spawn. On tick (every N ticks), counts live
## agents. If below `min_count`, respawns the nth template at its original
## spawn point (or a fallback position).
##
## No respawn delay — fires at most once per tick.

const RESPAWN_CHECK_INTERVAL_TICKS := 20  # ~10s at 0.5s/tick

var templates: Array = []   # copy of the original agents[] from generated_world
var min_count: int = 0
var _world_clock: Node = null
var _world_root: Node3D = null


func setup(world_root: Node3D, initial_agents: Array) -> void:
	_world_root = world_root
	templates = initial_agents.duplicate(true)
	min_count = templates.size()
	_world_clock = get_tree().root.find_child("WorldClock", true, false)
	if _world_clock and _world_clock.has_signal("tick"):
		_world_clock.tick.connect(_on_tick)
	print("[Population] Tracking ", min_count, " agents, respawn every ", RESPAWN_CHECK_INTERVAL_TICKS, " ticks")


func _on_tick(tick_count: int) -> void:
	if tick_count % RESPAWN_CHECK_INTERVAL_TICKS != 0:
		return
	var alive: int = get_tree().get_nodes_in_group("agent").size()
	if alive >= min_count:
		return
	# Find a template whose name isn't currently alive and respawn it.
	var alive_names: Dictionary = {}
	for a in get_tree().get_nodes_in_group("agent"):
		alive_names[a.name.replace("Entity_", "")] = true
	for tmpl in templates:
		var tname: String = str(tmpl.get("name", ""))
		if not alive_names.has(tname):
			print("[Population] Respawning ", tname, " (alive=", alive, "/", min_count, ")")
			WorldAgents.spawn_ai_agents(_world_root, {"agents": [tmpl]}, _world_root.meta_config, _world_root.asset_config)
			return  # one per check
