extends Node
class_name PartyDirector

## ADR 0026 — Party-member primitive (leashed NPCs that fight + KO).
##
## Reads entities tagged `party_member` and their `party_member_of`
## relation to find their leader (typically the player). Each frame:
##   - Computes a fan-out target position behind the leader based on
##     `state.party_index` (0..N).
##   - Smooth-lerps the member's `state.position` toward that target.
##   - Snaps KO'd members directly onto the leader so they "lie next
##     to" instead of standing in formation.
##
## Drains `env.signal_buffer` for `party_revival` signals and resets
## `state.ko` + `state.hp` on every party member when one arrives.
##
## Per ADR 0021, this module EXPOSES the existing relation + tag +
## state primitives — it does NOT introduce new vocabulary beyond
## what ADR 0026 documents (the `party_member` tag, the
## `party_member_of` relation type convention, and the `party_join`
## / `party_leave` / `party_ko` effects implemented in EffectApply).
##
## Wiring: PartyDirector expects to be a child of a Node whose script
## is `World`. Sibling of GameShell + ScreenFlow + LightingDirector.
##
## Lifecycle:
## 1. Boot: nothing to load — director is purely state-driven.
## 2. Per-frame: resolve env via parent.scheduler.env, run leash +
##    revival update.


# ============================================================
# CONSTANTS
# ============================================================

# Fan-out offset table — applied in the leader's local frame on the
# XZ plane (Y matches leader). Index 0/1/2 cover the 2-3 companion
# party-cap stated in the merchant GDD; indices ≥3 fall back to
# the last entry to avoid array OOB.
#
# Static var (not const) because Godot 4.x can't fold Vector3()
# constructor calls into `const` expressions — `static var` is the
# closest equivalent for class-level immutable tables. Same pattern
# used by Pathfinding for non-scalar defaults.
static var OFFSET_TABLE: Array = [
	Vector3(-1.0, 0.0, 1.5),    # index 0 — back-left
	Vector3( 1.0, 0.0, 1.5),    # index 1 — back-right
	Vector3( 0.0, 0.0, 2.5),    # index 2 — directly behind, deeper
]

# Per-frame lerp factor (0 = no movement, 1 = snap). Tuned for a
# "guard-following-the-king" feel: noticeable lag, but never lost.
const LEASH_LERP_RATE: float = 0.18

# Distance beyond which the director snaps instead of lerps. Prevents
# companions getting permanently stranded if the leader teleports
# (level transition, save/load, scene change).
const SNAP_DISTANCE: float = 12.0

const RELATION_TYPE: String = "party_member_of"
const PARTY_TAG: String = "party_member"


# ============================================================
# STATE
# ============================================================

var _world: Node = null


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	_world = get_parent()
	if _world == null or not _world.has_method("_build_env"):
		# No World parent — silently no-op (lets test harnesses include
		# the node without crashing).
		return


func _process(_delta: float) -> void:
	if _world == null: return
	var sched = _world.get("scheduler")
	if sched == null: return     # env not built yet
	var env: Dictionary = sched.env
	_drain_revival_signals(env)
	_apply_leashing(env)


# ============================================================
# REVIVAL — drain party_revival signals
# ============================================================

## Scan env.signal_buffer for any signal named "party_revival".
## For each one found: revive ALL party_member-tagged entities (clear
## ko, restore hp from properties.hp_max or state.hp_max).
##
## We DON'T pop the signals — phase_scheduler owns drain ordering.
## Listening here is read-only; double-revival is safe (idempotent).
func _drain_revival_signals(env: Dictionary) -> void:
	var buf = env.get("signal_buffer", null)
	if not (buf is Array): return
	var saw_revival: bool = false
	for sig in (buf as Array):
		if sig is Dictionary and str((sig as Dictionary).get("name", "")) == "party_revival":
			saw_revival = true
			break
	if not saw_revival: return
	revive_all(env)


## Public so tests + future content can invoke directly.
## Resets ko=0 + hp=hp_max on every party_member entity.
func revive_all(env: Dictionary) -> void:
	var entities: Dictionary = env.get("entities", {})
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		if not (ent as Entity).has_tag(PARTY_TAG): continue
		_revive_one(ent as Entity)


static func _revive_one(ent: Entity) -> void:
	ent.set_state("ko", 0)
	# Pick hp_max from state first (mutable), then properties (initial).
	var hp_max = ent.get_state("hp_max", null)
	if hp_max == null:
		hp_max = ent.get_property("hp_max", null)
	if hp_max != null:
		ent.set_state("hp", float(hp_max))


# ============================================================
# LEASHING — pull each party member toward their offset slot
# ============================================================

func _apply_leashing(env: Dictionary) -> void:
	var entities: Dictionary = env.get("entities", {})
	var relations = env.get("relations", null)
	if relations == null: return
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		var member: Entity = ent as Entity
		if not member.has_tag(PARTY_TAG): continue
		var leader: Entity = _resolve_leader(member, entities, relations)
		if leader == null: continue
		_apply_leash_to_member(member, leader)


## Resolve the leader entity for a party member. The convention is
## one-edge-per-member: a single `party_member_of` outgoing relation
## from the member to the leader. Multi-leader topologies are out
## of scope per ADR 0026.
static func _resolve_leader(member: Entity, entities: Dictionary, relations) -> Entity:
	if relations == null: return null
	var leaders: Array = relations.targets(RELATION_TYPE, member.instance_id)
	if leaders.size() != 1: return null
	var leader_id: String = str(leaders[0])
	if not entities.has(leader_id): return null
	var leader = entities[leader_id]
	return leader if leader is Entity else null


## Apply per-frame leash motion. KO'd members snap directly onto
## the leader; alive members lerp toward their offset slot.
func _apply_leash_to_member(member: Entity, leader: Entity) -> void:
	var leader_pos: Vector3 = _to_vec3(leader.get_position())
	var ko: int = int(member.get_state("ko", 0))
	if ko == 1:
		# KO'd: snap to leader. No offset (companions lie at leader's feet).
		member.set_position(leader_pos)
		member.set_velocity(Vector3.ZERO)
		return
	var idx: int = int(member.get_state("party_index", -1))
	if idx < 0: return  # member not yet assigned a slot — skip until party_join sets it
	var offset: Vector3 = offset_for_index(idx)
	var target: Vector3 = leader_pos + offset
	var current: Vector3 = _to_vec3(member.get_position())
	var moved: Vector3
	if current.distance_to(target) > SNAP_DISTANCE:
		moved = target  # leader teleported (level transition / load) — snap
	else:
		moved = current.lerp(target, LEASH_LERP_RATE)
	member.set_position(moved)


# ============================================================
# STATIC HELPERS (testable without a SceneTree)
# ============================================================

## Returns the offset vector for the given party-index slot. Indices
## beyond the table fall back to the last entry, ensuring large
## parties don't crash (they just bunch up at the deepest slot).
static func offset_for_index(idx: int) -> Vector3:
	if idx < 0: return Vector3.ZERO
	if idx >= OFFSET_TABLE.size():
		return OFFSET_TABLE[OFFSET_TABLE.size() - 1]
	return OFFSET_TABLE[idx]


## Compute target position for a member at index `idx` whose leader
## is at `leader_pos`. Pure-function helper used by tests.
static func target_position_for(leader_pos: Vector3, idx: int) -> Vector3:
	return leader_pos + offset_for_index(idx)


## Coerce a Vector2/Vector3/Array into Vector3. Vector2 is treated as
## XZ (y=0) — matches Yume's renderer convention from ADR 0004.
static func _to_vec3(v) -> Vector3:
	if v is Vector3: return v
	if v is Vector2: return Vector3(v.x, 0, v.y)
	if v is Array:
		var a: Array = v
		if a.size() == 3: return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2: return Vector3(float(a[0]), 0, float(a[1]))
	return Vector3.ZERO
