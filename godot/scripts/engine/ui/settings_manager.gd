extends Node
class_name SettingsManager

## ADR 0013 — Schema-driven settings.
##
## Loads `<data_root>/settings_schema.json` and `user://settings.cfg`.
## Each setting has type (slider/bool/enum/key_binding), default, and
## an `apply` effect chain that runs whenever the value changes.
##
## Per ADR 0021, we use Godot's ConfigFile for persistence (NOT custom
## JSON) — it's the standard Godot pattern for flat key-value settings.
## Only the SCHEMA stays JSON (for LLM-generability + per-game variation).
##
## Wiring: SettingsManager expects to be a child of a Node whose script
## is `World`. Sibling of GameShell + ScreenFlow + OverlayManager.
##
## Apply lifecycle:
## 1. Boot: load schema, load settings.cfg, fill defaults for missing
##    keys, apply_all() — every setting's apply block runs.
## 2. Player changes a setting (via settings_renderer UI): set(key, value)
##    → write ConfigFile, mirror into world_state, run apply block.
## 3. Reset to defaults: iterate schema, set each to its default.


# ============================================================
# CONSTANTS
# ============================================================

const CONFIG_PATH := "user://settings.cfg"


# ============================================================
# STATE
# ============================================================

var _world: Node = null
var _schema: Dictionary = {}              # parsed settings_schema.json
var _settings_by_key: Dictionary = {}     # key → setting-spec dict
var _values: Dictionary = {}              # key → current value (in-memory mirror)
var _cfg: ConfigFile = null


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	_world = get_parent()
	if _world == null or not _world.has_method("_build_env"):
		push_error("SettingsManager must be a child of a World node")
		return
	# Schema + config can load early (no scheduler needed). apply_all defers
	# to World.gd after scheduler is built — see world.gd `start()`.
	_load_schema()
	if _schema.is_empty():
		# No settings_schema.json — game hasn't opted in. Leave silent.
		return
	_load_config()
	_fill_defaults()


# ============================================================
# SCHEMA LOAD + VALIDATION
# ============================================================

func _load_schema() -> void:
	var root := str(_world.get("data_root")).rstrip("/")
	if root == "": return
	var path := root + "/settings_schema.json"
	if not FileAccess.file_exists(path): return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary): return
	_schema = data
	# Index settings by key. Validate as we go (schema validation per TD
	# condition #5).
	for cat in _schema.get("categories", []):
		if not (cat is Dictionary): continue
		var cat_id := str((cat as Dictionary).get("id", ""))
		for s in (cat as Dictionary).get("settings", []):
			if not (s is Dictionary): continue
			var sd: Dictionary = s
			sd["_category"] = cat_id   # back-ref for ConfigFile section
			var key := str(sd.get("key", ""))
			if key == "":
				push_warning("SettingsManager: setting in category '%s' missing 'key'" % cat_id)
				continue
			if _validate_setting(sd):
				_settings_by_key[key] = sd


## Returns true if the setting passes schema validation.
## Logs warnings (not errors — engine continues with valid subset).
static func _validate_setting(s: Dictionary) -> bool:
	var key := str(s.get("key", ""))
	var t := str(s.get("type", ""))
	if not s.has("default"):
		push_warning("SettingsManager: setting '%s' missing 'default'" % key)
		return false
	match t:
		"slider":
			var mn = s.get("min", null)
			var mx = s.get("max", null)
			var d = s.get("default", null)
			if mn == null or mx == null:
				push_warning("SettingsManager: slider '%s' needs min + max" % key)
				return false
			if float(mn) > float(mx):
				push_warning("SettingsManager: slider '%s' min > max" % key)
				return false
			if float(d) < float(mn) or float(d) > float(mx):
				push_warning("SettingsManager: slider '%s' default outside [min,max]" % key)
				return false
		"enum":
			var opts = s.get("options", null)
			if not (opts is Array) or (opts as Array).is_empty():
				push_warning("SettingsManager: enum '%s' needs non-empty options" % key)
				return false
			if not (s["default"] in (opts as Array)):
				push_warning("SettingsManager: enum '%s' default not in options" % key)
				return false
		"bool":
			pass  # default just needs to coerce to bool
		"key_binding":
			pass  # default is a key string; validity checked when applied
		_:
			push_warning("SettingsManager: unknown setting type '%s' for '%s'" % [t, key])
			return false
	return true


# ============================================================
# CONFIG FILE (ConfigFile per ADR 0021)
# ============================================================

func _load_config() -> void:
	_cfg = ConfigFile.new()
	# load() returns OK even if file doesn't exist (returns ERR_FILE_NOT_FOUND
	# which we ignore — defaults will fill).
	_cfg.load(CONFIG_PATH)


func _fill_defaults() -> void:
	# For every setting in the schema, read the current value from
	# ConfigFile (or default if absent). Mirror into _values.
	for key in _settings_by_key.keys():
		var s: Dictionary = _settings_by_key[key]
		var section := str(s.get("_category", "general"))
		var v = _cfg.get_value(section, str(key), s.get("default"))
		_values[str(key)] = v


# ============================================================
# PUBLIC API
# ============================================================

## Get the current value of a setting. Returns null if key unknown.
func get_value(key: String):
	return _values.get(key, null)


## Set a setting's value: persist to ConfigFile + mirror in _values
## + run apply block. If `run_apply` is false, skips the apply (used
## during boot where apply_all() runs all blocks together).
func set_value(key: String, value, run_apply: bool = true) -> void:
	if not _settings_by_key.has(key):
		push_warning("SettingsManager: unknown setting key '%s'" % key)
		return
	var s: Dictionary = _settings_by_key[key]
	# Validate/clamp value per type
	value = _clamp_value(s, value)
	_values[key] = value
	# Persist
	if _cfg != null:
		_cfg.set_value(str(s.get("_category", "general")), key, value)
		_cfg.save(CONFIG_PATH)
	if run_apply:
		_run_apply_block(s, value)


## Run every setting's apply block. Called once at boot. Also called by
## "Reset to defaults" after resetting all values.
func apply_all() -> void:
	for key in _settings_by_key.keys():
		var s: Dictionary = _settings_by_key[key]
		var v = _values.get(str(key), s.get("default"))
		_run_apply_block(s, v)


## Reset every setting to schema default + persist + apply.
func reset_to_defaults() -> void:
	for key in _settings_by_key.keys():
		var s: Dictionary = _settings_by_key[key]
		set_value(str(key), s.get("default"), false)
	apply_all()


## All schema categories — for settings_renderer to iterate.
func categories() -> Array:
	return _schema.get("categories", [])


## All setting specs by key — for settings_renderer wiring.
func setting_spec(key: String) -> Dictionary:
	return _settings_by_key.get(key, {})


# ============================================================
# APPLY BLOCK EXECUTION
# ============================================================

## Run the apply effect chain for a setting with a specific value.
## "value" tokens in the effect dict resolve to the current value.
##
## Example schema apply:
##   {"type": "set_audio_bus_volume", "bus": "Master", "linear": "value"}
## Becomes:
##   {"type": "set_audio_bus_volume", "bus": "Master", "linear": 0.7}
func _run_apply_block(s: Dictionary, value) -> void:
	if _world == null: return
	var sched = _world.get("scheduler")
	if sched == null: return
	var env: Dictionary = sched.env
	var apply_list = s.get("apply", null)
	if not (apply_list is Array): return
	var ctx: Dictionary = {"_rule_id": "settings:" + str(s.get("key", ""))}
	for eff in (apply_list as Array):
		if not (eff is Dictionary): continue
		var resolved: Dictionary = _resolve_value_tokens(eff as Dictionary, value)
		EffectApply.apply(resolved, env, ctx)


## Walk the effect dict; replace any field equal to literal string "value"
## with the actual setting value. Other fields pass through unchanged.
static func _resolve_value_tokens(eff: Dictionary, value) -> Dictionary:
	var out: Dictionary = {}
	for k in eff.keys():
		var v = eff[k]
		if v is String and str(v) == "value":
			out[str(k)] = value
		else:
			out[str(k)] = v
	return out


## Clamp + coerce a value to the setting's allowed range/options.
static func _clamp_value(s: Dictionary, value):
	var t := str(s.get("type", ""))
	match t:
		"slider":
			var mn := float(s.get("min", 0.0))
			var mx := float(s.get("max", 1.0))
			return clamp(float(value), mn, mx)
		"bool":
			return bool(value)
		"enum":
			var opts: Array = s.get("options", [])
			if value in opts:
				return value
			return opts[0] if not opts.is_empty() else null
		"key_binding":
			return str(value)
	return value
