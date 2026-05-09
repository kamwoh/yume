extends RefCounted
class_name EngineError

## Structured engine errors (Tier 2.6a).
##
## Replaces ad-hoc `push_error("...")` calls with JSON-shaped records so
## LLM agents and qa-tester can read engine failures programmatically:
##   - `code` is a stable enum string suitable for matching in retry loops.
##   - `where` is structured (file/rule_id/field) instead of formatted.
##   - `hint` is the suggested fix in plain text.
##
## Backward compatibility: `report()` still calls `push_error` /
## `push_warning` so the Godot dev console keeps showing failures during
## headless runs.
##
## Buffer drainage: callers (qa-tester, /yume-design orchestrator, future
## Tier 3 actors) read `env.error_buffer` after a tick to learn what
## failed. The buffer is plain `Array[Dictionary]` — JSON-serializable
## end-to-end.

# ============================================================
# ERROR CODES (stable strings)
# ============================================================
#
# Naming: `<module>.<symptom>`. Stable across versions — do not rename
# without an ADR. New codes are additive; downstream agents key off these.

const RULE_FILE_MISSING        := "rule.file_missing"
const RULE_INVALID_JSON        := "rule.invalid_json"
const RULE_LIST_NOT_ARRAY      := "rule.list_not_array"
const RULE_NOT_INSTANCE        := "rule.not_instance"
const RULE_MISSING_ID          := "rule.missing_id"
const RULE_DUPLICATE_ID        := "rule.duplicate_id"
const RULE_TRIGGER_MISSING     := "rule.trigger_missing"
const RULE_TRIGGER_INVALID     := "rule.trigger_invalid"
const RULE_EFFECT_EMPTY        := "rule.effect_empty"
const RULE_EFFECT_NOT_DICT     := "rule.effect_not_dict"
const RULE_EFFECT_MISSING_TYPE := "rule.effect_missing_type"
const RULE_CHANCE_OUT_OF_RANGE := "rule.chance_out_of_range"

const EFFECT_UNKNOWN_TYPE      := "effect.unknown_type"
const EFFECT_SPAWN_NO_DEF      := "effect.spawn_no_def"
const EFFECT_TRANSFORM_NO_DEF  := "effect.transform_no_def"
const EFFECT_EMIT_NO_BUFFER    := "effect.emit_no_buffer"
const EFFECT_BUILD_PLACE_NO_DEF    := "effect.build_place_no_def"
const EFFECT_BUILD_PLACE_INVALID   := "effect.build_place_invalid"
const EFFECT_BUILD_PLACE_NO_SOURCE := "effect.build_place_no_source"

const FORMULA_PARSE_FAILED     := "formula.parse_failed"
const FORMULA_EXEC_FAILED      := "formula.exec_failed"

const WORLD_ENTITIES_MISSING   := "world.entities_missing"
const WORLD_ENTITIES_INVALID   := "world.entities_invalid_json"
const WORLD_DEF_UNKNOWN        := "world.def_unknown"

const SHAPE_FILE_MISSING       := "shape.file_missing"
const SHAPE_INVALID_JSON       := "shape.invalid_json"
const MESH_FILE_MISSING        := "mesh.file_missing"
const MESH_INVALID_JSON        := "mesh.invalid_json"

const SCHEDULER_TOPO_CYCLE     := "scheduler.topo_cycle"

const ANIMATION_NO_DEFAULT     := "animation.no_default"

# ADR 0030 — class primitive
const CLASS_SWITCH_NO_DEF      := "class.switch_no_def"
const CLASS_SWITCH_COOLDOWN    := "class.switch_cooldown"
const CLASS_MISSING_ID         := "class.missing_id"
const CLASS_INVALID_JSON       := "class.invalid_json"


# ============================================================
# CONSTRUCTORS
# ============================================================

## Build a structured error record. All fields are JSON-friendly types.
##
## - `code`     : stable enum string (use one of the constants above)
## - `what`     : human-readable summary, includes the bad value
## - `where`    : structured location dict (file/rule_id/field/index/...)
## - `hint`     : suggested fix in plain text — written for an LLM reader
## - `severity` : "error" (default) or "warning"
static func make(code: String, what: String, where: Dictionary = {}, hint: String = "", severity: String = "error") -> Dictionary:
	return {
		"code": code,
		"what": what,
		"where": where.duplicate(),
		"hint": hint,
		"severity": severity,
	}


# ============================================================
# REPORTING
# ============================================================

## Push a record to env.error_buffer (creating it if absent) AND log to
## Godot's console via push_error/push_warning so headless runs still
## show failures. `env` may be {} when no buffer is wanted (e.g. static
## validators); the console call still fires.
static func report(env: Dictionary, record: Dictionary) -> void:
	if env != null and env is Dictionary:
		var buf: Array = env.get("error_buffer", [])
		if not (buf is Array):
			buf = []
		buf.append(record)
		env["error_buffer"] = buf
	_log_to_console(record)


## Convenience: build + report in one call.
static func raise(env: Dictionary, code: String, what: String, where: Dictionary = {}, hint: String = "", severity: String = "error") -> Dictionary:
	var rec := make(code, what, where, hint, severity)
	report(env, rec)
	return rec


## Drain accumulated errors. Returns the buffer's contents and resets it.
## Callers: qa-tester between scenarios, /yume-design between phases.
static func drain(env: Dictionary) -> Array:
	if env == null or not (env is Dictionary): return []
	var buf: Array = env.get("error_buffer", [])
	env["error_buffer"] = []
	return buf


# ============================================================
# INTERNAL
# ============================================================

static func _log_to_console(record: Dictionary) -> void:
	var sev := str(record.get("severity", "error"))
	var line := "[%s] %s" % [str(record.get("code", "?")), str(record.get("what", ""))]
	var hint := str(record.get("hint", ""))
	if hint != "":
		line += " — hint: " + hint
	if sev == "warning":
		push_warning(line)
	else:
		push_error(line)
