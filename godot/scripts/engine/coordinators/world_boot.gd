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


func _init(world: Node) -> void:
	_world = world


# ============================================================
# DISPATCH — reads as the boot TOC
# ============================================================


func run() -> void:
	_root = (_world.data_root as String).rstrip("/")
	_init_lib_resolver()
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
	_world.scheduler.flush_effects()
	_world._run_multimesh_director()
	_log_summary()


# ============================================================
# PHASES
# ============================================================


## ADR 0027 — populate the lib resolver cache from data/lib/**.json
## BEFORE any per-game loader runs. Later loaders (entities, rules,
## screens, scene, hud) call LibResolver.resolve transparently.
func _init_lib_resolver() -> void:
	LibResolver.init_cache(_root)


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
## world/physics.json + game/rules.json + game/flow.json +
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
		ldr.load_rules_file(_root + "/world/physics.json")
		ldr.load_rules_file(_root + "/game/rules.json", true)
		ldr.load_rules_file(_root + "/tutorial.json", true)
		ldr.load_world_file(_root + "/world/state.json")
		ldr.load_entities_path(_root)
		if _world.current_level != "":
			_world._level_transitions.load_level(_world.current_level)
	else:
		ldr.load_rules_file(_root + "/world/physics.json")
		ldr.load_rules_file(_root + "/game/rules.json", true)
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
