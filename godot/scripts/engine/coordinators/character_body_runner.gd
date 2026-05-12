extends CharacterBody3D
class_name CharacterBodyRunner

## ADR 0045 — Per-actor motion runner. One instance per entity with
## body_type: "character". Owned by the Entity Node (added as a child).
## Holds a typed back-reference to the Entity so its _physics_process
## can read state.velocity and write state.position.
##
## Why a Node and not an RID: ADR 0044's bodies use raw PhysicsServer3D
## RIDs (BODY_MODE_KINEMATIC etc.). Raw RIDs do NOT have move_and_slide;
## that method lives on CharacterBody3D the Godot scene class. Velocity-
## driven actors need slide/floor/step/ceiling detection, which is what
## CharacterBody3D ships. So character bodies are scene Nodes, not RIDs.
## PhysicsBodyBuilder.free_3d + sync_body_transform / sync_body_velocity
## dispatch on Variant type (is RID vs is Node) — see ADR 0045 Decision
## section.
##
## Freeze policy (Invariant #10): this script uses ONLY _physics_process,
## NEVER _process. PhysicsServer3D.set_active(false) (set by world.gd
## under modal freeze) suspends _physics_process automatically.
##
## Two motion paths share the same clamp + writeback helpers:
##   - _physics_process (live, 60Hz) → move_and_slide
##   - tick_headless (test harness) → Euler integration
## Both consume entity_ref.state.velocity and write entity_ref.state.position.

var entity_ref: Entity = null


## Set the back-reference. Called once by PhysicsBodyBuilder.build_character_3d
## right after instantiation, before add_child.
func bind(entity: Entity) -> void:
	entity_ref = entity


## Live per-physics-frame motion. Fires at Godot's physics rate (60Hz
## by default), independent of Yume's 10Hz sim tick. Reads entity_ref's
## velocity (already mirrored from rule effects via Entity.set_velocity's
## sync_body_velocity funnel), clamps, calls move_and_slide for the
## actual slide + slope + step + floor handling, writes the post-slide
## position back to entity_ref.state.position so rule queries can read
## the up-to-date position at the next sim-tick boundary.
##
## DO NOT add a _process callback. Only _physics_process is paused
## by PhysicsServer3D.set_active(false) — adding _process logic
## bypasses the freeze policy (Invariant #10 / Condition 3).
func _physics_process(_delta: float) -> void:
	if entity_ref == null:
		return
	_apply_speed_clamp()
	move_and_slide()
	_writeback_position()


## Headless equivalent of _physics_process for tests. Same velocity-read
## + speed-clamp + position-writeback semantics, but uses simple Euler
## integration (position += velocity * dt) instead of move_and_slide
## (which needs a live physics server + viewport — neither exists in
## the headless test harness).
##
## Used by step_runner + scenario_runner after the sim tick;
## those harnesses iterate entities with character bodies and call
## tick_headless on each one. Tests asserting exact collision-slid
## positions must use a windowed test (rare); the headless path is fine
## for the bulk of scenario assertions (position deltas, velocity
## magnitudes, max_speed clamp).
func tick_headless(delta: float) -> void:
	if entity_ref == null:
		return
	_apply_speed_clamp()
	global_position += velocity * delta
	_writeback_position()


# ============================================================
# SHARED HELPERS — live + headless paths share clamp + writeback
# ============================================================


## ADR 0045 Decision: speed clamp moves from world.gd._post_tick_speed_clamp
## into the body. Default max_speed=INF means clamp disabled; declaring a
## finite value opts in. Required for FP mode (anti-diagonal-fastrun bug).
func _apply_speed_clamp() -> void:
	var max_s := float(entity_ref.get_state("max_speed", INF))
	if max_s >= INF:
		return
	if velocity.length() > max_s:
		velocity = velocity.normalized() * max_s


## Write the body's authoritative post-move position back into the
## entity's state. Goes through Entity.set_position so the spatial
## index gets updated (rule radius queries depend on it). The body
## sync inside set_position is a self-assignment (body.global_position
## = global_position) — harmless no-op cost.
func _writeback_position() -> void:
	entity_ref.set_position(global_position)
