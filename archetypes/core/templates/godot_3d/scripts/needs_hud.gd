extends Control

## Needs HUD — manager. Creates one AgentNeedsPanel per agent in the
## "agent" group, lays them vertically. Adds/removes panels as agents
## spawn/despawn. Holds no per-need drawing logic itself — that's
## delegated to agent_needs_panel.gd (reusable).

const AgentPanelScript = preload("res://scripts/agent_needs_panel.gd")

var margin: float = 10.0
var panel_gap: float = 10.0
var top_offset: float = 110.0  # below the hp_bar

var _panels: Dictionary = {}  # agent_node → AgentNeedsPanel Control
var _refresh_timer: float = 0.0


func _ready() -> void:
	position = Vector2(margin, margin + top_offset)
	size = Vector2(380, 600)
	z_index = 100
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	_refresh_timer += delta
	# Rescan agent group ~2x per second to add/remove panels
	if _refresh_timer >= 0.5:
		_refresh_timer = 0.0
		_sync_panels()


func _sync_panels() -> void:
	var agents: Array = get_tree().get_nodes_in_group("agent")
	# Remove panels for agents that no longer exist
	for a in _panels.keys():
		if not is_instance_valid(a) or not (a in agents):
			var p: Control = _panels[a]
			if is_instance_valid(p):
				p.queue_free()
			_panels.erase(a)
	# Add panels for new agents
	for a in agents:
		if not (a in _panels):
			var panel := Control.new()
			panel.set_script(AgentPanelScript)
			panel.size = Vector2(380, 80)
			add_child(panel)
			panel.set_agent(a)
			_panels[a] = panel
	# Re-layout: stack panels vertically with gap based on each panel's height
	var y: float = 0.0
	for a in agents:
		if not (a in _panels):
			continue
		var p: Control = _panels[a]
		p.position = Vector2(0, y)
		var h: float = p.panel_height() if p.has_method("panel_height") else 80.0
		y += h + panel_gap
