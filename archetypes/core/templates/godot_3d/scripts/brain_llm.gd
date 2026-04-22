extends Node

const SimPos = preload("res://scripts/sim_pos.gd")

## LLM brain — calls `claude -p` to decide next action.
##
## Same decide() interface as other brains. Synchronous OS.execute for v1
## (blocks the tick where it fires; ~2-5s per call). Tick-driven: only calls
## LLM every `call_interval_ticks` ticks (default 6 = ~3s at 0.5s/tick).
##
## Response format expected from claude: a JSON action object. Examples:
##   {"type": "move_to", "target": [4, 0]}     — top-down [x, z]
##   {"type": "interact_element", "element_id": "wheat_mature",
##    "need": "hunger", "amount": 40, "remove": true}
##   {"type": "wander"}
##   {"type": "idle_rest", "duration": 2.0}

var current_plan: Array = []
var plan_index: int = 0
var action_timer: float = 0.0
var inventory: Node = null

# Need schema (max/critical per need). Values live on entity.meta.state.
var _need_schema: Dictionary = {}
var _entity: Node = null

# LLM state
var _world_clock: Node = null
var _last_call_tick: int = -999
var _call_interval_ticks: int = 6
var _calling: bool = false
var _ai_config: Dictionary = {}
var _llm_context: String = "You are an autonomous agent in a survival simulation. Your goal is to stay alive and explore."
# How to invoke claude. Default: direct binary on PATH.
# WSL-from-Windows example: cmd="wsl", prefix_args=["claude"]
var _claude_cmd: String = "claude"
var _claude_prefix_args: Array = []


func _ready() -> void:
	_world_clock = get_tree().root.find_child("WorldClock", true, false)


func init_config(config: Dictionary) -> void:
	_ai_config = config.get("ai_config", {})
	_call_interval_ticks = int(_ai_config.get("call_interval_ticks", _call_interval_ticks))
	_llm_context = str(_ai_config.get("llm_context", _llm_context))
	_claude_cmd = str(_ai_config.get("claude_cmd", _claude_cmd))
	var prefix = _ai_config.get("claude_prefix_args", null)
	if prefix is Array:
		_claude_prefix_args = prefix

	# Load need schema. State lives on the entity (meta.state).
	_entity = get_parent()
	var state: Dictionary = _entity.get_meta("state", {}) if _entity and _entity.has_meta("state") else {}
	var nf := FileAccess.open("res://data/sim/needs.json", FileAccess.READ)
	if nf:
		var nd = JSON.parse_string(nf.get_as_text())
		if nd is Dictionary:
			for need in nd.get("needs", []):
				var nid: String = str(need.get("id", ""))
				if nid == "":
					continue
				_need_schema[nid] = {
					"max": float(need.get("max", 100.0)),
					"critical": float(need.get("critical_threshold", 10.0)),
				}
				if not state.has(nid):
					state[nid] = float(need.get("start", 100.0))
	if _entity:
		_entity.set_meta("state", state)

	# Inventory setup (same pattern as brain_needs_driven)
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
		for si in config.get("starting_items", []):
			if inventory:
				inventory.add_item(str(si.get("item", "")), si.get("count", 1))

	print("[LLM] Initialized for ", entity.name if entity else "?", " call_interval=", _call_interval_ticks, " ticks")


func get_needs_summary() -> Dictionary:
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


func update_need(need_id: String, amount: float) -> void:
	if not _entity or not _need_schema.has(need_id):
		return
	var state: Dictionary = _entity.get_meta("state", {})
	var max_val: float = float(_need_schema[need_id].get("max", 100.0))
	var current: float = float(state.get(need_id, max_val))
	state[need_id] = clamp(current + amount, 0.0, max_val)
	_entity.set_meta("state", state)


func get_status_label() -> String:
	## LLM calls are synchronous so "Thinking..." won't show during the call
	## (the engine freezes). Instead: show current action + ticks until next call.
	if current_plan.size() > 0 and plan_index < current_plan.size():
		return "🤖 " + _step_to_label(current_plan[plan_index])
	var current_tick: int = _world_clock.tick_count if _world_clock else 0
	var wait: int = _call_interval_ticks - (current_tick - _last_call_tick)
	if wait <= 0:
		return "🤖 Ready to plan"
	return "🤖 Idle (LLM in %d ticks)" % wait


func _step_to_label(step: Dictionary) -> String:
	var t: String = str(step.get("type", "?"))
	match t:
		"move_to":
			var tgt = step.get("target", Vector2.ZERO)
			return "Walking → (%.1f, %.1f)" % [tgt.x, tgt.y]
		"interact_element":
			return "Using " + str(step.get("element_id", "?"))
		"wander":
			return "Wandering"
		"idle_rest":
			return "Resting"
	return t


func decide(entity: Node, world_state: Dictionary) -> Dictionary:
	var dt: float = entity.get_process_delta_time()
	action_timer -= dt

	# Execute current plan (one step at a time, every frame)
	if current_plan.size() > 0 and plan_index < current_plan.size():
		var step: Dictionary = current_plan[plan_index]
		var result: Dictionary = _execute_step(entity, step, dt)
		if result.get("step_done", false):
			plan_index += 1
			if plan_index >= current_plan.size():
				current_plan = []
				plan_index = 0
		return result

	# No plan — call LLM if interval elapsed
	var current_tick: int = _world_clock.tick_count if _world_clock else 0
	if not _calling and (current_tick - _last_call_tick) >= _call_interval_ticks:
		_last_call_tick = current_tick
		current_plan = _call_llm(entity)
		plan_index = 0

	return {"action": "idle"}


# ---------------------------------------------------------------------------
# LLM call
# ---------------------------------------------------------------------------

func _call_llm(entity: Node) -> Array:
	_calling = true
	var prompt: String = _build_prompt(entity)
	print("[LLM] ", entity.name, " calling claude...")

	var output: Array = []
	var args: PackedStringArray = []
	for a in _claude_prefix_args:
		args.append(str(a))
	args.append("-p")
	args.append(prompt)
	args.append("--output-format")
	args.append("json")
	var exit_code: int = OS.execute(_claude_cmd, args, output, true, false)
	_calling = false

	if exit_code != 0 or output.is_empty():
		var err_snippet: String = ""
		if not output.is_empty():
			err_snippet = str(output[0]).substr(0, 300)
		print("[LLM] ", entity.name, " call failed (exit=", exit_code, ") output: ", err_snippet)
		return [{"type": "wander"}]

	var raw: String = str(output[0]).strip_edges()
	# Claude -p with --output-format json wraps response: {"type":"result","result":"...","..."}
	var wrapper = JSON.parse_string(raw)
	var inner_text: String = ""
	if wrapper is Dictionary and wrapper.has("result"):
		inner_text = str(wrapper["result"])
	else:
		inner_text = raw

	# Strip code fences if claude wrapped JSON in ```json...```
	inner_text = inner_text.strip_edges()
	if inner_text.begins_with("```"):
		var first_nl: int = inner_text.find("\n")
		if first_nl > 0:
			inner_text = inner_text.substr(first_nl + 1)
		var fence: int = inner_text.rfind("```")
		if fence > 0:
			inner_text = inner_text.substr(0, fence)
		inner_text = inner_text.strip_edges()

	var action = JSON.parse_string(inner_text)
	if not (action is Dictionary):
		print("[LLM] ", entity.name, " could not parse action: ", inner_text.substr(0, 120))
		return [{"type": "wander"}]

	print("[LLM] ", entity.name, " → ", action)
	return [action]


func _build_prompt(entity: Node) -> String:
	var pos: Vector2 = SimPos.of(entity)
	var inv_str: String = inventory.to_string_summary() if inventory else "(empty)"

	var nearby: Array = []
	for el in entity.get_tree().get_nodes_in_group("sim_element"):
		var el_pos: Vector2 = SimPos.of(el)
		var d: float = pos.distance_to(el_pos)
		if d < 12.0:
			nearby.append({
				"id": str(el.get_meta("element_id", "?")),
				"pos": [snapped(el_pos.x, 0.1), snapped(el_pos.y, 0.1)],
				"dist": snapped(d, 0.1),
			})

	var needs_brief: Dictionary = {}
	var state: Dictionary = _entity.get_meta("state", {}) if _entity and _entity.has_meta("state") else {}
	for nid in _need_schema:
		needs_brief[nid] = "%d/%d" % [int(state.get(nid, 0)), int(_need_schema[nid].get("max", 100))]

	var lines: Array = [
		_llm_context,
		"",
		"STATE",
		"Position: %s" % JSON.stringify([snapped(pos.x, 0.1), snapped(pos.y, 0.1)]),
		"Needs (lower = more urgent): " + JSON.stringify(needs_brief),
		"Inventory: " + inv_str,
		"Nearby objects (within 12u): " + JSON.stringify(nearby),
		"",
		"AVAILABLE ACTIONS",
		'{"type": "move_to", "target": [x, z]}       — walk toward a top-down ground position',
		'{"type": "interact_element", "element_id": "ID", "need": "hunger|thirst|energy", "amount": N, "remove": true|false}',
		'{"type": "wander"}                          — pick a random nearby spot',
		'{"type": "idle_rest", "duration": 2.0}      — wait',
		"",
		"Return ONE action as raw JSON. No explanation, no markdown.",
	]
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# Step execution — minimal subset of brain_needs_driven actions.
# ---------------------------------------------------------------------------

func _execute_step(entity: Node, step: Dictionary, dt: float) -> Dictionary:
	var step_type: String = str(step.get("type", "idle"))
	match step_type:
		"move_to":
			var here: Vector2 = SimPos.of(entity)
			var tgt = step.get("target", here)
			var t_vec: Vector2 = here
			if tgt is Array and tgt.size() >= 2:
				# JSON arrays come as [x, z] (skip y if a 3-tuple — LLM may emit either)
				var ax: float = float(tgt[0])
				var az: float = float(tgt[2]) if tgt.size() >= 3 else float(tgt[1])
				t_vec = Vector2(ax, az)
			elif tgt is Vector2:
				t_vec = tgt
			var dist: float = here.distance_to(t_vec)
			if dist > 1.5:
				return {"action": "move_to", "target": t_vec}
			return {"action": "idle", "step_done": true}

		"interact_element":
			var need_id: String = str(step.get("need", ""))
			var amount: float = float(step.get("amount", 0))
			# LLM brain doesn't track needs internally; just log.
			print("[LLM] ", entity.name, " interacted ", step.get("element_id", "?"), " need=", need_id, " +", amount)
			if step.get("remove", false):
				var target_id: String = str(step.get("element_id", ""))
				if target_id != "":
					var target_node: Node = _find_nearest_element_node(entity, target_id)
					if target_node:
						target_node.queue_free()
			return {"action": "idle", "step_done": true}

		"wander":
			var here: Vector2 = SimPos.of(entity)
			var rx: float = here.x + randf_range(-6, 6)
			var ry: float = here.y + randf_range(-6, 6)
			return {"action": "move_to", "target": Vector2(rx, ry), "step_done": true}

		"idle_rest":
			var duration: float = float(step.get("duration", 2.0))
			if action_timer <= 0:
				action_timer = duration
			if action_timer <= dt:
				return {"action": "idle", "step_done": true}
			return {"action": "idle"}

	return {"action": "idle", "step_done": true}


func _find_nearest_element_node(entity: Node, element_id: String) -> Node:
	var here: Vector2 = SimPos.of(entity)
	var best_dist: float = 999.0
	var best: Node = null
	for n in entity.get_tree().get_nodes_in_group("sim_element"):
		if not n.has_meta("element_id"):
			continue
		if str(n.get_meta("element_id")) != element_id:
			continue
		var d: float = here.distance_to(SimPos.of(n))
		if d < best_dist:
			best_dist = d
			best = n
	return best
