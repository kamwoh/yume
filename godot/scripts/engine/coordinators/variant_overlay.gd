extends RefCounted
class_name VariantOverlay

## Variant overlay applicator (ADR 0009 Phase 2d) — extracted from
## world.gd on 2026-05-12.
##
## After rules + world_state + entities are loaded, an optional variant
## overlay layers field overrides on top. Variant precedence:
##   1. world.variant_override property (scenario_runner / tests)
##   2. scene.json's "variant" key
##   3. YUME_VARIANT environment variable
##   4. "" (no variant — overlay is no-op)
##
## Variant file at <root>/variants/<name>.json applies:
##   - rule overrides: chance + effect-field tweaks by rule id
##   - world_state overrides: scalar overlay
##   - entity state overrides: per-entity state field tweaks
##
## Purely additive — variants cannot change rule structure (trigger,
## query). Used for difficulty modes, debug overlays, A/B tests without
## duplicating the entire ruleset.
##
## Stateless beyond the world ref. Single public entry: `apply(root)`.

var _world: World


func _init(world: World) -> void:
	_world = world


# ============================================================
# PUBLIC API
# ============================================================


## Apply the active variant (if any) to the loaded rules / world_state /
## entities. Called from world.gd::load_data AFTER rules + world_state +
## entities are loaded, BEFORE save layer (so saved values overwrite
## variant defaults on load).
func apply(root: String) -> void:
	var variant_name := _active_variant_name(root)
	if variant_name == "":
		return
	var path := root + "/variants/" + variant_name + ".json"
	if not FileAccess.file_exists(path):
		if _world.verbose:
			print("[variant] '%s' selected but no file at %s — skipping" % [variant_name, path])
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var raw := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		push_warning("[variant] %s: invalid JSON" % path)
		return
	var v: Dictionary = parsed

	# 1. Rule overrides
	var rule_overrides: Dictionary = v.get("rules", {})
	for rid_v in rule_overrides:
		var rid := str(rid_v)
		var rule := _world.scheduler.get_rule_by_id(rid)
		if rule == null:
			push_warning("[variant] rule '%s' not found — override skipped" % rid)
			continue
		var fields: Dictionary = rule_overrides[rid_v]
		for path_key in fields:
			_apply_rule_override(rule, str(path_key), fields[path_key])

	# 2. world_state overlay
	var ws_overrides: Dictionary = v.get("world_state", {})
	for k in ws_overrides:
		_world.world_state[str(k)] = ws_overrides[k]

	# 3. Entity state overrides
	var ent_overrides: Dictionary = v.get("entities", {})
	for ent_id_v in ent_overrides:
		var ent_id := str(ent_id_v)
		var ent = _world.entities.get(ent_id, null)
		if not (ent is Entity):
			push_warning("[variant] entity '%s' not found — override skipped" % ent_id)
			continue
		var state_overrides: Dictionary = ent_overrides[ent_id_v]
		for sk in state_overrides:
			(ent as Entity).set_state(str(sk), state_overrides[sk])

	if _world.verbose:
		print(
			(
				"[variant] applied: %s (%d rules, %d world_state, %d entities)"
				% [variant_name, rule_overrides.size(), ws_overrides.size(), ent_overrides.size()]
			)
		)


# ============================================================
# INTERNAL
# ============================================================


## Determine the active variant. Precedence:
##   1. world.variant_override property (scenario_runner / tests)
##   2. scene.json's "variant" key
##   3. YUME_VARIANT env var
##   4. "" (no variant)
func _active_variant_name(root: String) -> String:
	if _world.variant_override != "":
		return _world.variant_override
	var scene_path := root + "/scene.json"
	if FileAccess.file_exists(scene_path):
		var f := FileAccess.open(scene_path, FileAccess.READ)
		var raw := f.get_as_text()
		f.close()
		var parsed = JSON.parse_string(raw)
		if parsed is Dictionary:
			var v := str((parsed as Dictionary).get("variant", ""))
			if v != "":
				return v
	return OS.get_environment("YUME_VARIANT")


## Apply a single rule override. Path forms:
##   "chance"                 → rule.chance
##   "effect.<key>"           → rule.effects[0][<key>]
##   "effects.<idx>.<key>"    → rule.effects[<idx>][<key>]
func _apply_rule_override(rule: Rule, path: String, value) -> void:
	if path == "chance":
		rule.chance = float(value)
		return
	if path.begins_with("effect."):
		var key := path.substr("effect.".length())
		if rule.effects.size() == 0:
			push_warning("[variant] rule '%s' has no effects to override .%s" % [rule.id, key])
			return
		(rule.effects[0] as Dictionary)[key] = value
		return
	if path.begins_with("effects."):
		var rest := path.substr("effects.".length())
		var dot := rest.find(".")
		if dot < 0:
			push_warning(
				"[variant] malformed effects path '%s' — expected effects.<idx>.<field>" % path
			)
			return
		var idx := int(rest.substr(0, dot))
		var key2 := rest.substr(dot + 1)
		if idx < 0 or idx >= rule.effects.size():
			push_warning("[variant] rule '%s' effects index %d out of range" % [rule.id, idx])
			return
		(rule.effects[idx] as Dictionary)[key2] = value
		return
	push_warning("[variant] unsupported override path '%s' on rule '%s'" % [path, rule.id])
