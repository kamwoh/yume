extends Object
class_name InputRegistrar

## Tier 2.6t — per-game dynamic input registration.
##
## Reads `data/<game>/inputs.json` and registers each declared action
## into Godot's InputMap at runtime. Lets games own their input
## vocabulary instead of bloating project.godot's static input map.
##
## Schema:
##   {
##     "actions": [
##       {"name": "build_1", "key": "1"},
##       {"name": "build_2", "keys": ["2", "Numpad2"]}
##     ]
##   }
##
## - `key` — single keycode string (lookup via OS.find_keycode_from_string)
## - `keys` — array of keycode strings (multiple bindings for one action)
## - At least one of `key` / `keys` is required
##
## Idempotent: calling register on the same action twice doesn't duplicate
## events — the engine clears events for the action before re-binding.
##
## Used by:
##   - World.load_data() — auto-registers per-game inputs at world startup
##   - scenario_runner — same hook (test scenarios get the same vocabulary)


## Read inputs.json at the given data root and register all actions.
## Silent no-op if file doesn't exist — game has no custom inputs.
static func register_from_data_root(data_root: String) -> void:
	var path := data_root.rstrip("/") + "/inputs.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_warning("[InputRegistrar] parse error in %s: %s"
			% [path, json.get_error_message()])
		return
	if not (json.data is Dictionary):
		return
	var spec: Dictionary = json.data
	for action_def in spec.get("actions", []):
		if not (action_def is Dictionary):
			continue
		_register_one(action_def)


static func _register_one(action_def: Dictionary) -> void:
	var name := str(action_def.get("name", ""))
	if name == "":
		return

	# Collect keycode strings — accept either `key` (single) or `keys` (array).
	var keys: Array = []
	if action_def.has("key"):
		keys.append(str(action_def["key"]))
	if action_def.has("keys") and action_def["keys"] is Array:
		for k in action_def["keys"]:
			keys.append(str(k))
	if keys.is_empty():
		push_warning("[InputRegistrar] action '%s' has no key bindings" % name)
		return

	# Idempotent: clear pre-existing events for this action so re-loading
	# a game's inputs doesn't accumulate duplicate bindings.
	if InputMap.has_action(name):
		InputMap.action_erase_events(name)
	else:
		InputMap.add_action(name)

	for key_str in keys:
		var keycode: int = OS.find_keycode_from_string(key_str)
		if keycode == 0:
			push_warning("[InputRegistrar] unknown key '%s' for action '%s'"
				% [key_str, name])
			continue
		var event := InputEventKey.new()
		event.physical_keycode = keycode
		InputMap.action_add_event(name, event)
