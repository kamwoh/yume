extends Node

class_name World

## Top-level orchestrator. Owns canonical engine state (entities, scheduler,
## relations, spatial index, world_state) and the coordinators that drive
## each subsystem. Almost all behavior lives in the coordinators; World's
## job is to construct them and sequence the per-frame + per-tick calls.
##
## Contract: docs/30_framework_primitives.md § "File layout after redesign"
##
## Renderer-agnostic. Extends plain Node — no transform. Entities are
## children; each gets a positioned renderer node (Sprite2D / MeshInstance3D)
## that reads state.position. Same script powers world_2d.tscn and
## world_3d.tscn.

@export_dir var data_root: String = ""  # e.g. "res://data/demo_ecology/"
@export var auto_start: bool = true
@export var tick_seconds: float = 0.5
@export var verbose: bool = false
## Optional: path to a Node2D script that renders Entity visuals. Each spawn
## attaches one instance as a child of the Entity. Set empty to disable (useful
## for headless tests).
@export_file("*.gd") var renderer_script: String = "res://scripts/renderer_2d/entity_sprite_2d.gd"
## Input actions polled while HELD — fire every frame the key is down.
## Suitable for continuous things (movement, charge meters).
##
## Default empty: per-game `inputs.json` declares each action's edge type
## (hold/press). Engine has no genre opinions about what's hold vs press —
## those are content decisions. (2026-05-05: dropped baked-in shooter
## defaults that broke turn-based games like sokoban.)
@export var input_actions_hold: PackedStringArray = PackedStringArray()
## Input actions polled on PRESS edge — fire once per keypress, not every frame.
## Suitable for discrete events (spawn bullet, toggle, dialog advance).
##
## Default empty — see input_actions_hold note.
@export var input_actions_press: PackedStringArray = PackedStringArray()
@export var actor_tag: String = "player"
## "stop" action queued when no movement keys pressed (lets velocity_set
## reset to zero). Empty string disables.
@export var stop_action_on_idle: String = "stop"

## ADR 0009 Phase 2d: variant override. If non-empty, takes precedence
## over scene.json's "variant" key and the YUME_VARIANT env var. Used
## by scenario_runner to test variant logic without mutating shared
## global state.
@export var variant_override: String = ""

# ============================================================
# STATE — engine-shared services (env-exposed)
# ============================================================

var entities: Dictionary = {}  # instance_id → Entity
var defs: Dictionary = {}  # def_id → entity definition
var world_state: Dictionary = {}  # world.* bindings
var next_id_seq: Dictionary = {"_": 0}  # shared spawn-id counter
var error_buffer: Array = []  # Tier 2.6a structured errors
var save_policy: Dictionary = {}  # ADR 0010 — empty = no persistence

var relations: RelationStore = null  # primitive #7
var spatial_index: SpatialIndex = null  # radius-query bucket hash
var scheduler: PhaseScheduler = null  # four-phase tick loop
var zone_store: ZoneStore = null  # ADR 0031 (always non-null)
var chunk_streamer: ChunkStreamer = null  # ADR 0014 (nullable)
var actor_manager = null  # ADR 0016 multi-actor
var macro_expander = null  # ADR 0019 macros

# ============================================================
# STATE — coordinators (private; World drives them)
# ============================================================

var _loader: WorldLoader = null  # JSON parsing
var _spawn_manager: SpawnManager = null  # spawn pipeline
var _motion_integrator: MotionIntegrator = null  # per-frame motion + collision
var _ground_constraint: GroundConstraint = null  # per-frame ground clamp + despawn
var _level_transitions: LevelTransitionCoordinator = null  # ADR 0006 multi-level swap
var _save_load: SaveLoadCoordinator = null  # ADR 0010 save/load drain
var _world_reset: WorldResetCoordinator = null  # restart pipeline
var _multimesh_director: MultiMeshDirector = null  # ADR 0041 multimesh batching

# ============================================================
# STATE — sim-tick accumulator (replaces former WorldClock child Node)
# ============================================================
#
# _process(delta) accumulates real-time delta; each crossing of
# tick_seconds drains one tick. _tick_count is the canonical sim clock
# (used by save/load + scenario tests); rate-coupled to wall-time only
# at the accumulator, so rule cascades + AI cadence stay deterministic.

var _tick_elapsed: float = 0.0
var _tick_count: int = 0

# ============================================================
# LIFECYCLE
# ============================================================


## Resolve --game= cmdline arg in _enter_tree, which fires top-down before
## any _ready (children's _ready otherwise runs before parent's _ready and
## sees data_root="" when GameShell + ScreenFlow try to read scene.json).
## Empirically caught 2026-05-07: play.tscn rendered blank gray for merchant
## because GameShell read empty scene_cfg → no camera follow_tag → camera
## stuck at (0,0) while player at (1500, 2400).
func _enter_tree() -> void:
	if data_root == "":
		_resolve_data_root_from_cmdline()


func _ready() -> void:
	_init_stores()
	_init_coordinators()
	if auto_start:
		start()


func start() -> void:
	if data_root != "":
		load_data()


## Engine-shared services. All non-null after this returns; downstream
## code reads them through env without null checks.
func _init_stores() -> void:
	relations = RelationStore.new()
	spatial_index = SpatialIndex.new()
	zone_store = ZoneStore.new()
	scheduler = PhaseScheduler.new(_build_env())


## Coordinator instances. Constructed once with a back-reference to
## World; per-frame and per-tick calls flow through these.
func _init_coordinators() -> void:
	_loader = WorldLoader.new(self)
	_spawn_manager = SpawnManager.new(self)
	_motion_integrator = MotionIntegrator.new(self)
	_ground_constraint = GroundConstraint.new(self)
	_level_transitions = LevelTransitionCoordinator.new(self)
	_save_load = SaveLoadCoordinator.new(self)
	_world_reset = WorldResetCoordinator.new(self)


## Look for `--game=<name>` in user args. The user-args separator `--`
## is required so Godot doesn't try to interpret these as engine flags.
## Game names are folder names under `res://data/` (e.g. `demo_tinypond`).
func _resolve_data_root_from_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s.begins_with("--game="):
			data_root = "res://data/" + s.substr(7)
			if verbose:
				print("[World] resolved data_root from cmdline: ", data_root)
			return


# ============================================================
# DATA LOADING
# ============================================================


## Load entity defs, initial instances, initial relations, rules, and world
## state from `data_root/`. Order: rules → entities → world → initial flush.
## Rules load first so that spawn-triggered rules can fire during initial
## entity load (per W0 finding on lifecycle-flush-at-load).
##
## ADR 0009 (Phase 5b sunset, 2026-05-05): single canonical layout —
## world/physics.json + game/rules.json + game/flow.json +
## levels/<name>/rules.json + world/state.json. Legacy single-file paths
## (world_rules.json, progression.json, world.json) are no longer
## consulted — all in-tree demos migrated. If you hit a "no rules
## loaded" warning on an old game, rename world_rules.json →
## world/physics.json (or split per Phase 3b classification).
func load_data() -> void:
	var root := data_root.rstrip("/")
	# ADR 0027 — load shared `data/lib/**.json` into LibResolver cache
	# BEFORE any per-game JSON loader runs. Resolver runs cache-once
	# subsequent calls are no-op. Lets later loaders (entities, rules,
	# screens, scene, hud) call LibResolver.resolve transparently.
	LibResolver.init_cache(root)
	# Tier 2.6t — register per-game input actions from inputs.json (if any).
	# Lets games own their input vocabulary; project.godot stays generic.
	# v2.6r: registrar returns press/hold action names so the engine extends
	# its poll lists. Without this, per-game actions get InputMap entries
	# but never reach the rule scheduler.
	# ADR 0009: registrar also checks new ui/input.json path.
	var registered: Dictionary = InputRegistrar.register_from_data_root(root)
	for n in registered.get("press", []) as Array:
		if not (input_actions_press as Array).has(str(n)):
			input_actions_press.append(str(n))
	for n in registered.get("hold", []) as Array:
		if not (input_actions_hold as Array).has(str(n)):
			input_actions_hold.append(str(n))
	# v2.6: scene.json may declare a `level_seed` integer that's applied to
	# Godot's global PRNG before any pattern/scatter/cluster runs. Makes
	# procedurally-generated layouts reproducible — same seed = same map.
	# Omit for stochastic per-session randomization.
	_loader.apply_level_seed_if_set(root)
	# ADR 0019: load per-game macros (if any) BEFORE rules, so every
	# rules file (world/physics.json, game/rules.json, levels/<n>/rules.json,
	# tutorial.json) can reference the same macro vocabulary. Empty
	# expander if no macros.json present (no-op pass-through).
	macro_expander = MacroExpander.load_from_data_root(root, _build_env())
	# ADR 0016: load (or synthesize) actor config. Single code path —
	# legacy single-player demos get a synthesized default actor whose
	# starting_entity_tag = the existing actor_tag export var. Mirror
	# active_actor_id into world_state so bindings can read it.
	actor_manager = ActorManager.load_or_synthesize(root, actor_tag)
	world_state["active_actor_id"] = actor_manager.active_actor_id
	# ADR 0018 Phase A: load scripted policies for any ai_policy actors.
	# No-op for legacy demos (no ai_policy actors in synthesized default).
	actor_manager.load_policies(root)
	# ADR 0006: multi-level support. If game/flow.json exists, load
	# progression + the starting level's content. Persistent entities come
	# from the root's entities.json. Otherwise (single-level games), load
	# entities + rules from the root directly.
	var prog_path := root + "/game/flow.json"
	if FileAccess.file_exists(prog_path):
		_loader.load_progression(prog_path)
		# Global rules (cross-level): physics first (register), game-rules
		# appended. Per-level rules append on top in _load_level.
		_loader.load_rules_file(root + "/world/physics.json")
		_loader.load_rules_file(root + "/game/rules.json", true)
		# ADR 0012: tutorial.json — optional, treated as additional rules
		# at global scope. Steps are rules whose effects fire show_overlay /
		# dismiss_overlay; sequencing via overlay_advanced signal + state.
		_loader.load_rules_file(root + "/tutorial.json", true)
		_loader.load_world_file(root + "/world/state.json")
		# Per ADR 0006: tag persistent entities "persistent" to survive
		# level transitions.
		_loader.load_entities_path(root)
		if current_level != "":
			_level_transitions.load_level(current_level)
	else:
		# Single-level layout
		_loader.load_rules_file(root + "/world/physics.json")
		_loader.load_rules_file(root + "/game/rules.json", true)
		_loader.load_rules_file(root + "/tutorial.json", true)
		_loader.load_world_file(root + "/world/state.json")
		_loader.load_entities_path(root)
		# ADR 0024: build navmesh for single-level games (multi-level
		# games build inside _load_level). No-op when no walkable_floor
		# entities exist.
		if scheduler != null:
			Pathfinding.build_navmesh_for_level(scheduler.env)
	# ADR 0031: load zones.json (optional). Backward-compat — absent file
	# means no zones, no overhead. Loads AFTER entities + world_state so
	# error reports can reach env.error_buffer; loads BEFORE save layer
	# so saved zone_state restores on top of state_init.
	_loader.load_zones_file(root + "/world/zones.json")
	# ADR 0014: open-world chunk streaming. world.json declares chunked-world
	# mode; absent means single-chunk legacy mode (no streaming, no chunks
	# directory consulted). When present:
	#   - chunks/_persistent/entities.json is loaded ONCE (entities live for
	#     the whole session, regardless of chunk eviction)
	#   - the starting chunk + stream_radius neighbors are loaded
	#   - per-tick update() in _process tick branch handles drift loads/unloads
	chunk_streamer = ChunkStreamer.try_load(root, verbose)
	if chunk_streamer != null:
		# Persistent chunk first — its entities never leave env.entities.
		var persist_dir := root + "/chunks/_persistent"
		if DirAccess.dir_exists_absolute(persist_dir):
			_loader.load_entities_file(persist_dir + "/entities.json")
		# Boot: load starting_chunk + stream_radius neighbors.
		chunk_streamer.boot(_build_env())
	# ADR 0009 Phase 2d: variant overlay applies after rules + world_state +
	# entities are loaded. Read variant name from scene.json's "variant" key
	# or YUME_VARIANT env var. Variant file at variants/<name>.json applies
	# rule-id-keyed field overrides + world_state overrides + entity-id state
	# overrides. Purely additive — cannot change rule structure.
	# Extracted to VariantOverlay module 2026-05-12.
	VariantOverlay.new(self).apply(root)
	# ADR 0010: load save policy + expose has_save binding for menus.
	save_policy = SaveState.load_policy(root)
	if not save_policy.is_empty():
		var slots := int(save_policy.get("slots", 1))
		var game := SaveLoadCoordinator.game_name_from_root(data_root)
		world_state["has_save"] = 1 if SaveState.has_any_save(game, slots) else 0
	else:
		world_state["has_save"] = 0
	# ADR 0013: now that scheduler + env are built, run SettingsManager's
	# apply_all so each setting's `apply` block fires (set_audio_bus_volume,
	# set_input_mapping, state_set target=world). SettingsManager is a Node
	# sibling — it loaded the schema + config in its own _ready, but
	# deferred apply_all here so EffectApply has a valid env.
	var settings_mgr := get_node_or_null("SettingsManager")
	if settings_mgr != null and settings_mgr.has_method("apply_all"):
		settings_mgr.apply_all()
	# ADR 0029: ScheduleDirector reads each entity def's `schedule` block
	# (if present) and starts resolving slots once World ticks. Register
	# AFTER entities are loaded so register_schedules_from_env can walk
	# env.entities and find their defs. No-op for games shipping no
	# schedules (existing demos unaffected).
	var sched_dir := get_node_or_null("ScheduleDirector")
	if sched_dir != null and sched_dir.has_method("register_schedules_from_env"):
		sched_dir.register_schedules_from_env(scheduler.env)
	# ADR 0036: LifecycleDirector reads each entity def's `lifecycle` block
	# and registers per-entity stage tables. No-op for games shipping no
	# lifecycle templates (existing demos unaffected — backward-compat by
	# absence of the field).
	var lc_dir := get_node_or_null("LifecycleDirector")
	if lc_dir != null and lc_dir.has_method("register_lifecycles_from_env"):
		lc_dir.register_lifecycles_from_env(scheduler.env)
	# ADR 0030: ClassManager loads class defs from <root>/classes/*.json
	# if the directory exists. No-op for games without occupations.
	# Loaded after entities so signal listeners (game-rules) are already
	# wired by the time the first switch_class effect can fire.
	var class_mgr := get_node_or_null("ClassManager")
	if class_mgr != null and class_mgr.has_method("register_classes_from_data_root"):
		class_mgr.register_classes_from_data_root(root, scheduler.env)
	# ADR 0033: TechTreeDirector loads tree defs from <root>/tech_trees.json
	# if present. No-op for games without a tech tree (existing demos
	# unaffected). Loaded after entities so signal listeners are wired
	# before the first try_discover_tech / learn_from_master effect can fire.
	var tech_dir := get_node_or_null("TechTreeDirector")
	if tech_dir != null and tech_dir.has_method("register_trees_from_data_root"):
		tech_dir.register_trees_from_data_root(root, scheduler.env)
	# ADR 0034: DynastyDirector hosts the four succession effects
	# (transfer_inventory / transfer_reputation / transfer_techs /
	# transition_player_to) plus the heir-resolver helper used by
	# per-game succession rules. No boot-time data to load — heir
	# state lives on each actor entity (state.heirs +
	# state.inheritance_policy), serialized via the normal entity
	# snapshot path (ADR 0010). Backward-compat: games without
	# heirs never trigger the director (Node may be absent from the
	# scene; the four effects log a no-manager warning and no-op).
	var _dynasty_dir := get_node_or_null("DynastyDirector")
	if _dynasty_dir != null and verbose:
		print("[World] DynastyDirector mounted (ADR 0034)")
	# ADR 0032: FactionDirector loads faction defs + initial relationships
	# from <root>/factions.json if present. No-op for games without
	# politics. Loaded after entities so member_count bindings can resolve
	# against the live entity set on first tick.
	_loader.load_factions_file(root + "/factions.json")
	scheduler.flush_effects()
	# ADR 0041: render-side batching for static decoration. Runs AFTER all
	# entities are loaded + rules registered (the director scans rules to
	# decide which entities are static). No-op when no mesh def has
	# multimesh_eligible: true (backward-compat for all existing demos).
	_run_multimesh_director()
	if verbose:
		var lvl_str := (" [level: " + current_level + "]") if current_level != "" else ""
		print(
			(
				"[World] loaded: %d defs, %d entities, %d relations%s"
				% [
					defs.size(),
					entities.size(),
					relations.count_total(),
					lvl_str,
				]
			),
		)


# ADR 0041 — bootstrap the multimesh director (lazy-init on first use).
# Reads renderer.position_scale from SpawnManager's renderer_cfg cache
# (default 0.05) and passes World as parent so MultiMeshInstance3D nodes
# sit at world scope. The cache is owned by SpawnManager (extracted
# 2026-05-11) — multimesh reads it as a consumer.
func _ensure_multimesh_director() -> MultiMeshDirector:
	if _multimesh_director != null:
		return _multimesh_director
	_multimesh_director = MultiMeshDirector.new()
	var cfg: Dictionary = _spawn_manager.renderer_cfg() if _spawn_manager != null else {}
	var ps: float = float(cfg.get("position_scale", 0.05))
	_multimesh_director.configure(self, ps)
	return _multimesh_director


func _run_multimesh_director() -> void:
	# Static-only optimization — skip when no entities use 3D renderer.
	# Also skip when renderer_script is empty (headless test mode).
	if renderer_script == "":
		return
	if not renderer_script.contains("entity_mesh_3d"):
		return
	var dir := _ensure_multimesh_director()
	var stats := dir.scan_and_batch(scheduler.env)
	if verbose and stats.get("groups", 0) > 0:
		print(
			(
				"[MULTIMESH-BUILD] entities=%d groups=%d instances=%d"
				% [
					stats.get("entities", 0),
					stats.get("groups", 0),
					stats.get("instances", 0),
				]
			),
		)


## ADR 0039: canonical sim-tick body. Reads as a schedule — each line
## is one step; implementation lives in private helpers below. Used by:
##   1. The live `_process(delta)` accumulator (above) after the freeze check.
##   2. The step runner (`step_runner.gd`) for headless tests + capture VQA.
##
## Single source of truth — both paths exercise identical engine state
## transitions, so scenario tests cannot pass while live play silently
## diverges.
##
## Does NOT include the freeze guard — callers gate on their own freeze
## policy. The step runner intentionally bypasses freeze (tests need to
## advance state regardless of modal screens).
func advance_one_tick() -> void:
	_pretick_velocity_zero()  # ADR 0040
	if actor_manager != null:
		actor_manager.tick_policies(scheduler.env)  # ADR 0018 — AI before input
	scheduler.tick()  # canonical phase loop
	_post_tick_speed_clamp()  # ADR 0040
	_tick_lifecycle_director()  # ADR 0036
	_decrement_lifetimes()  # Tier 2.6j
	_stream_chunks_if_active()  # ADR 0014
	if actor_manager != null:
		actor_manager.process_pending(scheduler.env, world_state, verbose)  # ADR 0016


## ADR 0040: zero velocity for opt-in actors before the input phase.
## Camera-relative WASD adds velocity each tick (velocity_add_relative);
## without a pretick reset, contributions accumulate unbounded.
func _pretick_velocity_zero() -> void:
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity):
			continue
		if not bool((ent as Entity).get_state("zero_velocity_pretick", false)):
			continue
		var v = (ent as Entity).get_velocity()
		if v is Vector2:
			(ent as Entity).set_velocity(Vector2.ZERO)
		elif v is Vector3:
			(ent as Entity).set_velocity(Vector3.ZERO)


## ADR 0040: clamp velocity magnitude to state.max_speed after the input
## phase. Default max_speed=INF disables the clamp; declaring a finite
## value opts in. Required for FP mode — without it W+D yields √2 × walk
## speed (classic Quake diagonal-fastrun bug, 2026-05-10 FP rollout).
func _post_tick_speed_clamp() -> void:
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity):
			continue
		var max_s := float((ent as Entity).get_state("max_speed", INF))
		if max_s >= INF:
			continue
		var v = (ent as Entity).get_velocity()
		if v is Vector2 and (v as Vector2).length() > max_s:
			(ent as Entity).set_velocity((v as Vector2).normalized() * max_s)
		elif v is Vector3 and (v as Vector3).length() > max_s:
			(ent as Entity).set_velocity((v as Vector3).normalized() * max_s)


## ADR 0036: advance entity ages + stage thresholds. dt=tick_seconds so
## a year_seconds=900 template ages tick_seconds/900 years per tick.
## No-op when no entity has a lifecycle template registered.
func _tick_lifecycle_director() -> void:
	var lc := get_node_or_null("LifecycleDirector")
	if lc != null and lc.has_method("tick"):
		lc.tick(scheduler.env, tick_seconds)


## ADR 0014: chunk streamer loads/unloads around the active actor.
## No-op (returns immediately) on single-chunk legacy games — those
## never instantiate a chunk_streamer.
func _stream_chunks_if_active() -> void:
	if chunk_streamer == null:
		return
	var actor_id := _find_actor_id()
	if actor_id == "":
		return
	chunk_streamer.update(scheduler.env, actor_id)


## Tier 2.6j: entities with state.lifetime > 0 auto-decrement each tick
## removed when lifetime reaches 0. Standard pattern for transient entities
## (bullets, particles, sparkles, "+10" damage numbers).
##
## Entities without a lifetime field are unaffected. Lifetime is in TICKS,
## not seconds — keeps it predictable across tick_seconds settings.
func _decrement_lifetimes() -> void:
	var to_remove: Array[String] = []
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity):
			continue
		var lf = (ent as Entity).get_state("lifetime", null)
		if lf == null:
			continue
		var lifetime := float(lf)
		if lifetime <= 0.0:
			continue
		lifetime -= 1.0
		(ent as Entity).set_state("lifetime", lifetime)
		if lifetime <= 0.0:
			to_remove.append(str(id))
	# Remove after iteration so we don't mutate the dict mid-loop.
	# Route through SpawnManager.despawn for unified cleanup
	# (relations + spatial_index + physics body + queue_free) — per
	# ADR 0044 Condition 4 body-leak prevention.
	for id in to_remove:
		_spawn_manager.despawn(id)


# ============================================================
# PER-FRAME: input polling + motion + sim-tick accumulator
# ============================================================
#
# Yume's frame-rate vs sim-rate split:
#   - FRAME-rate work runs every call to _process: input sampling
#     (~16ms latency target), smooth motion integration with continuous
#     delta, ground-clamp after motion.
#   - SIM-rate work runs only when the accumulator crosses tick_seconds:
#     scheduler.tick + AI policies + lifetime decay + pending drains.
#     Rule `interval: N` means "fire every N sim-ticks" — discrete
#     count, hardware-independent.
#
# Determinism (2026-05-12 design decision): the rate split is
# load-bearing. Coupling sim-ticks to frame rate would make rule
# cascades, lifetime decay, and AI cadence hardware-dependent and
# break scenario tests + save-state reproducibility. See ADR 0001
# (seven primitives — Trigger.tick is discrete) and the post-mortem
# entry that catalogs the failure modes.


func _process(delta: float) -> void:
	if scheduler == null:
		return
	# --- FRAME-rate work (every call) -----------------------------------
	# Input polling lives in InputRegistrar (extracted 2026-05-11 — kept
	# the full input lifecycle co-located in one module). _find_actor_id
	# stays here because actor routing is world.gd's concern.
	(
		InputRegistrar
		. poll(
			scheduler,
			_find_actor_id(),
			input_actions_hold,
			input_actions_press,
			stop_action_on_idle,
			entities,
		)
	)
	_motion_integrator.integrate(delta)
	# Ground primitive (Tier 2.6r): if scene.json declares a ground.y,
	# clamp tagged "creature" entities to that Y, and remove tagged
	# "projectile" entities that drop below it. Applied after motion.
	_ground_constraint.apply()
	# --- SIM-rate work (only when accumulator crosses tick_seconds) -----
	# Inlined from former WorldClock child Node on 2026-05-12 — no signal
	# hop, same delta-accumulator pattern.
	_tick_elapsed += delta
	if _tick_elapsed < tick_seconds:
		return
	_tick_elapsed -= tick_seconds
	_tick_count += 1
	# ADR 0011 + 0012: under modal/overlay freeze, suppress the sim tick.
	# Renderer keeps drawing the frozen scene; game-level pipelines (save
	# / level transition / reset) drain in GameShell._process at frame
	# rate so "Save" / "Travel" / "New Game" buttons still work.
	var freeze := int(world_state.get("screen_freeze_world", 0)) != 0
	freeze = freeze or int(world_state.get("overlay_freeze_world", 0)) != 0
	# ADR 0044 Invariant #10: PhysicsServer3D pauses with the sim. Rigid
	# integration / kinematic movement / queries all halt; Godot animation
	# / tween / audio continue.
	PhysicsServer3D.set_active(not freeze)
	if freeze:
		return
	advance_one_tick()
	if verbose and _tick_count % 4 == 0:
		_print_tick_summary(_tick_count)


## Tier 2.6o Phase 3 — accumulate mouse motion across the frame.
## GameShell drains env.mouse_delta in first/third-person camera modes
## to update the actor's state.facing (yaw). Set + reset per frame.
func _input(event: InputEvent) -> void:
	if scheduler == null:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var current = scheduler.env.get("mouse_delta", Vector2.ZERO)
		if not (current is Vector2):
			current = Vector2.ZERO
		scheduler.env["mouse_delta"] = (current as Vector2) + motion.relative


## ADR 0016: resolve which entity should receive input this frame.
## Routes through actor_manager (single code path per ADR 0016).
## The legacy `actor_tag` scan fallback was removed 2026-05-11 — it
## was dead code in production paths AND silently masked authoring
## bugs in actors.json (a typoed starting_entity_tag would invisibly
## fall back to "player" tag instead of surfacing as "no actor entity
## found"). Returns "" if no entity matches; callers handle.
func _find_actor_id() -> String:
	if actor_manager == null:
		return ""  # auto_start=false test mode; no input routing
	return actor_manager.resolve_active_entity(entities)


## Per-frame motion + collision = MotionIntegrator coordinator
## (see coordinators/motion_integrator.gd). Per-frame ground clamp +
## projectile-despawn = GroundConstraint coordinator (see
## coordinators/ground_constraint.gd). _process delegates to both.

# Ground constraint config lives on _ground_constraint (above).
# WorldLoader.load_ground_cfg populates ground_y / clamp_tags / despawn_tags
# on that coordinator.

# ADR 0038: grid-based placement config. Loaded once from scene.json's
# `grid` block (mirroring _load_ground_cfg), exposed via env["scene_grid"]
# in _build_env. Empty dict = grid disabled (default for 13 existing demos
# that don't declare a grid block — backward-compat sentinel).
var _grid_cfg: Dictionary = {}

# ============================================================
# MULTI-LEVEL (ADR 0006)
# ============================================================
## Active level + progression. current_level == "" for single-level games.
var current_level: String = ""
var level_order: Array = []
var levels_root: String = ""
var on_all_complete_msg: String = ""


## Generic tick summary: total entity count + counts per common tag.
## Adapts to whatever tags the loaded data uses; silent if no common ones match.
func _print_tick_summary(count: int) -> void:
	var bits: Array = ["n=%d" % entities.size()]
	# Probe a small set of common tags. Add yours here if useful.
	var probe_tags := [
		"seed",
		"young",
		"mature",
		"rotten",
		"water",
		"player",
		"sparkle",
		"enemy",
		"projectile",
		"crop",
		"fire",
		"tree",
		"burning_tree",
		"ash",
		"grass",
		"rabbit",
		"fox",
		"animal",
		"predator",
		"prey",
		"bird",
		"iron_ore",
		"iron",
		"copper_ore",
		"copper",
		"fertilizer",
		"mushroom",
		"seedling",
		"weather",
		"bush",
		"square",
		"piece",
	]
	for t in probe_tags:
		var n := QueryLib.run({"tags_all": [t]}, _build_env()).size()
		if n > 0:
			bits.append("%s=%d" % [t, n])
	# If a "ctr_1" counter is present, show its state (demo convenience).
	var ctr = entities.get("ctr_1", null)
	if ctr is Entity:
		bits.append("ctr=%s" % (ctr as Entity).state)
	print("[t%d] %s" % [count, " ".join(bits)])


# ============================================================
# PUBLIC API
# ============================================================


func queue_input(action: String, params: Dictionary = {}) -> void:
	scheduler.queue_input(action, params)


func entity(id: String) -> Entity:
	return entities.get(id, null)


func count_entities_matching(spec: Dictionary) -> int:
	return QueryLib.run(spec, _build_env()).size()


func count_relations_of(type: String) -> int:
	return relations.count(type)


# ============================================================
# INTERNAL
# ============================================================


func _build_env() -> Dictionary:
	# ADR 0038: ensure grid config is loaded before any rule resolves it.
	# Idempotent — first call from any path triggers; subsequent are no-op.
	# Null guard: _build_env can be called from PhaseScheduler.new() in
	# _ready BEFORE _loader is set (one line later). Tests that construct
	# World.new() without going through _ready also hit this.
	if _loader != null:
		_loader.load_grid_cfg()
	return {
		"entities": entities,
		"defs": defs,
		"relations": relations,
		"spatial_index": spatial_index,
		"world": world_state,
		"parent": self,
		"next_id": next_id_seq,
		"error_buffer": error_buffer,
		# ADR 0011: ScreenFlow drains transition_screen / quit_app /
		# show_toast / reload_scene effects from this buffer. Lazily created
		# by effect_apply if no ScreenFlow is mounted (harmless — events
		# accumulate and stay quiet).
		"screen_event_buffer": [],
		# ADR 0012: OverlayManager drains show_overlay / dismiss_overlay
		# effects from this buffer.
		"overlay_event_buffer": [],
		# ADR 0031: zone-state primitive. Always non-null (empty store is
		# fine — backward-compat for demos with no world/zones.json).
		"zone_store": zone_store,
		# ADR 0038: grid config (empty dict = grid disabled). Step runner +
		# build_place + SpawnManager.spawn all read this via GridSnap helpers.
		"scene_grid": _grid_cfg,
	}
