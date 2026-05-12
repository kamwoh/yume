extends CharacterBody3D
class_name CharacterBodyRunner

## ADR 0045 Session A — skeleton; _physics_process body lands in Session B.
##
## Per-actor motion runner. One instance per entity with
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
## Session B will fill _physics_process with:
##   1. Read entity_ref.state.velocity into self.velocity
##   2. Clamp via velocity.limit_length(entity_ref.state.max_speed)
##   3. Call move_and_slide()
##   4. Write self.global_position back into entity_ref.state.position
##
## Session B will also add a tick_headless(delta) method for use by
## step_runner / scenario_runner (which have no live physics server).
## Per Condition 5 — keeps headless test path coherent.

var entity_ref: Entity = null


## Set the back-reference. Called once by PhysicsBodyBuilder.build_character_3d
## right after instantiation, before add_child.
func bind(entity: Entity) -> void:
	entity_ref = entity


## Session B: read velocity from entity_ref, clamp, move_and_slide,
## write position back. Empty in Session A so no actor is moved by
## this runner yet (purely additive lifecycle plumbing).
##
## DO NOT add a _process callback. Only _physics_process is paused
## by PhysicsServer3D.set_active(false) — adding _process logic
## bypasses the freeze policy (Invariant #10 / Condition 3).
func _physics_process(_delta: float) -> void:
	pass
