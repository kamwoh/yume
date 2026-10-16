class_name AssetPath
extends RefCounted
## ADR 0087 — turn an asset reference from game JSON into a Godot path.
##
## The spec writes an asset path relative to the game folder
## ("assets/meshes/hero.glb") or to the shared library
## ("@lib/shaders/toon.gdshader"). Godot needs a res:// path. Every value
## that comes from game JSON goes through resolve(). Engine code may still
## name its own files with res://.
##
## `game_root` is a static because renderers and the static physics and UI
## builders have no world reference. One world loads at a time.
## World.load_data() sets it before any loader runs.
##
## The Python twin is `tools/validators/content.py` (asset_file). Keep
## EXTENSIONS and problem() the same in both files.

const LIB_PREFIX := "@lib/"
const LIB_ROOT := "res://data/lib/"

## The game folder of the loaded world, for example "res://data/demo_x".
static var game_root: String = ""

## A string that ends with one of these is an asset reference (ADR 0087).
const EXTENSIONS := [
	".glb", ".gltf", ".png", ".jpg", ".jpeg", ".webp", ".svg",
	".exr", ".hdr", ".ogg", ".wav", ".mp3", ".gdshader", ".tres",
]


## True when `value` is a string that names an asset file.
static func is_asset(value) -> bool:
	if not (value is String):
		return false
	var lower := (value as String).to_lower()
	for ext in EXTENSIONS:
		if lower.ends_with(ext):
			return true
	return false


## Why `path` is not a host-neutral asset path, or "" when it is one.
static func problem(path: String) -> String:
	if path.contains("://"):
		return "it has a scheme"
	if path.begins_with("/"):
		return "it starts with /"
	if ".." in path.split("/"):
		return "it has a .. segment"
	return ""


## The res:// path for a spec path. Returns "" for an empty path, and
## reports asset_path.not_neutral and returns "" for a path that is not
## neutral.
static func resolve(path: String) -> String:
	path = path.strip_edges()
	if path == "":
		return ""
	var why := problem(path)
	if why != "":
		push_error("asset_path.not_neutral: '%s' (%s). Write it relative to the game folder, or as @lib/<path> (ADR 0087)." % [path, why])
		return ""
	if path.begins_with(LIB_PREFIX):
		return LIB_ROOT + path.substr(LIB_PREFIX.length())
	return game_root.rstrip("/") + "/" + path


## Resolve and load. Returns null when the path is empty, not neutral or
## missing. The caller reports a missing file in its own words.
static func load_asset(path: String) -> Resource:
	var res_path := resolve(path)
	if res_path == "" or not ResourceLoader.exists(res_path):
		return null
	return load(res_path)
