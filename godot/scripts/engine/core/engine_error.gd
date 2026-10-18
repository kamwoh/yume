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

const RULE_FILE_MISSING := "rule.file_missing"
const RULE_INVALID_JSON := "rule.invalid_json"
const RULE_LIST_NOT_ARRAY := "rule.list_not_array"
const RULE_NOT_INSTANCE := "rule.not_instance"
const RULE_MISSING_ID := "rule.missing_id"
const RULE_DUPLICATE_ID := "rule.duplicate_id"
const RULE_TRIGGER_MISSING := "rule.trigger_missing"
const RULE_TRIGGER_INVALID := "rule.trigger_invalid"
const RULE_EFFECT_EMPTY := "rule.effect_empty"
const RULE_EFFECT_NOT_DICT := "rule.effect_not_dict"
const RULE_EFFECT_MISSING_TYPE := "rule.effect_missing_type"
const RULE_CHANCE_OUT_OF_RANGE := "rule.chance_out_of_range"
## ADR 0080 — `once` and `once_per` are different quantifiers over the same
## rule; combining them has no coherent meaning.
const RULE_ONCE_CONFLICT := "rule.once_conflict"

const EFFECT_UNKNOWN_TYPE := "effect.unknown_type"
const EFFECT_SPAWN_NO_DEF := "effect.spawn_no_def"
const EFFECT_TRANSFORM_NO_DEF := "effect.transform_no_def"
const EFFECT_EMIT_NO_BUFFER := "effect.emit_no_buffer"

const FORMULA_PARSE_FAILED := "formula.parse_failed"
const FORMULA_EXEC_FAILED := "formula.exec_failed"
const FORMULA_UNKNOWN_FUNCTION := "formula.unknown_function"

const SHADER_UNKNOWN := "shader.unknown"
const SHADER_NOT_COMPILED := "shader.not_compiled"

## ADR 0090 — the spec vocabularies.
const INPUT_UNKNOWN_KEY := "input.unknown_key"
const AUDIO_UNKNOWN_CHANNEL := "audio.unknown_channel"
const SCENE_UNKNOWN_FIELD := "scene.unknown_field"
const PHYSICS_UNKNOWN_BODY_TYPE := "physics.unknown_body_type"
const PHYSICS_UNKNOWN_LAYER := "physics.unknown_layer"

## ADR 0091 — articulated bodies.
const PHYSICS_BAD_ARTICULATION := "physics.bad_articulation"

const WORLD_ENTITIES_MISSING := "world.entities_missing"
const WORLD_ENTITIES_INVALID := "world.entities_invalid_json"
const WORLD_DEF_UNKNOWN := "world.def_unknown"

const SHAPE_FILE_MISSING := "shape.file_missing"
const SHAPE_INVALID_JSON := "shape.invalid_json"
const MESH_FILE_MISSING := "mesh.file_missing"
const MESH_INVALID_JSON := "mesh.invalid_json"

const SCHEDULER_TOPO_CYCLE := "scheduler.topo_cycle"
## ADR 0077 — level subroutines.
const LEVEL_RETURN_EMPTY_STACK := "level.return_empty_stack"
const LEVEL_RETURN_ORPHANED := "level.return_orphaned"
## ADR 0078 — calendar clock.
const TIME_REENTRANT_ADVANCE := "time.reentrant_advance"

const ANIMATION_NO_DEFAULT := "animation.no_default"

# ADR 0039 — Playwright-style scenario steps
const STEP_UNKNOWN_VERB := "step.unknown_verb"
const STEP_UNKNOWN_ACTION := "step.unknown_action"
const STEP_CLICK_NOT_FOUND := "step.click_not_found"
const STEP_CLICK_AMBIGUOUS := "step.click_ambiguous"
const STEP_EXPECT_FAILED := "step.expect_failed"
const STEP_RELEASE_NOT_HELD := "step.release_not_held"
const STEP_INVALID_DURATION := "step.invalid_duration"

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
static func make(
	code: String,
	what: String,
	where: Dictionary = {},
	hint: String = "",
	severity: String = "error"
) -> Dictionary:
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
static func raise(
	env: Dictionary,
	code: String,
	what: String,
	where: Dictionary = {},
	hint: String = "",
	severity: String = "error"
) -> Dictionary:
	var rec := make(code, what, where, hint, severity)
	report(env, rec)
	return rec


## Drain accumulated errors. Returns the buffer's contents and resets it.
## Callers: qa-tester between scenarios, /yume-design between phases.
static func drain(env: Dictionary) -> Array:
	if env == null or not (env is Dictionary):
		return []
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
