extends Node
class_name ClassManager

## ADR 0030 — Occupation/class primitive.
##
## Holds class definitions (loaded from data/<game>/classes/*.json files OR
## registered directly by tests) and hosts the `switch_class` semantics:
## validates the target class exists, validates cooldown, swaps
## `state.current_class`, records the switch day, and emits a
## `class_switched` signal into env.signal_buffer.
##
## Per ADR 0021, this module EXPOSES existing primitives (state mutation +
## signal emission) under one declarative effect. No new VERBS beyond
## `switch_class`. The class definition shape is the new declarative
## primitive (data on disk); ClassManager is the interpreter.
##
## Design contract (from ADR 0030 §3 player-actor state schema):
##   - state.current_class      : String — active class id
##   - state.class_progress     : Dict {class_id: {level, xp, ...}} — per-class
##                                progression. Preserved across switches.
##   - state.inventory          : Array — class-agnostic, untouched here.
##   - state.reputation         : Dict — class-agnostic, untouched here.
##   - state.last_class_switch_day : int — bookkeeping for cooldown.
##
## Wiring: ClassManager expects to be a child of a Node whose script is
## `World`. Sibling of GameShell + ScreenFlow + LightingDirector +
## ScheduleDirector + LifecycleDirector + PartyDirector. No per-tick work —
## class state is a plain entity field; rules read it via standard query
## bindings (e.g. `state: {current_class_eq: "farmer"}`).
##
## Phase 1 scope (this commit):
##   - register classes via direct API (`register_class`)
##   - JSON-loading from data/<game>/classes/*.json (additive; tests
##     register manually so JSON loading isn't on the hot path of unit
##     tests)
##   - switch_class state mutation + signal emission
##   - cooldown validation (day-based)
##   - atomic on failure: unknown class id leaves state untouched.
##
## Phase 2 (deferred — game_shell concerns):
##   - HUD-panel swap (rebuild_class_hud) — game_shell listens to
##     class_switched signal to swap per-class HUD region.
##   - Verb-set rebind via InputRegistrar.rebind_actions.
##   - Camera-mode swap via game_shell.set_camera_mode.
##   - Audio-bed swap via AudioBusManager.set_ambient_bed.
##   - Barker-pool swap.
## Engine emits the signal cleanly; game_shell + content rules subscribe.
##
## Lifecycle:
## 1. Boot: world.gd instantiates this Node sibling and (if data root has
##    a classes/ directory) calls `register_classes_from_data_root(root, env)`.
##    No-op when no classes directory.
## 2. Effect dispatch: effect_apply.gd's `switch_class` arm calls
##    `switch_class(env, ctx, target_id, to_class, opts)` and surfaces
##    the result.
## 3. Tests: instantiate directly, call register_class + switch_class.

# ============================================================
# CONSTANTS
# ============================================================

const SIGNAL_CLASS_SWITCHED: String = "class_switched"
const STATE_CURRENT_CLASS: String = "current_class"
const STATE_CLASS_PROGRESS: String = "class_progress"
const STATE_LAST_SWITCH_DAY: String = "last_class_switch_day"
const FAILURE_REASON_NO_DEF: String = "unknown_class"
const FAILURE_REASON_COOLDOWN: String = "cooldown"

# ============================================================
# STATE
# ============================================================

var _world: Node = null
# class_id (String) → class def (Dictionary)
var _class_defs: Dictionary = {}

# ============================================================
# LIFECYCLE
# ============================================================


func _ready() -> void:
	_world = get_parent()
	# No World parent → silently no-op (lets test harnesses include the
	# node without crashing). Tests instantiate the manager directly and
	# call register_class + switch_class without a SceneTree.
	if _world == null or not _world.has_method("_build_env"):
		return


# ============================================================
# REGISTRATION
# ============================================================


## Register a single class definition. Idempotent: re-registering the same
## id replaces the prior def. Used by both the JSON loader and tests.
##
## A minimal valid class def has at least an `id`. All other fields
## (verbs / hud_panel / camera_mode / switch_cooldown_days / etc.) are
## treated as optional metadata. The class def is content's contract;
## ClassManager doesn't enforce a schema beyond the id presence.
func register_class(class_id: String, class_def: Dictionary) -> void:
	if class_id == "":
		push_warning("ClassManager: register_class called with empty id — skipping.")
		return
	# Make sure the def carries its id (round-trip clean if the def
	# originally lacked one — e.g. a test passing a literal dict).
	var stored: Dictionary = class_def.duplicate(true)
	stored["id"] = class_id
	_class_defs[class_id] = stored


## Bulk-register from disk. Walks `<root>/classes/*.json`, parses each,
## and registers under its `id` field. No-op when the directory is absent
## (existing demos without occupations). Logs structural errors via
## EngineError; continues processing other files.
##
## Phase 1: $extends / @lib refs are NOT resolved here. The lib_resolver
## runs at JSON-load time elsewhere (entities, rules, screens). When
## class JSON files start using `@lib.classes.X` or `$extends`, the
## upstream resolver should run on the parsed dict before
## register_class is invoked. Documented in the ADR; not blocking
## Phase 1 tests.
func register_classes_from_data_root(root: String, env: Dictionary = {}) -> void:
	if root == "":
		return
	var classes_dir: String = root.rstrip("/") + "/classes"
	if not DirAccess.dir_exists_absolute(classes_dir):
		# Optional — most games won't ship a class catalog.
		return
	var dir := DirAccess.open(classes_dir)
	if dir == null:
		return
	var files: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	files.sort()
	for f in files:
		var path: String = classes_dir + "/" + f
		var parsed: Dictionary = _read_json(path, env)
		if parsed.is_empty():
			continue
		var cid: String = str(parsed.get("id", ""))
		if cid == "":
			push_warning("ClassManager: class def at '%s' missing 'id' — skipping." % path)
			if env != null and env is Dictionary and env.has("error_buffer"):
				EngineError.raise(
					env,
					EngineError.CLASS_MISSING_ID,
					"ClassManager: class def at '%s' has no id" % path,
					{"file": path},
					'Add an \'id\' field naming this class (e.g. "id": "farmer").',
					"warning"
				)
			continue
		register_class(cid, parsed)


## Returns true iff a class with this id has been registered.
func has_class(class_id: String) -> bool:
	return _class_defs.has(class_id)


## Returns the class def dict (or {} if not registered). Read-only —
## callers should not mutate the returned dict.
##
## Named `get_class_def` (not `get_class`) because GDScript's Object base
## already defines `get_class()` as a built-in returning the type name —
## shadowing it produces a "Could not resolve external class member"
## parse error at any call site. Empirical case 2026-05-10.
func get_class_def(class_id: String) -> Dictionary:
	var d = _class_defs.get(class_id, null)
	return d if d is Dictionary else {}


## Returns the list of registered class ids. For diagnostics / tooling.
func known_class_ids() -> Array:
	return _class_defs.keys()


# ============================================================
# SWITCH_CLASS
# ============================================================


## Atomic switch. Returns a result dict:
##   {ok: bool, reason: String, from: String, to: String}
## On success:
##   - state.current_class set to to_class
##   - state.last_class_switch_day set to world.current_day (or 0 if absent)
##   - class_switched signal pushed to env.signal_buffer
## On failure (unknown class OR cooldown not met):
##   - state UNCHANGED (atomic)
##   - reason populated ("unknown_class" | "cooldown")
##   - NO signal emitted (caller chooses whether to surface the failure
##     via on_failure_signal — handled in effect_apply.gd's wrapper)
##
## Cooldown semantics:
##   - effect-level `cooldown_days` parameter (default 1).
##   - if state.last_class_switch_day exists AND
##     world.current_day - last_class_switch_day < cooldown_days → fail.
##   - games without a day clock leave world.current_day absent → reads
##     as 0 → first switch always succeeds; subsequent switches on the
##     same "day 0" with cooldown_days >= 1 will fail. Author guidance:
##     set cooldown_days to 0 if no day clock.
func switch_class(
	env: Dictionary, target_id: String, to_class: String, cooldown_days: int = 1
) -> Dictionary:
	var entities = env.get("entities", null)
	if not (entities is Dictionary) or not (entities as Dictionary).has(target_id):
		return {
			"ok": false,
			"reason": "no_target",
			"from": "",
			"to": to_class,
		}
	var ent = (entities as Dictionary)[target_id]
	if not (ent is Entity):
		return {"ok": false, "reason": "no_target", "from": "", "to": to_class}
	var prev_class: String = str((ent as Entity).get_state(STATE_CURRENT_CLASS, ""))
	# 1. Validate class def exists.
	if not _class_defs.has(to_class):
		EngineError.raise(
			env,
			EngineError.CLASS_SWITCH_NO_DEF,
			"switch_class: no class def '%s'" % to_class,
			{"target": target_id, "to_class": to_class, "known_classes": _class_defs.keys()},
			(
				"Register the class def via register_class or add data/<game>/classes/%s.json."
				% to_class
			),
			"warning"
		)
		return {
			"ok": false,
			"reason": FAILURE_REASON_NO_DEF,
			"from": prev_class,
			"to": to_class,
		}
	# 2. Validate cooldown. Read current_day from world; default 0 if absent.
	var world_dict: Dictionary = (
		env.get("world", {}) if env.get("world", null) is Dictionary else {}
	)
	var current_day: int = int(world_dict.get("current_day", 0))
	var cd: int = max(0, cooldown_days)
	if cd > 0 and (ent as Entity).get_state(STATE_LAST_SWITCH_DAY, null) != null:
		var last_day: int = int((ent as Entity).get_state(STATE_LAST_SWITCH_DAY, 0))
		if current_day - last_day < cd:
			(
				EngineError
				. raise(
					env,
					EngineError.CLASS_SWITCH_COOLDOWN,
					(
						"switch_class: cooldown active (last_day=%d, current_day=%d, required=%d)"
						% [last_day, current_day, cd]
					),
					{
						"target": target_id,
						"to_class": to_class,
						"last_class_switch_day": last_day,
						"current_day": current_day,
						"cooldown_days": cd
					},
					"Wait until current_day - last_class_switch_day >= cooldown_days, or set cooldown_days=0 in the effect.",
					"warning"
				)
			)
			return {
				"ok": false,
				"reason": FAILURE_REASON_COOLDOWN,
				"from": prev_class,
				"to": to_class,
			}
	# 3. Atomic apply. State + signal happen as one unit; no partial
	#    mutation if validation failed above.
	(ent as Entity).set_state(STATE_CURRENT_CLASS, to_class)
	(ent as Entity).set_state(STATE_LAST_SWITCH_DAY, current_day)
	# 4. Emit signal for downstream listeners (game_shell HUD swap,
	#    rule subscribers for tutorial / unlock / barker re-pool).
	var buf = env.get("signal_buffer", null)
	if buf is Array:
		(
			(buf as Array)
			. append(
				{
					"name": SIGNAL_CLASS_SWITCHED,
					"payload":
					{
						"entity_id": (ent as Entity).instance_id,
						"from": prev_class,
						"to": to_class,
						"day": current_day,
					}
				}
			)
		)
	# else: signal_buffer absent (test harness without scheduler) —
	# state mutation still applied; signal silently dropped. Tests that
	# check the signal must provide their own buffer.
	return {
		"ok": true,
		"reason": "",
		"from": prev_class,
		"to": to_class,
	}


# ============================================================
# INTERNAL
# ============================================================


static func _read_json(path: String, env: Dictionary) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_warning("ClassManager: invalid JSON at '%s' (%s)" % [path, json.get_error_message()])
		if env != null and env is Dictionary and env.has("error_buffer"):
			EngineError.raise(
				env,
				EngineError.CLASS_INVALID_JSON,
				"ClassManager: invalid JSON at '%s'" % path,
				{"file": path, "parse_error": json.get_error_message()},
				"Validate the file with `python -m json.tool < %s`." % path,
				"warning"
			)
		return {}
	return json.data if json.data is Dictionary else {}
