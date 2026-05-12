extends Node
class_name LifecycleDirector

## ADR 0036 — Lifecycle / aging primitive.
##
## Reads each entity def's `lifecycle` block (a stage table or a
## $extends-resolved variant of @lib.lifecycles.<species>) and per-tick:
##   1. increments `state.age` by (dt / year_seconds) × age_per_in_game_year
##   2. on threshold crossing (age >= current_stage.max_age), advances
##      `state.life_stage` to the next stage
##   3. on advance: swaps `entity.visual.mesh`, rewrites tags (removes
##      previous stage's abilities, adds new stage's abilities), writes
##      `state.speed_mult`, and emits `life_stage_changed` (and
##      `entity_died` on terminal stages) into env.signal_buffer
##
## Per ADR 0021 this module EXPOSES the existing tag + state primitives —
## it does NOT introduce new effect types. The lifecycle block is the new
## primitive (declarative data on entity defs); LifecycleDirector is the
## interpreter; nothing about WHAT a given entity's life arc looks like
## moves into engine code.
##
## Wiring: LifecycleDirector expects to be a child of a Node whose script
## is `World`. Sibling of GameShell + ScreenFlow + LightingDirector +
## ScheduleDirector + PartyDirector. World.start() calls
## `register_lifecycles_from_env(env)` AFTER entity load (same hook
## ScheduleDirector uses); `tick(env)` is called by the World per-frame
## process loop OR explicitly by tests. No-op when no entity def carries
## a lifecycle block (existing 13 demos unaffected).
##
## Lifecycle:
## 1. Boot: nothing to load — director is purely state-driven from defs.
## 2. Per-tick (driven by World._process or tests): scan registered
##    lifecycles, increment age, check transitions, mutate state +
##    visual.mesh + tags, emit transition signals into env.signal_buffer.
## 3. Entity register: `register_lifecycle(entity_id, template_dict)` —
##    called by World after entity creation OR by tests.
##
## Backward-compat: entities WITHOUT a `lifecycle` field never age. Cache
## stays empty for those entities; tick is a no-op for the entire dict.
##
## Cross-game template (reference shape — actual JSON authored under
## data/lib/lifecycles/<name>.json per ADR 0027):
##
##   @lib.lifecycles.human:
##     {
##       "stages": [
##         {"id": "infant", "min_age": 0,  "max_age": 2,
##          "mesh": "human_infant_3d",
##          "abilities": ["needs_caring"], "speed_mult": 0.4},
##         {"id": "child",  "min_age": 2,  "max_age": 12,
##          "mesh": "human_child_3d",
##          "abilities": ["gather", "talk"], "speed_mult": 0.85},
##         {"id": "adult",  "min_age": 12, "max_age": 50,
##          "mesh": "merchant_npc_3d",
##          "abilities": ["all"], "speed_mult": 1.0},
##         {"id": "elder",  "min_age": 50, "max_age": 80,
##          "mesh": "human_elder_3d",
##          "abilities": ["talk", "tend_fire", "teach"],
##          "speed_mult": 0.6},
##         {"id": "dead",   "min_age": 80,
##          "mesh": null, "abilities": [], "speed_mult": 0.0,
##          "terminal": true}
##       ],
##       "age_per_in_game_year": 1.0,
##       "year_seconds": 900
##     }

# ============================================================
# CONSTANTS
# ============================================================

const SIGNAL_STAGE_CHANGED: String = "life_stage_changed"
const SIGNAL_ENTITY_DIED: String = "entity_died"
const ABILITY_ALL: String = "all"
const DEFAULT_YEAR_SECONDS: float = 900.0

# ============================================================
# STATE
# ============================================================

var _world: Node = null
# Per-entity cache: entity_id → {
#   template:           Dictionary (resolved stage table),
#   template_id:        String (e.g. "human", "deer" — for signal payloads),
#   age_per_in_game_year: float,
#   year_seconds:       float,
# }
var _cache: Dictionary = {}

# ============================================================
# LIFECYCLE
# ============================================================


func _ready() -> void:
	_world = get_parent()
	# No World parent — silently no-op (lets test harnesses include
	# the node without crashing). Tests instantiate the director
	# directly and call register/tick without a SceneTree.
	if _world == null or not _world.has_method("_build_env"):
		return


# ============================================================
# REGISTRATION
# ============================================================


## Register an entity's lifecycle. Called by World.load_data after
## entity creation walks defs/instances. The template_dict comes from
## the entity def's `lifecycle` block (or a $extends-resolved variant).
##
## Idempotent: re-registering an entity_id replaces its cache entry.
## No-op for malformed templates (logged via EngineError; director
## continues operating on other entities).
func register_lifecycle(
	entity_id: String, template: Dictionary, env: Dictionary = {}, template_id: String = ""
) -> void:
	if entity_id == "":
		return
	if not _validate_template(entity_id, template, env):
		return
	_cache[entity_id] = {
		"template": template,
		"template_id": template_id,
		"age_per_in_game_year": float(template.get("age_per_in_game_year", 0.0)),
		"year_seconds": float(template.get("year_seconds", DEFAULT_YEAR_SECONDS)),
	}


## Unregister on despawn. Idempotent.
func unregister_lifecycle(entity_id: String) -> void:
	_cache.erase(entity_id)


## Bulk-register from env. Walks env.entities; for each entity whose def
## carries a `lifecycle` block, registers the resolved template. Called
## once after world load_data completes.
##
## Per ADR 0027 ($extends + @lib references), the lifecycle block on a
## def MAY be a string reference like "@lib.lifecycles.human" OR an
## already-resolved dict. The lib_resolver runs at JSON-load time so by
## the time we get here, the field is a Dictionary OR a string the
## resolver couldn't resolve (logged as warning, skipped here).
func register_lifecycles_from_env(env: Dictionary) -> void:
	var entities = env.get("entities", null)
	var defs = env.get("defs", null)
	if not (entities is Dictionary) or not (defs is Dictionary):
		return
	for entity_id in (entities as Dictionary).keys():
		var ent = (entities as Dictionary)[entity_id]
		if not (ent is Entity):
			continue
		var def_id := str((ent as Entity).def_id)
		if def_id == "":
			continue
		var def = (defs as Dictionary).get(def_id, null)
		if not (def is Dictionary):
			continue
		var lc = (def as Dictionary).get("lifecycle", null)
		if lc == null:
			continue
		# Accept Dictionary directly; string references should already
		# be resolved by lib_resolver upstream. Skip strings here so we
		# don't silently treat them as malformed templates.
		if not (lc is Dictionary):
			push_warning(
				(
					"LifecycleDirector: '%s' lifecycle field is not a Dictionary — was lib resolution skipped?"
					% entity_id
				)
			)
			continue
		register_lifecycle(str(entity_id), lc as Dictionary, env, def_id)


# ============================================================
# TICK — the interpreter loop
# ============================================================


## Called by World per-frame OR by tests. dt is seconds since last tick.
## env is the engine's standard env dict.
func tick(env: Dictionary, dt: float = 1.0) -> void:
	if _cache.is_empty():
		return
	var entities = env.get("entities", null)
	if not (entities is Dictionary):
		return
	var settings_dict: Dictionary = (
		env.get("settings", {}) if env.get("settings", null) is Dictionary else {}
	)
	var infinite_life: bool = bool(settings_dict.get("infinite_life", false))

	for entity_id in _cache.keys():
		if not (entities as Dictionary).has(entity_id):
			continue
		var ent = (entities as Dictionary)[entity_id]
		if not (ent is Entity):
			continue
		var cache: Dictionary = _cache[entity_id]
		var template: Dictionary = cache.get("template", {})
		if template.is_empty():
			continue

		# Skip terminal entities — already at the end-stage. Aging stops.
		var current_stage_id: String = str((ent as Entity).get_state("life_stage", ""))
		var current_stage: Dictionary = _find_stage(template, current_stage_id)
		# If life_stage isn't set yet, resolve it from current age (handles
		# entities created with state_init.age but no explicit life_stage).
		if current_stage.is_empty():
			var age0: float = float((ent as Entity).get_state("age", 0.0))
			current_stage = _find_stage_for_age(template, age0)
			if not current_stage.is_empty():
				(ent as Entity).set_state("life_stage", str(current_stage.get("id", "")))
				(ent as Entity).set_state("speed_mult", float(current_stage.get("speed_mult", 1.0)))
				current_stage_id = str(current_stage.get("id", ""))

		if current_stage.get("terminal", false):
			continue

		# 1. Increment age. rate=0 = aging disabled (Phase 1 schema-only).
		var rate: float = float(cache.get("age_per_in_game_year", 0.0))
		var year_secs: float = float(cache.get("year_seconds", DEFAULT_YEAR_SECONDS))
		if year_secs <= 0.0:
			year_secs = DEFAULT_YEAR_SECONDS
		var delta_years: float = (dt / year_secs) * rate
		var prev_age: float = float((ent as Entity).get_state("age", 0.0))
		var new_age: float = prev_age + delta_years
		(ent as Entity).set_state("age", new_age)

		# 2. Threshold check. Final stage has no max_age — the search in
		#    _find_stage_for_age handles that by returning the final stage
		#    when age >= its min_age.
		var has_max: bool = (
			current_stage.has("max_age") and current_stage.get("max_age", null) != null
		)
		if not has_max:
			continue
		var current_max: float = float(current_stage.get("max_age", 0.0))
		if new_age < current_max:
			continue

		# 3. Find new stage by age — linear scan; ≤6 stages typical.
		var new_stage: Dictionary = _find_stage_for_age(template, new_age)
		if new_stage.is_empty():
			continue
		var new_id: String = str(new_stage.get("id", ""))
		if new_id == current_stage_id:
			# Defensive: shouldn't happen if max_age was crossed, but
			# guard against malformed templates with overlapping ranges.
			continue

		# 3a. Infinite-life mode for player-tagged entities: cap at the
		#     stage BEFORE terminal. The director just refuses to advance
		#     into a terminal stage when the player carries this flag.
		if (
			infinite_life
			and (ent as Entity).has_tag("player")
			and bool(new_stage.get("terminal", false))
		):
			# Pin age to (current_max - epsilon) so we don't keep
			# re-triggering the threshold every tick.
			(ent as Entity).set_state("age", current_max - 0.001)
			continue

		_transition(ent as Entity, current_stage, new_stage, env, str(cache.get("template_id", "")))


# ============================================================
# TRANSITION
# ============================================================


func _transition(
	ent: Entity, prev: Dictionary, next: Dictionary, env: Dictionary, template_id: String
) -> void:
	var old_id: String = str(prev.get("id", ""))
	var new_id: String = str(next.get("id", ""))

	# 1. Update state.
	ent.set_state("life_stage", new_id)
	ent.set_state("speed_mult", float(next.get("speed_mult", 1.0)))

	# 2. Swap visual.mesh. null mesh = invisible / despawn-eligible —
	#    game rules can listen for entity_died and choose corpse vs remove.
	var new_mesh = next.get("mesh", null)
	if ent.visual == null:
		ent.visual = {}
	ent.visual["mesh"] = new_mesh

	# 3. Rewrite tags. Special-case: abilities=["all"] = preserve all
	#    prior tags, just remove the prev stage's abilities (so the
	#    "child→adult" transition correctly drops "needs_caring" while
	#    keeping species + faction tags).
	var prev_abilities: Array = (
		prev.get("abilities", []) if prev.get("abilities", null) is Array else []
	)
	var new_abilities: Array = (
		next.get("abilities", []) if next.get("abilities", null) is Array else []
	)
	var all_passthrough: bool = new_abilities.size() == 1 and str(new_abilities[0]) == ABILITY_ALL
	# Always remove prev stage's specific ability tags (unless they were
	# "all" too — nothing to remove). This keeps non-ability tags
	# intact (species/faction/named_npc/etc).
	if not (prev_abilities.size() == 1 and str(prev_abilities[0]) == ABILITY_ALL):
		for ab in prev_abilities:
			ent.remove_tag(str(ab))
	if not all_passthrough:
		for ab in new_abilities:
			ent.add_tag(str(ab))

	# 4. Emit signals into env.signal_buffer (same surface effect_apply._emit
	#    uses). PhaseScheduler drains during react phase. ScheduleDirector
	#    also writes here on transitions, so consumers can listen via the
	#    standard signal-trigger primitive: {"trigger": {"type": "signal",
	#    "name": "life_stage_changed"}, ...}.
	var buf = env.get("signal_buffer", null)
	if not (buf is Array):
		# No signal buffer — scheduler not initialized. Same warning path
		# effect_apply._emit uses (silent here; tests provide a buffer).
		return
	(
		(buf as Array)
		. append(
			{
				"name": SIGNAL_STAGE_CHANGED,
				"payload":
				{
					"entity_id": ent.instance_id,
					"old_stage": old_id,
					"new_stage": new_id,
				}
			}
		)
	)
	if bool(next.get("terminal", false)):
		(
			(buf as Array)
			. append(
				{
					"name": SIGNAL_ENTITY_DIED,
					"payload":
					{
						"entity_id": ent.instance_id,
						"lifecycle_id": template_id,
						"age": float(ent.get_state("age", 0.0)),
						"cause": "old_age",
					}
				}
			)
		)


# ============================================================
# STAGE LOOKUP
# ============================================================


## Find a stage by id. Returns {} when not found.
static func _find_stage(template: Dictionary, stage_id: String) -> Dictionary:
	if stage_id == "":
		return {}
	var stages: Array = template.get("stages", []) if template.get("stages", null) is Array else []
	for s in stages:
		if s is Dictionary and str((s as Dictionary).get("id", "")) == stage_id:
			return s
	return {}


## Find the stage whose [min_age, max_age) covers `age`. Final stage has
## no max_age (terminal: true) and matches everything past its min_age.
## Returns {} when stages array is empty / malformed.
static func _find_stage_for_age(template: Dictionary, age: float) -> Dictionary:
	var stages: Array = template.get("stages", []) if template.get("stages", null) is Array else []
	if stages.is_empty():
		return {}
	for s in stages:
		if not (s is Dictionary):
			continue
		var sd: Dictionary = s
		var lo: float = float(sd.get("min_age", 0.0))
		var hi_v = sd.get("max_age", null)
		if hi_v == null:
			# Final stage: matches age >= min_age (no upper bound).
			if age >= lo:
				return sd
		else:
			var hi: float = float(hi_v)
			if age >= lo and age < hi:
				return sd
	# Past final stage's min_age but nothing matched (shouldn't happen
	# with a sane template; defensive return of last stage).
	var last = stages[stages.size() - 1]
	if last is Dictionary:
		return last
	return {}


# ============================================================
# VALIDATION
# ============================================================


## Sanity-check a template at registration. Logs (push_warning +
## EngineError) on malformed input but DOES NOT crash — the director
## skips this entity and continues with others.
##
## Returns true iff the template is well-enough-formed to register.
static func _validate_template(entity_id: String, template: Dictionary, env: Dictionary) -> bool:
	if template.is_empty():
		push_warning("LifecycleDirector: '%s' has empty lifecycle template — skipping." % entity_id)
		return false
	var stages = template.get("stages", null)
	if not (stages is Array) or (stages as Array).is_empty():
		push_warning("LifecycleDirector: '%s' lifecycle has no stages — skipping." % entity_id)
		if env.has("error_buffer"):
			EngineError.raise(
				env,
				"lifecycle.no_stages",
				"LifecycleDirector: '%s' has empty stages array" % entity_id,
				{"entity": entity_id},
				"Add at least one stage with id + min_age.",
				"warning"
			)
		return false
	# Every stage must have an id. min_age is required for all but the
	# very first stage (which conventionally has min_age=0 anyway).
	var any_valid: bool = false
	for s in stages as Array:
		if s is Dictionary and (s as Dictionary).has("id"):
			any_valid = true
			break
	if not any_valid:
		push_warning(
			"LifecycleDirector: '%s' lifecycle has no stage with required keys (id)" % entity_id
		)
		if env.has("error_buffer"):
			EngineError.raise(
				env,
				"lifecycle.malformed",
				"LifecycleDirector: '%s' has no stage with required key 'id'" % entity_id,
				{"entity": entity_id},
				"Each stage needs id; non-terminal stages need min_age + max_age.",
				"warning"
			)
		return false
	return true
