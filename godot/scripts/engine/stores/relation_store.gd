extends RefCounted
class_name RelationStore

## Primitive #7 — Relation.
##
## Contract: docs/guideline/30_framework_primitives.md §7
##
## Typed directed edges between entities. Storage is a directed multigraph
## indexed both ways: (type, from) → [to_ids] and (type, to) → [from_ids].
## Relation types are user-defined strings — engine treats them all identically.
##
## Uniqueness: (type, from, to) triples are deduplicated at insert time.
## Multiple edges of the same type between different endpoints are allowed.
##
## Signals fire when edges change. `trigger_dispatch.gd` listens to these for
## the `relation_changed` rule trigger.

signal relation_added(type: String, from_id: String, to_id: String)
signal relation_removed(type: String, from_id: String, to_id: String)

var _from_idx: Dictionary = {}  # "type::from_id" → Array[String] of to_ids
var _to_idx: Dictionary = {}  # "type::to_id"   → Array[String] of from_ids

## ADR 0075 — edge-scoped state. "type::from_id::to_id" → Dictionary.
## The fourth state scope alongside entity.state / zone.state / world_state.
## Only edges that actually carry state get an entry; stateless edges cost
## nothing. Entries are created lazily and dropped with their edge.
var _edge_state: Dictionary = {}

# ============================================================
# MUTATION
# ============================================================


## Add an edge. The triple is deduplicated; `state` (ADR 0075) is MERGED into
## the edge either way, so an edge can be created and seeded in either order
## and a later `relate` can update fields without first removing the edge.
func relate(type: String, from_id: String, to_id: String, state: Dictionary = {}) -> void:
	var fk := _key(type, from_id)
	var tk := _key(type, to_id)
	var tos: Array = _from_idx.get(fk, [])
	if to_id in tos:
		_merge_edge_state(type, from_id, to_id, state)
		return  # dedup — edge already present, state merged above
	_merge_edge_state(type, from_id, to_id, state)
	if not _from_idx.has(fk):
		_from_idx[fk] = []
	if not _to_idx.has(tk):
		_to_idx[tk] = []
	_from_idx[fk].append(to_id)
	_to_idx[tk].append(from_id)
	relation_added.emit(type, from_id, to_id)


## Remove an edge. No-op if not present.
func unrelate(type: String, from_id: String, to_id: String) -> void:
	var fk := _key(type, from_id)
	var tk := _key(type, to_id)
	if not _from_idx.has(fk):
		return
	var tos: Array = _from_idx[fk]
	if not (to_id in tos):
		return
	tos.erase(to_id)
	if _to_idx.has(tk):
		(_to_idx[tk] as Array).erase(from_id)
	# ADR 0075 — edge state dies with the edge. No orphan entries.
	_edge_state.erase(_ekey(type, from_id, to_id))
	relation_removed.emit(type, from_id, to_id)


## Atomically swap the `to` endpoint. Useful for "move item between holders"
## (contract §7 calls this `transfer_relation`).
func transfer_to(type: String, from_id: String, old_to_id: String, new_to_id: String) -> void:
	# ADR 0075 — the edge's state travels with the edge. "Move 3 of this item
	# from Alice to Bob" must not silently drop the 3.
	var carried: Dictionary = edge_state(type, from_id, old_to_id).duplicate(true)
	unrelate(type, from_id, old_to_id)
	relate(type, from_id, new_to_id, carried)


## Swap the `from` endpoint.
func transfer_from(type: String, old_from_id: String, new_from_id: String, to_id: String) -> void:
	var carried: Dictionary = edge_state(type, old_from_id, to_id).duplicate(true)
	unrelate(type, old_from_id, to_id)
	relate(type, new_from_id, to_id, carried)


## Drop every edge that touches `entity_id` as either endpoint.
## Called by entity despawn path to keep the store consistent.
func clear_entity(entity_id: String) -> void:
	var drops: Array = []  # [{type, from, to}, ...]
	for key in _from_idx.keys():
		var parts = str(key).split("::", true, 1)
		var type: String = parts[0]
		var src: String = parts[1]
		for to_id in (_from_idx[key] as Array).duplicate():
			if src == entity_id or to_id == entity_id:
				drops.append({"type": type, "from": src, "to": to_id})
	for d in drops:
		unrelate(d["type"], d["from"], d["to"])


# ============================================================
# EDGE STATE (ADR 0075)
# ============================================================


## The edge's state dict. Returns the LIVE dictionary (mutation path), or an
## empty dict when the edge carries no state / doesn't exist. Callers that
## intend to keep the result past the edge's lifetime must duplicate().
func edge_state(type: String, from_id: String, to_id: String) -> Dictionary:
	return _edge_state.get(_ekey(type, from_id, to_id), {})


## Write one field. Returns false (and writes nothing) when the edge doesn't
## exist — these mutators never manufacture graph structure, so a typo'd
## relation name can't silently create edges. Creation stays `relate`'s job.
func set_edge_field(type: String, from_id: String, to_id: String, field: String, value) -> bool:
	if field == "" or not has_edge(type, from_id, to_id):
		return false
	var k := _ekey(type, from_id, to_id)
	if not _edge_state.has(k):
		_edge_state[k] = {}
	(_edge_state[k] as Dictionary)[field] = value
	return true


## Add to a numeric field. Missing field starts from 0 (matches state_add).
func add_edge_field(type: String, from_id: String, to_id: String, field: String, amount) -> bool:
	if field == "" or not has_edge(type, from_id, to_id):
		return false
	var k := _ekey(type, from_id, to_id)
	if not _edge_state.has(k):
		_edge_state[k] = {}
	var cur = (_edge_state[k] as Dictionary).get(field, 0)
	(_edge_state[k] as Dictionary)[field] = cur + amount
	return true


## Clamp a numeric field into [lo, hi]. No-op on a missing field (strict —
## mirrors state_clamp, which never invents a value to clamp).
func clamp_edge_field(type: String, from_id: String, to_id: String, field: String, lo, hi) -> bool:
	if field == "" or not has_edge(type, from_id, to_id):
		return false
	var k := _ekey(type, from_id, to_id)
	if not _edge_state.has(k):
		return false
	var d: Dictionary = _edge_state[k]
	if not d.has(field):
		return false
	d[field] = clampf(float(d[field]), float(lo), float(hi))
	return true


## Merge `state` into the edge's dict. Empty `state` allocates nothing, so
## stateless edges stay free.
func _merge_edge_state(type: String, from_id: String, to_id: String, state: Dictionary) -> void:
	if state.is_empty():
		return
	var k := _ekey(type, from_id, to_id)
	if not _edge_state.has(k):
		_edge_state[k] = {}
	var d: Dictionary = _edge_state[k]
	for f in state:
		d[f] = state[f]


# ============================================================
# QUERY
# ============================================================


## Ids that `from_id` relates to via `type`.
func targets(type: String, from_id: String) -> Array:
	return (_from_idx.get(_key(type, from_id), []) as Array).duplicate()


## Ids that relate to `to_id` via `type`.
func sources(type: String, to_id: String) -> Array:
	return (_to_idx.get(_key(type, to_id), []) as Array).duplicate()


## Does the exact triple exist?
func has_edge(type: String, from_id: String, to_id: String) -> bool:
	var tos: Array = _from_idx.get(_key(type, from_id), [])
	return to_id in tos


## Total edges of a given type. O(n) over the from-index buckets for this type.
func count(type: String) -> int:
	var n := 0
	var prefix := type + "::"
	for key in _from_idx.keys():
		if str(key).begins_with(prefix):
			n += (_from_idx[key] as Array).size()
	return n


## Total edges across all types. Diagnostic / display.
func count_total() -> int:
	var n := 0
	for key in _from_idx.keys():
		n += (_from_idx[key] as Array).size()
	return n


## All edges of `type` as [{from, to}, ...]. For iteration/snapshot.
func all_of_type(type: String) -> Array:
	var out: Array = []
	var prefix := type + "::"
	for key in _from_idx.keys():
		var ks := str(key)
		if not ks.begins_with(prefix):
			continue
		var from_id := ks.substr(prefix.length())
		for to_id in _from_idx[key]:
			out.append({"from": from_id, "to": str(to_id)})
	return out


# ============================================================
# SERIALIZATION (for save/load, replay, tests)
# ============================================================


func snapshot() -> Array:
	var out: Array = []
	for key in _from_idx.keys():
		var parts = str(key).split("::", true, 1)
		var type: String = parts[0]
		var from_id: String = parts[1]
		for to_id in _from_idx[key]:
			var elem: Dictionary = {"type": type, "from": from_id, "to": str(to_id)}
			# ADR 0075 — only emit `state` when the edge has any, so stateless
			# saves stay byte-identical to the pre-0075 shape.
			var st: Dictionary = edge_state(type, from_id, str(to_id))
			if not st.is_empty():
				elem["state"] = st.duplicate(true)
			out.append(elem)
	return out


## Replace entire store with the snapshot contents. Emits `relation_added`
## for each restored edge.
##
## ADR 0075 back-compat: elements WITHOUT a `state` key restore a stateless
## edge, so pre-0075 save files keep loading unchanged.
func restore(snap: Array) -> void:
	_from_idx.clear()
	_to_idx.clear()
	_edge_state.clear()
	for e in snap:
		if e is Dictionary:
			var st = e.get("state", {})
			relate(
				str(e.get("type", "")),
				str(e.get("from", "")),
				str(e.get("to", "")),
				(st as Dictionary) if st is Dictionary else {}
			)


# ============================================================
# INTERNAL
# ============================================================


func _key(type: String, id: String) -> String:
	return type + "::" + id


## Edge-state key (ADR 0075). Distinct from `_key` — this one identifies a
## whole triple, not a (type, endpoint) index bucket.
func _ekey(type: String, from_id: String, to_id: String) -> String:
	return type + "::" + from_id + "::" + to_id
