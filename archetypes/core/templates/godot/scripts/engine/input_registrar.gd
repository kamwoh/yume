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
##       {"name": "spark", "key": "Space"},
##       {"name": "build_1", "key": "1", "edge": "press"},
##       {"name": "charge", "key": "C", "edge": "hold"},
##       {"name": "weapon_2", "keys": ["2", "Numpad2"]}
##     ]
##   }
##
## - `key` — single keycode string (lookup via OS.find_keycode_from_string)
## - `keys` — array of keycode strings (multiple bindings for one action)
## - `edge` — `"press"` (fire once on press-edge, default) or `"hold"`
##   (fire every frame while held). Engine adds the action to its
##   `input_actions_press` or `input_actions_hold` poll list automatically.
## - At least one of `key` / `keys` is required
##
## Idempotent: calling register on the same action twice doesn't duplicate
## events — the engine clears events for the action before re-binding.
##
## Used by:
##   - World.load_data() — auto-registers per-game inputs at world startup
##     and extends its poll lists with the returned action names
##   - scenario_runner — same hook (test scenarios get the same vocabulary)


## Read inputs config at the given data root and register all actions.
## Returns a Dictionary {"press": [String, ...], "hold": [String, ...]} so
## the caller can extend its poll lists. Silent no-op (returns empty
## dict) if the file doesn't exist.
##
## ADR 0009: prefers new path ui/input.json; falls back to legacy
## inputs.json. New path takes priority if both exist.
static func register_from_data_root(data_root: String) -> Dictionary:
	var out: Dictionary = {"press": [], "hold": []}
	var root := data_root.rstrip("/")
	var path := root + "/ui/input.json"
	if not FileAccess.file_exists(path):
		path = root + "/inputs.json"
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_warning("[InputRegistrar] parse error in %s: %s"
			% [path, json.get_error_message()])
		return out
	if not (json.data is Dictionary):
		return out
	var spec: Dictionary = json.data
	for action_def in spec.get("actions", []):
		if not (action_def is Dictionary):
			continue
		var name := _register_one(action_def)
		if name == "": continue
		var edge := str((action_def as Dictionary).get("edge", "press"))
		if edge == "hold":
			(out["hold"] as Array).append(name)
		else:
			(out["press"] as Array).append(name)
	return out


## Register one action; returns the action name on success, "" on failure.
static func _register_one(action_def: Dictionary) -> String:
	var name := str(action_def.get("name", ""))
	if name == "":
		return ""

	# Collect keycode strings — accept either `key` (single) or `keys` (array).
	var keys: Array = []
	if action_def.has("key"):
		keys.append(str(action_def["key"]))
	if action_def.has("keys") and action_def["keys"] is Array:
		for k in action_def["keys"]:
			keys.append(str(k))
	# 2026-05-05: keys-optional mode for already-registered InputMap actions.
	# Lets per-game inputs.json declare edge-classification (hold vs press)
	# for actions whose keys are already bound in project.godot (e.g.
	# move_north). Without this, every game that wanted WASD movement would
	# have to re-declare the keys redundantly. With it, inputs.json just
	# says `{"name": "move_north", "edge": "hold"}` and the existing
	# project.godot binding stays.
	if keys.is_empty():
		if InputMap.has_action(name):
			return name
		push_warning("[InputRegistrar] action '%s' has no key bindings AND is not already in InputMap — skipping" % name)
		return ""

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
	return name
