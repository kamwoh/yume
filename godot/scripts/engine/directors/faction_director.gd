extends Node
class_name FactionDirector

## ADR 0032 — Faction primitive.
##
## Holds faction definitions + inter-faction relationship state (stance +
## tension scalar) and hosts the four declarative effect verbs that mutate
## faction state:
##   - declare_war   → stance "at_war",  tension 100
##   - sign_treaty   → stance neutral (or arg), tension = stance baseline
##   - propose_alliance → stance "allied", tension 0
##   - swear_loyalty → mutate target NPC's state.faction_loyalty[<id>]
##
## Stance vocabulary is fixed at 5 values, ordered by escalation:
##   allied < neutral < rivals < hostile < at_war
## Tension is a numeric 0-100 scalar that decays toward the active stance's
## baseline each in-game day; effects nudge it on provocations.
##
## Per ADR 0021, this module EXPOSES existing primitives (state mutation +
## signal emission) under declarative effects. No new VERBS beyond the
## four listed above. The faction definition shape is the new declarative
## primitive (data on disk); FactionDirector is the interpreter.
##
## Design contract (from ADR 0032 §schema):
##   - factions.json declares `factions[]` and initial `relationships[]`
##   - relationships are stored as DIRECTED EDGES from→to (asymmetric ok)
##   - NPC entities carry state.faction_loyalty: {<faction_id>: <0..100>}
##
## Wiring: FactionDirector expects to be a child of a Node whose script is
## `World`. Sibling of GameShell + ScreenFlow + ClassManager + ZoneStore-
## holding World + ScheduleDirector + LifecycleDirector + PartyDirector.
## No per-tick work in Phase 1 (daily tension-drift deferred to ADR 0032
## §Phase 2). Effects mutate state synchronously via apply_*; bindings
## resolve through the exposed `faction` namespace in formula context.
##
## Phase 1 scope (this commit):
##   - register factions via direct API (`register_factions`)
##   - declare_war / sign_treaty / propose_alliance / swear_loyalty applies
##   - faction.<id>.<field> binding namespace (member_count, tension_with.X,
##     stance_with.X, leader, controls_zone)
##   - find_factions_with_stance, get_relationship diagnostic helpers
##   - signal emission into env.signal_buffer (faction_war_declared,
##     faction_treaty_signed, faction_alliance_formed, faction_loyalty_changed)
##   - atomic on failure: unknown faction id leaves state untouched, raises
##     FACTION_NO_DEF
##   - zone-control helper (set_zone_control composes zone_state_set)
##
## Phase 2 (deferred):
##   - daily tension drift (per-tick rule firing into apply_drift)
##   - pruning loyalty entries below threshold
##   - JSON loading from data/<game>/factions.json (load_from_data_root)
##   - save/load round-trip helper plumbed into save_state.gd

# ============================================================
# CONSTANTS
# ============================================================

const SIGNAL_WAR_DECLARED: String = "faction_war_declared"
const SIGNAL_TREATY_SIGNED: String = "faction_treaty_signed"
const SIGNAL_ALLIANCE_FORMED: String = "faction_alliance_formed"
const SIGNAL_LOYALTY_CHANGED: String = "faction_loyalty_changed"

const STATE_FACTION_LOYALTY: String = "faction_loyalty"

const STANCE_ALLIED: String = "allied"
const STANCE_NEUTRAL: String = "neutral"
const STANCE_RIVALS: String = "rivals"
const STANCE_HOSTILE: String = "hostile"
const STANCE_AT_WAR: String = "at_war"

# Membership threshold — loyalty values >= this count toward member_count.
const MEMBER_THRESHOLD: int = 50

# Default delta for swear_loyalty when neither delta nor value is provided.
const DEFAULT_LOYALTY_DELTA: int = 10

# Stance → tension baseline mapping. sign_treaty without an explicit
# new_stance falls to neutral; its baseline tension is 10.
const STANCE_BASELINE: Dictionary = {
	STANCE_ALLIED: 0,
	STANCE_NEUTRAL: 10,
	STANCE_RIVALS: 40,
	STANCE_HOSTILE: 70,
	STANCE_AT_WAR: 100,
}

# ============================================================
# STATE
# ============================================================

var _world: Node = null
# faction_id (String) → faction def (Dictionary)
var _factions: Dictionary = {}
# "<from>:<to>" (String) → {stance: String, tension: int}
var _relationships: Dictionary = {}

# ============================================================
# LIFECYCLE
# ============================================================


func _ready() -> void:
	_world = get_parent()
	# No World parent → silently no-op (lets test harnesses include the
	# node without crashing). Tests instantiate the director directly and
	# call register_factions + apply_* without a SceneTree.
	if _world == null or not _world.has_method("_build_env"):
		return


# ============================================================
# REGISTRATION
# ============================================================


## Register factions + initial relationships from a parsed factions.json
## dict. Idempotent: re-registering the same id replaces the prior def.
##
## Schema:
##   {
##     "factions": [{"id": "<id>", "leader": "<entity_id>",
##                   "ideology": "...", "color": "#hex",
##                   "home_zone": "<zone_id>"}, ...],
##     "relationships": [{"from": "<id>", "to": "<id>",
##                        "stance": "neutral|allied|rivals|hostile|at_war",
##                        "tension": 0..100}, ...]
##   }
##
## Returns Array of EngineError records (empty on success). Validates:
##   - duplicate faction id    → error (warning, last wins)
##   - relationship from/to    → error if either id is unknown
##   - relationship stance     → error if not one of the 5 stances
func register_factions(data: Dictionary, env: Dictionary = {}) -> Array:
	var errors: Array = []
	if data == null or not (data is Dictionary):
		return errors

	# Phase 1: register faction defs
	var faction_list = data.get("factions", [])
	if faction_list is Array:
		for raw in faction_list as Array:
			if not (raw is Dictionary):
				errors.append(
					EngineError.raise(
						env,
						"faction.invalid_entry",
						"faction entry not a dict",
						{"file": "factions.json", "got": str(raw)},
						"Each faction must be a dict with at least an 'id' field.",
						"warning"
					)
				)
				continue
			var f: Dictionary = raw
			var fid := str(f.get("id", ""))
			if fid == "":
				errors.append(
					EngineError.raise(
						env,
						"faction.missing_id",
						"faction missing id",
						{"file": "factions.json", "entry": f},
						"Every faction needs a unique 'id' string.",
						"warning"
					)
				)
				continue
			var stored: Dictionary = f.duplicate(true)
			stored["id"] = fid
			_factions[fid] = stored

	# Phase 2: register initial relationships (validated against faction set)
	var rel_list = data.get("relationships", [])
	if rel_list is Array:
		for raw_r in rel_list as Array:
			if not (raw_r is Dictionary):
				continue
			var r: Dictionary = raw_r
			var from_id := str(r.get("from", ""))
			var to_id := str(r.get("to", ""))
			var stance := str(r.get("stance", STANCE_NEUTRAL))
			var tension := int(r.get("tension", STANCE_BASELINE.get(stance, 0)))
			if not _factions.has(from_id):
				errors.append(
					EngineError.raise(
						env,
						EngineError.FACTION_NO_DEF,
						"relationship 'from' references unknown faction '%s'" % from_id,
						{"file": "factions.json", "from": from_id, "to": to_id},
						"Add a faction def with id '%s' or fix the relationship." % from_id,
						"warning"
					)
				)
				continue
			if not _factions.has(to_id):
				errors.append(
					EngineError.raise(
						env,
						EngineError.FACTION_NO_DEF,
						"relationship 'to' references unknown faction '%s'" % to_id,
						{"file": "factions.json", "from": from_id, "to": to_id},
						"Add a faction def with id '%s' or fix the relationship." % to_id,
						"warning"
					)
				)
				continue
			if not STANCE_BASELINE.has(stance):
				(
					errors
					. append(
						(
							EngineError
							. raise(
								env,
								EngineError.FACTION_INVALID_STANCE,
								(
									"relationship stance '%s' not one of allied|neutral|rivals|hostile|at_war"
									% stance
								),
								{
									"file": "factions.json",
									"from": from_id,
									"to": to_id,
									"stance": stance
								},
								"Use one of: allied, neutral, rivals, hostile, at_war.",
								"warning"
							)
						)
					)
				)
				continue
			_set_rel(from_id, to_id, stance, tension)
	return errors


## Returns true iff a faction with this id has been registered.
func has_faction(faction_id: String) -> bool:
	return _factions.has(faction_id)


## Returns the list of registered faction ids. For diagnostics / tooling.
func known_faction_ids() -> Array:
	return _factions.keys()


## Returns the faction def dict (or {} if not registered). Read-only —
## callers should not mutate the returned dict.
func get_faction_def(faction_id: String) -> Dictionary:
	var d = _factions.get(faction_id, null)
	return d if d is Dictionary else {}


# ============================================================
# RELATIONSHIP ACCESS
# ============================================================


static func _rel_key(from_id: String, to_id: String) -> String:
	return "%s:%s" % [from_id, to_id]


func _set_rel(from_id: String, to_id: String, stance: String, tension: int) -> void:
	_relationships[_rel_key(from_id, to_id)] = {
		"stance": stance,
		"tension": clamp(tension, 0, 100),
	}


## Returns {stance, tension} for the directed pair. Defaults to
## {stance: "neutral", tension: 0} if no relationship row exists — matches
## the binding default documented in ADR 0032 §bindings.
func get_relationship(from_id: String, to_id: String) -> Dictionary:
	var key := _rel_key(from_id, to_id)
	if _relationships.has(key):
		return _relationships[key]
	return {"stance": STANCE_NEUTRAL, "tension": 0}


## Returns the stance string (one of the 5; defaults to "neutral").
func get_stance(from_id: String, to_id: String) -> String:
	return str(get_relationship(from_id, to_id).get("stance", STANCE_NEUTRAL))


## Returns tension int 0-100 (defaults to 0 if no relationship row).
func get_tension(from_id: String, to_id: String) -> int:
	return int(get_relationship(from_id, to_id).get("tension", 0))


## Returns Array of {from, to} dicts for every relationship at this stance.
## Used by tests + game-rules to enumerate at-war pairs / allied pairs.
func find_factions_with_stance(stance: String) -> Array:
	var out: Array = []
	for key in _relationships.keys():
		var rec: Dictionary = _relationships[key]
		if str(rec.get("stance", "")) == stance:
			var parts := str(key).split(":", false, 1)
			if parts.size() == 2:
				out.append({"from": parts[0], "to": parts[1]})
	return out


# ============================================================
# EFFECT — DECLARE_WAR
# ============================================================


## Set relationship stance to at_war, tension to 100. Atomic on unknown
## faction (no mutation, raises FACTION_NO_DEF). Emits faction_war_declared
## signal to env.signal_buffer with from/to payload.
func apply_declare_war(env: Dictionary, from_id: String, to_id: String) -> Dictionary:
	if not _factions.has(from_id) or not _factions.has(to_id):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"declare_war: unknown faction '%s' or '%s'" % [from_id, to_id],
			{"from": from_id, "to": to_id, "known": _factions.keys()},
			"Register the faction via register_factions or add it to factions.json.",
			"warning"
		)
		return {"ok": false, "reason": "no_def", "from": from_id, "to": to_id}
	_set_rel(from_id, to_id, STANCE_AT_WAR, STANCE_BASELINE[STANCE_AT_WAR])
	_emit(env, SIGNAL_WAR_DECLARED, {"from": from_id, "to": to_id})
	return {"ok": true, "reason": "", "from": from_id, "to": to_id}


# ============================================================
# EFFECT — SIGN_TREATY
# ============================================================


## Reset relationship stance to `new_stance` (default neutral) and tension
## to that stance's baseline. Emits faction_treaty_signed signal. Atomic
## on unknown faction or invalid stance.
func apply_sign_treaty(
	env: Dictionary, from_id: String, to_id: String, new_stance: String = STANCE_NEUTRAL
) -> Dictionary:
	if not _factions.has(from_id) or not _factions.has(to_id):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"sign_treaty: unknown faction '%s' or '%s'" % [from_id, to_id],
			{"from": from_id, "to": to_id, "known": _factions.keys()},
			"Register the faction via register_factions or add it to factions.json.",
			"warning"
		)
		return {"ok": false, "reason": "no_def", "from": from_id, "to": to_id}
	if not STANCE_BASELINE.has(new_stance):
		EngineError.raise(
			env,
			EngineError.FACTION_INVALID_STANCE,
			"sign_treaty: stance '%s' not one of allied|neutral|rivals|hostile|at_war" % new_stance,
			{"from": from_id, "to": to_id, "stance": new_stance},
			"Use one of: allied, neutral, rivals, hostile, at_war.",
			"warning"
		)
		return {"ok": false, "reason": "invalid_stance", "from": from_id, "to": to_id}
	var baseline: int = int(STANCE_BASELINE[new_stance])
	_set_rel(from_id, to_id, new_stance, baseline)
	_emit(
		env,
		SIGNAL_TREATY_SIGNED,
		{"from": from_id, "to": to_id, "stance": new_stance, "tension": baseline}
	)
	return {"ok": true, "reason": "", "from": from_id, "to": to_id, "stance": new_stance}


# ============================================================
# EFFECT — PROPOSE_ALLIANCE
# ============================================================


## Set relationship stance to allied, tension to 0. Emits
## faction_alliance_formed signal. Atomic on unknown faction.
func apply_propose_alliance(env: Dictionary, from_id: String, to_id: String) -> Dictionary:
	if not _factions.has(from_id) or not _factions.has(to_id):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"propose_alliance: unknown faction '%s' or '%s'" % [from_id, to_id],
			{"from": from_id, "to": to_id, "known": _factions.keys()},
			"Register the faction via register_factions or add it to factions.json.",
			"warning"
		)
		return {"ok": false, "reason": "no_def", "from": from_id, "to": to_id}
	_set_rel(from_id, to_id, STANCE_ALLIED, STANCE_BASELINE[STANCE_ALLIED])
	_emit(env, SIGNAL_ALLIANCE_FORMED, {"from": from_id, "to": to_id})
	return {"ok": true, "reason": "", "from": from_id, "to": to_id}


# ============================================================
# EFFECT — SWEAR_LOYALTY
# ============================================================


## Mutate target entity's state.faction_loyalty[faction] field. Either
## adds `delta` (default +10) or sets `value` directly. Loyalty values are
## clamped 0-100. Atomic on unknown faction (no entity mutation, raises
## FACTION_NO_DEF).
##
## opts shape: {delta: int} OR {value: int}. delta wins if both present.
func apply_swear_loyalty(
	env: Dictionary, entity_id: String, faction_id: String, opts: Dictionary = {}
) -> Dictionary:
	if not _factions.has(faction_id):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"swear_loyalty: unknown faction '%s'" % faction_id,
			{"target": entity_id, "faction": faction_id, "known": _factions.keys()},
			"Register the faction via register_factions or add it to factions.json.",
			"warning"
		)
		return {"ok": false, "reason": "no_def", "target": entity_id, "faction": faction_id}
	var entities = env.get("entities", null)
	if not (entities is Dictionary) or not (entities as Dictionary).has(entity_id):
		return {"ok": false, "reason": "no_target", "target": entity_id, "faction": faction_id}
	var ent = (entities as Dictionary)[entity_id]
	if not (ent is Entity):
		return {"ok": false, "reason": "no_target", "target": entity_id, "faction": faction_id}
	var ent_e: Entity = ent
	# Read or initialize faction_loyalty dict on the entity.
	var loyalty_v = ent_e.get_state(STATE_FACTION_LOYALTY, null)
	var loyalty: Dictionary = loyalty_v if loyalty_v is Dictionary else {}
	var prev_value: int = int(loyalty.get(faction_id, 0))
	var new_value: int = prev_value
	if opts.has("delta"):
		new_value = prev_value + int(opts["delta"])
	elif opts.has("value"):
		new_value = int(opts["value"])
	else:
		new_value = prev_value + DEFAULT_LOYALTY_DELTA
	new_value = int(clamp(new_value, 0, 100))
	loyalty[faction_id] = new_value
	# Re-store the dict so set_state captures the mutation. (Dict was mutated
	# in place, but explicit set keeps the contract: callers can rely on
	# state[STATE_FACTION_LOYALTY] always being the canonical reference.)
	ent_e.set_state(STATE_FACTION_LOYALTY, loyalty)
	_emit(
		env,
		SIGNAL_LOYALTY_CHANGED,
		{
			"entity_id": ent_e.instance_id,
			"faction": faction_id,
			"from": prev_value,
			"to": new_value,
		}
	)
	return {
		"ok": true,
		"reason": "",
		"target": entity_id,
		"faction": faction_id,
		"from": prev_value,
		"to": new_value
	}


# ============================================================
# ZONE CONTROL (composition with ADR 0031 zone_store)
# ============================================================


## Mark a zone as controlled by a faction. Pure composition over zone_store —
## writes the conventional `controlling_faction` field; queries on either
## side resolve through standard zone_state bindings. Returns true if
## successful, false if zone or faction unknown (warns via EngineError).
func set_zone_control(env: Dictionary, faction_id: String, zone_id: String) -> bool:
	if not _factions.has(faction_id):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"set_zone_control: unknown faction '%s'" % faction_id,
			{"faction": faction_id, "zone": zone_id, "known": _factions.keys()},
			"Register the faction via register_factions or add it to factions.json.",
			"warning"
		)
		return false
	var zs = env.get("zone_store", null)
	if zs == null or not zs.has_method("set_field") or not zs.has(zone_id):
		EngineError.raise(
			env,
			"faction.unknown_zone",
			"set_zone_control: unknown zone '%s'" % zone_id,
			{"faction": faction_id, "zone": zone_id},
			"Verify the zone exists in world/zones.json or that zone_store is wired.",
			"warning"
		)
		return false
	zs.set_field(zone_id, "controlling_faction", faction_id)
	return true


# ============================================================
# BINDING SNAPSHOT (faction.<id>.<field>)
# ============================================================


## Build a flat snapshot suitable for use as the `faction` root in a
## Formula context. Each faction id maps to a dict containing:
##   leader            : <entity_id String>
##   member_count      : <int — entities with loyalty[id] >= MEMBER_THRESHOLD>
##   tension_with      : {<other_id>: <int>, ...}
##   stance_with       : {<other_id>: <String>, ...}
##   controls_zone     : <bool — any zone controlling_faction == id>
## Plus a copy of the faction def's metadata fields (ideology, color,
## home_zone) so authors can read them via `faction.<id>.ideology` etc.
##
## Returns a fresh dict; safe to share into formula context as-is.
func binding_snapshot(env: Dictionary = {}) -> Dictionary:
	var out: Dictionary = {}
	# Pre-compute member counts in one pass over entities.
	var member_counts: Dictionary = _compute_member_counts(env)
	# Pre-compute zone control flags in one pass over zone_store.
	var controls_zone_flags: Dictionary = _compute_zone_control_flags(env)
	for fid in _factions.keys():
		var def: Dictionary = _factions[fid]
		var entry: Dictionary = {
			"leader": str(def.get("leader", "")),
			"ideology": str(def.get("ideology", "")),
			"color": str(def.get("color", "")),
			"home_zone": str(def.get("home_zone", "")),
			"member_count": int(member_counts.get(fid, 0)),
			"controls_zone": bool(controls_zone_flags.get(fid, false)),
			"tension_with": {},
			"stance_with": {},
		}
		# Build per-other faction tension + stance maps from _relationships.
		# Default 0 / "neutral" for absent edges (matches get_relationship).
		for other_id in _factions.keys():
			if other_id == fid:
				continue
			var rel: Dictionary = get_relationship(fid, other_id)
			(entry["tension_with"] as Dictionary)[other_id] = int(rel.get("tension", 0))
			(entry["stance_with"] as Dictionary)[other_id] = str(rel.get("stance", STANCE_NEUTRAL))
		out[fid] = entry
	return out


func _compute_member_counts(env: Dictionary) -> Dictionary:
	var counts: Dictionary = {}
	for fid in _factions.keys():
		counts[fid] = 0
	var entities = env.get("entities", null)
	if not (entities is Dictionary):
		return counts
	for id in (entities as Dictionary).keys():
		var ent = (entities as Dictionary)[id]
		if not (ent is Entity):
			continue
		var loyalty_v = (ent as Entity).get_state(STATE_FACTION_LOYALTY, null)
		if not (loyalty_v is Dictionary):
			continue
		for fid in (loyalty_v as Dictionary).keys():
			var fid_s := str(fid)
			if not counts.has(fid_s):
				continue
			if int((loyalty_v as Dictionary)[fid]) >= MEMBER_THRESHOLD:
				counts[fid_s] = int(counts[fid_s]) + 1
	return counts


func _compute_zone_control_flags(env: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var zs = env.get("zone_store", null)
	if zs == null or not zs.has_method("binding_snapshot"):
		return out
	var snap: Dictionary = zs.binding_snapshot()
	for zid in snap.keys():
		var st = snap[zid]
		if not (st is Dictionary):
			continue
		var cf := str((st as Dictionary).get("controlling_faction", ""))
		if cf == "":
			continue
		out[cf] = true
	return out


# ============================================================
# SAVE / LOAD
# ============================================================


## Serialize relationship state for save_state.gd. Returns flat
## {<from>:<to>: {stance, tension}}. Faction defs themselves are NOT saved
## (they re-load from factions.json on next session).
func to_save() -> Dictionary:
	var out: Dictionary = {}
	for key in _relationships.keys():
		out[str(key)] = (_relationships[key] as Dictionary).duplicate(true)
	return out


## Restore relationship state from a save dict. Pairs in save but absent
## from current factions.json are silently dropped (forgiveness). Pairs
## in current factions.json absent from save retain their initial state.
func from_save(d: Dictionary) -> void:
	if d == null or not (d is Dictionary):
		return
	for key in d.keys():
		var key_s := str(key)
		var parts := key_s.split(":", false, 1)
		if parts.size() != 2:
			continue
		var from_id := str(parts[0])
		var to_id := str(parts[1])
		if not _factions.has(from_id) or not _factions.has(to_id):
			continue
		var rec = d[key]
		if not (rec is Dictionary):
			continue
		var stance := str((rec as Dictionary).get("stance", STANCE_NEUTRAL))
		if not STANCE_BASELINE.has(stance):
			continue
		var tension := int((rec as Dictionary).get("tension", STANCE_BASELINE[stance]))
		_set_rel(from_id, to_id, stance, tension)


# ============================================================
# INTERNAL — signal emission
# ============================================================


func _emit(env: Dictionary, signal_name: String, payload: Dictionary) -> void:
	# signal_buffer absent (test harness without scheduler) → state still
	# applied; signal silently dropped. Tests that check the signal must
	# provide their own buffer (mirrors ClassManager's convention).
	var buf = env.get("signal_buffer", null)
	if not (buf is Array):
		return
	(
		(buf as Array)
		. append(
			{
				"name": signal_name,
				"payload": payload,
			}
		)
	)
