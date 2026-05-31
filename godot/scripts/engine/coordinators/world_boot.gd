extends RefCounted
class_name WorldBoot

## Boot sequence for World.load_data(). Each line in run() is one phase;
## the bodies live in named methods below. Reads as a Table of Contents
## for what happens between "scene loaded" and "first tick can fire."
##
## Phases are deliberately NOT data-driven — order is load-bearing and
## many phases depend on state established by earlier ones (e.g. zones
## load AFTER entities so error reports can reach env.error_buffer;
## factions load AFTER entities so member_count bindings resolve).
##
## Most phases no-op when the relevant ADR-introduced file is absent
## (game/flow.json, macros.json, actors.json, zones.json, chunks/,
## factions.json, etc.) — backward-compat for games that don't use
## that capability.

var _world: Node = null  # World back-ref
var _root: String = ""

## The engine's fixed Director set. Each pair = [Node name, script path].
## WorldBoot._mount_default_directors auto-creates these as World children
## at boot UNLESS the per-game .tscn already provides one with that name
## (adopt-and-skip). Each is internally a no-op when its config / data is
## absent — backward-compat by absence. Adding a new ADR director = one
## row here (no per-game .tscn changes needed).
##
## Order mirrors play.tscn — GameShell first (drains shell events early),
## then ScreenFlow / Overlay / Settings (UI scaffolding), then domain
## directors. ScreenSmokeRunner + NameplateRenderer at the end since
## they're optional QA / visual layers.
const _DEFAULT_DIRECTORS: Array = [
	["GameShell", "res://scripts/engine/ui/game_shell.gd"],
	["ScreenFlow", "res://scripts/engine/ui/screen_flow.gd"],
	["OverlayManager", "res://scripts/engine/ui/overlay.gd"],
	["SettingsManager", "res://scripts/engine/ui/settings_manager.gd"],
	["LightingDirector", "res://scripts/engine/directors/lighting_director.gd"],
	["PartyDirector", "res://scripts/engine/directors/party_director.gd"],
	["ScheduleDirector", "res://scripts/engine/directors/schedule_director.gd"],
	["LifecycleDirector", "res://scripts/engine/directors/lifecycle_director.gd"],
	["ClassManager", "res://scripts/engine/directors/class_manager.gd"],
	["FactionDirector", "res://scripts/engine/directors/faction_director.gd"],
	["TechTreeDirector", "res://scripts/engine/directors/tech_tree.gd"],
	["DynastyDirector", "res://scripts/engine/directors/dynasty_director.gd"],
	["NameplateRenderer", "res://scripts/engine/ui/nameplate_renderer.gd"],
	["ScreenSmokeRunner", "res://scripts/engine/qa/screen_smoke_runner.gd"],
]


func _init(world: Node) -> void:
	_world = world


# ============================================================
# DISPATCH — reads as the boot TOC
# ============================================================


func run() -> void:
	_root = (_world.data_root as String).rstrip("/")
	_mount_default_directors()  # ensure UI + ADR director Nodes exist
	_spawn_engine_entity()  # ADR 0047: _engine singleton backs world.* state
	_init_lib_resolver()
	_load_engine_rules()  # ADR 0049: auto-loaded engine_rules lib bundles
	_register_inputs()
	_apply_level_seed()
	_load_macros()
	_load_actor_config()
	_load_content()  # rules + entities + world_state (multi- vs single-level)
	_load_zones()
	_try_chunk_streamer()
	_apply_variant_overlay()
	_load_save_policy()
	_mount_directors()
	_load_factions()
	_build_ground_mesh()
	_world.scheduler.flush_effects()
	_world._run_multimesh_director()
	_log_summary()


# ============================================================
# PHASES
# ============================================================


## ADR 0047 — spawn the `_engine` singleton entity. Its state dict is
## shared by reference with World.world_state so:
##   - rules writing `state_set target=world` continue to work
##   - HUD bindings `world.X` continue to resolve (game_shell._resolve_binding)
##   - rules can ALSO query the entity via `tags_all: ["_engine"]`
##   - saves serialize cleanly via the standard entity path
##
## One store: every piece of named state lives on an entity. world_state
## is a backward-compat handle for "_engine.state", not a parallel store.
##
## No renderer (no visual block), no spatial-index entry (set_position
## never called), no scene-tree _process (Entity is a passive data Node).
## The entity is hidden — it exists for the engine's bookkeeping only.
func _spawn_engine_entity() -> void:
	if _world.entities.has("_engine"):
		return
	var ent := Entity.new()
	ent.name = "_engine"
	ent.def_id = "_engine"
	ent.instance_id = "_engine"
	ent.tags = ["_engine"]
	# Share the dict by REFERENCE — writes via either name update the
	# same data. PhaseScheduler captured env.world before this point;
	# we mutate the existing dict in place, not replace it.
	ent.state = _world.world_state
	_world.add_child(ent)
	_world.entities["_engine"] = ent


## Auto-mount the standard Director / UI Node set as World children.
## Adopt-and-skip when a per-game .tscn already provides one with the
## same name (legacy compatibility). Each director is internally a
## no-op when its config / data is absent, so mounting them all is
## safe — they just sit idle for games that don't use that capability.
##
## Replaces the 14-line "every per-game .tscn must mount these"
## boilerplate. New games can ship a 5-line .tscn (World root + Camera3D
## + data_root + auto_start) and inherit the full Director suite from
## the engine.
func _mount_default_directors() -> void:
	for entry in _DEFAULT_DIRECTORS:
		var node_name: String = entry[0]
		var script_path: String = entry[1]
		if _world.get_node_or_null(node_name) != null:
			continue  # adopt-and-skip — per-game .tscn provided one
		var script = load(script_path)
		if script == null:
			push_warning("[WorldBoot] missing director script: " + script_path)
			continue
		var node := Node.new()
		node.name = node_name
		node.set_script(script)
		_world.add_child(node)
		# ADR 0061 Phase 2.5: under an external tick driver (lockstep), NO node
		# may mutate sim state per-frame — only the driver's tick advances the
		# world, else peers desync from differing frame counts. Disabling the
		# director's process_mode from boot cascades to its children (e.g.
		# GameShell's camera). Movement etc. still works: it's tick-locked rules
		# in advance_one_tick, not director _process. Generic seam (not lockstep-
		# specific) — any external-tick model gets a deterministic live scene.
		if Engine.has_meta("yume_external_tick_driver"):
			node.process_mode = Node.PROCESS_MODE_DISABLED


## ADR 0027 — populate the lib resolver cache from data/lib/**.json
## BEFORE any per-game loader runs. Later loaders (entities, rules,
## screens, scene, hud) call LibResolver.resolve transparently.
func _init_lib_resolver() -> void:
	LibResolver.init_cache(_root)


## ADR 0049 — auto-load engine_rules lib bundles. Every JSON file under
## data/lib/engine_rules/ is registered as global rules BEFORE any
## per-game rules load. Expresses what used to be hardcoded engine
## scans (lifetime decay, etc.) as primitive rules content authors
## could write — engine ships only the irreducible mechanism
## (scheduler, query, effect dispatch), not the behaviors.
##
## Auto-included (not opt-in): no per-game `$include` needed, no risk
## of a game forgetting to wire in the engine's built-in behaviors.
func _load_engine_rules() -> void:
	var lib_root := _root.rstrip("/").get_base_dir() + "/lib/engine_rules"
	if not DirAccess.dir_exists_absolute(lib_root):
		return
	var dir := DirAccess.open(lib_root)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			_world._loader.load_rules_file(lib_root + "/" + fname, true)
		fname = dir.get_next()
	dir.list_dir_end()


## Tier 2.6t / ADR 0009 — register per-game input actions from
## ui/input.json. Registrar returns press/hold action names so the
## engine extends its poll lists; without this, per-game actions
## get InputMap entries but never reach the rule scheduler.
func _register_inputs() -> void:
	var registered: Dictionary = InputRegistrar.register_from_data_root(_root)
	for n in registered.get("press", []) as Array:
		if not (_world.input_actions_press as Array).has(str(n)):
			_world.input_actions_press.append(str(n))
	for n in registered.get("hold", []) as Array:
		if not (_world.input_actions_hold as Array).has(str(n)):
			_world.input_actions_hold.append(str(n))


## v2.6 — scene.json may declare a `level_seed` integer applied to
## Godot's global PRNG before any pattern/scatter/cluster runs.
## Same seed = same procedural layout. Omit for stochastic per-session.
func _apply_level_seed() -> void:
	_world._loader.apply_level_seed_if_set(_root)


## ADR 0019 — load per-game macros BEFORE rules so every rules file
## can reference the shared macro vocabulary. Empty expander when no
## macros.json present (no-op pass-through).
func _load_macros() -> void:
	_world.macro_expander = MacroExpander.load_from_data_root(_root, _world._build_env())


## ADR 0016 — load (or synthesize) actor config + scripted policies.
## Legacy single-player demos get a synthesized default actor whose
## starting_entity_tag = world.actor_tag. Mirror active_actor_id into
## world_state so bindings can read it. ADR 0018 Phase A: load scripted
## policies for any ai_policy actors (no-op for legacy demos).
func _load_actor_config() -> void:
	_world.actor_manager = ActorManager.load_or_synthesize(_root, _world.actor_tag)
	_world.world_state["active_actor_id"] = _world.actor_manager.active_actor_id
	_world.actor_manager.load_policies(_root)


## ADR 0006 — load rules + entities + world_state. Multi-level (when
## game/flow.json exists): load progression first, then global rules,
## then the starting level's content. Single-level: load everything
## from the root.
##
## ADR 0009 (Phase 5b sunset, 2026-05-05): single canonical layout —
## world/rules.json + game/goals.json + game/flow.json +
## levels/<name>/rules.json + world/state.json. Legacy single-file
## paths (world_rules.json, progression.json, world.json) are no
## longer consulted.
##
## ADR 0024: single-level games build the navmesh here (multi-level
## builds inside _level_transitions.load_level). No-op when no
## walkable_floor entities exist.
func _load_content() -> void:
	var ldr = _world._loader
	var prog_path := _root + "/game/flow.json"
	if FileAccess.file_exists(prog_path):
		ldr.load_progression(prog_path)
		# load_rules_files_for: directory form wins over single-file form
		# (#109). Games can split world/rules.json into world/rules/*.json
		# feature modules; engine concatenates them deterministically.
		ldr.load_rules_files_for(_root + "/world/rules.json")
		ldr.load_rules_files_for(_root + "/game/goals.json", true)
		ldr.load_rules_file(_root + "/tutorial.json", true)
		ldr.load_world_file(_root + "/world/state.json")
		ldr.load_entities_path(_root)
		if _world.current_level != "":
			_world._level_transitions.load_level(_world.current_level)
	else:
		ldr.load_rules_files_for(_root + "/world/rules.json")
		ldr.load_rules_files_for(_root + "/game/goals.json", true)
		ldr.load_rules_file(_root + "/tutorial.json", true)
		ldr.load_world_file(_root + "/world/state.json")
		ldr.load_entities_path(_root)
		if _world.scheduler != null:
			Pathfinding.build_navmesh_for_level(_world.scheduler.env)


## ADR 0031 — zones.json (optional). Loads AFTER entities + world_state
## so error reports can reach env.error_buffer; BEFORE save layer so
## saved zone_state restores on top of state_init defaults.
func _load_zones() -> void:
	_world._loader.load_zones_file(_root + "/world/zones.json")


## ADR 0014 — open-world chunk streaming. world.json declares chunked
## mode; absent means single-chunk legacy (no streaming, no chunks
## directory consulted). When present: load persistent chunk first
## (those entities never leave env), then boot starting_chunk +
## stream_radius neighbors. Per-tick drift load/unload runs in
## _stream_chunks_if_active.
func _try_chunk_streamer() -> void:
	_world.chunk_streamer = ChunkStreamer.try_load(_root, _world.verbose)
	if _world.chunk_streamer == null:
		return
	var persist_dir := _root + "/chunks/_persistent"
	if DirAccess.dir_exists_absolute(persist_dir):
		_world._loader.load_entities_file(persist_dir + "/entities.json")
	_world.chunk_streamer.boot(_world._build_env())


## ADR 0009 Phase 2d — variant overlay applies after rules + world_state
## + entities are loaded. Reads variant name from scene.json's "variant"
## key or YUME_VARIANT env var. Purely additive — cannot change rule
## structure.
func _apply_variant_overlay() -> void:
	VariantOverlay.new(_world).apply(_root)


## ADR 0010 — load save policy + expose has_save binding for menus.
func _load_save_policy() -> void:
	_world.save_policy = SaveState.load_policy(_root)
	if _world.save_policy.is_empty():
		_world.world_state["has_save"] = 0
		return
	var slots := int(_world.save_policy.get("slots", 1))
	var game := SaveLoadCoordinator.game_name_from_root(_world.data_root)
	_world.world_state["has_save"] = 1 if SaveState.has_any_save(game, slots) else 0


## Mount sibling Director nodes placed by the per-game .tscn. Five-row
## table in world.gd::_BOOT_DIRECTORS — one row per ADR director. Each
## is optional; absence = backward-compat for games not using that ADR.
## DynastyDirector is the odd one out (no method call, just verbose log).
func _mount_directors() -> void:
	_world._mount_boot_directors(_root)
	if _world.get_node_or_null("DynastyDirector") != null and _world.verbose:
		# ADR 0034: heir state lives on actor entities; the four
		# succession effects detect the director at fire-time.
		print("[World] DynastyDirector mounted (ADR 0034)")


## ADR 0032 — factions.json (optional). Loads AFTER entities so
## member_count bindings resolve against the live entity set on first
## tick. No-op for games without politics.
func _load_factions() -> void:
	_world._loader.load_factions_file(_root + "/factions.json")


## Build the visual floor plane from scene.json's `ground.mesh` block
## (size + color + material). Skipped when the per-game .tscn already
## mounts a Ground MeshInstance3D (adopt-and-skip), or when the block
## is absent (abstract / overlay-only games).
func _build_ground_mesh() -> void:
	var gr := GroundRenderer.new(_world)
	gr.build()
	gr.build_water()  # ADR 0059 — water surface from scene.json `water` block
	GrassRenderer.new(_world).build()  # grass-blade MultiMesh (opt-in via scene.json)


func _log_summary() -> void:
	if not _world.verbose:
		return
	var cur_level := str(_world.current_level)
	var lvl_str := (" [level: " + cur_level + "]") if cur_level != "" else ""
	print(
		(
			"[World] loaded: %d defs, %d entities, %d relations%s"
			% [
				_world.defs.size(),
				_world.entities.size(),
				_world.relations.count_total(),
				lvl_str,
			]
		),
	)
