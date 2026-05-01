extends RefCounted
class_name RelationStore

## Primitive #7 — Relation.
##
## Contract: docs/30_framework_primitives.md §7
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

var _from_idx: Dictionary = {}   # "type::from_id" → Array[String] of to_ids
var _to_idx: Dictionary = {}     # "type::to_id"   → Array[String] of from_ids


# ============================================================
# MUTATION
# ============================================================

## Add an edge. No-op if the exact triple already exists (dedup).
func relate(type: String, from_id: String, to_id: String) -> void:
	var fk := _key(type, from_id)
	var tk := _key(type, to_id)
	var tos: Array = _from_idx.get(fk, [])
	if to_id in tos:
		return  # dedup
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
	relation_removed.emit(type, from_id, to_id)

## Atomically swap the `to` endpoint. Useful for "move item between holders"
## (contract §7 calls this `transfer_relation`).
func transfer_to(type: String, from_id: String, old_to_id: String, new_to_id: String) -> void:
	unrelate(type, from_id, old_to_id)
	relate(type, from_id, new_to_id)

## Swap the `from` endpoint.
func transfer_from(type: String, old_from_id: String, new_from_id: String, to_id: String) -> void:
	unrelate(type, old_from_id, to_id)
	relate(type, new_from_id, to_id)

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
			out.append({"type": type, "from": from_id, "to": str(to_id)})
	return out

## Replace entire store with the snapshot contents. Emits `relation_added`
## for each restored edge.
func restore(snap: Array) -> void:
	_from_idx.clear()
	_to_idx.clear()
	for e in snap:
		if e is Dictionary:
			relate(str(e.get("type", "")), str(e.get("from", "")), str(e.get("to", "")))


# ============================================================
# INTERNAL
# ============================================================

func _key(type: String, id: String) -> String:
	return type + "::" + id
