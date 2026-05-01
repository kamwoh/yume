extends RefCounted
class_name QueryLib

## Primitive #6 — Query.
##
## Contract: docs/30_framework_primitives.md §6
##
## Declarative entity matcher. One code path serves Rule.query (pivot scan),
## contact pair matching (`a`/`b`), formula `self.nearest(...)`, and effect
## target resolution.
##
## Two entry points:
##   matches(entity, spec, env, context)   — does this one entity match?
##   run(spec, env, context)               — scan all entities, return matches
##
## `env` is a dict carrying engine services the query may need:
##   env.entities  : Dictionary (instance_id → Entity)
##   env.relations : RelationStore
##
## `context` is rule-local bindings (`self`, `a`, `b`, input payload keys).
## Used by the `relations` clause when a target is `"self"` / `"a"` / etc.
##
## Supported clauses (all optional; empty spec matches everything):
##   properties     : {field: value, field_op: value, ...}
##   state          : {field: value, field_op: value, ...}
##   tags_all       : [str, ...]   — entity must have every tag
##   tags_any       : [str, ...]   — entity must have at least one
##   tags_none      : [str, ...]   — entity must have none
##   relations      : {type: target, ...} — see §7 of contract
##   radius         : float        — spatial filter, origin from context
##   limit          : int          — cap result size (run() only)
##   order_by       : "distance_asc" | "distance_desc"
##
## Strict matching: if a query references a field an entity doesn't have,
## the entity fails to match. No permissive fallback.

const OPERATOR_SUFFIXES: Array = [
	"_eq", "_ne", "_gt", "_lt", "_gte", "_lte", "_atleast", "_atmost",
]


# ============================================================
# PUBLIC
# ============================================================

## Does `entity` match the query spec?
static func matches(entity: Entity, spec: Dictionary, env: Dictionary, context: Dictionary = {}) -> bool:
	if spec.is_empty(): return true

	if spec.has("tags_all"):
		for t in spec["tags_all"]:
			if not entity.has_tag(str(t)): return false

	if spec.has("tags_any"):
		var any_ok := false
		for t in spec["tags_any"]:
			if entity.has_tag(str(t)):
				any_ok = true
				break
		if not any_ok: return false

	if spec.has("tags_none"):
		for t in spec["tags_none"]:
			if entity.has_tag(str(t)): return false

	if spec.has("properties"):
		if not _match_fields(entity.properties, spec["properties"]): return false

	if spec.has("state"):
		if not _match_fields(entity.state, spec["state"]): return false

	if spec.has("relations"):
		if not _match_relations(entity, spec["relations"], env, context): return false

	return true


## Scan entities, return those matching `spec`. Applies `radius`,
## `order_by`, and `limit` after the match filter.
##
## If `spec` includes `radius` and `env.spatial_index` exists, the candidate
## set is narrowed via the spatial index (W3.1) — avoids O(n) over all
## entities. Without radius, full scan as before.
static func run(spec: Dictionary, env: Dictionary, context: Dictionary = {}) -> Array:
	var all: Dictionary = env.get("entities", {})
	var out: Array = []
	var has_radius: bool = spec.has("radius")
	var radius: float = float(spec.get("radius", 0))
	var origin: Vector2 = _resolve_origin(spec, env, context)

	# Narrow candidate set via spatial index when radius + index present.
	var candidates: Array = []
	if has_radius:
		var sx = env.get("spatial_index", null)
		if sx != null and sx.has_method("query_radius_ids"):
			var ids: Array = sx.query_radius_ids(origin, radius)
			for id in ids:
				if all.has(id): candidates.append(all[id])
		else:
			# fallback: scan all
			candidates = all.values()
	else:
		candidates = all.values()

	for ent in candidates:
		if not (ent is Entity): continue
		if not matches(ent, spec, env, context): continue
		if has_radius and (ent as Entity).get_planar_position().distance_to(origin) > radius: continue
		out.append(ent)

	if spec.has("order_by"):
		var ob: String = str(spec["order_by"])
		if ob == "distance_asc":
			out.sort_custom(func(a, b): return (a as Entity).get_planar_position().distance_to(origin) < (b as Entity).get_planar_position().distance_to(origin))
		elif ob == "distance_desc":
			out.sort_custom(func(a, b): return (a as Entity).get_planar_position().distance_to(origin) > (b as Entity).get_planar_position().distance_to(origin))

	if spec.has("limit"):
		var n: int = int(spec["limit"])
		if out.size() > n:
			out = out.slice(0, n)

	return out


# ============================================================
# INTERNAL
# ============================================================

## Match a flat field map against a spec dict of {field_with_op: value, ...}.
## Used for both `properties` and `state` clauses.
static func _match_fields(fields: Dictionary, spec: Dictionary) -> bool:
	for k in spec:
		var key: String = str(k)
		var target = spec[key]
		var op: String = "eq"
		var field: String = key
		for suffix in OPERATOR_SUFFIXES:
			if key.ends_with(suffix):
				op = suffix.substr(1)
				field = key.substr(0, key.length() - suffix.length())
				break
		if not fields.has(field):
			return false  # strict: missing field = no match
		if not _compare(fields[field], target, op):
			return false
	return true


static func _compare(actual, target, op: String) -> bool:
	match op:
		"eq": return actual == target
		"ne": return actual != target
		"gt": return actual > target
		"lt": return actual < target
		"gte", "atleast": return actual >= target
		"lte", "atmost": return actual <= target
	return false


## Match a relations clause:
##   {held_by: "self"}              → entity `held_by` the context.self id
##   {part_of: {"tags_any": ["house"]}} → entity `part_of` any house-tagged entity
##   {owned_by: "player_1"}         → literal id reference
static func _match_relations(entity: Entity, rel_spec: Dictionary, env: Dictionary, context: Dictionary) -> bool:
	var store: RelationStore = env.get("relations", null)
	if store == null:
		return false
	for rel_type in rel_spec:
		var target = rel_spec[rel_type]
		if not _check_single_relation(entity, str(rel_type), target, store, env, context):
			return false
	return true


static func _check_single_relation(entity: Entity, rel_type: String, target, store: RelationStore, env: Dictionary, context: Dictionary) -> bool:
	# String target: look up target id via context binding, else treat as literal id.
	if target is String:
		var key := str(target)
		var target_id: String = ""
		if key.begins_with("$"):
			target_id = str(context.get(key.substr(1), ""))
		elif context.has(key):
			target_id = str(context[key])
		else:
			target_id = key  # literal id
		if target_id == "":
			return false
		return store.has_edge(rel_type, entity.instance_id, target_id)
	# Dict target: nested query — does SOME related entity match?
	if target is Dictionary:
		var entities: Dictionary = env.get("entities", {})
		for cid in store.targets(rel_type, entity.instance_id):
			if not entities.has(cid): continue
			var candidate = entities[cid]
			if candidate is Entity and matches(candidate, target, env, context):
				return true
		return false
	return false


## For `radius` queries, find the spatial origin in planar (XZ) space.
## Priority:
##   1. context._origin_position (explicit Vector2 or Array)
##   2. context.self → entity.get_planar_position()
##   3. Vector2.ZERO (no origin; radius filter effectively useless)
static func _resolve_origin(spec: Dictionary, env: Dictionary, context: Dictionary) -> Vector2:
	if context.has("_origin_position"):
		var p = context["_origin_position"]
		if p is Vector2: return p
		if p is Vector3: return Vector2(p.x, p.z)
		if p is Array and (p as Array).size() >= 2: return Vector2(float(p[0]), float(p[1]))
	if context.has("self"):
		var sid := str(context["self"])
		var all: Dictionary = env.get("entities", {})
		if all.has(sid) and all[sid] is Entity:
			return (all[sid] as Entity).get_planar_position()
	return Vector2.ZERO
