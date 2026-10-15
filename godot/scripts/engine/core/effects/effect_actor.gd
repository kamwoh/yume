extends Object
class_name EffectActor

## Actor-control effect handlers.
##
##   - switch_actor — change which actor receives input (ADR 0016)
##   - queue_input_for_actor — synthesize an input event for any actor
##   - reset_world — reload current level + reset persistent state
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
