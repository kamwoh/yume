extends Node
class_name DynastyDirector

## ADR 0034 — Dynasty / heir succession primitive.
##
## Composes existing engine primitives — multi-actor framework (ADR 0016),
## tech-tree filter (ADR 0033), and lifecycle/death signal (ADR 0036) —
## into a coherent succession layer. Owns the four new transfer effects
## (transfer_inventory / transfer_reputation / transfer_techs /
## transition_player_to) and the heir-resolution / extinct-fallback
## helpers used by content rules.
##
## Per ADR 0021 this module EXPOSES the existing per-entity state stores
## under generic store-mover effects. NOT semantic verbs like
## "inherit_kingdom" — each effect is "move sub-store of kind X from
## entity A to entity B." A factory game (parent factory → spawned
## subsidiary) or a roguelike NG+ uses the same effects with different
## inheritance policies.
##
## Wiring: DynastyDirector expects to be a child of a Node whose script
## is `World`. Sibling of GameShell + ScreenFlow + LightingDirector +
## ScheduleDirector + LifecycleDirector + ClassManager + FactionDirector
## + TechTreeDirector + PartyDirector. No per-tick work — succession is
## fired on the entity_died signal by per-game rules; the director just
## hosts the effect implementations and the orchestration helper.
##
## Lifecycle:
## 1. Boot: nothing to load — director is purely effect-driven.
## 2. Effect dispatch: effect_apply.gd's four new arms locate this node
##    via env.parent.get_node_or_null("DynastyDirector") and call the
##    transfer methods.
## 3. Tests: instantiate directly, call transfer_inventory + ...
##
## Backward-compat: games WITHOUT heirs/dynasty_id state never trigger
## the director. The four effects are a no-op when source/heir entities
## are missing or have empty stores.
##
## Cross-ADR dependencies:
## - ADR 0016 multi-actor — transition_player_to delegates to ActorManager.set_active
## - ADR 0033 tech-tree   — transfer_techs delegates to TechTreeDirector.inherit_to
## - ADR 0036 lifecycle   — entity_died signal triggers per-game succession rules
## - ADR 0030 class       — class_progress NOT transferred (heir starts fresh)
## - ADR 0010 save/load   — heir state persists via normal entity serialization

# ============================================================
# CONSTANTS
# ============================================================

const SIGNAL_DYNASTY_SUCCEEDED: String = "dynasty_succeeded"
const SIGNAL_DYNASTY_EXTINCT: String = "dynasty_extinct"

const STATE_INVENTORY: String = "inventory"
const STATE_REPUTATION: String = "reputation"
const STATE_KNOWN_TECHS: String = "known_techs"
const STATE_HEIRS: String = "heirs"
const STATE_LIFE_STAGE: String = "life_stage"
const STATE_INHERITANCE_POLICY: String = "inheritance_policy"

const TERMINAL_LIFE_STAGE: String = "dead"

const FILTER_CORE_ONLY: String = "core_only"
const FILTER_ALL: String = "all"

# ============================================================
# STATE
# ============================================================

var _world: Node = null

# ============================================================
# LIFECYCLE
# ============================================================


func _ready() -> void:
	_world = get_parent()
	# No World parent → silently no-op (lets test harnesses include the
	# node without crashing). Tests instantiate the director directly and
	# call the transfer methods without a SceneTree.
	if _world == null or not _world.has_method("_build_env"):
		return


# ============================================================
# TRANSFER: INVENTORY
# ============================================================


## Move source.state.inventory → heir.state.inventory.
## Append-then-clear-source semantics: heir's existing inventory is
## preserved; source items append to the end; source's inventory is
## cleared after the copy. Items keep their state (durability,
## contents, etc.) — they're moved by reference (live dicts/strings).
##
## Returns the count of items transferred. 0 = no-op (source missing,
## heir missing, or source had no inventory).
func transfer_inventory(env: Dictionary, source_id: String, heir_id: String) -> int:
	var source := _resolve_entity(env, source_id)
	var heir := _resolve_entity(env, heir_id)
	if source == null or heir == null:
		return 0
	var src_inv = source.get_state(STATE_INVENTORY, null)
	if not (src_inv is Array) or (src_inv as Array).is_empty():
		return 0
	var heir_inv = heir.get_state(STATE_INVENTORY, null)
	if not (heir_inv is Array):
		heir_inv = []
	var transferred: int = 0
	for item in src_inv as Array:
		(heir_inv as Array).append(item)
		transferred += 1
	heir.set_state(STATE_INVENTORY, heir_inv)
	# Clear source's inventory (atomic — source no longer has the items
	# the heir just received).
	source.set_state(STATE_INVENTORY, [])
	return transferred


# ============================================================
# TRANSFER: REPUTATION
# ============================================================


## Move source.state.reputation → heir.state.reputation. Replace-merge
## with max() for overlapping faction keys: if both source and heir
## have reputation with faction X, heir's post-transfer rep is
## max(source_rep, heir_rep).
##
## Returns the count of factions whose heir reputation was updated
## (set or raised). 0 = no-op (source missing, heir missing, or
## source had no reputation).
##
## The source's reputation is cleared after transfer (atomic — source
## entity is dying, its reputation no longer accrues to it).
func transfer_reputation(env: Dictionary, source_id: String, heir_id: String) -> int:
	var source := _resolve_entity(env, source_id)
	var heir := _resolve_entity(env, heir_id)
	if source == null or heir == null:
		return 0
	var src_rep = source.get_state(STATE_REPUTATION, null)
	if not (src_rep is Dictionary) or (src_rep as Dictionary).is_empty():
		return 0
	var heir_rep = heir.get_state(STATE_REPUTATION, null)
	if not (heir_rep is Dictionary):
		heir_rep = {}
	var updated: int = 0
	for faction_key in (src_rep as Dictionary).keys():
		var src_value: float = float((src_rep as Dictionary)[faction_key])
		var existing = (heir_rep as Dictionary).get(faction_key, null)
		if existing == null:
			(heir_rep as Dictionary)[faction_key] = src_value
			updated += 1
		else:
			var existing_value: float = float(existing)
			var max_value: float = max(src_value, existing_value)
			if max_value != existing_value:
				(heir_rep as Dictionary)[faction_key] = max_value
				updated += 1
	heir.set_state(STATE_REPUTATION, heir_rep)
	# Clear source — atomic ownership transfer.
	source.set_state(STATE_REPUTATION, {})
	return updated


# ============================================================
# TRANSFER: TECHS
# ============================================================


## Move filtered subset of source.state.known_techs → heir.state.known_techs.
##
## Two filter modes:
## - "core_only" (default): delegates to TechTreeDirector.inherit_to so
##   the `core` flag on each tech node is consulted.
## - "all": every node from source.known_techs copied to heir
##   (heir.known_techs unionized; duplicates skipped).
##
## When TechTreeDirector is unmounted (test harnesses without a
## SceneTree, OR demos that ship no tech_trees.json), the director
## falls back to a duplicated implementation: filter="all" copies
## every node; filter="core_only" copies nothing (no tree definitions
## to consult, so no node is known to be core).
##
## The source's known_techs is preserved (NOT cleared) — techs are
## knowledge, not items. The dying parent "remembers" what they knew
## even as they pass it on; this matches ADR 0033's append-only
## known_techs convention. (Class progress is the field that resets
## on succession; techs are civilization-scale knowledge that survive.)
##
## Returns the array of node ids actually transferred (heir's pre-
## existing techs are skipped).
func transfer_techs(
	env: Dictionary, source_id: String, heir_id: String, filter: String = FILTER_CORE_ONLY
) -> Array:
	var source := _resolve_entity(env, source_id)
	var heir := _resolve_entity(env, heir_id)
	if source == null or heir == null:
		return []
	# Prefer TechTreeDirector for core-flag-aware inheritance (ADR 0033 §7).
	var ttd: Node = null
	if _world != null:
		ttd = _world.get_node_or_null("TechTreeDirector")
	if ttd != null and ttd.has_method("inherit_to"):
		return ttd.call("inherit_to", env, source_id, heir_id, filter)
	# Fallback: no director mounted. With "core_only" we have no tree
	# data to consult, so no node is known-core — transfer nothing
	# (matches ADR 0010 §9 fail-soft policy). With "all" we copy every
	# node verbatim.
	if filter == FILTER_CORE_ONLY:
		return []
	var src_known = source.get_state(STATE_KNOWN_TECHS, null)
	if not (src_known is Array):
		return []
	var heir_known = heir.get_state(STATE_KNOWN_TECHS, null)
	if not (heir_known is Array):
		heir_known = []
	var transferred: Array = []
	for nid_v in src_known as Array:
		var nid: String = str(nid_v)
		if (heir_known as Array).has(nid):
			continue
		(heir_known as Array).append(nid)
		transferred.append(nid)
	heir.set_state(STATE_KNOWN_TECHS, heir_known)
	return transferred


# ============================================================
# TRANSITION PLAYER
# ============================================================


## Hand input + camera control to a new actor. Looks up ActorManager
## via env.parent ("World"); when present, delegates to set_active
## for the proper deferred swap. When absent (test harnesses without
## a SceneTree), falls back to setting state.is_player on the new
## entity so content rules with `state: {is_player_eq: 1}` filters
## continue to work.
##
## new_actor_id can be either an ActorManager actor_id (e.g.
## "default_player") OR an entity instance_id — ActorManager.set_active
## is tried first; if that rejects (unknown actor_id), we treat the
## value as an entity_id and set state.is_player=1 on it.
##
## Returns true on successful swap; false on no-op.
func transition_player_to(env: Dictionary, new_actor_id: String) -> bool:
	if new_actor_id == "":
		return false
	# Path 1: ActorManager-aware swap. World holds the manager; a
	# successful set_active updates active_actor_id and sets the
	# binding world_state.active_actor_id (caller usually mirrors
	# this via ActorManager.process_pending).
	var am = null
	if _world != null and "actor_manager" in _world:
		am = _world.actor_manager
	if am != null and am.has_method("set_active"):
		if am.call("set_active", new_actor_id):
			# Mirror into world_state so binding readers (camera follow,
			# HUD) see the new actor immediately. Matches the post-swap
			# bookkeeping in ActorManager.process_pending.
			var world_dict = env.get("world", null)
			if world_dict is Dictionary:
				(world_dict as Dictionary)["active_actor_id"] = new_actor_id
			return true
	# Path 2: fallback. Treat new_actor_id as an entity_id and set
	# state.is_player=1 on it. Tests use this path so they can verify
	# the swap succeeded without mounting a full ActorManager.
	var ent := _resolve_entity(env, new_actor_id)
	if ent == null:
		return false
	ent.set_state("is_player", 1)
	return true


# ============================================================
# HEIR RESOLUTION
# ============================================================


## Walk source.state.heirs in priority order; return the first id
## that exists in env.entities AND is not in the terminal life_stage
## ("dead"). Returns "" if no eligible heir.
##
## ADR 0034 §"Multi-heir branching": ordered first-wins selection —
## eldest takes over by default, but if they died in combat,
## second-born inherits. Tests use this to verify branching logic.
func resolve_first_eligible_heir(env: Dictionary, source_id: String) -> String:
	var source := _resolve_entity(env, source_id)
	if source == null:
		return ""
	var heirs = source.get_state(STATE_HEIRS, null)
	if not (heirs is Array):
		return ""
	var entities = env.get("entities", null)
	if not (entities is Dictionary):
		return ""
	for heir_id_v in heirs as Array:
		var hid: String = str(heir_id_v)
		if hid == "":
			continue
		if not (entities as Dictionary).has(hid):
			continue
		var heir = (entities as Dictionary)[hid]
		if not (heir is Entity):
			continue
		var stage: String = str((heir as Entity).get_state(STATE_LIFE_STAGE, ""))
		if stage == TERMINAL_LIFE_STAGE:
			continue
		return hid
	return ""


# ============================================================
# ATOMIC SUCCESSION CHAIN
# ============================================================


## Run a complete succession chain in one atomic block. Picks first
## eligible heir from heirs_list (or source.state.heirs if heirs_list
## is empty), calls all configured transfers, swaps the active actor,
## emits dynasty_succeeded. If no eligible heir exists, emits
## dynasty_extinct and returns a no-op result.
##
## Atomic: all transfers happen inside this single call. Save/load
## cannot capture mid-transition state because each transfer runs to
## completion before the surrounding effect chain commits (ADR 0009
## freeze-policy + Invariant #9).
##
## Returns a result dict:
##   {ok: bool, heir_id: String, transferred: {inventory, reputation,
##    techs}, reason: "" | "extinct" | "no_source"}
##
## Reads heir's state.inheritance_policy to filter transfers. Default
## policy when absent: {inventory: "all", reputation: "all",
## core_techs: true, class_progress: false, relationships: "family"}.
func handle_dynasty_succession(
	env: Dictionary, dying_entity_id: String, heirs_list: Array = []
) -> Dictionary:
	var source := _resolve_entity(env, dying_entity_id)
	if source == null:
		return {"ok": false, "reason": "no_source", "heir_id": ""}
	# Pick eligible heir from explicit list OR source.state.heirs.
	var heir_id: String = ""
	if not heirs_list.is_empty():
		var entities = env.get("entities", null)
		if entities is Dictionary:
			for h_v in heirs_list:
				var hid: String = str(h_v)
				if hid == "" or not (entities as Dictionary).has(hid):
					continue
				var ent = (entities as Dictionary)[hid]
				if not (ent is Entity):
					continue
				var stage: String = str((ent as Entity).get_state(STATE_LIFE_STAGE, ""))
				if stage == TERMINAL_LIFE_STAGE:
					continue
				heir_id = hid
				break
	else:
		heir_id = resolve_first_eligible_heir(env, dying_entity_id)
	# No eligible heir — emit extinct and return.
	if heir_id == "":
		_emit_signal(
			env,
			SIGNAL_DYNASTY_EXTINCT,
			{
				"deceased": dying_entity_id,
			}
		)
		return {"ok": false, "reason": "extinct", "heir_id": ""}
	# Read heir's inheritance policy (default: full inheritance minus
	# class_progress).
	var heir := _resolve_entity(env, heir_id)
	var policy: Dictionary = _resolve_inheritance_policy(heir)
	# Run transfers per policy. Each transfer is idempotent on no-op
	# input; partial state is impossible because each runs to
	# completion before the next starts.
	var inv_count: int = 0
	var rep_count: int = 0
	var tech_list: Array = []
	if str(policy.get("inventory", "all")) != "none":
		inv_count = transfer_inventory(env, dying_entity_id, heir_id)
	if str(policy.get("reputation", "all")) != "none":
		rep_count = transfer_reputation(env, dying_entity_id, heir_id)
	if bool(policy.get("core_techs", true)):
		tech_list = transfer_techs(env, dying_entity_id, heir_id, FILTER_CORE_ONLY)
	# Class progress NOT transferred — per ADR 0034 "every generation
	# rediscovers their own path." Heir's class_progress stays empty
	# (or whatever it was initialized to).
	# Hand control to the heir.
	transition_player_to(env, heir_id)
	# Emit succeeded signal so downstream content rules (story beats,
	# audio stings, juice profiles) can react.
	_emit_signal(
		env,
		SIGNAL_DYNASTY_SUCCEEDED,
		{
			"deceased": dying_entity_id,
			"successor": heir_id,
			"transferred_inventory_count": inv_count,
			"transferred_reputation_count": rep_count,
			"transferred_techs": tech_list,
		}
	)
	return {
		"ok": true,
		"reason": "",
		"heir_id": heir_id,
		"transferred":
		{
			"inventory": inv_count,
			"reputation": rep_count,
			"techs": tech_list,
		},
	}


# ============================================================
# INTERNAL HELPERS
# ============================================================


static func _resolve_entity(env: Dictionary, entity_id: String) -> Entity:
	if entity_id == "":
		return null
	var entities = env.get("entities", null)
	if not (entities is Dictionary):
		return null
	if not (entities as Dictionary).has(entity_id):
		return null
	var ent = (entities as Dictionary)[entity_id]
	return ent if ent is Entity else null


static func _resolve_inheritance_policy(heir: Entity) -> Dictionary:
	var default_policy: Dictionary = {
		"inventory": "all",
		"reputation": "all",
		"core_techs": true,
		"class_progress": false,
		"relationships": "family",
	}
	if heir == null:
		return default_policy
	var policy = heir.get_state(STATE_INHERITANCE_POLICY, null)
	if not (policy is Dictionary):
		return default_policy
	# Merge (heir overrides default fields). This makes a partial
	# policy declaration legal — heir can declare just one field
	# and inherit defaults for the rest.
	var merged: Dictionary = default_policy.duplicate(true)
	for k in (policy as Dictionary).keys():
		merged[k] = (policy as Dictionary)[k]
	return merged


static func _emit_signal(env: Dictionary, name: String, payload: Dictionary) -> void:
	var buf = env.get("signal_buffer", null)
	if buf is Array:
		(buf as Array).append({"name": name, "payload": payload})
	# else: signal_buffer absent (test harness without scheduler) —
	# state mutations still applied; signal silently dropped. Tests that
	# check the signal must provide their own buffer.
