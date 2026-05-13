extends Object
class_name EffectActor

## Actor-control + party effect handlers.
##
##   - switch_actor — change which actor receives input (ADR 0016)
##   - queue_input_for_actor — synthesize an input event for any actor
##   - reset_world — reload current level + reset persistent state
##   - party_join / party_leave / party_ko — ADR 0026 party-member
##     primitive (leashed NPCs that fight + KO)
##
## All static. Resolution helpers live in EffectResolution.

# ============================================================
# MULTI-ACTOR EFFECTS (ADR 0016)
# ============================================================


## Switch the active actor. DEFERRED — takes effect at next tick boundary
## (per TD condition #3). Subsequent rules in the SAME tick still see the
## old active_actor_id; world.gd processes _pending_active_actor between
## ticks (matches transition_level / save_state pattern).
static func switch_actor(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var target := str(EffectResolution.value(e.get("target_id", e.get("target", "")), ctx, env))
	if target == "":
		push_warning("switch_actor: missing target_id (rule=%s)" % str(ctx.get("_rule_id", "")))
		return
	env["_pending_active_actor"] = target


## Synthesize input for a specific (typically non-human) actor.
## Foundation for AI policies (ADR 0018). Pushes onto the scheduler's
## input queue with the actor_id in the params dict.
static func queue_input_for_actor(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var actor_id := str(EffectResolution.value(e.get("actor_id", ""), ctx, env))
	var action := str(EffectResolution.value(e.get("action", ""), ctx, env))
	if actor_id == "" or action == "":
		push_warning(
			(
				"queue_input_for_actor: missing actor_id or action (rule=%s)"
				% str(ctx.get("_rule_id", ""))
			)
		)
		return
	var parent_node = env.get("parent", null)
	if parent_node == null or parent_node.get("scheduler") == null:
		return
	var sched = parent_node.scheduler
	if sched.has_method("queue_input"):
		sched.queue_input(action, {"actor": actor_id, "synthesized": true})


## ADR 0010+0011 follow-up (#99): reset world state without scene reload.
## Used by "New Game" buttons after the player previously clicked Continue
## (which mutated state via load_state). Without this effect, a New Game
## chain is broken: reload_scene + transition_screen drops the transition
## (destructive chain footgun); just transition_screen leaves loaded state
## intact.
##
## Behavior (deferred to between-tick processing in world.gd):
## - Despawn all non-persistent entities (matches transition_level pattern)
## - Reset world_state to initial values from world/state.json
## - For multi-level games (game/flow.json present): reset current_level
##   to starting_level + reload that level's entities
## - For single-level games: reload entities/initial_instances
##
## Non-destructive to the effect chain: only mutates env via
## _pending_world_reset flag, processed at end of tick. Subsequent effects
## (transition_screen, etc.) fire normally.
static func reset_world(_e: Dictionary, env: Dictionary, _ctx: Dictionary) -> void:
	env["_pending_world_reset"] = true


# ============================================================
# PARTY EFFECTS (ADR 0026)
# ============================================================
#
# Three convenience effects that compose existing primitives (relate /
# tag_add / tag_remove / state_set / unrelate) into a single declarative
# verb per author intent. Per ADR 0026, the engine ships these because
# every party game would otherwise spell out the same 6-line effect chain.
# The PartyDirector module reads the resulting tag + relation + state to
# drive per-frame leashing.


## party_join — add an NPC to the player's party.
##   {target: <npc>, leader: <player_id>}
##
## Effects:
##   1. Add `party_member` tag to target.
##   2. Create `party_member_of` relation: target → leader.
##   3. Set target.state.party_index = leader.state.party_count (next slot).
##   4. Increment leader.state.party_count by 1.
##   5. Initialize target.state.ko = 0 (so KO intercept rules read it).
##
## Idempotent on tag/relation (RelationStore dedup; tag_add no-ops on
## already-present tag) but party_index is only valid for the first call —
## a second party_join would push the count up and reassign a new slot,
## leaving the original index dangling. Authors should gate joins on
## `tags_none: ["party_member"]` to avoid double-add.
static func party_join(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var member: Entity = EffectResolution.target(e, env, ctx)
	if member == null:
		return
	var leader_id := EffectResolution.resolve_id(e.get("leader", "player"), ctx)
	if leader_id == "":
		return
	var entities: Dictionary = env.get("entities", {})
	if not entities.has(leader_id):
		return
	var leader = entities[leader_id]
	if not (leader is Entity):
		return
	var leader_ent: Entity = leader
	# 1. Tag membership.
	member.add_tag("party_member")
	# 2. Relation: member → leader.
	var store: RelationStore = env.get("relations", null)
	if store != null:
		store.relate("party_member_of", member.instance_id, leader_id)
	# 3. + 4. Slot assignment via leader's party_count counter.
	var slot: int = int(leader_ent.get_state("party_count", 0))
	member.set_state("party_index", slot)
	leader_ent.add_state("party_count", 1)
	# 5. Initialize KO state so intercept rules can read it cleanly.
	if member.get_state("ko", null) == null:
		member.set_state("ko", 0)


## party_leave — remove an NPC from the party.
##   {target: <npc>}
##
## Effects:
##   1. Remove `party_member` tag.
##   2. Drop the `party_member_of` relation (resolved via the store —
##      authors don't pass leader explicitly).
##   3. Decrement leader's state.party_count if a relation existed.
##   4. Clear ko + party_index on the target.
##
## NOTE: this does NOT compact remaining members' party_index. If
## index 0 leaves and indices 1+2 remain, they stay at 1 and 2 — the
## director's offset table treats slots as positions, not order, so
## leaving "slot 0 empty" just means no companion stands there.
## Authors who want re-shuffling can issue party_leave + party_join
## on the remaining members.
static func party_leave(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var member: Entity = EffectResolution.target(e, env, ctx)
	if member == null:
		return
	var store: RelationStore = env.get("relations", null)
	# 2. + 3. Drop relation; track leader for count decrement.
	var entities: Dictionary = env.get("entities", {})
	if store != null:
		var leaders: Array = store.targets("party_member_of", member.instance_id)
		for leader_id in leaders:
			store.unrelate("party_member_of", member.instance_id, str(leader_id))
			if entities.has(str(leader_id)):
				var leader = entities[str(leader_id)]
				if leader is Entity:
					(leader as Entity).add_state("party_count", -1)
	# 1. Tag.
	member.remove_tag("party_member")
	# 4. Clear member's party state.
	member.set_state("ko", 0)
	member.set_state("party_index", -1)


## party_ko — knock out a party member without removing them.
##   {target: <npc>}
##
## Effects:
##   1. Set state.ko = 1 (intercept rules check this).
##   2. Set state.hp = 1 (so subsequent damage doesn't re-fire KO logic
##      every tick — a hp=0 entity would keep matching an `hp_lte: 0`
##      query indefinitely).
##   3. Snap state.position to leader's current position (so KO'd
##      companions visibly fall next to the player).
##   4. Zero state.velocity (no drift while KO'd).
##
## Author-side: pair with a tick rule that emits `party_revival` on
## reaching a town to wake the member back up. The director listens
## for that signal and resets ko + hp.
static func party_ko(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var member: Entity = EffectResolution.target(e, env, ctx)
	if member == null:
		return
	# 1. + 2. KO + hp pin.
	member.set_state("ko", 1)
	member.set_state("hp", 1)
	# 3. Snap to leader. Resolve leader via relation; fall back to no-op
	# if no relation (orphaned ko'd entity stays where it died).
	var store: RelationStore = env.get("relations", null)
	if store != null:
		var leaders: Array = store.targets("party_member_of", member.instance_id)
		if leaders.size() == 1:
			var entities: Dictionary = env.get("entities", {})
			var leader_id: String = str(leaders[0])
			if entities.has(leader_id) and entities[leader_id] is Entity:
				member.set_position((entities[leader_id] as Entity).get_position())
	# 4. Stop motion.
	# Use Vector3.ZERO if the member's position is 3D, Vector2.ZERO if 2D —
	# matches Entity.set_velocity's normalization expectations.
	var pos = member.get_position()
	if pos is Vector3:
		member.set_velocity(Vector3.ZERO)
	else:
		member.set_velocity(Vector2.ZERO)
