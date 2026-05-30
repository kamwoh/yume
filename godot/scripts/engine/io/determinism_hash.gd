extends Object
class_name DeterminismHash

## ADR 0060 Part 1 — the determinism contract.
##
## `canonical(world)` produces a per-tick fingerprint of the ENTIRE world
## state, canonicalized so that the SAME (initial_state, input_log) yields an
## identical hash sequence run-to-run / machine-to-machine (same arch). It is
## the proof that nothing observable changed (Phase-1 parity) and the gate for
## a demo being deterministic-replayable.
##
## Serialization rules (the contract — pin once, document here):
##   - Entities iterated in id-sorted order; each entity = its full
##     `snapshot()` (def/id/properties/state/tags/visual/position).
##   - Dictionary keys sorted; Array order preserved (it is semantic).
##   - Floats at FIXED precision `%.6f` (FLOAT_FMT below). -0.0 normalized to
##     0.0 so the two signed zeros don't hash apart.
##   - world_state included (sorted keys); relations.snapshot() included,
##     SORTED (the store's iteration order is insertion-dependent, not
##     semantic, so it must be sorted to be canonical).
##   - Vector2/Vector3 serialized as their component arrays.
##   - The canonical string is hashed with SHA-256 (deterministic, collision-
##     safe enough for a determinism gate).
##
## Returns `{"hash": <overall sha256>, "ents": {id: <per-entity sha256>}}`.
## The per-entity map lets the oracle name the FIRST divergent entity, not
## just the tick.
##
## NEW ENGINE VOCABULARY — surfaced for tech-director review (ADR 0060).
## Cross-arch float bit-identity is NOT guaranteed; the contract bounds it to
## same-arch with fixed-precision serialization as mitigation (ADR §Consequences).

const FLOAT_FMT := "%.6f"


static func canonical(world) -> Dictionary:
	var ent_hashes: Dictionary = {}
	var ids: Array = []
	for id in world.entities.keys():
		ids.append(str(id))
	ids.sort()

	var parts: PackedStringArray = PackedStringArray()
	for id in ids:
		var e = world.entities[id]
		if not (e is Entity):
			continue
		var ent_canon := _canon((e as Entity).snapshot())
		ent_hashes[id] = ent_canon.sha256_text()
		parts.append(id + "=" + ent_canon)

	# world_state + relations are part of the contract's "state".
	var ws_canon := _canon(world.world_state)
	var rels: Array = []
	if world.relations != null:
		rels = (world.relations.snapshot() as Array).duplicate()
	# Sort relation edges canonically (insertion order is not semantic).
	rels.sort_custom(func(a, b): return _rel_key(a) < _rel_key(b))
	var rel_canon := _canon(rels)

	var overall := "E[" + "\n".join(parts) + "]|WS" + ws_canon + "|REL" + rel_canon
	return {"hash": overall.sha256_text(), "ents": ent_hashes}


static func _rel_key(r) -> String:
	if r is Dictionary:
		return str(r.get("type", "")) + "::" + str(r.get("from", "")) + "::" + str(r.get("to", ""))
	return str(r)


## Recursive canonical serializer for any JSON-able value (+ Vector2/3).
static func _canon(v) -> String:
	if v == null:
		return "null"
	if v is bool:
		return "true" if v else "false"
	if v is int:
		return str(v)
	if v is float:
		var f: float = v
		if absf(f) < 1e-12:  # collapse ±0.0
			f = 0.0
		return FLOAT_FMT % f
	if v is String:
		return "\"" + v + "\""
	if v is Vector2:
		return "[" + (FLOAT_FMT % v.x) + "," + (FLOAT_FMT % v.y) + "]"
	if v is Vector3:
		return "[" + (FLOAT_FMT % v.x) + "," + (FLOAT_FMT % v.y) + "," + (FLOAT_FMT % v.z) + "]"
	if v is Array:
		var items: PackedStringArray = PackedStringArray()
		for e in v:
			items.append(_canon(e))
		return "[" + ",".join(items) + "]"
	if v is Dictionary:
		var keys: Array = []
		for k in v.keys():
			keys.append(str(k))
		keys.sort()
		var pairs: PackedStringArray = PackedStringArray()
		for k in keys:
			pairs.append("\"" + k + "\":" + _canon(v[k]))
		return "{" + ",".join(pairs) + "}"
	# Unknown (Object ref, RID, etc.) — stringify; flagged as a hazard if it
	# ever appears in hashed state (would likely be non-deterministic).
	return "\"<%s>\"" % str(typeof(v))
