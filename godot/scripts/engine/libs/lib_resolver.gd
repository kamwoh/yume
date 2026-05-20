extends Object
class_name LibResolver

## ADR 0027 — cross-game JSON reuse system.
##
## Resolves three operators at JSON load time:
##
##   "@lib.<category>.<name>[.field...]"  — value-replacement reference.
##                                           Replaces the string with the
##                                           cached dict, optionally
##                                           traversing into sub-fields.
##
##   {"$extends": "@lib.X.Y", ...spec}     — merge with overrides. Resolves
##                                           @lib.X.Y as base, overlays
##                                           spec keys (shallow merge —
##                                           top-level only). Spec wins.
##
##   {"$include": "@lib.X.Y"}              — array splice. Inside a parent
##                                           array, replaces this dict with
##                                           the resolved array's elements
##                                           (flattens). Also accepts
##                                           {"$include": [refA, refB, ...]}.
##
## Cache: data/lib/**.json scanned once at engine boot, in-memory keyed by
## file path (slashes → dots, ".json" stripped). Live-edit requires restart
## (per ADR condition 7).
##
## Cycle detection + depth limit (≤ MAX_DEPTH) mirror macro_expander.gd.
## Resolution failures are non-fatal — the resolver pushes a warning and
## leaves the original ref in place so authors see the broken ref in
## downstream errors. Static validator (tools/validate_lib_refs.py) is the
## sync-time gate.
##
## Every resolved dict is stamped with `_origin: "@lib.X.Y"` (or
## `$extends:@lib.X.Y`) so downstream error messages cite the source.

const MAX_DEPTH := 8

# Cache: key = "category.subcat.name" (file path sans extension, slashes → dots)
# Value = parsed top-level JSON of that file (typically a Dictionary)
static var _cache: Dictionary = {}
static var _cache_loaded: bool = false

# ============================================================
# PUBLIC API
# ============================================================


## Load all data/lib/**.json files into the cache. Idempotent — first call
## populates, subsequent calls no-op. Call at engine boot.
static func init_cache(data_root: String) -> void:
	if _cache_loaded:
		return
	_cache_loaded = true
	# data_root is the per-game folder (e.g. data/demo_aldenmere). Lib lives
	# at the SHARED root, one level up.
	var shared_root := data_root.rstrip("/").get_base_dir()
	var lib_root := shared_root + "/lib"
	if not DirAccess.dir_exists_absolute(lib_root):
		# No lib folder — fine, all games can run without lib refs.
		return
	_walk_dir(lib_root, "")


## Reset cache. Used by tests + dev-mode reload. Production code shouldn't
## call this — startup-only is documented behavior per ADR 0027 condition 7.
static func reset_cache_for_test() -> void:
	_cache.clear()
	_cache_loaded = false


## Recursively walk a parsed JSON value and replace lib references. Returns
## a new value (deep-copied where mutated; pass-through if no refs).
static func resolve(value, depth: int = 0, visited: Array = []):
	if depth > MAX_DEPTH:
		push_error(
			(
				"[lib_resolver] depth limit (%d) exceeded — likely cycle: %s"
				% [MAX_DEPTH, str(visited)]
			)
		)
		return value

	# String reference
	if value is String:
		var s := value as String
		if s.begins_with("@lib."):
			return _resolve_string_ref(s, depth, visited)
		return s

	# Dict — check for $extends operator first, then recurse into children.
	# Plain JSON-tree recursion does NOT increment depth — only @lib
	# resolution boundaries do (see _resolve_string_ref / _resolve_extends).
	# depth+visited together catch lib-ref cycles; depth alone shouldn't
	# fire on a deeply-nested screens.json that has no @lib refs at all.
	# Empirical case 2026-05-20: screens.json with nested vbox/elements
	# tripped MAX_DEPTH=8 on plain tree walk (visited=[], no lib chasing).
	if value is Dictionary:
		var d := value as Dictionary
		if d.has("$extends"):
			return _resolve_extends(d, depth, visited)
		var out: Dictionary = {}
		for k in d.keys():
			out[str(k)] = resolve(d[k], depth, visited)
		return out

	# Array — handle $include splices inline. Depth not incremented on
	# plain array recursion (same rationale as the dict case above).
	if value is Array:
		var arr := value as Array
		var out_arr: Array = []
		for item in arr:
			if item is Dictionary and (item as Dictionary).has("$include"):
				_resolve_include_into(out_arr, item as Dictionary, depth, visited)
			else:
				out_arr.append(resolve(item, depth, visited))
		return out_arr

	# Scalars (int / float / bool / null) — pass through.
	return value


# ============================================================
# INTERNAL — REFERENCE RESOLUTION
# ============================================================


## "@lib.X.Y[.field...]" → look up X.Y in cache, traverse remaining fields.
## Returns the resolved value (deep-copied so callers can't mutate cache).
## Stamps `_origin` if the resolved value is a Dictionary.
static func _resolve_string_ref(ref: String, depth: int, visited: Array):
	if visited.has(ref):
		push_error("[lib_resolver] cycle detected: %s → %s" % [" → ".join(visited), ref])
		return null
	var path := ref.substr(5)  # drop "@lib."
	var parts := path.split(".")
	# Find longest matching cache key prefix
	for cut in range(parts.size(), 0, -1):
		var key := ".".join(parts.slice(0, cut))
		if _cache.has(key):
			var val = _cache[key]
			# Traverse remaining parts into the cached dict
			for i in range(cut, parts.size()):
				if not (val is Dictionary):
					push_warning(
						(
							"[lib_resolver] @lib ref '%s' traversal hit non-dict at part '%s'"
							% [ref, parts[i]]
						)
					)
					return value_with_warning(ref)
				val = (val as Dictionary).get(parts[i])
				if val == null:
					push_warning(
						"[lib_resolver] @lib ref '%s' missing field '%s'" % [ref, parts[i]]
					)
					return value_with_warning(ref)
			# Deep-copy + recurse so the lib's own @lib refs expand too
			var new_visited := visited.duplicate()
			new_visited.append(ref)
			var deep_copy = _deep_copy(val)
			var resolved = resolve(deep_copy, depth + 1, new_visited)
			# Stamp _origin metadata on dicts
			if resolved is Dictionary:
				(resolved as Dictionary)["_origin"] = ref
			return resolved
	push_warning(
		"[lib_resolver] @lib ref '%s' not found in cache (loaded: %s)" % [ref, str(_cache.keys())]
	)
	return value_with_warning(ref)


## $extends: merge spec over resolved base. Shallow merge — top-level only.
## Spec keys override base keys.
static func _resolve_extends(d: Dictionary, depth: int, visited: Array) -> Dictionary:
	var extends_ref = d["$extends"]
	var base = resolve(extends_ref, depth + 1, visited)
	if not (base is Dictionary):
		push_warning(
			"[lib_resolver] $extends value '%s' did not resolve to a dict" % str(extends_ref)
		)
		return d
	var merged := (base as Dictionary).duplicate(true)
	for k in d.keys():
		var ks := str(k)
		if ks == "$extends":
			continue
		merged[ks] = resolve(d[k], depth + 1, visited)
	merged["_origin"] = "$extends:" + str(extends_ref)
	return merged


## $include inside an array: splice resolved array's elements into out_arr.
## Accepts $include as String or Array of String.
static func _resolve_include_into(
	out_arr: Array, item: Dictionary, depth: int, visited: Array
) -> void:
	var inc = item["$include"]
	var refs: Array = []
	if inc is String:
		refs.append(inc)
	elif inc is Array:
		for r in inc:
			refs.append(r)
	for r in refs:
		var resolved = resolve(r, depth + 1, visited)
		if resolved is Array:
			for elem in resolved as Array:
				out_arr.append(resolve(elem, depth + 1, visited))
		else:
			push_warning("[lib_resolver] $include ref '%s' did not resolve to an array" % str(r))


# ============================================================
# INTERNAL — CACHE WALK + UTIL
# ============================================================


## Walk a directory tree under `dir_path`, parsing every .json into _cache
## keyed by the path (sans extension, slashes → dots) joined with `key_prefix`.
static func _walk_dir(dir_path: String, key_prefix: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		# Skip hidden + manifest (manifest is for the validator, not resolver)
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		if dir.current_is_dir():
			var sub_prefix: String = entry
			if key_prefix != "":
				sub_prefix = key_prefix + "." + entry
			_walk_dir(dir_path + "/" + entry, sub_prefix)
		elif entry.ends_with(".json") and entry != "manifest.json":
			var key_base := entry.substr(0, entry.length() - 5)  # strip .json
			var full_key: String = key_base
			if key_prefix != "":
				full_key = key_prefix + "." + key_base
			var f := FileAccess.open(dir_path + "/" + entry, FileAccess.READ)
			if f != null:
				var raw := f.get_as_text()
				f.close()
				var parsed = JSON.parse_string(raw)
				if parsed != null:
					_cache[full_key] = parsed
				else:
					push_warning("[lib_resolver] parse error in %s/%s" % [dir_path, entry])
		entry = dir.get_next()


## Deep-copy a JSON value (Dict / Array / scalar). Mirrors Dictionary.duplicate(true)
## but also handles arrays of dicts properly (Godot's Dictionary.duplicate(true)
## already deep-copies, so this just unifies the API).
static func _deep_copy(value):
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	if value is Array:
		var out: Array = []
		for item in value as Array:
			out.append(_deep_copy(item))
		return out
	return value


## Return the original ref string when resolution fails — keeps it visible
## in downstream error output so authors notice. NB: this is the fallback
## path; the validator should catch unresolved refs at sync time.
static func value_with_warning(ref: String) -> String:
	return ref
