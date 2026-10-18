extends RefCounted
class_name WorldLoader

## Boot-time JSON parsers — extracted from world.gd on 2026-05-12.
##
## Consolidates 9 file-reading utilities that load per-game JSON at
## boot (entities, rules, world state, zones, progression,
## scene config). Each method is a thin parser + dispatcher:
##   - Opens the file (no-op if missing)
##   - Parses JSON (warns on malformed)
##   - Resolves @lib / $include refs via LibResolver (where applicable)
##   - Hands the dict to the appropriate target (scheduler / defs /
##     world_state / zone_store / spawn_manager)
##
## Pattern: RefCounted, per-World instance, world reference for state
## access. The CACHE flags for ground/grid scene.json reads live HERE
## (avoids double-parsing); the parsed VALUES are written to the
## GroundConstraint coordinator (ground.y/clamp/despawn tags) and to
## world.gd's _grid_cfg field (read by _build_env).
##
## load_data orchestration STAYS in world.gd — it's the boot sequence
## owner. This module just provides the parsers it calls.

var _world: World
var _level_seed: int = 0  # ADR 0060 — scene.json level_seed for per-pattern RNGs

# Cache flags — keep us from re-parsing scene.json. Ground values are
# written to _world._ground_constraint; grid values to _world._grid_cfg.
var _ground_cfg_loaded: bool = false
var _grid_cfg_loaded: bool = false


func _init(world: World) -> void:
	_world = world


# ============================================================
# ENTITY LOADERS
# ============================================================


## Load entity data from `<root>/entities.json` and/or `<root>/entities/`.
## Two-phase: collect all dicts first, then process (a) definitions before
## (b) initial_instances + initial_relations so spawn-time def lookups work
## regardless of file order.
func load_entities_path(root: String) -> void:
	var env := _world._build_env()
	var dicts: Array[Dictionary] = []

	var single := root + "/entities.json"
	if FileAccess.file_exists(single):
		var d := _read_entities_json(single, env)
		if not d.is_empty():
			dicts.append(d)

	var dir_path := root + "/entities"
	if DirAccess.dir_exists_absolute(dir_path):
		var dir := DirAccess.open(dir_path)
		if dir != null:
			var files: Array[String] = []
			dir.list_dir_begin()
			var fname := dir.get_next()
			while fname != "":
				if not dir.current_is_dir() and fname.ends_with(".json"):
					files.append(fname)
				fname = dir.get_next()
			files.sort()
			for f in files:
				var d2 := _read_entities_json(dir_path + "/" + f, env)
				if not d2.is_empty():
					dicts.append(d2)

	if dicts.is_empty():
		EngineError.raise(
			env,
			EngineError.WORLD_ENTITIES_MISSING,
			"No entities found at %s (checked entities.json + entities/)" % root,
			{"file": root},
			"Create entities.json or an entities/ directory with one JSON file per def.",
			"warning"
		)
		return

	# Phase 1: register all definitions
	for d in dicts:
		for def in d.get("definitions", []):
			if def is Dictionary:
				_world.defs[str(def.get("id", ""))] = def
	# Phase 1.5: expand declarative patterns into concrete instance dicts.
	# Tier 2.6q — entities/zz_instances.json (and similar) can declare
	# `patterns: [{def, pattern, count, ...}]` instead of hand-typing
	# every position. Patterns expand to the same shape as initial_instances.
	for d in dicts:
		for p in d.get("patterns", []):
			if p is Dictionary:
				for inst in InstancePatterns.expand(p, _level_seed):
					_world._spawn_manager.spawn(inst)
	# Phase 2: process hand-coded initial instances + relations
	for d in dicts:
		for inst in d.get("initial_instances", []):
			if inst is Dictionary:
				_world._spawn_manager.spawn(inst)
		for rel in d.get("initial_relations", []):
			if rel is Dictionary:
				# ADR 0075 — carry the authored `state` block onto the edge.
				# Without this, edge state is reachable from RULES but not
				# from authored initial content: the edge loads with empty
				# state, and any `_edge` query filter over it fails the
				# strict-missing check and silently matches nothing.
				var rel_state = (rel as Dictionary).get("state", {})
				(
					_world
					. relations
					. relate(
						str(rel.get("type", "")),
						str(rel.get("from", "")),
						str(rel.get("to", "")),
						(rel_state as Dictionary) if rel_state is Dictionary else {},
					)
				)


## ADR 0014: load a single entities JSON file (definitions + patterns +
## initial_instances + initial_relations). Used by ChunkStreamer to
## stream per-chunk content; reuses the same definition-then-instance
## pipeline as `load_entities_path` so chunk-loaded entities and
## bootstrap entities follow identical semantics.
##
## Called at runtime — definitions appearing in chunk files are added
## to defs if new; existing-id collisions are silently overwritten.
func load_entities_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var env := _world._build_env()
	var d := _read_entities_json(path, env)
	if d.is_empty():
		return
	# Definitions
	for def in d.get("definitions", []):
		if def is Dictionary:
			_world.defs[str(def.get("id", ""))] = def
	# Patterns
	for p in d.get("patterns", []):
		if p is Dictionary:
			for inst in InstancePatterns.expand(p, _level_seed):
				_world._spawn_manager.spawn(inst)
	# Initial instances
	for inst in d.get("initial_instances", []):
		if inst is Dictionary:
			_world._spawn_manager.spawn(inst)
	# Initial relations
	for rel in d.get("initial_relations", []):
		if rel is Dictionary:
			# `state` included — ADR 0075 edge state. The load_data path was fixed
			# for this and load_level was not, so a relation declared in a LEVEL
			# silently lost its edge state while the identical declaration at the
			# root kept it. Fixing the one site the bug surfaced at, and not its
			# twin, is the failure `.claude/rules/post-mortem.md` step 3a is about.
			(
				_world
				. relations
				. relate(
					str(rel.get("type", "")),
					str(rel.get("from", "")),
					str(rel.get("to", "")),
					(rel.get("state", {}) as Dictionary) if rel.get("state") is Dictionary else {},
				)
			)


## Read one entities JSON file. Returns {} on missing/malformed; reports
## structured errors via env.error_buffer.
func _read_entities_json(path: String, env: Dictionary) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		(
			EngineError
			. raise(
				env,
				EngineError.WORLD_ENTITIES_INVALID,
				"Invalid JSON: %s" % path,
				{"file": path},
				"Top-level must be a JSON object with 'definitions' / 'initial_instances' / 'initial_relations'."
			)
		)
		return {}
	# ADR 0027: expand @lib.X / $extends / $include refs before consumption.
	# Pass-through if no refs present.
	var resolved = LibResolver.resolve(data)
	if resolved is Dictionary:
		return resolved as Dictionary
	return data as Dictionary


# ============================================================
# RULE LOADER
# ============================================================


func load_rules_file(path: String, append: bool = false) -> void:
	if not FileAccess.file_exists(path):
		return
	var env := _world._build_env()
	# ADR 0019: macro_expander expands per-game macro effect references
	# in this file's rules to primitive sequences before parsing into
	# Rule instances. Null when game has no macros.json.
	var rules := Rule.load_from_file(path, env, _world.macro_expander)
	var errors := Rule.validate_all(rules)
	for record in errors:
		EngineError.report(env, record)
	if append and _world.scheduler.has_method("append_rules"):
		_world.scheduler.append_rules(rules)
	else:
		_world.scheduler.register_rules(rules)
	if _world.verbose:
		print("[World] %d rules %s" % [rules.size(), "appended" if append else "registered"])


## Load rules from EITHER `<path>` (single file, legacy) OR `<path_no_ext>/`
## directory of feature modules (each `<dir>/*.json` is a separate rules
## file, concatenated in alphabetical order for determinism). Directory
## form wins if present. Used at every existing load_rules_file call site
## so a game can opt-in to chain-per-file authoring (#109, 2026-05-16)
## without breaking single-file games.
##
## Example: `load_rules_files_for("world/rules.json", false)` tries
## `world/rules/` first (globs *.json), falls back to `world/rules.json`.
func load_rules_files_for(path: String, append: bool = false) -> void:
	var dir_path := path.trim_suffix(".json")
	if DirAccess.dir_exists_absolute(dir_path):
		var d := DirAccess.open(dir_path)
		if d == null:
			return
		var files: Array[String] = []
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			if not d.current_is_dir() and name.ends_with(".json"):
				files.append(name)
			name = d.get_next()
		d.list_dir_end()
		files.sort()  # determinism — load order is filename alpha
		var first := true
		for fname in files:
			load_rules_file(dir_path + "/" + fname, append if first else true)
			first = false
		return
	# Fall back to single-file form (legacy + small games).
	load_rules_file(path, append)


# ============================================================
# WORLD STATE LOADER
# ============================================================


func load_world_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		# Merge `state` block into world_state (preserves any pre-set keys
		# like current_level from progression.json).
		var s: Dictionary = data.get("state", {}) as Dictionary
		for k in s.keys():
			_world.world_state[str(k)] = s[k]


# ============================================================
# ZONES
# ============================================================


## ADR 0031 — load world/zones.json into ZoneStore.
## Optional file; absent = empty store, full backward-compat.
func load_zones_file(path: String) -> void:
	if _world.zone_store == null:
		_world.zone_store = ZoneStore.new()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()
	var data = JSON.parse_string(raw)
	if not (data is Dictionary):
		EngineError.raise(
			_world._build_env(),
			"zone.invalid_json",
			"world/zones.json is not a JSON object",
			{"file": path},
			'The top-level value must be a dict like {"zones": [...]}.'
		)
		return
	var errors := _world.zone_store.load_from_dict(data, _world._build_env())
	if _world.verbose:
		print(
			(
				"[World] zone_store loaded: %d zones, %d errors"
				% [_world.zone_store.count(), errors.size()]
			)
		)


# ============================================================
# MULTI-LEVEL PROGRESSION (ADR 0006)
# ============================================================


func load_progression(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return
	if not (json.data is Dictionary):
		return
	var p: Dictionary = json.data
	_world.level_order = p.get("levels", [])
	var ptags = p.get("persistent_tags", null)
	if ptags is Array and not (ptags as Array).is_empty():
		_world.level_persistent_tags = (ptags as Array).duplicate()
	_world.current_level = str(
		p.get("starting_level", _world.level_order[0] if _world.level_order.size() > 0 else "")
	)
	_world.levels_root = _world.data_root.rstrip("/") + "/levels"
	var oac = p.get("on_all_complete", null)
	if oac is Dictionary:
		_world.on_all_complete_msg = str((oac as Dictionary).get("win_message", ""))
	# ADR 0047: current_level is a World property that proxies to
	# world_state["current_level"] — the setter above already wrote it.


# ============================================================
# SCENE CONFIG (ground / grid / level_seed)
# ============================================================


## scene.json's `level_seed` integer applied to Godot's global PRNG
## before any pattern/scatter/cluster runs. Makes procedurally-generated
## layouts reproducible — same seed = same map.
func apply_level_seed_if_set(root: String) -> void:
	var path := root + "/scene.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return
	if not (json.data is Dictionary):
		return
	if not (json.data as Dictionary).has("level_seed"):
		return
	var s: int = int((json.data as Dictionary).get("level_seed", 0))
	seed(s)  # still seed the global PRNG for non-pattern randf consumers
	SpecRandom.shared.set_seed(s)  # ADR 0095: rule chance and formula randf()
	_level_seed = s  # ADR 0060 — threaded into per-pattern RNGs (the real gate)
	if _world.verbose:
		print("[World] level_seed=%d applied — patterns are deterministic" % s)


## Lazy-load scene.json's `ground` block into the GroundConstraint
## coordinator's ground_y / clamp_tags / despawn_tags fields. The
## coordinator (not World) owns the config + per-frame apply loop;
## this is just the setter. Cache flag is internal to avoid double-parse.
func load_ground_cfg() -> void:
	if _ground_cfg_loaded:
		return
	_ground_cfg_loaded = true
	var path := _world.data_root.rstrip("/") + "/scene.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return
	if not (json.data is Dictionary):
		return
	var cfg: Dictionary = json.data
	if not (cfg.get("ground", null) is Dictionary):
		return
	var g: Dictionary = cfg["ground"]
	var gc: GroundConstraint = _world._ground_constraint
	if g.has("y"):
		gc.ground_y = float(g["y"])
	gc.clamp_tags = g.get("clamp_tags", ["creature"])
	gc.despawn_tags = g.get("despawn_tags", ["projectile"])


## ADR 0038: grid-based placement config. Loaded once from scene.json's
## `grid` block, exposed via env["scene_grid"] in _build_env. Field
## stays on World; this is the setter.
func load_grid_cfg() -> void:
	if _grid_cfg_loaded:
		return
	_grid_cfg_loaded = true
	var path := _world.data_root.rstrip("/") + "/scene.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return
	if not (json.data is Dictionary):
		return
	var cfg: Dictionary = json.data
	if cfg.get("grid", null) is Dictionary:
		_world._grid_cfg = cfg["grid"]
	# ADR 0079 — simulation tiers. `simulation.embodied_radius` is the
	# distance inside which entities are `embodied`. Absent or <= 0 means
	# every entity is embodied, i.e. the pre-0079 behaviour.
	if cfg.get("simulation", null) is Dictionary and _world.scheduler != null:
		var sim: Dictionary = cfg["simulation"]
		_world.scheduler.env["embodied_radius"] = float(sim.get("embodied_radius", 0.0))
