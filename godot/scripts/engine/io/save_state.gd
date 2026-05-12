extends Object
class_name SaveState

## ADR 0010 — Save / load persistence.
##
## Per-game `save_policy.json` declares what persists; engine has ONE
## save/load implementation that reads the policy. Composes Godot
## primitives (FileAccess, JSON, user://) — does NOT reimplement them.
##
## Save format (slot_N.json):
## {
##   "version": <int>,
##   "_meta": {"game": "<name>", "saved_at_unix": <int>, "tick": <int>},
##   "world_state": {<filtered keys>},
##   "persistent_entities": [
##     {"id": "<inst_id>", "def": "<def_id>",
##      "position": [x, y] | [x, y, z],
##      "state": {<filtered fields>},
##      "tags_added": [<runtime tags>]}
##   ],
##   "relations": [
##     {"type": "<rel>", "from": "<id>", "to": "<id>"}
##   ],
##   "current_chunk": [x, y]  // ADR 0014 — only when game opted into
##                            // chunked-world mode (world.json present)
## }
##
## Atomic write: writes to slot_N.json.tmp, then renames over slot_N.json.
## Crash mid-write leaves the prior slot intact.

# ============================================================
# PATHS
# ============================================================


## Resolve user://saves/<game>/slot_N.json. game_name is the data_root
## folder name (e.g. "demo_sokoban"). Engine uses this to namespace per-game.
static func slot_path(game_name: String, slot: int) -> String:
	return "user://saves/%s/slot_%d.json" % [game_name, slot]


static func _ensure_save_dir(game_name: String) -> bool:
	var dir_path := "user://saves/%s" % game_name
	if DirAccess.dir_exists_absolute(dir_path):
		return true
	# DirAccess.make_dir_recursive is the cross-platform way
	var err := DirAccess.make_dir_recursive_absolute(dir_path)
	return err == OK


# ============================================================
# POLICY
# ============================================================


## Load `<data_root>/save_policy.json`. Returns {} if absent, which
## means the game hasn't opted in to save/load. Caller-side: if empty,
## save_state / load_state effects no-op + warn.
static func load_policy(data_root: String) -> Dictionary:
	var root := data_root.rstrip("/")
	var path := root + "/save_policy.json"
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return {}
	return data as Dictionary


# ============================================================
# SAVE
# ============================================================


## Serialize per policy into slot_N.json (atomic). Returns true on
## success. Logs structured error on failure.
##
## env: the live engine env (entities, world dict, relations, ...)
## policy: parsed save_policy.json
## slot: integer 0..N-1
## game_name: data_root basename (e.g. "demo_sokoban")
static func save_to_slot(
	env: Dictionary, policy: Dictionary, slot: int, game_name: String, current_tick: int
) -> bool:
	if policy.is_empty():
		push_warning("save_to_slot: policy is empty (no save_policy.json?); refusing to save")
		return false

	if not _ensure_save_dir(game_name):
		push_error("save_to_slot: cannot create user://saves/%s" % game_name)
		return false

	var payload: Dictionary = {
		"version": int(policy.get("version", 1)),
		"_meta":
		{
			"game": game_name,
			"saved_at_unix": int(Time.get_unix_time_from_system()),
			"tick": current_tick,
		},
		"world_state": _filter_world_state(env, policy),
		"persistent_entities": _serialize_persistent_entities(env, policy),
		"relations": _filter_relations(env, policy),
		# ADR 0031: zone_state persists by default (analogous to world_state).
		# Policy can opt out via "persist_zones": false; or filter via an
		# array of allowed ids.
		"zone_state": _serialize_zone_state(env, policy),
	}
	# ADR 0014: persist current_chunk if game is in chunked-world mode.
	# Read from the live World node (env.parent) — chunk_streamer is the
	# source of truth, NOT world_state["current_chunk"] (which is a
	# mirror that may lag if save fires between tick + update).
	var parent_node = env.get("parent", null)
	if parent_node != null and "chunk_streamer" in parent_node:
		var streamer = parent_node.chunk_streamer
		if streamer != null:
			var c: Vector2i = streamer.current_chunk
			payload["current_chunk"] = [c.x, c.y]

	var dest := slot_path(game_name, slot)
	var tmp := dest + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("save_to_slot: cannot open %s for write" % tmp)
		return false
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	# Atomic rename. DirAccess.rename works on user:// paths.
	var d := DirAccess.open("user://")
	if d == null:
		push_error("save_to_slot: cannot open user:// for rename")
		return false
	# rename() takes paths relative to user://; strip the "user://" prefix
	var src_rel := tmp.replace("user://", "")
	var dst_rel := dest.replace("user://", "")
	# If destination exists, rename overwrites on most platforms; if not,
	# we delete the prior slot first to be safe.
	if FileAccess.file_exists(dest):
		d.remove(dst_rel)
	var err := d.rename(src_rel, dst_rel)
	if err != OK:
		push_error("save_to_slot: rename failed (err=%d) %s → %s" % [err, src_rel, dst_rel])
		return false
	return true


# Apply entity_state_blacklist globs. Returns the filtered world_state.
static func _filter_world_state(env: Dictionary, policy: Dictionary) -> Dictionary:
	var ws_in: Dictionary = env.get("world", {}) as Dictionary
	var keys: Array = policy.get("world_state_keys", [])
	var out: Dictionary = {}
	for k in keys:
		var key := str(k)
		if ws_in.has(key):
			out[key] = ws_in[key]
	return out


static func _serialize_persistent_entities(env: Dictionary, policy: Dictionary) -> Array:
	var entities_in: Dictionary = env.get("entities", {}) as Dictionary
	var tags: Array = policy.get("entity_tags_persistent", [])
	var blacklist: Array = policy.get("entity_state_blacklist", [])
	var out: Array = []
	if tags.is_empty():
		return out
	for inst_id in entities_in.keys():
		var ent = entities_in[inst_id]
		if not (ent is Entity):
			continue
		var e := ent as Entity
		# Match if entity has ANY of the persistent tags
		var matches := false
		for t in tags:
			if e.has_tag(str(t)):
				matches = true
				break
		if not matches:
			continue
		var rec: Dictionary = {
			"id": str(inst_id),
			"def": str(e.def_id),
			"position": _position_to_array(e.get_position()),
			"state": _filter_state(e, blacklist),
		}
		out.append(rec)
	return out


## Filter entity state per blacklist globs. "_temp_*" matches any field
## starting with "_temp_". Field names matched literally if no `*`.
static func _filter_state(e: Entity, blacklist: Array) -> Dictionary:
	var out: Dictionary = {}
	var st: Dictionary = e.state
	for field in st.keys():
		var key := str(field)
		if _matches_any_glob(key, blacklist):
			continue
		out[key] = st[field]
	return out


static func _matches_any_glob(s: String, patterns: Array) -> bool:
	for p in patterns:
		var pat := str(p)
		if pat.ends_with("*"):
			var prefix := pat.substr(0, pat.length() - 1)
			if s.begins_with(prefix):
				return true
		elif pat.begins_with("*"):
			var suffix := pat.substr(1)
			if s.ends_with(suffix):
				return true
		elif s == pat:
			return true
	return false


static func _filter_relations(env: Dictionary, policy: Dictionary) -> Array:
	var rs = env.get("relations", null)
	if rs == null or not rs.has_method("all_of_type"):
		return []
	var allowed: Array = policy.get("relations_persistent", [])
	if allowed.is_empty():
		return []
	var out: Array = []
	for rel_type in allowed:
		var pairs = rs.all_of_type(str(rel_type))
		if not (pairs is Array):
			continue
		for p in pairs:
			if p is Dictionary:
				(
					out
					. append(
						{
							"type": str(rel_type),
							"from": str((p as Dictionary).get("from", "")),
							"to": str((p as Dictionary).get("to", "")),
						}
					)
				)
	return out


## ADR 0031 — serialize zone state per `persist_zones` policy.
##
## persist_zones values:
##   - true  / absent  → all zones persist (default)
##   - false           → no zones persist (returns {})
##   - Array[String]   → only the listed zone ids persist
##
## ZoneStore.to_save() returns flat {zone_id: {field: value, ...}, ...};
## we filter that by the policy.
static func _serialize_zone_state(env: Dictionary, policy: Dictionary) -> Dictionary:
	var zs = env.get("zone_store", null)
	if zs == null or not zs.has_method("to_save"):
		return {}
	var policy_val = policy.get("persist_zones", true)
	if policy_val is bool and not policy_val:
		return {}
	var full: Dictionary = zs.to_save()
	if policy_val is Array:
		var allowed: Array = policy_val
		var filtered: Dictionary = {}
		for zid in full.keys():
			for a in allowed:
				if str(a) == str(zid):
					filtered[zid] = full[zid]
					break
		return filtered
	return full


## ADR 0031 — restore zone state from a save payload's "zone_state" key.
## Called by world.gd's load path after read_slot returns ok. Zones in the
## save but absent from current zones.json are silently dropped (forgive-
## ness — same as entity-state on def removal). Zones present in zones.json
## but absent from save retain their state_init values.
static func restore_zone_state(env: Dictionary, payload: Dictionary) -> void:
	var zs = env.get("zone_store", null)
	if zs == null or not zs.has_method("from_save"):
		return
	var d = payload.get("zone_state", {})
	if d is Dictionary:
		zs.from_save(d)


static func _position_to_array(p) -> Array:
	if p is Vector2:
		return [p.x, p.y]
	if p is Vector3:
		return [p.x, p.y, p.z]
	if p is Array:
		return p as Array
	return [0, 0]


# ============================================================
# LOAD
# ============================================================


## Read slot_N.json, validate version, mutate env in place.
## Returns: {ok: bool, error: String, payload: Dictionary}.
##
## Caller (world.gd) is responsible for what to do AFTER load:
## - clear non-persistent entities (the ones not in payload)
## - re-spawn persistent entities at saved positions/state
## - re-apply relations
## - trigger a level reload of world_state.current_level
##
## This module just reads + validates; mutation is world.gd's job
## because it has the spawn / despawn / level-transition machinery.
static func read_slot(game_name: String, slot: int, policy: Dictionary) -> Dictionary:
	var path := slot_path(game_name, slot)
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "no_such_save", "payload": {}}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "open_failed", "payload": {}}
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return {"ok": false, "error": "invalid_json", "payload": {}}
	var payload := data as Dictionary
	# Schema version check — refuse on mismatch (per ADR; no v1 migrations)
	var save_ver := int(payload.get("version", -1))
	var policy_ver := int(policy.get("version", 1))
	if save_ver != policy_ver:
		return {
			"ok": false,
			"error": "version_mismatch",
			"payload": payload,
			"save_version": save_ver,
			"policy_version": policy_ver
		}
	# Schema sanity check — warn on unknown world_state keys (TD condition)
	_warn_unknown_keys(payload, policy)
	return {"ok": true, "error": "", "payload": payload}


static func _warn_unknown_keys(payload: Dictionary, policy: Dictionary) -> void:
	var ws_in: Dictionary = payload.get("world_state", {}) as Dictionary
	var allowed: Array = policy.get("world_state_keys", [])
	for k in ws_in.keys():
		if not (str(k) in allowed):
			push_warning(
				"save load: unknown world_state key '%s' in save (not in policy); keeping" % str(k)
			)


## Has any save slot been written? Used for the "Continue" button
## visible_if binding (world.has_save).
static func has_any_save(game_name: String, max_slots: int) -> bool:
	for slot in range(max_slots):
		if FileAccess.file_exists(slot_path(game_name, slot)):
			return true
	return false
