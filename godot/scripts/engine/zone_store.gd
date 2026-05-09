extends RefCounted
class_name ZoneStore

## ADR 0031 — Aggregated zone-state primitive.
##
## A third storage scope alongside entities + world_state, specialized
## for hierarchical aggregate values. Examples:
##   - city.rice_supply (Pendrel has 50 sacks; Brookhaven has 8)
##   - region.iron_demand (Pendrel-region wants iron; Forest-Road doesn't)
##   - kingdom.unrest (kingdom-wide aggregate fed by faction AI)
##
## Authoring shape (data/<game>/world/zones.json):
##   {
##     "zones": [
##       {"id": "kingdom_aldenmere", "type": "kingdom",
##        "contains": ["region_pendrel"], "state_init": {"unrest": 0}},
##       {"id": "region_pendrel", "type": "region",
##        "contains": ["city_pendrel"], "state_init": {"iron_supply": 100}},
##       {"id": "city_pendrel", "type": "city",
##        "contains": [], "state_init": {"iron_supply": 30}}
##     ]
##   }
##
## Authoring rules:
##   - Single-parent tree (no zone listed in two `contains` arrays)
##   - No cycles (A contains B; B contains A → load-time error)
##   - Unknown ids in `contains` → load-time error
##
## Engine API:
##   has(id), get_field(id, field, default), set_field(id, field, value),
##   add_field(id, field, delta), clamp_field(id, field, lo, hi),
##   parent_of(id), descendants_of(id, depth), find(filter).
##
## NO auto-aggregation: zone_state_add to a child does NOT propagate to
## parent. Authors write explicit rollup rules with tick triggers.
##
## NO entity-zone membership: this store doesn't track which entity is in
## which zone. That's content-side (entity declares state.home_zone).
## Future ADR could add an indexed entity_in_zone relation.


# Flat: zone_id → {type, state, contains, parent}
#   type:     String (e.g. "kingdom", "region", "city")
#   state:    Dictionary of fields → values
#   contains: Array of child zone_ids
#   parent:   String parent zone_id (or "" for root)
var zones: Dictionary = {}


# ============================================================
# LOAD
# ============================================================

## Load zones from a parsed zones.json dict.
## Returns Array of EngineError records (empty on success).
##
## Validation:
##   - duplicate id           → error
##   - unknown id in contains → error
##   - multi-parent           → error
##   - cycle                  → error (zone reachable from itself)
func load_from_dict(zones_cfg: Dictionary, env: Dictionary = {}) -> Array:
	var errors: Array = []
	zones.clear()
	if zones_cfg == null or not (zones_cfg is Dictionary):
		return errors
	var zone_list = zones_cfg.get("zones", [])
	if not (zone_list is Array):
		return errors

	# Phase 1: register zones (no parent links yet)
	for raw in zone_list:
		if not (raw is Dictionary):
			errors.append(EngineError.raise(env, "zone.invalid_entry",
				"zone entry not a dict",
				{"file": "world/zones.json", "got": str(raw)},
				"Each zone must be a dict with id/type/contains/state_init."))
			continue
		var z: Dictionary = raw
		var zid := str(z.get("id", ""))
		if zid == "":
			errors.append(EngineError.raise(env, "zone.missing_id",
				"zone missing id",
				{"file": "world/zones.json", "entry": z},
				"Every zone needs a unique 'id' string."))
			continue
		if zones.has(zid):
			errors.append(EngineError.raise(env, "zone.duplicate_id",
				"duplicate zone id: '%s'" % zid,
				{"file": "world/zones.json", "id": zid},
				"Each zone id must be unique across zones.json."))
			continue
		var state_init: Dictionary = (z.get("state_init", {}) as Dictionary).duplicate(true)
		var contains_in = z.get("contains", [])
		var contains_arr: Array = []
		if contains_in is Array:
			for cid in (contains_in as Array):
				contains_arr.append(str(cid))
		zones[zid] = {
			"type": str(z.get("type", "")),
			"state": state_init,
			"contains": contains_arr,
			"parent": "",
		}

	# Phase 2: build parent links + detect multi-parent + unknown refs
	for zid in zones.keys():
		var entry: Dictionary = zones[zid]
		for cid in (entry["contains"] as Array):
			var child_id := str(cid)
			if not zones.has(child_id):
				errors.append(EngineError.raise(env, "zone.unknown_contained",
					"zone '%s' lists unknown child '%s' in contains" % [zid, child_id],
					{"file": "world/zones.json", "parent": zid, "child": child_id},
					"Every id in a zone's 'contains' must reference a defined zone id."))
				continue
			var child: Dictionary = zones[child_id]
			if str(child.get("parent", "")) != "":
				errors.append(EngineError.raise(env, "zone.multi_parent",
					"zone '%s' contained by both '%s' and '%s'" % [child_id, child["parent"], zid],
					{"file": "world/zones.json", "child": child_id,
					 "first_parent": child["parent"], "second_parent": zid},
					"Single-parent tree only — list each zone in at most one 'contains' array."))
				continue
			child["parent"] = zid

	# Phase 3: cycle detection (DFS from each root, detect self-reachable)
	for zid in zones.keys():
		var path: Array = []
		var cycle := _detect_cycle(zid, path)
		if cycle != "":
			errors.append(EngineError.raise(env, "zone.cycle_detected",
				"zone hierarchy contains a cycle: %s" % cycle,
				{"file": "world/zones.json", "cycle_path": cycle},
				"Cycles are forbidden — single-parent tree invariant. Break the loop in zones.json."))
			# Keep first detected cycle, don't spam more for the same SCC
			break
	return errors


## DFS from `start` walking `contains`. Returns "" if no cycle reachable;
## otherwise returns a string like "A → B → C → A" describing the cycle.
func _detect_cycle(start: String, path: Array) -> String:
	if path.has(start):
		var idx := path.find(start)
		var loop: Array = path.slice(idx)
		loop.append(start)
		return " → ".join(loop)
	if not zones.has(start):
		return ""
	var new_path: Array = path.duplicate()
	new_path.append(start)
	for cid in (zones[start]["contains"] as Array):
		var sub := _detect_cycle(str(cid), new_path)
		if sub != "":
			return sub
	return ""


# ============================================================
# ACCESS
# ============================================================

func has(zone_id: String) -> bool:
	return zones.has(zone_id)

func has_zone(zone_id: String) -> bool:
	return zones.has(zone_id)

## Return the full zone record (read-only by convention).
func get_zone(zone_id: String) -> Dictionary:
	if not zones.has(zone_id): return {}
	return zones[zone_id]

## Read a zone state field. Returns `default` if zone or field missing.
## Strict-missing semantic matches QueryLib's convention.
func get_field(zone_id: String, field: String, default = null):
	if not zones.has(zone_id): return default
	var st: Dictionary = zones[zone_id]["state"]
	if not st.has(field): return default
	return st[field]

func set_field(zone_id: String, field: String, value) -> void:
	if not zones.has(zone_id): return
	(zones[zone_id]["state"] as Dictionary)[field] = value

## Add a delta to a numeric field. Auto-initializes missing field to 0
## (consistent with state_add semantics on entity state). Negative deltas OK.
func add_field(zone_id: String, field: String, delta: float) -> void:
	if not zones.has(zone_id): return
	var st: Dictionary = zones[zone_id]["state"]
	var cur := float(st.get(field, 0))
	st[field] = cur + delta

## Clamp a numeric field. No-op if zone missing OR field missing
## (no auto-init — clamping a never-set value would invent a number from
## thin air; per ADR §test_state_clamp_min_max).
func clamp_field(zone_id: String, field: String, lo: float, hi: float) -> void:
	if not zones.has(zone_id): return
	var st: Dictionary = zones[zone_id]["state"]
	if not st.has(field): return
	st[field] = clamp(float(st[field]), lo, hi)


# ============================================================
# HIERARCHY
# ============================================================

## Return the parent zone id of `zone_id`, or "" if root / unknown.
func parent_of(zone_id: String) -> String:
	if not zones.has(zone_id): return ""
	return str(zones[zone_id].get("parent", ""))

## Return descendants of `zone_id`. depth=1 → direct children only;
## depth=-1 (or any negative) → all transitive descendants. depth=0 → empty.
func descendants_of(zone_id: String, depth: int = 1) -> Array:
	var out: Array = []
	if not zones.has(zone_id): return out
	if depth == 0: return out
	var direct: Array = (zones[zone_id]["contains"] as Array).duplicate()
	for cid in direct:
		var c := str(cid)
		out.append(c)
		if depth < 0 or depth > 1:
			var sub_depth := -1 if depth < 0 else (depth - 1)
			for d in descendants_of(c, sub_depth):
				out.append(d)
	return out


# ============================================================
# QUERY (parallel to QueryLib.run, but over zones not entities)
# ============================================================

## Filter shape (all optional):
##   id:           "X"            → direct id match (fires once if exists)
##   type:         "city"         → type tag match
##   contained_by: "X"            → zones whose ancestor (depth-bounded) is X
##   contains:     "X"            → zone(s) whose `contains` includes X
##   depth:        int            → for contained_by; default 1, -1 = all
##   state:        {field_op: v}  → field-comparator vocabulary like entities
##
## Returns Array of zone_ids matching all filters (intersection).
func find(spec: Dictionary) -> Array:
	if spec == null or not (spec is Dictionary):
		return []
	# Direct id case is the cheapest path
	if spec.has("id"):
		var zid := str(spec["id"])
		if not zones.has(zid): return []
		if not _matches_filters(zid, spec): return []
		return [zid]
	# Otherwise scan candidates
	var candidates: Array = []
	if spec.has("contained_by"):
		var parent_id := str(spec["contained_by"])
		var depth := int(spec.get("depth", 1))
		candidates = descendants_of(parent_id, depth)
	elif spec.has("contains"):
		var child_id := str(spec["contains"])
		# return zones whose contains list has child_id (typically 1 — the parent)
		for zid in zones.keys():
			if (zones[zid]["contains"] as Array).has(child_id):
				candidates.append(zid)
	else:
		candidates = zones.keys()
	var out: Array = []
	for zid in candidates:
		if _matches_filters(str(zid), spec):
			out.append(str(zid))
	return out


func _matches_filters(zone_id: String, spec: Dictionary) -> bool:
	if not zones.has(zone_id): return false
	var z: Dictionary = zones[zone_id]
	if spec.has("type"):
		if str(z.get("type", "")) != str(spec["type"]): return false
	if spec.has("state"):
		if not _match_state_fields(z["state"] as Dictionary, spec["state"] as Dictionary):
			return false
	return true


# Mirror of QueryLib._match_fields — kept private so we don't depend on
# QueryLib's static internals from another module.
const _ZONE_OPERATOR_SUFFIXES: Array = [
	"_eq", "_ne", "_gt", "_lt", "_gte", "_lte", "_atleast", "_atmost",
]

func _match_state_fields(fields: Dictionary, spec: Dictionary) -> bool:
	for k in spec.keys():
		var key: String = str(k)
		var target = spec[key]
		var op: String = "eq"
		var field: String = key
		for suffix in _ZONE_OPERATOR_SUFFIXES:
			if key.ends_with(suffix):
				op = suffix.substr(1)
				field = key.substr(0, key.length() - suffix.length())
				break
		if not fields.has(field): return false  # strict-missing
		if not _compare(fields[field], target, op): return false
	return true


static func _compare(actual, target, op: String) -> bool:
	match op:
		"eq": return actual == target
		"ne": return actual != target
		"gt": return actual > target
		"lt": return actual < target
		"gte", "atleast": return actual >= target
		"lte", "atmost":  return actual <= target
	return false


# ============================================================
# BINDING SNAPSHOT (for Formula evaluation)
# ============================================================

## Build a flat `{zone_id: {field: value}}` snapshot suitable for use as
## the `zone` root in a Formula context. Resolves `zone.<id>.<field>`.
##
## Returns a SHARED reference into the live state dicts — Formula reads it
## but won't mutate (Formula is a read-only evaluator). Mutation goes
## through set_field / add_field / clamp_field.
func binding_snapshot() -> Dictionary:
	var out: Dictionary = {}
	for zid in zones.keys():
		out[str(zid)] = zones[zid]["state"]
	return out


# ============================================================
# SAVE / LOAD
# ============================================================

## Serialize zone state for save_state.gd. Returns flat
## {zone_id: {field: value, ...}, ...} — only state, not type/contains
## (those re-load from the current zones.json on next session).
func to_save() -> Dictionary:
	var out: Dictionary = {}
	for zid in zones.keys():
		# Duplicate to decouple save snapshot from live state
		out[str(zid)] = (zones[zid]["state"] as Dictionary).duplicate(true)
	return out


## Restore zone state from a save dict. Zones in the save but absent from
## current zones.json are dropped (forgiveness — same as entity-on-def-
## removal). Zones in current zones.json absent from the save retain
## state_init values. Per-field merge: save values override state_init
## but missing fields keep state_init defaults.
func from_save(d: Dictionary) -> void:
	if d == null or not (d is Dictionary): return
	for zid in d.keys():
		var key := str(zid)
		if not zones.has(key): continue
		var saved: Dictionary = d[zid] as Dictionary
		var live: Dictionary = zones[key]["state"]
		for fk in saved.keys():
			live[str(fk)] = saved[fk]


# ============================================================
# DIAGNOSTICS
# ============================================================

func count() -> int:
	return zones.size()
