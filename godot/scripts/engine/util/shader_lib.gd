class_name ShaderLib
extends RefCounted
## ADR 0089 — the named shaders of the spec.
##
## Content names a library shader by name ("sky_clouds"), never by file.
## A custom shader is a `shader_dag` graph (ADR 0058), which
## tools/yume_shadergen compiles to GRAPH_OUTPUT in the game folder.
##
## validate_host_neutral.py and gen_api_manifest.py read NAMES and
## INTERPRETER_PARAMS from this file. A new name needs an ADR.

const NAMES: Array = [
	"sky_clouds", "water_stylized", "ground_biome_displace",
	"ground_ortho_displace", "toon",
]

## Parameters that the interpreter sets. Content does not set them.
const INTERPRETER_PARAMS: Array = ["plane_size", "screen_tex", "depth_tex", "water_normal_tex"]

const DIR := "res://data/lib/shaders/"

## Where yume_shadergen writes the compiled ground graph, relative to the
## game folder.
const GRAPH_OUTPUT := "assets/shaders/ground.gdshader"

## Textures that the Godot interpreter supplies when content gives none.
## They are Godot resources, so the spec cannot name them (ADR 0089).
const DEFAULT_TEXTURES := {
	"water_stylized": {"water_normal_tex": "res://data/lib/textures/water_normal.tres"},
}


## The library shader `shader_name`, or null after shader.unknown.
## `where` names the JSON field for the error message.
static func load_named(shader_name: String, where: String) -> Shader:
	if not shader_name in NAMES:
		push_error(
			"%s: %s '%s' is not a shader name. The names are: %s (ADR 0089)."
			% [EngineError.SHADER_UNKNOWN, where, shader_name, ", ".join(NAMES)]
		)
		return null
	return load(DIR + shader_name + ".gdshader") as Shader


## The compiled ground graph of the loaded game, or null after
## shader.not_compiled.
static func load_graph() -> Shader:
	var path := AssetPath.resolve(GRAPH_OUTPUT)
	if path == "" or not ResourceLoader.exists(path):
		push_error(
			"%s: ground.mesh.shader_dag has no compiled shader at %s. Run: python3 -m tools.yume_shadergen <game>."
			% [EngineError.SHADER_NOT_COMPILED, GRAPH_OUTPUT]
		)
		return null
	return load(path) as Shader


## `params` plus the DEFAULT_TEXTURES of `shader_name` that it does not set.
static func with_defaults(shader_name: String, params: Dictionary) -> Dictionary:
	var out := params.duplicate()
	var defaults: Dictionary = DEFAULT_TEXTURES.get(shader_name, {})
	for k in defaults:
		if not out.has(k):
			out[k] = load(defaults[k])
	return out
