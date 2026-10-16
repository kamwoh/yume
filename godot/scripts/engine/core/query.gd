extends RefCounted
class_name QueryLib

## Primitive #6 — Query.
##
## Contract: docs/guideline/30_framework_primitives.md §6
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
	"_eq",
	"_ne",
	"_gt",
	"_lt",
	"_gte",
	"_lte",
	"_atleast",
	"_atmost",
]
# Note: `_has` (set membership where the field is an array) and `_in`
# (ADR 0040, where target is array) are handled as separate suffix branches
# in _match_fields rather than via the scalar-comparison loop above.

## ADR 0075 — reserved key inside a `relations` dict target. Filters the
## EDGE's state rather than the related entity's. The `_` prefix marks the
## engine-reserved namespace inside a query dict, matching `_comment`.
const EDGE_STATE_KEY: String = "_edge"

## ADR 0084 dynamic gate. When true, each query that uses the tag index also
## runs the full scan that the index replaces and compares the two ordered
## results. The test runner and the scenario runner set it, and fail when
## `index_mismatches` is above 0 at the end.
static var verify_index: bool = false
static var index_mismatches: int = 0

# ============================================================
# PUBLIC
# ============================================================


## Does `entity` match the query spec?
static func matches(
	entity: Entity, spec: Dictionary, env: Dictionary, context: Dictionary = {}
) -> bool:
	if spec.is_empty():
		return true

	if spec.has("tags_all"):
		for t in spec["tags_all"]:
			if not entity.has_tag(str(t)):
				return false

	if spec.has("tags_any"):
		var any_ok := false
		for t in spec["tags_any"]:
			if entity.has_tag(str(t)):
				any_ok = true
				break
		if not any_ok:
			return false

	if spec.has("tags_none"):
		for t in spec["tags_none"]:
			if entity.has_tag(str(t)):
				return false

	# Select a specific entity by instance id (or one of a set). Optional;
	# tests use it (the steps[] `expect` by-id case, ADR 0060 migration);
	# rules generally shouldn't hardcode ids (data-demo.md) but the
	# primitive is generic.
	if spec.has("id"):
		if str(entity.instance_id) != str(spec["id"]):
			return false

	if spec.has("ids"):
		var id_ok := false
		for x in spec["ids"]:
			if str(x) == str(entity.instance_id):
				id_ok = true
				break
		if not id_ok:
			return false

	if spec.has("properties"):
		if not _match_fields(entity.properties, spec["properties"]):
			return false

	if spec.has("state"):
		if not _match_fields(entity.state, spec["state"]):
			return false

	if spec.has("relations"):
		if not _match_relations(entity, spec["relations"], env, context):
			return false

	return true


## Scan entities, return those matching `spec`. Applies `radius`,
## `order_by`, and `limit` after the match filter.
##
## If `spec` includes `radius` and `env.spatial_index` exists, the candidate
## set is narrowed via the spatial index (W3.1) — avoids O(n) over all
## entities. Without radius, full scan as before.
##
## Without radius, a query with `tags_all` or `tags_any` starts from the tag
## index (ADR 0084). The result keeps the full scan's order: `env.entities`
## insertion order.
static func run(spec: Dictionary, env: Dictionary, context: Dictionary = {}) -> Array:
	var out := _run(spec, env, context, true)
	if verify_index and not spec.has("radius") and _uses_tag_index(spec):
		var full := _run(spec, env, context, false)
		if full != out:
			index_mismatches += 1
			var msg := (
				"tag index result %s differs from the full scan %s"
				% [_ids(out), _ids(full)]
			)
			push_error("[query.index_mismatch] %s spec=%s" % [msg, spec])
			EngineError.raise(
				env,
				"query.index_mismatch",
				msg,
				{"spec": spec},
				"A tag changed without Entity.tag_epoch. Write tags only through add_tag, remove_tag or the tags setter."
			)
	return out


static func _run(
	spec: Dictionary, env: Dictionary, context: Dictionary, use_index: bool
) -> Array:
	var all: Dictionary = env.get("entities", {})
	var out: Array = []
	var has_radius: bool = spec.has("radius")
	var radius: float = float(spec.get("radius", 0))
	var origin: Vector2 = _resolve_origin(spec, env, context)

	# Narrow candidate set via spatial index when radius + index present.
	var candidates: Array = []
	var from_tag_index := false
	if has_radius:
		var sx = env.get("spatial_index", null)
		if sx != null and sx.has_method("query_radius_ids"):
			var ids: Array = sx.query_radius_ids(origin, radius)
			for id in ids:
				if all.has(id):
					candidates.append(all[id])
		else:
			# fallback: scan all
			candidates = all.values()
	elif use_index and _uses_tag_index(spec):
		candidates = _tag_candidates(spec, env, all)
		from_tag_index = true
	else:
		candidates = all.values()

	for ent in candidates:
		if not (ent is Entity):
			continue
		# Ids are reused across levels and by forced-id spawns, so check the
		# identity, not only the id.
		if from_tag_index and all.get((ent as Entity).instance_id) != ent:
			continue
		if not matches(ent, spec, env, context):
			continue
		if has_radius and (ent as Entity).get_planar_position().distance_to(origin) > radius:
			continue
		out.append(ent)

	if spec.has("order_by"):
		var ob: String = str(spec["order_by"])
		if ob == "distance_asc":
			out.sort_custom(
				func(a, b):
					return (
						(a as Entity).get_planar_position().distance_to(origin)
						< (b as Entity).get_planar_position().distance_to(origin)
					)
			)
		elif ob == "distance_desc":
			out.sort_custom(
				func(a, b):
					return (
						(a as Entity).get_planar_position().distance_to(origin)
						> (b as Entity).get_planar_position().distance_to(origin)
					)
			)

	if spec.has("limit"):
		var n: int = int(spec["limit"])
		if out.size() > n:
			out = out.slice(0, n)

	return out


# ============================================================
# INTERNAL
# ============================================================


static func _uses_tag_index(spec: Dictionary) -> bool:
	var ta = spec.get("tags_all")
	var tn = spec.get("tags_any")
	return (ta is Array and not ta.is_empty()) or (tn is Array and not tn.is_empty())


## The candidates for a tag query, in `env.entities` order. `tags_all` takes
## its smallest tag array. `tags_any` takes the union of its arrays.
static func _tag_candidates(spec: Dictionary, env: Dictionary, all: Dictionary) -> Array:
	var idx := _tag_index(env, all)
	var by_tag: Dictionary = idx["by_tag"]
	var tags_all = spec.get("tags_all")
	if tags_all is Array and not tags_all.is_empty():
		var best: Array = []
		var best_size := -1
		for t in tags_all:
			var arr: Array = by_tag.get(str(t), [])
			if best_size < 0 or arr.size() < best_size:
				best = arr
				best_size = arr.size()
		return best
	var tags_any: Array = spec["tags_any"]
	if tags_any.size() == 1:
		return by_tag.get(str(tags_any[0]), [])
	var ord: Dictionary = idx["ord"]
	var seen := {}
	var union: Array = []
	for t in tags_any:
		for ent in by_tag.get(str(t), []):
			if not seen.has(ent):
				seen[ent] = true
				union.append(ent)
	union.sort_custom(func(a, b): return ord[a] < ord[b])
	return union


## The lazy tag index in `env["_tag_index"]`. It rebuilds when any tag
## changed (Entity.tag_epoch), or when the entity dictionary or its size
## changed (spawn, despawn, level transition, reset).
static func _tag_index(env: Dictionary, all: Dictionary) -> Dictionary:
	var idx = env.get("_tag_index", null)
	if (
		idx is Dictionary
		and idx["epoch"] == Entity.tag_epoch
		and idx["count"] == all.size()
		and is_same(idx["entities"], all)
	):
		return idx
	var by_tag := {}
	var ord := {}
	var i := 0
	for ent in all.values():
		if ent is Entity:
			ord[ent] = i
			for t in (ent as Entity).tags:
				var arr: Array = by_tag.get(t, [])
				if arr.is_empty():
					by_tag[t] = arr
				elif arr.back() == ent:
					continue  # a def that lists a tag twice
				arr.append(ent)
		i += 1
	idx = {
		"epoch": Entity.tag_epoch,
		"count": all.size(),
		"entities": all,
		"by_tag": by_tag,
		"ord": ord,
	}
	env["_tag_index"] = idx
	return idx


static func _ids(ents: Array) -> Array:
	return ents.map(func(e): return (e as Entity).instance_id if e is Entity else str(e))


## Match a flat field map against a spec dict of {field_with_op: value, ...}.
## Used for both `properties` and `state` clauses.
static func _match_fields(fields: Dictionary, spec: Dictionary) -> bool:
	for k in spec:
		var key: String = str(k)
		var target = spec[key]
		# `<field>_has` tests Array set membership. It came with the tech
		# tree that ADR 0085 deleted. The operator is generic, so it stays. Treated as a separate op-suffix branch
		# because OPERATOR_SUFFIXES is sized for scalar comparisons; set
		# membership has different semantics (missing field = no match,
		# non-Array field = no match, value present in array = match).
		if key.ends_with("_has"):
			var field_h: String = key.substr(0, key.length() - 4)
			if not fields.has(field_h):
				return false
			var arr_v = fields[field_h]
			if not (arr_v is Array):
				return false
			if not (arr_v as Array).has(target):
				return false
			continue
		# ADR 0040 — `<field>_in` operator: tests scalar field is in target
		# array. Mirror of `_has` with reversed direction. Used by lib bundle
		# WASD variants to gate on `camera_mode_in: [top_down_3d,
		# third_person_3d]` instead of multiple separate rules.
		if key.ends_with("_in"):
			var field_i: String = key.substr(0, key.length() - 3)
			if not fields.has(field_i):
				return false
			if not (target is Array):
				return false
			if not (target as Array).has(fields[field_i]):
				return false
			continue
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
		"eq":
			return actual == target
		"ne":
			return actual != target
		"gt":
			return actual > target
		"lt":
			return actual < target
		"gte", "atleast":
			return actual >= target
		"lte", "atmost":
			return actual <= target
	return false


## Match a relations clause:
##   {held_by: "self"}              → entity `held_by` the context.self id
##   {part_of: {"tags_any": ["house"]}} → entity `part_of` any house-tagged entity
##   {owned_by: "player_1"}         → literal id reference
static func _match_relations(
	entity: Entity, rel_spec: Dictionary, env: Dictionary, context: Dictionary
) -> bool:
	var store: RelationStore = env.get("relations", null)
	if store == null:
		return false
	for rel_type in rel_spec:
		var target = rel_spec[rel_type]
		if not _check_single_relation(entity, str(rel_type), target, store, env, context):
			return false
	return true


static func _check_single_relation(
	entity: Entity,
	rel_type: String,
	target,
	store: RelationStore,
	env: Dictionary,
	context: Dictionary
) -> bool:
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
	#
	# ADR 0075: the reserved `_edge` key filters the EDGE's own state with the
	# standard operator suffixes; every OTHER key stays the nested entity query
	# it has always been. Both must hold for the SAME edge, which is why the
	# edge check lives inside this loop rather than beside it.
	if target is Dictionary:
		var entities: Dictionary = env.get("entities", {})
		var edge_spec: Dictionary = {}
		var entity_spec: Dictionary = target
		if target.has(EDGE_STATE_KEY):
			var raw = target[EDGE_STATE_KEY]
			edge_spec = (raw as Dictionary) if raw is Dictionary else {}
			entity_spec = target.duplicate()
			entity_spec.erase(EDGE_STATE_KEY)
		for cid in store.targets(rel_type, entity.instance_id):
			if not entities.has(cid):
				continue
			if not edge_spec.is_empty():
				if not _match_fields(
					store.edge_state(rel_type, entity.instance_id, str(cid)), edge_spec
				):
					continue
			var candidate = entities[cid]
			if candidate is Entity and matches(candidate, entity_spec, env, context):
				return true
		return false
	return false


# ============================================================
# ZONE QUERY (ADR 0031 — query_zone operator)
# ============================================================


## Run a zone query against env.zone_store. Returns Array of zone_ids.
## Mirror of run() but over zones, not entities. See ZoneStore.find for
## supported filter shape (id / type / contained_by / contains / state).
##
## Phase scheduler integration: rules with a `query_zone` clause iterate
## these matches and bind `@matched` (the zone dict) into the rule's
## context for effect evaluation. Wiring is phase_scheduler.gd's job
## (out of this ADR's scope per task split — this static helper is the
## stable entry point a future scheduler change can call).
static func run_zones(spec: Dictionary, env: Dictionary) -> Array:
	var zs = env.get("zone_store", null)
	if zs == null or not zs.has_method("find"):
		return []
	if spec == null or not (spec is Dictionary):
		return []
	return zs.find(spec)


## For `radius` queries, find the spatial origin in planar (XZ) space.
## Priority:
##   1. context._origin_position (explicit Vector2 or Array)
##   2. context.self → entity.get_planar_position()
##   3. Vector2.ZERO (no origin; radius filter effectively useless)
static func _resolve_origin(_spec: Dictionary, env: Dictionary, context: Dictionary) -> Vector2:
	if context.has("_origin_position"):
		var p = context["_origin_position"]
		if p is Vector2:
			return p
		if p is Vector3:
			return Vector2(p.x, p.z)
		if p is Array and (p as Array).size() >= 2:
			return Vector2(float(p[0]), float(p[1]))
	if context.has("self"):
		var sid := str(context["self"])
		var all: Dictionary = env.get("entities", {})
		if all.has(sid) and all[sid] is Entity:
			return (all[sid] as Entity).get_planar_position()
	return Vector2.ZERO
