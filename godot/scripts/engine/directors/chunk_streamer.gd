extends RefCounted
class_name ChunkStreamer

## ADR 0014 — Open-world chunked substrate.
##
## Loads / unloads spatial chunks based on active-actor position. Each chunk
## lives at `chunks/<x>_<y>/entities.json` and contains JSON in the same
## shape as the legacy single-file `entities.json` (definitions +
## initial_instances + initial_relations + patterns).
##
## Active code path: `update(env)` is called once per tick from World._process tick branch
## (after process_pending_level_transition, before pending_save_load). We
## resolve the active actor via ActorManager, compute its current chunk,
## load any chunks within `stream_radius` that aren't already loaded, and
## despawn entities in chunks beyond `unload_radius`. Hysteresis (stream
## vs unload radius) prevents flip-flop at boundaries.
##
## **Persistent entities** (per ADR § Revisions #1):
##   `chunks/_persistent/entities.json` is loaded ONCE at boot from
##   World.load_data and never streamed. Its entities live in env.entities
##   + spatial_index for the entire session — they survive any chunk
##   eviction and are findable by queries regardless of chunk state.
##
## **Coordinate convention** (per ADR § geometry):
##   Chunk (x, y) covers world rectangle
##     [x * chunk_size.x, (x+1) * chunk_size.x)
##     [y * chunk_size.y, (y+1) * chunk_size.y)  on planar XZ axes.
##   Within a chunk, entity positions are ABSOLUTE world coords (not
##   chunk-local). This keeps the spatial index simple — same coordinate
##   system everywhere.
##
## **Unit semantics** (per ADR § Revisions #2):
##   chunk_size matches the engine's entity-position unit, which in turn
##   matches the renderer's `position_scale` convention:
##     - 2D pixel renderer: pixels (e.g. [320, 320] = 10×10 cells of 32px)
##     - 3D world renderer: world units / meters (e.g. [50, 50] = 50m × 50m)
##   No unit declaration in world.json — inherits from the renderer.

# ============================================================
# CONFIG (from world.json)
# ============================================================

var chunk_size: Vector2 = Vector2(320, 320)
var stream_radius: int = 1
var unload_radius: int = 2
var starting_chunk: Vector2i = Vector2i(0, 0)
var starting_position: Vector2 = Vector2(160, 160)
var persistent_tags: Array = ["persistent"]
var boundary_mode: String = "clamp"

var data_root: String = ""
## Set of chunks currently loaded as transient (excludes _persistent).
## Map of Vector2i → Array[String] (entity ids spawned by that chunk).
var _loaded_chunks: Dictionary = {}
## Track current chunk for save/load + verbose logging.
var current_chunk: Vector2i = Vector2i(0, 0)
var verbose: bool = false

# ============================================================
# LIFECYCLE
# ============================================================


## Read world.json from data_root; returns null if no world.json present
## (single-chunk legacy mode). Caller (World.load_data) checks this and
## either skips streaming entirely or wires up the streamer.
static func try_load(data_root: String, verbose: bool = false) -> ChunkStreamer:
	var root := data_root.rstrip("/")
	var path := root + "/world.json"
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return null
	var d := data as Dictionary

	var cs := ChunkStreamer.new()
	cs.data_root = root
	cs.verbose = verbose

	var size_arr = d.get("chunk_size", [320, 320])
	if size_arr is Array and (size_arr as Array).size() >= 2:
		cs.chunk_size = Vector2(float(size_arr[0]), float(size_arr[1]))
	cs.stream_radius = int(d.get("stream_radius", 1))
	cs.unload_radius = int(d.get("unload_radius", max(2, cs.stream_radius + 1)))
	if cs.unload_radius < cs.stream_radius:
		cs.unload_radius = cs.stream_radius + 1  # enforce hysteresis

	var sc = d.get("starting_chunk", [0, 0])
	if sc is Array and (sc as Array).size() >= 2:
		cs.starting_chunk = Vector2i(int(sc[0]), int(sc[1]))
	cs.current_chunk = cs.starting_chunk

	var sp = d.get("starting_position", null)
	if sp is Array and (sp as Array).size() >= 2:
		cs.starting_position = Vector2(float(sp[0]), float(sp[1]))
	else:
		# Default: center of starting chunk
		cs.starting_position = Vector2(
			(float(cs.starting_chunk.x) + 0.5) * cs.chunk_size.x,
			(float(cs.starting_chunk.y) + 0.5) * cs.chunk_size.y,
		)

	var tags = d.get("persistent_tags", ["persistent"])
	if tags is Array:
		cs.persistent_tags = tags as Array
	cs.boundary_mode = str(d.get("boundary_mode", "clamp"))

	return cs


## Compute which chunk a world-planar position falls into.
func chunk_of(planar_pos: Vector2) -> Vector2i:
	return Vector2i(
		int(floor(planar_pos.x / chunk_size.x)),
		int(floor(planar_pos.y / chunk_size.y)),
	)


# ============================================================
# UPDATE — called per tick from World._process tick branch
# ============================================================


## Compute desired chunk set from active-actor position; load missing
## chunks; despawn entities in chunks beyond unload_radius. Persistent
## entities (loaded once at boot from chunks/_persistent/) are never
## touched here.
##
## env: standard engine env (entities, defs, relations, spatial_index,
##      world, parent, next_id, error_buffer). `parent` is the World node
##      and provides the spawn helper.
## actor_id: the entity id the streamer should anchor to (resolved by
##           caller via ActorManager.resolve_active_entity()).
func update(env: Dictionary, actor_id: String) -> void:
	if actor_id == "":
		return
	var entities: Dictionary = env.get("entities", {})
	var actor_ent = entities.get(actor_id, null)
	if actor_ent == null:
		return
	if not actor_ent.has_method("get_planar_position"):
		return
	var actor_pos: Vector2 = actor_ent.get_planar_position()
	var anchor: Vector2i = chunk_of(actor_pos)
	if anchor == current_chunk and not _loaded_chunks.is_empty():
		# Same anchor as last update + something already loaded → we're
		# stable. (Empty _loaded_chunks means we just booted; fall through
		# so the initial load fires.)
		return
	current_chunk = anchor

	# 1. LOAD: chunks within stream_radius of anchor that aren't loaded
	for dx in range(-stream_radius, stream_radius + 1):
		for dy in range(-stream_radius, stream_radius + 1):
			var c := Vector2i(anchor.x + dx, anchor.y + dy)
			if _loaded_chunks.has(c):
				continue
			_load_chunk(c, env)

	# 2. UNLOAD: chunks beyond unload_radius
	var to_unload: Array = []
	for c in _loaded_chunks.keys():
		var cv: Vector2i = c
		if abs(cv.x - anchor.x) > unload_radius or abs(cv.y - anchor.y) > unload_radius:
			to_unload.append(cv)
	for c in to_unload:
		_unload_chunk(c, env)

	# Mirror current_chunk into world_state for save/load + binding access
	var world_state: Dictionary = env.get("world", {})
	world_state["current_chunk"] = [anchor.x, anchor.y]


## Initial boot — called once from World.load_data after _persistent has
## been loaded by the World loader. Loads the starting chunk + its
## stream_radius neighbors so the actor's first frame has full context.
func boot(env: Dictionary) -> void:
	current_chunk = starting_chunk
	for dx in range(-stream_radius, stream_radius + 1):
		for dy in range(-stream_radius, stream_radius + 1):
			var c := Vector2i(starting_chunk.x + dx, starting_chunk.y + dy)
			if _loaded_chunks.has(c):
				continue
			_load_chunk(c, env)
	var world_state: Dictionary = env.get("world", {})
	world_state["current_chunk"] = [starting_chunk.x, starting_chunk.y]


# ============================================================
# CHUNK LOAD / UNLOAD
# ============================================================


## Load chunks/<x>_<y>/entities.json. Records spawned entity ids so
## _unload_chunk knows what to despawn later. Persistent-tagged entities
## that appear in a transient chunk are NOT recorded — they survive
## eviction (consistent with chunks/_persistent/ semantics).
func _load_chunk(c: Vector2i, env: Dictionary) -> void:
	var path := "%s/chunks/%d_%d/entities.json" % [data_root, c.x, c.y]
	if not FileAccess.file_exists(path):
		# Empty chunk is valid — record as loaded so we don't re-attempt
		# every tick. boundary_mode "clamp" treats absent chunks as void.
		_loaded_chunks[c] = []
		return
	var entities_before: Array = (env.get("entities", {}) as Dictionary).keys().duplicate()
	_load_entities_json_via_world(path, env)
	var spawned: Array = []
	var entities_after: Dictionary = env.get("entities", {})
	for id in entities_after.keys():
		if entities_before.has(id):
			continue
		# Skip persistent-tagged spawns from the unload tracking — they
		# live forever (treated like _persistent chunk content).
		var ent = entities_after[id]
		if ent != null and ent.has_method("has_tag"):
			var is_persistent := false
			for t in persistent_tags:
				if ent.has_tag(str(t)):
					is_persistent = true
					break
			if is_persistent:
				continue
		spawned.append(str(id))
	_loaded_chunks[c] = spawned
	if verbose:
		print("[ChunkStreamer] loaded chunk (%d, %d): %d entities" % [c.x, c.y, spawned.size()])


## Despawn all entities recorded by `_load_chunk` for this chunk.
## Persistent entities were never recorded so they're naturally untouched.
## We DO remove them from spatial_index here (despite ADR Revisions #3
## stating "spatial_index doesn't keep stale entries") — confirming that
## invariant by an explicit remove_entity call per despawn.
func _unload_chunk(c: Vector2i, env: Dictionary) -> void:
	var ids: Array = _loaded_chunks.get(c, [])
	var entities: Dictionary = env.get("entities", {})
	var relations = env.get("relations", null)
	var spatial_index = env.get("spatial_index", null)
	var unloaded := 0
	for id_v in ids:
		var id := str(id_v)
		var ent = entities.get(id, null)
		if ent == null:
			continue
		if relations != null and relations.has_method("clear_entity"):
			relations.clear_entity(id)
		if spatial_index != null and spatial_index.has_method("remove_entity"):
			spatial_index.remove_entity(id)
		entities.erase(id)
		if ent is Node:
			ent.queue_free()
		unloaded += 1
	_loaded_chunks.erase(c)
	if verbose:
		print("[ChunkStreamer] unloaded chunk (%d, %d): %d entities" % [c.x, c.y, unloaded])


## Bridge to World's loader. Calls the parent World's _load_entities_path
## variant scoped to a single file by reading + spawning via the same
## hook used for entities.json. Per ADR Invariant #1 (JSON-only content)
## the loader logic stays in world.gd — this just delegates.
func _load_entities_json_via_world(path: String, env: Dictionary) -> void:
	var parent_node = env.get("parent", null)
	if parent_node == null:
		return
	if not parent_node.has_method("load_entities_file"):
		# World.gd doesn't expose this yet — fail loudly so the wiring
		# can be added.
		push_warning(
			"[ChunkStreamer] World node missing load_entities_file(); chunk %s ignored" % path
		)
		return
	parent_node.load_entities_file(path)


# ============================================================
# DIAGNOSTICS
# ============================================================


func loaded_chunk_count() -> int:
	return _loaded_chunks.size()


func is_chunk_loaded(c: Vector2i) -> bool:
	return _loaded_chunks.has(c)


## Returns Array[Vector2i] of currently-loaded chunk coords. Used by
## tests + save/load for state introspection.
func loaded_chunks() -> Array:
	return _loaded_chunks.keys()
