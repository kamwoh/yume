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
	_apply_vertical(_delta)
	_apply_speed_clamp()
	var pre_pos := global_position
	var was_grounded := is_on_floor()
	var desired_h := Vector3(velocity.x, 0.0, velocity.z) * _delta
	move_and_slide()
	_try_step_up(pre_pos, desired_h, was_grounded)
	_writeback_vertical_state()
	_writeback_position()


## Stair/ledge step-up (CharacterBody3D has none natively — move_and_slide
## treats a vertical riser like a wall). After the slide, if a grounded,
## moving body got blocked horizontally, virtually test rise → forward → drop:
## if it lands on a walkable surface within `max_step_height`, snap the body
## up onto it. Opt-in: state.max_step_height defaults to 0 (disabled), so
## existing actors are unaffected. (2026-06-09.)
func _try_step_up(pre_pos: Vector3, desired_h: Vector3, was_grounded: bool) -> void:
	var max_step := float(entity_ref.get_state("max_step_height", 0.0))
	if max_step <= 0.0 or not was_grounded:
		return
	var want := desired_h.length()
	if want < 0.001:
		return
	# Blocked? Compare actual horizontal travel this frame to what we wanted.
	var actual_h := global_position - pre_pos
	actual_h.y = 0.0
	if actual_h.length() >= want - 0.01:
		return  # moved freely — nothing to step over
	var remaining := desired_h - actual_h
	if remaining.length() < 0.001:
		return
	var up := up_direction * max_step
	var t := global_transform
	var col := KinematicCollision3D.new()
	# 1. rise — abort if a ceiling is within the step height.
	if test_move(t, up, col):
		return
	t.origin += up
	# 2. move forward over the step — if still blocked, it's a real wall (too tall).
	if test_move(t, remaining, col):
		return
	t.origin += remaining
	# 3. drop back down to find the step surface (a little past max_step).
	if not test_move(t, -up - up_direction * 0.1, col):
		return  # nothing to land on within reach → stepping would float us
	# Only step onto a WALKABLE surface (not a steep slope / overhang).
	if col.get_normal().dot(up_direction) < cos(floor_max_angle):
		return
	# Accept: place the body on the step, kill downward velocity so the next
	# frame's floor-snap grounds it cleanly (no gravity spike / jitter).
	global_position = t.origin + col.get_travel()
	if OS.is_debug_build():
		print("[STEP-UP] climbed to y=%.2f" % global_position.y)
	if velocity.y < 0.0:
		velocity.y = 0.0
		entity_ref.set_state("y_velocity", 0.0)


## Apply gravity + jump-impulse mechanics (2026-05-20). Each physics
## frame BEFORE move_and_slide:
##
##   1. Read state.y_velocity (defaults to 0). This is the entity's
##      authoritative up-axis velocity; rules write to it for jumps.
##   2. If state.on_floor is 0 (mid-air), accumulate gravity into
##      state.y_velocity. Gravity is configurable via state.gravity
##      (default 18.0 m/s², a touch heavier than Earth for snappy
##      arcade-jump feel; tune down to 9.8 for realism).
##   3. Set body.velocity.y = state.y_velocity so move_and_slide sees
##      the vertical motion.
##
## After move_and_slide, _writeback_vertical_state mirrors is_on_floor()
## back to state.on_floor and updates state.y_velocity to body.velocity.y
## (capturing the floor-clamped value so we don't keep accumulating
## negative gravity while grounded).
##
## Players opt in by declaring state.y_velocity / state.on_floor /
## state.gravity in their state_init (or accepting the defaults). The
## existing Vector2 horizontal velocity continues to work — only the
## body's y component is owned by this path.
func _apply_vertical(delta: float) -> void:
	var y_vel := float(entity_ref.get_state("y_velocity", 0.0))
	var on_floor := int(entity_ref.get_state("on_floor", 1))
	if on_floor == 0:
		var gravity := float(entity_ref.get_state("gravity", 18.0))
		y_vel -= gravity * delta
	# Write into body.velocity.y BEFORE move_and_slide. Horizontal x/z
	# came from sync_body_velocity (which now preserves y per the same
	# ADR 0055-follow-up change in physics_body_builder.gd).
	velocity.y = y_vel
	entity_ref.set_state("y_velocity", y_vel)


## After move_and_slide: capture grounded state + clamped y-velocity.
## When grounded with a downward y_velocity, snap it to 0 so the
## accumulator doesn't run away during stationary frames.
##
## Real ground collision (2026-05-24, task #124): GroundRenderer now
## attaches a StaticBody3D + BoxShape3D matching the ground.mesh.size,
## so is_on_floor() returns true via physics inside the plane. Outside
## the plane (player walks off the edge), no collider → gravity pulls
## them down indefinitely. Replaces the prior soft y_floor convention
## that clamped y<=0 everywhere in world space.
##
## Optional soft fallback: if state.floor_y is explicitly set on the
## entity, still apply the clamp. Lets games without ground colliders
## (2D demos, abstract puzzles, scenes with no PlaneMesh) opt into the
## old behavior via JSON.
func _writeback_vertical_state() -> void:
	var grounded := is_on_floor()
	# Optional soft clamp — only active when state.floor_y is set.
	# Default null/missing = use physics-based grounding from
	# move_and_slide + ground StaticBody3D.
	var floor_y_v = entity_ref.get_state("floor_y", null)
	if floor_y_v != null:
		var floor_y := float(floor_y_v)
		if global_position.y <= floor_y:
			global_position.y = floor_y
			grounded = true
	entity_ref.set_state("on_floor", 1 if grounded else 0)
	if grounded and velocity.y < 0.0:
		velocity.y = 0.0
		entity_ref.set_state("y_velocity", 0.0)
	else:
		entity_ref.set_state("y_velocity", velocity.y)


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
