extends Node
class_name World

## Top-level orchestrator. Owns the entity map, definitions, relation store,
## phase scheduler, world clock, and global world-state dictionary.
##
## Contract: docs/30_framework_primitives.md § "File layout after redesign"
##
## **Renderer-agnostic.** World extends plain Node — no transform of its own.
## Entities (also plain Node) are children. Each entity gets a positioned
## RENDERER child attached (Sprite2D for 2D scenes, MeshInstance3D for 3D),
## which reads `entity.state.position` and updates its own transform per
## frame. Camera2D / Camera3D live as siblings of entities in the scene
## tree. Same World script powers both world_2d.tscn and world_3d.tscn.

@export_dir var data_root: String = ""       # e.g. "res://data/demo_ecology/"
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
# STATE
# ============================================================

var entities: Dictionary = {}                 # instance_id → Entity
var defs: Dictionary = {}                     # def_id → entity definition dict
var relations: RelationStore = null
var spatial_index: SpatialIndex = null        # W3 — bucket hash for radius queries
var scheduler: PhaseScheduler = null
var world_state: Dictionary = {}              # global "world.*" bindings
var next_id_seq: Dictionary = {"_": 0}        # shared counter for spawns
var _clock: WorldClock = null
## Tier 2.6a — accumulating buffer of structured engine errors. Shared
## by reference into `env.error_buffer`; readable by qa-tester / VQA /
## LLM agents. Drain with `EngineError.drain(env)` between scenarios.
var error_buffer: Array = []
## ADR 0010 — save/load policy loaded from <data_root>/save_policy.json.
## Empty if the game hasn't opted in to persistence; save_state /
## load_state effects are no-ops when empty.
var save_policy: Dictionary = {}
## ADR 0019 — per-game macro expander. Loaded once at game start;
## passed into every Rule.load_from_file call so macro references in
## any rules file (world/physics.json, game/rules.json, levels/<n>/rules.json,
## tutorial.json) are expanded uniformly.
var macro_expander = null
## ADR 0016 — multi-actor manager. Loaded at game start; synthesizes a
## default single-actor config if no actors.json present (zero-migration
## for legacy demos). active_actor_id mirrored into world_state for
## binding readers (camera follow, input dispatch).
var actor_manager = null
## SpawnManager (extracted from world.gd 2026-05-11). Owns the entity
## spawn pipeline + renderer-attach + persistent-clobber guard + grid
## snap + renderer_cfg cache. Single public entry: `spawn(inst)`.
var _spawn_manager: SpawnManager = null
## LevelTransitionCoordinator (extracted from world.gd 2026-05-12).
## Owns ADR 0006 multi-level pipeline: process_pending(env),
## do_transition(target), load_level(name).
var _level_transitions: LevelTransitionCoordinator = null
## SaveLoadCoordinator (extracted from world.gd 2026-05-12). Owns
## ADR 0010 save/load pipeline: process_pending(env), do_save(slot),
## do_load(slot).
var _save_load: SaveLoadCoordinator = null
## WorldResetCoordinator (extracted from world.gd 2026-05-12). Owns
## Task #99 reset pipeline: process_pending(env), do_reset().
var _world_reset: WorldResetCoordinator = null
## WorldLoader (extracted from world.gd 2026-05-12). Owns boot-time
## JSON parsers: load_entities_path, load_entities_file, load_rules_file,
## load_world_file, load_zones_file, load_factions_file, load_progression,
## apply_level_seed_if_set, load_ground_cfg, load_grid_cfg. Loader is
## the SETTER; cached field values (ground_y, grid_cfg) live on World
## so tick-time code can read them without going through the loader.
var _loader: WorldLoader = null
## ADR 0014 — chunk streamer. Non-null only when the game opted into
## open-world mode by shipping a `world.json`. When null, single-chunk
## legacy behavior; all entities live in env.entities for the whole run.
## When non-null, _on_tick calls update() each tick.
var chunk_streamer: ChunkStreamer = null
## ADR 0031 — zone-state primitive. Hierarchical aggregate scope alongside
## entities + world_state. Always non-null (an empty store is fine);
## populated from world/zones.json if that file exists. Passed through env
## so effects (zone_state_*) and Formula (zone.X.Y bindings) can access it.
var zone_store: ZoneStore = null


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


## ADR 0044 Session C — free the cached collision-test sphere at exit.
## Without this, the SphereShape3D RID leaks (caught 2026-05-12 boot
## test: "1 RID allocation of type 'P12GodotShape3D' was leaked at exit").
func _exit_tree() -> void:
	if _physics_test_shape_3d.is_valid():
		PhysicsServer3D.free_rid(_physics_test_shape_3d)
		_physics_test_shape_3d = RID()


var _multimesh_director: MultiMeshDirector = null


func _ready() -> void:
	relations = RelationStore.new()
	spatial_index = SpatialIndex.new()
	# ADR 0031: zone_store always exists (empty until zones.json loads).
	# Empty store has no overhead and lets env.zone_store be non-null
	# everywhere — backward-compat for demos with no zones file.
	zone_store = ZoneStore.new()
	scheduler = PhaseScheduler.new(_build_env())
	_spawn_manager = SpawnManager.new(self)
	_level_transitions = LevelTransitionCoordinator.new(self)
	_save_load = SaveLoadCoordinator.new(self)
	_world_reset = WorldResetCoordinator.new(self)
	_loader = WorldLoader.new(self)
	if auto_start:
		start()


func start() -> void:
	if data_root != "":
		load_data()
	_start_clock()


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
	# BEFORE any per-game JSON loader runs. Resolver runs cache-once;
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
	for n in (registered.get("press", []) as Array):
		if not (input_actions_press as Array).has(str(n)):
			input_actions_press.append(str(n))
	for n in (registered.get("hold", []) as Array):
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
	#   - per-tick update() in _on_tick handles drift loads/unloads
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
		world_state["has_save"] = 1 if SaveState.has_any_save(SaveLoadCoordinator.game_name_from_root(data_root), slots) else 0
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
		print("[World] loaded: %d defs, %d entities, %d relations%s" % [
			defs.size(), entities.size(), relations.count_total(), lvl_str
		])

# ADR 0041 — bootstrap the multimesh director (lazy-init on first use).
# Reads renderer.position_scale from SpawnManager's renderer_cfg cache
# (default 0.05) and passes World as parent so MultiMeshInstance3D nodes
# sit at world scope. The cache is owned by SpawnManager (extracted
# 2026-05-11) — multimesh reads it as a consumer.
func _ensure_multimesh_director() -> MultiMeshDirector:
	if _multimesh_director != null: return _multimesh_director
	_multimesh_director = MultiMeshDirector.new()
	var cfg: Dictionary = _spawn_manager.renderer_cfg() if _spawn_manager != null else {}
	var ps: float = float(cfg.get("position_scale", 0.05))
	_multimesh_director.configure(self, ps)
	return _multimesh_director


func _run_multimesh_director() -> void:
	# Static-only optimization — skip when no entities use 3D renderer.
	# Also skip when renderer_script is empty (headless test mode).
	if renderer_script == "": return
	if not renderer_script.contains("entity_mesh_3d"): return
	var dir := _ensure_multimesh_director()
	var stats := dir.scan_and_batch(scheduler.env)
	if verbose and stats.get("groups", 0) > 0:
		print("[MULTIMESH-BUILD] entities=%d groups=%d instances=%d" % [
			stats.get("entities", 0),
			stats.get("groups", 0),
			stats.get("instances", 0),
		])




# ============================================================
# CLOCK
# ============================================================

func _start_clock() -> void:
	_clock = WorldClock.new()
	_clock.name = "WorldClock"
	_clock.tick_seconds = tick_seconds
	add_child(_clock)
	_clock.tick.connect(_on_tick)


func _on_tick(count: int) -> void:
	# ADR 0011 + 0012: when a screen OR overlay with freeze_world=true is
	# active, suppress simulation. Renderer keeps drawing the frozen scene
	# behind the modal/overlay. Input still routes to the active screen
	# (ScreenFlow's _process) or overlay (OverlayManager's _process); we
	# just skip scheduler.tick().
	var freeze := int(world_state.get("screen_freeze_world", 0)) != 0
	freeze = freeze or int(world_state.get("overlay_freeze_world", 0)) != 0
	# ADR 0044 Invariant #10: PhysicsServer3D.set_active(false) under
	# freeze. Pauses ALL physics processing (rigid integration, kinematic
	# movement, query results) without affecting Godot animation / tween
	# / audio systems. Required so wolves / rigid bodies don't drift
	# during pause-menu modals.
	PhysicsServer3D.set_active(not freeze)
	if freeze:
		# Game-level pipelines (save/load, level transitions, world reset)
		# drain in GameShell._process — runs at frame rate regardless of
		# freeze, so "Save" / "Travel" / "New Game" buttons on freeze
		# screens still work. This _on_tick early-return just suppresses
		# the SIM tick. (Pipeline ownership moved 2026-05-12 per the
		# "world = sim, game_shell = game" principle.)
		return
	advance_one_tick()
	if verbose and count % 4 == 0:
		_print_tick_summary(count)


## ADR 0039: canonical tick body. Used by:
##   1. The live clock callback `_on_tick` (above) after the freeze check.
##   2. The step runner (`step_runner.gd`) for headless tests + capture VQA.
##
## Single source of truth — both paths exercise identical engine state
## transitions, so scenario tests cannot pass while live play silently
## diverges. Includes scheduler.tick(), LifecycleDirector.tick,
## actor_manager.tick_policies, lifetime decrement, and all `process_pending_*`
## drains in the original phase order.
##
## Does NOT include the freeze guard — callers are expected to gate the
## call on their own freeze policy. The step runner intentionally bypasses
## freeze (tests need to advance state regardless of modal screens).
func advance_one_tick() -> void:
	# ADR 0040: pretick velocity zero for actors with the opt-in flag.
	# Camera-relative WASD uses velocity_add_relative each tick; without
	# this reset, contributions accumulate unbounded. Runs BEFORE
	# scheduler.tick so the input phase's add contributions sum to a
	# fresh value each tick.
	for id in entities.keys():
		var pre_ent = entities[id]
		if pre_ent is Entity and bool((pre_ent as Entity).get_state("zero_velocity_pretick", false)):
			var pre_vel = (pre_ent as Entity).get_velocity()
			if pre_vel is Vector2:
				(pre_ent as Entity).set_velocity(Vector2.ZERO)
			elif pre_vel is Vector3:
				(pre_ent as Entity).set_velocity(Vector3.ZERO)
	# ADR 0018 Phase A: tick AI policies BEFORE scheduler.tick so their
	# synthesized actions land in the input queue and are processed in
	# the same tick as human input. AI actors decide simultaneously
	# with human-controlled ones.
	if actor_manager != null:
		actor_manager.tick_policies(scheduler.env)
	scheduler.tick()
	# ADR 0040: post-input speed clamp. Per Condition C4 tightening
	# (2026-05-10), default max_speed=INF means clamp DISABLED unless
	# explicitly declared. Originally gated on zero_velocity_pretick (iso
	# mode), but FP mode also wants this — without it, W+D in FP gives
	# √2 × walking speed (classic Quake diagonal-fastrun bug). Refined
	# 2026-05-10 (FP rollout): any actor with max_speed < INF gets clamped.
	for id in entities.keys():
		var clamp_ent = entities[id]
		if not (clamp_ent is Entity): continue
		var max_s := float((clamp_ent as Entity).get_state("max_speed", INF))
		if max_s < INF:
			var v = (clamp_ent as Entity).get_velocity()
			if v is Vector2 and (v as Vector2).length() > max_s:
				(clamp_ent as Entity).set_velocity((v as Vector2).normalized() * max_s)
			elif v is Vector3 and (v as Vector3).length() > max_s:
				(clamp_ent as Entity).set_velocity((v as Vector3).normalized() * max_s)
	# ADR 0036: LifecycleDirector advances entity ages + checks stage
	# thresholds on the same per-tick cadence. dt = tick_seconds so a
	# year_seconds=900 template ages an entity by tick_seconds/900 years
	# per tick (Phase 1 default → schema-only when age_per_in_game_year=0).
	# No-op when no entity has a lifecycle template registered.
	var lc_dir2 := get_node_or_null("LifecycleDirector")
	if lc_dir2 != null and lc_dir2.has_method("tick"):
		lc_dir2.tick(scheduler.env, tick_seconds)
	_decrement_lifetimes()
	# ADR 0014: chunk streaming is a SIM concern (about what entities exist).
	# Stays in world.gd. The game-level pipelines (save/load, level
	# transitions, world reset) drain in GameShell._process — they don't
	# belong to the sim tick.
	process_chunk_streaming()
	# ADR 0016: switch_actor takes effect at next tick boundary. SIM concern
	# (input routing). Stays in world.gd, AFTER scheduler.tick so the
	# current tick's rules saw the OLD active_actor; the next tick's input
	# phase will see the NEW one.
	process_pending_actor_switch()


## ADR 0014: per-tick chunk streaming. Resolves the active actor's planar
## position via ActorManager, then asks chunk_streamer to load any
## chunks within stream_radius and despawn entities in chunks beyond
## unload_radius. Persistent entities (from chunks/_persistent/ or
## tagged via persistent_tags) are never affected — they live in env
## for the whole session.
##
## No-op when chunk_streamer is null (legacy single-chunk demos).
func process_chunk_streaming() -> void:
	if chunk_streamer == null: return
	var actor_id := _find_actor_id()
	if actor_id == "": return
	chunk_streamer.update(scheduler.env, actor_id)



## Tier 2.6j: entities with state.lifetime > 0 auto-decrement each tick;
## removed when lifetime reaches 0. Standard pattern for transient entities
## (bullets, particles, sparkles, "+10" damage numbers).
##
## Entities without a lifetime field are unaffected. Lifetime is in TICKS,
## not seconds — keeps it predictable across tick_seconds settings.
func _decrement_lifetimes() -> void:
	var to_remove: Array[String] = []
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		var lf = (ent as Entity).get_state("lifetime", null)
		if lf == null: continue
		var lifetime := float(lf)
		if lifetime <= 0.0: continue
		lifetime -= 1.0
		(ent as Entity).set_state("lifetime", lifetime)
		if lifetime <= 0.0:
			to_remove.append(str(id))
	# Remove after iteration so we don't mutate the dict mid-loop.
	for id in to_remove:
		var ent: Entity = entities.get(id, null)
		if ent == null: continue
		if relations != null:
			relations.clear_entity(id)
		if spatial_index != null and spatial_index.has_method("remove_entity"):
			spatial_index.remove_entity(id)
		entities.erase(id)
		ent.queue_free()


# ============================================================
# PER-FRAME: input polling + motion integration (W2.2 + W2.5)
# ============================================================

func _process(delta: float) -> void:
	if scheduler == null: return
	# Input polling lives in InputRegistrar (extracted 2026-05-11 — kept
	# the full input lifecycle co-located in one module). _find_actor_id
	# stays here because actor routing is world.gd's concern.
	InputRegistrar.poll(
		scheduler, _find_actor_id(),
		input_actions_hold, input_actions_press,
		stop_action_on_idle, entities
	)
	_integrate_motion(delta)


## Tier 2.6o Phase 3 — accumulate mouse motion across the frame.
## GameShell drains env.mouse_delta in first/third-person camera modes
## to update the actor's state.facing (yaw). Set + reset per frame.
func _input(event: InputEvent) -> void:
	if scheduler == null: return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var current = scheduler.env.get("mouse_delta", Vector2.ZERO)
		if not (current is Vector2): current = Vector2.ZERO
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


## ADR 0016: process queued switch_actor between ticks. Effect handlers
## set env._pending_active_actor; we read + clear it here so input
## routing changes happen at tick boundaries, not mid-rule.
func process_pending_actor_switch() -> void:
	var env: Dictionary = scheduler.env
	var pending = env.get("_pending_active_actor", null)
	if pending == null or actor_manager == null: return
	env.erase("_pending_active_actor")
	var target := str(pending)
	if actor_manager.set_active(target):
		world_state["active_actor_id"] = target
		if verbose:
			print("[World] active actor → ", target)


## Integrate velocity → position each frame for smooth motion.
## Velocity is in units-per-second; multiply by delta. Updates spatial index.
##
## Tier 2.6i: entities with state.drag > 0 decelerate when no input is
## actively setting velocity. drag is per-second factor (0.0 = no drag,
## 1.0 = full stop in 1s). Velocity multiplies by (1 - drag * delta) each
## frame. Below DRAG_REST_EPSILON it snaps to zero.
##
## ADR 0004: entities with the `blocks_motion` tag and `properties.aabb_extents`
## act as static obstacles. Each moving entity is tested against blockers as
## a circle (XZ plane) with radius from `properties.body_radius` (default
## 0.4). On intersection, motion slides along separate axes — try X-only, then
## Z-only, else stay. Approximation: no swept CCD, so very fast entities at
## oblique angles can tunnel through thin walls. Acceptable for arcade-feel.
const DRAG_REST_EPSILON := 0.5
const DEFAULT_BODY_RADIUS := 0.4

## ADR 0044 Session D — motion integration uses physics for collision.
## Hand-rolled AABB sweep deleted. Only Vector3 path supported (2D scenes
## need Vector3 entities with Y=0 OR a future PhysicsServer2D backend).
##
## Per-entity flow:
##   1. Apply drag (state.drag) — decay velocity toward zero
##   2. Skip if entity has blocks_motion tag (static; doesn't move itself)
##   3. Compute proposed position = current + velocity * delta
##   4. _resolve_motion_via_physics_3d slides if collision detected
##   5. Entity.set_position writes — auto-syncs to body if attached
##   6. Spatial index updated for radius queries
func _integrate_motion(delta: float) -> void:
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		var v = (ent as Entity).get_velocity()
		if v == null: continue
		# Apply drag if configured. Skipped if drag = 0 (default).
		var drag_v := float((ent as Entity).get_state("drag", 0.0))
		if drag_v > 0.0:
			var factor: float = 1.0 - clamp(drag_v * delta, 0.0, 1.0)
			if v is Vector2:
				var v2: Vector2 = v
				if v2 != Vector2.ZERO:
					v2 *= factor
					if v2.length() < DRAG_REST_EPSILON: v2 = Vector2.ZERO
					(ent as Entity).set_velocity(v2)
					v = v2
			elif v is Vector3:
				var v3: Vector3 = v
				if v3 != Vector3.ZERO:
					v3 *= factor
					if v3.length() < DRAG_REST_EPSILON * 0.01: v3 = Vector3.ZERO
					(ent as Entity).set_velocity(v3)
					v = v3
		# Static obstacles don't move themselves.
		if (ent as Entity).has_tag("blocks_motion"): continue
		var body_r: float = float((ent as Entity).get_property("body_radius", DEFAULT_BODY_RADIUS))
		var p = (ent as Entity).get_position()
		var moved := false
		# Vector3 path — all 3D scenes (Aldenmere + future 3D games).
		# Vector2 velocity translated to Vector3 (x, 0, y) per Yume convention.
		if p is Vector3:
			var new_p3: Vector3
			if v is Vector3 and v != Vector3.ZERO:
				new_p3 = (p as Vector3) + (v as Vector3) * delta
			elif v is Vector2 and v != Vector2.ZERO:
				var v2: Vector2 = v
				new_p3 = (p as Vector3) + Vector3(v2.x, 0, v2.y) * delta
			else:
				continue
			new_p3 = _resolve_motion_via_physics_3d(p as Vector3, new_p3, body_r)
			(ent as Entity).set_position(new_p3)
			moved = true
		elif p is Vector2 and v is Vector2 and v != Vector2.ZERO:
			# 2D scene fallback (no physics collision; entity moves freely).
			# Other demos using Vector2 motion need PhysicsServer2D backend
			# (future sub-step). Aldenmere doesn't hit this branch.
			(ent as Entity).set_position((p as Vector2) + (v as Vector2) * delta)
			moved = true
		if moved and spatial_index != null:
			spatial_index.update_entity(id, (ent as Entity).get_planar_position())
	# Ground primitive (Tier 2.6r): if scene.json declares a ground.y,
	# clamp tagged "creature" entities to that Y, and remove tagged
	# "projectile" entities that drop below it.
	_apply_ground()


var _ground_y: float = -INF
var _ground_clamp_tags: Array = []
var _ground_despawn_tags: Array = []


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









func _apply_ground() -> void:
	_loader.load_ground_cfg()
	if _ground_y == -INF: return
	var to_remove: Array[String] = []
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		var p = (ent as Entity).get_position()
		var py: float = p.y if p is Vector3 else 0.0
		if py >= _ground_y: continue
		# Below ground. Despawn projectiles, clamp creatures.
		var despawn := false
		for t in _ground_despawn_tags:
			if (ent as Entity).has_tag(str(t)):
				despawn = true; break
		if despawn:
			to_remove.append(str(id))
			continue
		var clamp_match := false
		for t in _ground_clamp_tags:
			if (ent as Entity).has_tag(str(t)):
				clamp_match = true; break
		if clamp_match and p is Vector3:
			(ent as Entity).set_position(Vector3(p.x, _ground_y, p.z))
	for rid in to_remove:
		var rent: Entity = entities.get(rid, null)
		if rent == null: continue
		if relations != null:
			relations.clear_entity(rid)
		if spatial_index != null and spatial_index.has_method("remove_entity"):
			spatial_index.remove_entity(rid)
		entities.erase(rid)
		rent.queue_free()



# ============================================================
# ADR 0044 Session C — physics-driven collision (PhysicsServer3D)
# ============================================================

## Cached SphereShape3D for collision queries. Created once per
## unique body_radius; freed at world exit.
var _physics_test_shape_3d: RID = RID()
var _physics_test_shape_radius: float = -1.0

func _ensure_physics_test_shape(radius: float) -> RID:
	if _physics_test_shape_3d.is_valid() and abs(_physics_test_shape_radius - radius) < 0.001:
		return _physics_test_shape_3d
	if _physics_test_shape_3d.is_valid():
		PhysicsServer3D.free_rid(_physics_test_shape_3d)
	_physics_test_shape_3d = PhysicsServer3D.sphere_shape_create()
	PhysicsServer3D.shape_set_data(_physics_test_shape_3d, radius)
	_physics_test_shape_radius = radius
	return _physics_test_shape_3d


## Returns true if a sphere of `radius` at `pos` overlaps ANY physics
## body in the 3D space. Used by _integrate_motion to detect collision
## between a moving (body-less) entity and static walls (which DO have
## bodies via Session A translation of blocks_motion).
##
## Returns false when no 3D space exists (2D scene, headless test
## without viewport) — caller falls back to legacy AABB code.
func _physics_collides_3d(pos: Vector3, radius: float) -> bool:
	var vp := get_viewport()
	if vp == null: return false
	var w3d := vp.find_world_3d()
	if w3d == null: return false
	var space: RID = w3d.space
	if not space.is_valid(): return false
	var ds := PhysicsServer3D.space_get_direct_state(space)
	if ds == null: return false
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape_rid = _ensure_physics_test_shape(radius)
	query.transform = Transform3D(Basis(), pos)
	query.collision_mask = 0xFFFFFFFF
	return not ds.intersect_shape(query, 1).is_empty()


## Resolve 3D motion via PhysicsServer3D.intersect_shape — replaces
## the hand-rolled AABB slide. Same separate-axes slide policy: try
## X-only, then Z-only, then stay. Y is preserved (Aldenmere's
## entities stay on ground; ground constraint handled separately).
func _resolve_motion_via_physics_3d(from_p: Vector3, to_p: Vector3, radius: float) -> Vector3:
	if not _physics_collides_3d(to_p, radius):
		return to_p
	var x_only := Vector3(to_p.x, from_p.y, from_p.z)
	if not _physics_collides_3d(x_only, radius):
		return Vector3(to_p.x, to_p.y, from_p.z)
	var z_only := Vector3(from_p.x, from_p.y, to_p.z)
	if not _physics_collides_3d(z_only, radius):
		return Vector3(from_p.x, to_p.y, to_p.z)
	return from_p



## Coerce Array / Vector2 / Vector3 to Vector3.
static func _to_vec3(v) -> Vector3:
	if v is Vector3: return v
	if v is Vector2: return Vector3(v.x, 0, v.y)
	if v is Array:
		var a := v as Array
		if a.size() >= 3: return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2: return Vector3(float(a[0]), 0, float(a[1]))
	return Vector3.ZERO


## Generic tick summary: total entity count + counts per common tag.
## Adapts to whatever tags the loaded data uses; silent if no common ones match.
func _print_tick_summary(count: int) -> void:
	var bits: Array = ["n=%d" % entities.size()]
	# Probe a small set of common tags. Add yours here if useful.
	var probe_tags := ["seed", "young", "mature", "rotten", "water",
		"player", "sparkle", "enemy", "projectile", "crop",
		"fire", "tree", "burning_tree", "ash",
		"grass", "rabbit", "fox", "animal", "predator", "prey",
		"bird", "iron_ore", "iron", "copper_ore", "copper",
		"fertilizer", "mushroom", "seedling", "weather", "bush",
		"square", "piece"]
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
