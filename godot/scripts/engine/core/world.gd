extends Node

class_name World

## Top-level orchestrator. Owns canonical engine state (entities, scheduler,
## relations, spatial index, world_state) and the coordinators that drive
## each subsystem. Almost all behavior lives in the coordinators; World's
## job is to construct them and sequence the per-frame + per-tick calls.
##
## Contract: docs/guideline/30_framework_primitives.md § "File layout after redesign"
##
## Renderer-agnostic. Extends plain Node — no transform. Entities are
## children; each gets a positioned renderer node (Sprite2D / MeshInstance3D)
## that reads state.position. Same script powers world_2d.tscn and
## world_3d.tscn.

@export_dir var data_root: String = ""  # e.g. "res://data/demo_aldenmere/"
@export var auto_start: bool = true
@export var tick_seconds: float = 0.0167  # 60Hz — matches Godot's physics_fps default. Override per-game only with a documented reason (see CLAUDE.md § "Tick rate is the engine's heartbeat").
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
## `world.*` binding store. ADR 0047: this dict is shared by reference
## with the `_engine` singleton entity's state — writes via either path
## update the same data. Reserved for ENGINE bookkeeping only:
##   active_actor_id, has_save, current_screen, screen_freeze_world,
##   overlay_freeze_world, current_level, current_chunk, ...
## Game state belongs on tagged singleton entities (world_clock, etc.),
## not here. See `.claude/rules/data-demo.md` § world-state singleton.
var world_state: Dictionary = {}
var next_id_seq: Dictionary = {"_": 0}  # shared spawn-id counter
var error_buffer: Array = []  # Tier 2.6a structured errors
var _overlap_events: Array = []  # ADR 0070 — area overlap event buffer
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
# STATE — trajectory recording (ADR 0058 audit follow-up)
# ============================================================
#
# When set_trajectory_recorder(path) is called, World opens a JSONL
# file and writes one row per tick capturing (state, actions). This
# is the explicit-world-model → implicit-world-model bridge per
# docs/guideline/00_what_yume_is.md. The recorder is opt-in; default is null
# (no recording, no overhead).

var _trajectory_file: FileAccess = null
var _trajectory_path: String = ""
var _trajectory_scenario: String = ""

# ADR 0060 Part 1 — determinism oracle. When --hash-log=<path> is on the
# cmdline, World appends {"tick", "hash", "ents"} per tick (after each
# advance_one_tick) via DeterminismHash.canonical(). Hooked at the canonical
# tick body so it works under ANY driver (scenario_runner, capture_runner).
var _hash_log_file: FileAccess = null

# ============================================================
# STATE — multi-level progression (ADR 0006)
# ============================================================
#
# current_level is a property that proxies to world_state["current_level"]
# — single source of truth per ADR 0047. Engine code reading
# `_world.current_level` and content formulas reading `world.current_level`
# both reach the same dict entry. Defaults to "" for single-level games.
# level_order / levels_root / on_all_complete_msg are engine-only fields
# (no formula access needed).

var current_level: String:
	get:
		return str(world_state.get("current_level", ""))
	set(value):
		world_state["current_level"] = value

var level_order: Array = []
var levels_root: String = ""
var on_all_complete_msg: String = ""

# ============================================================
# STATE — boot-cached scene config
# ============================================================
#
# Populated by WorldLoader during load_data(). Exposed to rules via
# _build_env()'s scene_grid entry. Empty dict = grid disabled
# (backward-compat sentinel for demos without a grid block in scene.json).

var _grid_cfg: Dictionary = {}  # ADR 0038 grid-based placement

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
	_apply_debug_flags()
	_apply_hash_log_flag()
	_init_stores()
	_init_coordinators()
	if auto_start:
		start()


## ADR 0060 — open the determinism hash log if --hash-log=<path> is present.
## World-level (not capture_runner-level) so the hash sequence is logged under
## whatever drives the canonical tick — scenario_runner (tick-locked, the
## oracle's driver) OR capture_runner (real-time). One {tick,hash,ents} JSONL
## row per advance_one_tick.
## Tracks hash-log paths opened in THIS process so multiple Worlds (e.g. the
## scenario_runner's fresh-World-per-scenario) ACCUMULATE into one log instead
## of each truncating it. The oracle deletes the file before each process run,
## so the first World creates it (WRITE) and later Worlds append.
static var _hash_paths_opened: Dictionary = {}


func _apply_hash_log_flag() -> void:
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s.begins_with("--hash-log="):
			var path := s.substr(11)
			if _hash_paths_opened.has(path) and FileAccess.file_exists(path):
				_hash_log_file = FileAccess.open(path, FileAccess.READ_WRITE)
				if _hash_log_file != null:
					_hash_log_file.seek_end()  # append, don't truncate
			else:
				_hash_log_file = FileAccess.open(path, FileAccess.WRITE)
			if _hash_log_file == null:
				push_warning("[world] could not open hash-log: %s" % path)
			else:
				_hash_paths_opened[path] = true
				if verbose:
					print("[World] determinism hash-log → ", path)
			return


## Read debug flags from cmdline + scene.json BEFORE physics bodies are
## created, so Godot's built-in collision-wireframe drawing picks them up.
##
## Enabled by either:
##   - cmdline:    --debug-colliders
##   - scene.json: { "debug": {"show_colliders": true} }
##
## Draws every CollisionShape3D / CollisionShape2D as a wireframe (Godot's
## built-in "Visible Collision Shapes" behavior). Useful for diagnosing
## mesh-vs-collider misalignment (e.g., "I can't jump on the bench" → its
## collider doesn't extend up to the bench's visual top).
##
## Per docs/guideline/00_what_yume_is.md, this is PROJECTION (debug overlay), not
## world-model state. Doesn't affect game behavior, only visualization.
func _apply_debug_flags() -> void:
	var show_colliders := false
	for arg in OS.get_cmdline_user_args():
		if str(arg) == "--debug-colliders":
			show_colliders = true
			break
	if not show_colliders and data_root != "":
		var scene_path := data_root.rstrip("/") + "/scene.json"
		if FileAccess.file_exists(scene_path):
			var f := FileAccess.open(scene_path, FileAccess.READ)
			if f != null:
				var raw := f.get_as_text()
				f.close()
				var sj := JSON.new()
				if sj.parse(raw) == OK and sj.data is Dictionary:
					var debug_cfg = (sj.data as Dictionary).get("debug", {})
					if debug_cfg is Dictionary:
						show_colliders = bool(debug_cfg.get("show_colliders", false))
	if show_colliders:
		get_tree().debug_collisions_hint = true
		if verbose:
			print("[World] collider debug overlay ON")


## Shutdown cleanup (2026-05-21). Clears engine-side static caches that
## survive the SceneTree teardown — otherwise Godot reports "ObjectDB
## instances leaked at exit" + "1 resources still in use at exit" at
## game-quit time. Cosmetic warnings (OS reclaims memory), but tidy.
##
## Targets:
##   - GroundRenderer: ShaderMaterial + heightmap Image + params dict
##   - Formula:        Expression cache (RefCounted refs)
##
## Add new static-cache cleanups here as the engine grows them. The
## _exit_tree hook fires when the World node leaves the tree — which
## happens at game-quit before Godot's ObjectDB sweep, so cleanup
## lands BEFORE the warning would have been emitted.
func _exit_tree() -> void:
	GroundRenderer.cleanup()
	Formula.clear_cache()
	# MultiMeshDirector is a Node but NEVER added to the tree (held only
	# as world._multimesh_director). When World exits, its Node lingers
	# as an orphan → Godot reports "1 resources still in use at exit"
	# (the GDScript) + "Leaked instance: Node:... path: ''" + the
	# GDScript+GDScriptNativeClass refs that hold it. Free here so the
	# ref count drops to 0 before Godot's ObjectDB sweep.
	#
	# Empirical case 2026-05-21: --verbose at exit pointed at
	# multimesh_director.gd as the resource leak. The hint was right —
	# orphan Node, never queued.
	if _multimesh_director != null and is_instance_valid(_multimesh_director):
		_multimesh_director.free()
		_multimesh_director = null
	# Close trajectory recorder if open (ADR 0058 audit follow-up).
	stop_trajectory_recording()


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
	_ground_constraint = GroundConstraint.new(self)
	_level_transitions = LevelTransitionCoordinator.new(self)
	_save_load = SaveLoadCoordinator.new(self)
	_world_reset = WorldResetCoordinator.new(self)


## Look for `--game=<name>` in user args. The user-args separator `--`
## is required so Godot doesn't try to interpret these as engine flags.
## Game names are folder names under `res://data/` (e.g. `demo_aldenmere`).
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
## state from `data_root/`. Boot sequence is in WorldBoot (see
## coordinators/world_boot.gd) — its run() reads as a TOC of boot phases.
##
## Rules load first so that spawn-triggered rules can fire during initial
## entity load (per W0 finding on lifecycle-flush-at-load).
##
## ADR 0009 (Phase 5b sunset, 2026-05-05): single canonical layout —
## world/rules.json + game/goals.json + game/flow.json +
## levels/<name>/rules.json + world/state.json. Legacy single-file paths
## (world_rules.json, progression.json, world.json) are no longer
## consulted — all in-tree demos migrated. If you hit a "no rules
## loaded" warning on an old game, rename world_rules.json →
## world/rules.json (or split per Phase 3b classification).
func load_data() -> void:
	# Apply deterministic RNG seed if scene.json declares one. Required
	# for trajectory replay — without seeding, the global Random
	# continues from whatever state the previous run left it in, so
	# stochastic effects (rule chance rolls, scatter patterns, formula
	# randf() calls) drift between rollouts even with identical input
	# sequences. ADR 0058 audit follow-up (2026-05-23).
	_apply_world_seed_from_scene()
	WorldBoot.new(self).run()


func _apply_world_seed_from_scene() -> void:
	"""Read ground.mesh-adjacent `world_seed` from scene.json and seed
	the global RNG. Zero / unset = leave RNG to default (non-deterministic).
	Set to a non-zero int in scene.json to make rollouts deterministic."""
	if data_root == "":
		return
	var scene_path: String = data_root.rstrip("/") + "/scene.json"
	if not FileAccess.file_exists(scene_path):
		return
	var f := FileAccess.open(scene_path, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()
	var sj := JSON.new()
	if sj.parse(raw) != OK or not (sj.data is Dictionary):
		return
	var cfg: Dictionary = sj.data
	if not cfg.has("world_seed"):
		return
	var s = cfg["world_seed"]
	if not (s is int or s is float):
		return
	var seed_int := int(s)
	if seed_int == 0:
		return
	seed(seed_int)
	if verbose:
		print("[World] seeded RNG with world_seed=%d" % seed_int)


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


## ADR 0063 — runtime spawn/despawn from a driver (e.g. client-server netcode
## spawning a player on join). Thin public wrappers over SpawnManager so io/
## drivers don't reach into the private member. `inst` is the same dict shape as
## initial_instances ({def, id, position, state, ...}).
func spawn_instance(inst: Dictionary) -> void:
	if _spawn_manager != null:
		_spawn_manager.spawn(inst)


func despawn_entity(id: String) -> void:
	if _spawn_manager != null:
		_spawn_manager.despawn(id)


## Build the physics body for a RUNTIME-spawned entity (the `spawn` effect),
## restoring parity with SpawnManager.spawn's initial-instance path. Without
## this, rule-spawned entities (projectiles, summoned NPCs) get a renderer but
## NO physics body, so they can't move — only initial instances did. Called by
## EffectCore.spawn via env.parent. Empirical 2026-06-06 (doomarena3d): runtime
## monsters + bullets were frozen at spawn because only initial instances built
## bodies.
func build_runtime_physics_body(ent: Entity) -> void:
	if _spawn_manager != null and ent is Entity:
		_spawn_manager._build_physics_body_if_declared(ent)


## Attach the per-entity renderer (entity_mesh_3d / entity_sprite_2d) to a
## RUNTIME-spawned entity — parity with SpawnManager.spawn's initial path.
## _attach_renderer lives on SpawnManager, so EffectCore.spawn (which only has
## env.parent == this World) could never reach it: its `parent.has_method(
## "_attach_renderer")` guard was ALWAYS false, so rule-spawned entities got a
## collider but NO MESH — invisible. Empirical 2026-06-06 (doomarena3d): the
## debug-collider capsule showed where a monster was, but the monster itself
## was never drawn.
func attach_runtime_renderer(ent: Entity) -> void:
	if _spawn_manager != null and ent is Entity:
		_spawn_manager._attach_renderer(ent)


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
	# Increment the monotonic sim-tick counter HERE (not in _tick_due) so
	# step_runner-driven advances also bump it. velocity_add_relative
	# (ADR 0048) reads ws._tick to detect "first fire this tick" for the
	# auto-reset; without the bump the counter stays stale and velocity
	# accumulates without reset → scenario tests fail with vel >>1
	# magnitudes. Empirical case 2026-05-16.
	_tick_count += 1
	world_state["_tick"] = _tick_count
	if actor_manager != null:
		actor_manager.tick_policies(scheduler.env)  # ADR 0018 — AI before input
	scheduler.tick()  # canonical phase loop (lifetime decay via ADR 0049 rules)
	_tick_lifecycle_director()  # ADR 0036
	_stream_chunks_if_active()  # ADR 0014
	if actor_manager != null:
		actor_manager.process_pending(scheduler.env, world_state, verbose)  # ADR 0016
	# Trajectory recording (opt-in, ADR 0058 audit follow-up /
	# docs/guideline/00_what_yume_is.md § "Bridging to implicit world models").
	# Set via set_trajectory_recorder(path); writes one JSONL row per
	# tick capturing (state_t, actions_applied_this_tick). Paired
	# consecutive rows give (state_t, action_t, state_{t+1}) triples
	# for training an implicit world model from explicit rollouts.
	if _trajectory_file != null:
		_write_trajectory_row()
	write_hash_log_row()  # ADR 0060 (no-op unless --hash-log)


## ADR 0060 — append one {tick, hash, ents} row for the just-completed tick.
## Public + no-op unless --hash-log is active, so the LEGACY scenario loop
## (scenario_runner, which calls scheduler.tick() directly and bypasses
## advance_one_tick) can trigger it manually — same pattern as
## _write_trajectory_row. Hooked at both tick paths = every demo audited.
func write_hash_log_row() -> void:
	if _hash_log_file == null:
		return
	var d: Dictionary = DeterminismHash.canonical(self)
	_hash_log_file.store_line(JSON.stringify({
		"tick": _tick_count,
		"hash": d["hash"],
		"ents": d["ents"],
	}))
	_hash_log_file.flush()  # survive a killed process mid-run


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
#
# Clock coherence (ADR 0068, 2026-06-11): the sim-tick gate runs in
# _physics_process, NOT _process. Character bodies (ADR 0044) integrate
# on the physics clock; if ticks drained on the render clock, a loaded
# instance (frame rate < tick rate) slides the RULE clock to frame rate
# while physics catches up to wall time — multiple body steps integrate
# a stale velocity_set between steering decisions. Empirical: autorace
# net record 2026-06-11, cars burst to 5x top_speed + cut corners 10.9m
# off-line on a ~15fps server. One clock for rules + integration; under
# load both dilate together instead of skewing.


## Frame-rate work — reads top-to-bottom as the per-frame flow:
##   - input poll (16ms latency target; skipped under freeze)
##   - ground clamp
##   - frame_tick rules (ADR 0050 — content-authored per-frame behaviors)
## The sim-tick gate lives in _physics_process (ADR 0068).
func _process(_delta: float) -> void:
	if scheduler == null:
		return
	# GENERIC external-tick-driver seam (NOT lockstep-specific): when something
	# outside World owns ticking, World must not auto-advance. Today that's the
	# lockstep netcode (ADR 0061); the same flag serves any future model (rollback,
	# server-sync, replay) or tooling — the engine core stays model-agnostic, each
	# driver is a sibling in io/. Set by the driver's autoload _ready, before this
	# node's first _process (StdioStepDriver uses set_process(false) directly).
	if Engine.has_meta("yume_external_tick_driver"):
		return
	# NOTE (ADR 0069): _poll_input moved to _physics_process. Polling here
	# (display rate) made hold-action cadence FRAME-RATE-DEPENDENT: at 8
	# fps a held key fired 8×/s against rules firing 60×/s, so any
	# per-tick opposing force (drag, decay) overpowered held input.
	# Empirical 2026-06-11: autorace coast_drag (0.05/tick) made W/S
	# unresponsive on a machine rendering ~8-19 fps.
	_ground_constraint.apply()
	scheduler.fire_frame_tick()  # ADR 0050 — per-frame content rules


## Sim-rate work (ADR 0068): the tick gate runs on the physics clock so
## rules and body integration can never skew. delta here is FIXED
## (1/physics_fps) and Godot's physics catch-up calls this multiple times
## per frame under load — sim ticks inherit that catch-up 1:1.
## The bounded drain loop serves tick_seconds < physics dt (e.g. a 120Hz
## game on 60Hz physics needs 2 ticks per step); 8 caps runaway debt.
##   - freeze gate (modal/overlay screens pause the sim, ADR 0011/0012)
##   - advance_one_tick — kept as a public method because step_runner.gd
##     calls it directly for headless tests + capture VQA (bypasses freeze)
func _physics_process(delta: float) -> void:
	if scheduler == null:
		return
	if Engine.has_meta("yume_external_tick_driver"):
		return
	var frozen := (
		int(world_state.get("screen_freeze_world", 0)) != 0
		or int(world_state.get("overlay_freeze_world", 0)) != 0
	)
	# ADR 0044 Invariant #10: PhysicsServer3D pauses with the sim.
	# Godot animation / tween / audio continue regardless.
	PhysicsServer3D.set_active(not frozen)
	if frozen:
		# Freeze also skips _poll_input — otherwise actions queue up in
		# scheduler.input_queue and re-fire when the screen pops.
		# Empirical 2026-05-16: pressing I inside the inventory screen
		# queued open_inventory; Close → queued I drained → inventory
		# reopened ("flash" UX). Screen-level global_inputs poll
		# Godot.Input directly, so they still work during freeze.
		return
	# ADR 0069: input polls on the PHYSICS clock, once per step, BEFORE
	# the tick gate — so a held action fires once per sim tick at any
	# render frame rate (the documented `edge: "hold"` contract). Godot
	# tracks is_action_just_pressed per physics frame separately, so
	# press-edges fire exactly once here too. Catch-up steps (multiple
	# _physics_process calls per render frame under load) each poll —
	# held keys correctly fire once per recovered tick.
	_poll_input()
	# Snap: tick_seconds within 0.5% of the physics step means "one tick per
	# step", exactly. Without this, 0.0167 vs 1/60 (a 33ppm rounding gap)
	# starves the accumulator into skipping one tick every ~8s — recorded as a
	# single 2-step displacement spike (empirical 2026-06-11: both autorace
	# cars logged a 25 u/s one-tick burst at the same tick, once per record).
	if absf(tick_seconds - delta) < delta * 0.005:
		advance_one_tick()
		if verbose and _tick_count % 4 == 0:
			_print_tick_summary(_tick_count)
		return
	var drained := 0
	while _tick_due(delta) and drained < 8:
		advance_one_tick()
		drained += 1
		delta = 0.0  # accumulator already credited this step's delta
	if verbose and drained > 0 and _tick_count % 4 == 0:
		_print_tick_summary(_tick_count)


## Drain the real-time delta accumulator. Returns true when one sim-tick
## should fire this frame, false otherwise. Mutates _tick_elapsed only —
## the _tick_count increment + world_state["_tick"] write are in
## advance_one_tick so both _process and step_runner paths bump the
## counter equivalently.
##
## Determinism (2026-05-12 design decision): the rate split is
## load-bearing. Coupling sim-ticks to frame rate would make rule
## cascades + AI cadence hardware-dependent and break scenario tests
## + save reproducibility. See ADR 0001 (Trigger.tick is discrete).
func _tick_due(delta: float) -> bool:
	_tick_elapsed += delta
	if _tick_elapsed < tick_seconds:
		return false
	_tick_elapsed -= tick_seconds
	# Counter bump moved into advance_one_tick (2026-05-16) so step_runner
	# paths also increment world_state["_tick"].
	return true


## InputRegistrar polls Godot's InputMap for press-edge + held actions
## and queues them onto the active actor via scheduler.queue_input.
## _find_actor_id resolves "who is the player right now" (ADR 0016).
func _poll_input() -> void:
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


## Forward Godot's per-event input lifecycle into InputRegistrar.
## Mouse-motion delta accumulation lives in InputRegistrar.handle_event
## next to the keyboard polling sibling — both are Godot-API bridges.
func _input(event: InputEvent) -> void:
	InputRegistrar.handle_event(event, scheduler)


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


## Per-frame motion: ADR 0045 — CharacterBody3D._physics_process per
## actor body (Godot drives this at 60Hz in C++). Per-frame ground
## clamp + projectile-despawn = GroundConstraint (see
## coordinators/ground_constraint.gd). _process drives only the
## ground clamp + sim-tick accumulator now.

# Ground constraint config lives on _ground_constraint (above).
# WorldLoader.load_ground_cfg populates ground_y / clamp_tags / despawn_tags
# on that coordinator. Multi-level + grid_cfg state declared in the top
# STATE blocks (see top of file).


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

## Sibling Director nodes (mounted by per-game .tscn) that need a
## register/apply call once World finishes loading. Columns:
##   [0] node_name      — name of the sibling Node in the scene tree
##   [1] method_name    — method to invoke (verified via has_method)
##   [2] args_pattern   — "none" / "env" / "root_env"
##
## Each row is optional at runtime — absence of the Node is
## backward-compat for games not using that ADR's capability. To add
## a new ADR director, add one row (no per-director branch needed).
const _BOOT_DIRECTORS: Array = [
	# ADR 0013 — settings overrides (audio bus, input mapping, etc.).
	# Schema + config loaded in SettingsManager._ready; deferred apply
	# here so EffectApply has a valid env.
	["SettingsManager", "apply_all", "none"],
	# ADR 0029 — schedule slot resolution per entity def's `schedule`.
	["ScheduleDirector", "register_schedules_from_env", "env"],
	# ADR 0036 — lifecycle stage tables per entity def's `lifecycle`.
	["LifecycleDirector", "register_lifecycles_from_env", "env"],
	# ADR 0030 — class defs from <root>/classes/*.json.
	["ClassManager", "register_classes_from_data_root", "root_env"],
	# ADR 0033 — tech tree defs from <root>/tech_trees.json.
	["TechTreeDirector", "register_trees_from_data_root", "root_env"],
]


func _mount_boot_directors(root: String) -> void:
	for entry in _BOOT_DIRECTORS:
		var node_name: String = entry[0]
		var method_name: String = entry[1]
		var args_pattern: String = entry[2]
		var dir := get_node_or_null(node_name)
		if dir == null or not dir.has_method(method_name):
			continue
		match args_pattern:
			"none":
				dir.call(method_name)
			"env":
				dir.call(method_name, scheduler.env)
			"root_env":
				dir.call(method_name, root, scheduler.env)


# ============================================================
# ADR 0070 — physics area overlap monitor
# ============================================================


## Wire a PhysicsServer3D area's monitor callback to this World.
## Called by SpawnManager after building a body_type:"area" entity.
func register_area_monitor(area_rid: RID, area_entity_id: String) -> void:
	PhysicsServer3D.area_set_monitor_callback(area_rid, _on_area_overlap.bind(area_entity_id))


## PhysicsServer monitor callback (fires during the physics step).
## Buffers only — rules run in the react phase of the next sim tick, so
## overlap dispatch stays inside the tick's phase discipline. The EVENT
## ORIGIN is Godot physics and therefore not cross-machine deterministic;
## per ADR 0070, overlap rules are presentation-grade.
func _on_area_overlap(
	status: int, _body_rid: RID, instance_id: int, _body_shape: int, _self_shape: int,
	area_entity_id: String,
) -> void:
	var change := ""
	if status == PhysicsServer3D.AREA_BODY_ADDED:
		change = "enter"
	elif status == PhysicsServer3D.AREA_BODY_REMOVED:
		change = "exit"
	else:
		return
	var body_eid := _entity_id_from_instance(instance_id)
	if body_eid == "" or body_eid == area_entity_id:
		return
	_overlap_events.append({"a": area_entity_id, "b": body_eid, "change": change})


## Resolve a physics callback's object instance id to a Yume entity id.
## RID bodies carry the Entity node's id (build_3d attaches it);
## character bodies resolve via the CharacterBody3D node's entity_ref.
func _entity_id_from_instance(iid: int) -> String:
	var obj = instance_from_id(iid)
	if obj == null:
		return ""
	if obj is Entity:
		return (obj as Entity).instance_id
	if obj is CharacterBodyRunner:
		var er = (obj as CharacterBodyRunner).entity_ref
		if er != null:
			return str(er.instance_id)
	return ""


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
		# ADR 0070 — physics area overlap events, appended by
		# _on_area_overlap, drained by PhaseScheduler._phase_react.
		"overlap_events": _overlap_events,
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


# ============================================================
# TRAJECTORY RECORDING (ADR 0058 audit follow-up)
# ============================================================
#
# Opt-in JSONL-per-tick world-state dump. Bridges the explicit world
# model (Yume's JSON-spec'd rollouts) to implicit world model
# trainers (DreamerV3, MuZero, etc. — see docs/guideline/00_what_yume_is.md
# § "Bridging to implicit world models").


## Open a trajectory file. Subsequent ticks write one JSONL row each
## containing (tick, scenario, actions_applied_this_tick, entities,
## world_state). Paired consecutive rows give (state_t, action_t,
## state_{t+1}) triples. Call stop_trajectory_recording() to close.
## Returns true on success.
func set_trajectory_recorder(path: String, scenario_name: String = "") -> bool:
	if _trajectory_file != null:
		_trajectory_file.close()
	_trajectory_file = FileAccess.open(path, FileAccess.WRITE)
	if _trajectory_file == null:
		push_warning("[world] could not open trajectory file: %s" % path)
		_trajectory_path = ""
		return false
	_trajectory_path = path
	_trajectory_scenario = scenario_name
	return true


## Close + flush the trajectory file. Safe to call without an open
## recorder (no-op).
func stop_trajectory_recording() -> void:
	if _trajectory_file != null:
		_trajectory_file.close()
		_trajectory_file = null


## Record the inputs about to be applied this tick. ScenarioRunner /
## StepRunner / capture_runner can call this immediately before
## advance_one_tick() to associate inputs with the resulting state.
## The list is consumed (cleared) by _write_trajectory_row.
var _trajectory_actions_this_tick: Array = []


func record_trajectory_action(action_name: String) -> void:
	_trajectory_actions_this_tick.append(action_name)


## Internal: write one JSONL row capturing the just-completed tick.
## Called from advance_one_tick() AFTER scheduler.tick() — captures
## state_{t+1} (the result of this tick's actions).
func _write_trajectory_row() -> void:
	if _trajectory_file == null:
		return
	var ents: Dictionary = {}
	for id in entities:
		var e = entities[id]
		if not (e is Entity):
			continue
		var ent: Entity = e
		var state_subset: Dictionary = {}
		for k in ent.state.keys():
			var ks: String = str(k)
			if ks.begins_with("_"):
				continue
			var v = ent.state[k]
			if v is int or v is float or v is String or v is bool:
				state_subset[ks] = v
			elif v is Vector2:
				state_subset[ks] = [v.x, v.y]
			elif v is Vector3:
				state_subset[ks] = [v.x, v.y, v.z]
			elif v is Array and v.size() <= 8:
				state_subset[ks] = v.duplicate()
		var pos = ent.get_position()
		var pos_arr: Array
		if pos is Vector3:
			pos_arr = [pos.x, pos.y, pos.z]
		elif pos is Vector2:
			pos_arr = [pos.x, pos.y]
		else:
			pos_arr = []
		ents[id] = {
			"def": ent.def_id,
			"pos": pos_arr,
			"state": state_subset,
			"tags": ent.tags.duplicate() if ent.tags is Array else [],
		}
	var ws: Dictionary = {}
	for k in world_state.keys():
		var ks: String = str(k)
		if ks.begins_with("_"):
			continue
		var v = world_state[k]
		if v is int or v is float or v is String or v is bool:
			ws[ks] = v
	var row: Dictionary = {
		"tick": _tick_count,
		"scenario": _trajectory_scenario,
		"actions": _trajectory_actions_this_tick.duplicate(),
		"entities": ents,
		"world_state": ws,
	}
	_trajectory_file.store_line(JSON.stringify(row))
	_trajectory_actions_this_tick.clear()
