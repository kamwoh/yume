extends RefCounted
class_name EffectApply

## Primitive #5 — Effect (application side).
##
## Contract: docs/guideline/30_framework_primitives.md §5
##
## `apply(effect, env, context)` mutates the world to fulfill one effect dict.
## The calling phase scheduler (W1.8) decides *when* to apply (commit vs react)
## and in what order. This module is purely about *how*.
##
## `env` carries mutable engine services:
##   env.entities    : Dictionary (instance_id → Entity)
##   env.relations   : RelationStore
##   env.defs        : Dictionary (def_id → entity definition)
##   env.parent      : Node  — parent node for spawned entity children (the
##                             scene's entity root). Node2D expected.
##   env.next_id     : Dictionary {"_": int} — spawn-id counter (shared ref)
##
## `context` carries per-rule bindings: `self`, `a`, `b`, input-payload keys.
##
## W1 scope:
##   state_set, state_add, state_mul, state_clamp,
##   spawn, remove, transform,
##   relate, unrelate, transfer_relation,
##   tag_add, tag_remove.
##
## Deferred:
##   velocity_set (W2 — motion tick lives alongside)
##   emit         (W2 — signal scheduler wires outbound queue)
##   formula-valued numeric fields (W4 — formula.gd wrapper)

# ============================================================
# PUBLIC
# ============================================================


## Apply a single effect. Returns a side-effect record for the scheduler to
## consume (e.g. emitted signals); empty dict if none.
static func apply(effect: Dictionary, env: Dictionary, context: Dictionary) -> Dictionary:
	var type: String = str(effect.get("type", ""))
	match type:
		"state_set":
			EffectCore.state_set(effect, env, context)
		"state_add":
			EffectCore.state_add(effect, env, context)
		"state_mul":
			EffectCore.state_mul(effect, env, context)
		"state_clamp":
			EffectCore.state_clamp(effect, env, context)
		# ADR 0031 — aggregated zone-state primitive
		"zone_state_set":
			EffectCore.zone_state_set(effect, env, context)
		"zone_state_add":
			EffectCore.zone_state_add(effect, env, context)
		"zone_state_clamp":
			EffectCore.zone_state_clamp(effect, env, context)
		"spawn":
			return EffectCore.spawn(effect, env, context)
		"remove":
			EffectCore.remove(effect, env, context)
		"transform":
			return EffectCore.transform(effect, env, context)
		"relate":
			EffectCore.relate(effect, env, context)
		"unrelate":
			EffectCore.unrelate(effect, env, context)
		"transfer_relation":
			EffectCore.transfer_relation(effect, env, context)
		# ADR 0077 — level subroutines. DESTRUCTIVE, like transition_level:
		# must be LAST in their effect chain.
		# ADR 0078 — the calendar clock. Not destructive.
		"refresh_screen":
			EffectShell.refresh_screen(effect, env, context)
		"advance_time":
			EffectShell.advance_time(effect, env, context)
		"level_call":
			EffectShell.level_call(effect, env, context)
		"level_return":
			EffectShell.level_return(effect, env, context)
		"relation_set":
			EffectCore.relation_set(effect, env, context)
		"relation_add":
			EffectCore.relation_add(effect, env, context)
		"relation_clamp":
			EffectCore.relation_clamp(effect, env, context)
		"tag_add":
			EffectCore.tag_add(effect, env, context)
		"tag_remove":
			EffectCore.tag_remove(effect, env, context)
		"velocity_set":
			EffectMotion.velocity_set(effect, env, context)
		"velocity_lerp":
			EffectMotion.velocity_lerp(effect, env, context)
		"velocity_set_relative":
			EffectMotion.velocity_set_relative(effect, env, context)
		"velocity_add_relative":
			EffectMotion.velocity_add_relative(effect, env, context)
		"pathfind_to":
			EffectMotion.pathfind_to(effect, env, context)
		"raycast_hit":
			EffectMotion.raycast_hit(effect, env, context)
		"transition_level":
			EffectShell.transition_level(effect, env, context)
		"emit":
			EffectCore.emit(effect, env, context)
		"array_set_at":
			EffectCore.array_set_at(effect, env, context)
		"array_insert_first_empty":
			EffectCore.array_insert_first_empty(effect, env, context)
		"array_sync_to_field":
			EffectCore.array_sync_to_field(effect, env, context)
		"array_count_matching":
			EffectCore.array_count_matching(effect, env, context)
		"emit_shell_event":
			EffectCore.emit_shell_event(effect, env, context)
		"transition_screen":
			EffectShell.transition_screen(effect, env, context)
		"quit_app":
			EffectShell.quit_app(effect, env, context)
		"show_toast":
			EffectShell.show_toast(effect, env, context)
		"reload_scene":
			EffectShell.reload_scene(effect, env, context)
		"scene_change":
			EffectShell.scene_change(effect, env, context)
		"screen_fade":
			EffectShell.screen_fade(effect, env, context)
		"save_state":
			EffectShell.save_state(effect, env, context)
		"load_state":
			EffectShell.load_state(effect, env, context)
		"show_overlay":
			EffectShell.show_overlay_effect(effect, env, context)
		"dismiss_overlay":
			EffectShell.dismiss_overlay_effect(effect, env, context)
		"set_audio_bus_volume":
			EffectShell.set_audio_bus_volume(effect, env, context)
		"set_input_mapping":
			EffectShell.set_input_mapping(effect, env, context)
		"switch_actor":
			EffectActor.switch_actor(effect, env, context)
		"queue_input_for_actor":
			EffectActor.queue_input_for_actor(effect, env, context)
		"reset_world":
			EffectActor.reset_world(effect, env, context)
		_:
			EngineError.raise(
				env,
				EngineError.EFFECT_UNKNOWN_TYPE,
				"Unknown effect type: '%s'" % type,
				{"rule_id": context.get("_rule_id", ""), "field": "effect.type", "got": type},
				"Use an effect type from docs/engine-reference/api-manifest.json (generated from this dispatcher).",
				"warning"
			)
	return {}
