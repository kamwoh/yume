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

@export_dir var data_root: String = ""  # e.g. "res://data/demo_aldenmere/"
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
# STATE — multi-level progression (ADR 0006)
# ============================================================
#
# current_level == "" for single-level games. level_order +
# levels_root + on_all_complete_msg are populated by
# WorldLoader.load_progression when game/flow.json is present.

var current_level: String = ""
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
## world/physics.json + game/rules.json + game/flow.json +
## levels/<name>/rules.json + world/state.json. Legacy single-file paths
## (world_rules.json, progression.json, world.json) are no longer
## consulted — all in-tree demos migrated. If you hit a "no rules
## loaded" warning on an old game, rename world_rules.json →
## world/physics.json (or split per Phase 3b classification).
func load_data() -> void:
	WorldBoot.new(self).run()


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
	_pretick_velocity_zero()  # ADR 0040 — reset additive WASD accumulators
	if actor_manager != null:
		actor_manager.tick_policies(scheduler.env)  # ADR 0018 — AI before input
	scheduler.tick()  # canonical phase loop
	_tick_lifecycle_director()  # ADR 0036
	_decrement_lifetimes()  # Tier 2.6j
	_stream_chunks_if_active()  # ADR 0014
	if actor_manager != null:
		actor_manager.process_pending(scheduler.env, world_state, verbose)  # ADR 0016


## ADR 0040: zero velocity for opt-in actors before the input phase.
## Camera-relative WASD adds velocity each tick (velocity_add_relative);
## without a pretick reset, contributions accumulate across sim ticks
## and the actor glides after key release. This is a sim-tick discipline
## concern (state hygiene between input phases), not motion integration —
## kept in world.gd post-ADR-0045 even though motion moved to Godot's
## CharacterBody3D.
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
	# Motion: ADR 0045 — actors with body_type:"character" drive their own
	# CharacterBody3D._physics_process at 60Hz. Engine no longer iterates
	# entities for motion; Godot does it per-body in optimized C++.
	# Ground primitive (Tier 2.6r): if scene.json declares a ground.y,
	# clamp tagged "creature" entities to that Y, and remove tagged
	# "projectile" entities that drop below it.
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
