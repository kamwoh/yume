extends Node3D
class_name EntityMesh3D

## 3D renderer for Entity (W5.0a). Mirrors entity_sprite_2d.gd's three-tier
## fallback for 3D:
##   1. entity.visual.model_3d → load .glb / .gltf / .scn / .tscn
##   2. entity.visual.mesh → compose primitives from meshes.json
##   3. nothing → bare colored box (entity.visual.color + size)
##
## Position is synced from entity.state.position (Vector2 or Vector3) each
## frame. 2D positions get lifted to XZ plane (Y=0) per W5.0 coordinate
## convention. Same data contract as the 2D renderer — engine doesn't change.

@export var fallback_color: Color = Color(0.7, 0.7, 0.7)
@export var fallback_size: float = 0.5
@export var meshes_path: String = "res://data/meshes.json"
## Scale entity.state.position into world-units. Engine uses pixel-scale
## positions (~200 unit demos); 3D scenes typically have entities ~1m apart.
## With position_scale=0.05, 200 pixels → 10 world units.
@export var position_scale: float = 0.05

# Render mode: "model", "mesh", "glb", or "bare"
var _mode: String = "bare"
# True when a STATIC .glb was normalized to unit-height/base-on-ground so
# fitted state.scale places it like a kit (see _normalize_glb). Animated
# .glb (player) are left at their authored scale, so this stays false.
var _glb_normalized: bool = false

# Mesh-mode state
var _mesh_primitives: Array = []
var _mesh_params: Dictionary = {}
var _mesh_cast_shadow: bool = true

# Entity reference + position sync
var _entity_ref: Entity = null

# ADR 0035 — per-entity animation interpreter (null when mesh has no
# `animations` block or when load-time validation failed).
var _animation_director: AnimationDirector = null

# Cached mesh library
static var _mesh_lib_cache: MeshLib = null


func _ready() -> void:
	var ent := get_parent() as Entity
	if ent == null:
		push_warning("EntityMesh3D requires an Entity parent")
		return
	_entity_ref = ent
	# ADR 0041 — engine-managed tag set by multimesh_director when this
	# entity is batched. Mark the renderer so the director can find +
	# remove it cleanly; skip the mesh-build path so we don't waste work
	# on nodes that'll be queue_freed in the same frame.
	set_meta("_yume_renderer", true)
	if ent.has_tag("_multimesh_managed"):
		return
	var visual: Dictionary = ent.visual

	# ADR 0072 — per-entity light source(s). Mounted FIRST (independent
	# of which visual tier renders below); follow the entity like any
	# child. Accepts a single dict or an ARRAY of dicts — multi-light
	# fixtures (area-light emulation panels, chandeliers, paired
	# headlights) are one def.
	var light_v = visual.get("light", null)
	if light_v is Dictionary:
		_mount_light(light_v)
	elif light_v is Array:
		for lc in (light_v as Array):
			if lc is Dictionary:
				_mount_light(lc)

	# Tier 1 — real model file
	var model_path := str(visual.get("model_3d", ""))
	if model_path != "" and ResourceLoader.exists(model_path):
		var packed = load(model_path)
		if packed is PackedScene:
			add_child((packed as PackedScene).instantiate())
		elif packed is Mesh:
			var mi := MeshInstance3D.new()
			mi.mesh = packed
			add_child(mi)
		_mode = "model"
		_apply_shadow_only_if_set(visual)
		_sync_position()
		return

	# Tier 1.5 — .glb-backed mesh (ADR 0046 Phase B). When `visual.mesh`
	# points to a .glb / .gltf file (vs a mesh-lib name), load it as a
	# Godot PackedScene. State-rules from `visual.animation_state_rules`
	# drive the imported AnimationPlayer (Godot's GLTF importer auto-
	# creates one with all the .glb's clips). Material overrides from
	# `visual.material_overrides` patch named surfaces post-load.
	#
	# Authoring contract:
	#   visual: {
	#     "mesh": "res://path/to/foo.glb",
	#     "animation_state_rules": [
	#       {"if_velocity_gt": 0.1, "state": "walk", "clip_alias": "Walking"},
	#       {"default": "idle", "clip_alias": "Idle"}
	#     ],
	#     "animation_blend_seconds": 0.15,
	#     "material_overrides": {"body": "#a0c0e0"}  // surface_name → color
	#   }
	#
	# clip_alias maps the engine-side `state` name to the .glb's clip
	# name (which is decided by the modeling tool, e.g. Blender NLA
	# track names). Falls back to the state name verbatim if no alias.
	var mesh_field := str(visual.get("mesh", ""))
	if mesh_field.ends_with(".glb") or mesh_field.ends_with(".gltf"):
		_load_glb_mesh(mesh_field, visual, ent)
		return

	# Tier 2 — mesh from library (compose primitives). Falls back to
	# visual.shape if no explicit visual.mesh — convenient for shared data
	# files where 2D shape names match 3D mesh names by convention.
	var mesh_name := str(visual.get("mesh", visual.get("shape", "")))
	if mesh_name != "":
		var lib := _get_mesh_lib()
		if lib.has(mesh_name):
			var mesh_def := lib.get_mesh(mesh_name)
			_mesh_primitives = mesh_def.get("primitives", [])
			_mesh_params = MeshLib.merge_params(mesh_def, visual.get("params", {}) as Dictionary)
			_mesh_cast_shadow = bool(mesh_def.get("cast_shadow", true))
			_build_mesh_children()
			# ADR 0035 — instantiate animation director if mesh def declares
			# animations. Returns null for static meshes (backwards-compat).
			# ADR 0046 Phase A.2 (2026-05-17): cutover from GDScript
			# interpolator → Godot AnimationPlayer. Build a translated
			# AnimationLibrary and mount an AnimationPlayer as a child of
			# THIS Node3D. Track paths in the library resolve relative to
			# the AnimationPlayer's root_node (defaults to "..", i.e. this
			# parent — exactly where the mesh pieces live).
			# Invariant #11: the AnimationPlayer is owned by this entity's
			# visual root; it dies with the entity on transition_level. No
			# new smoothed-state surface that survives the discontinuity.
			_animation_director = AnimationDirector.from_mesh_def(mesh_def, self, ent, {})
			if _animation_director != null:
				var ap := AnimationPlayer.new()
				ap.name = "AnimationPlayer"
				add_child(ap)
				var anims_block: Dictionary = mesh_def["animations"]
				var baselines := AnimationTranslator.collect_baselines(self, anims_block)
				var anim_lib := AnimationTranslator.build_library(anims_block, baselines)
				if anim_lib != null:
					# Empty library name = default; clip names look up directly.
					ap.add_animation_library("", anim_lib)
				_animation_director.attach_player(ap)
			# Task #117: paint every primitive with a shared albedo texture
			# when the entity def declares one (typically asset-gen output).
			if visual.has("albedo_texture"):
				_apply_albedo_texture_to_primitives(str(visual["albedo_texture"]))
			# ADR 0052: custom shader. Replaces the per-primitive
			# StandardMaterial3D with a ShaderMaterial backed by the
			# referenced .gdshader. Uniforms come from `visual.
			# shader_params` (a dict of param-name → value). Applied
			# to ALL primitives uniformly — for per-primitive shaders,
			# extend with material_overrides later.
			if visual.has("shader"):
				_apply_shader_to_primitives(
					str(visual["shader"]),
					visual.get("shader_params", {})
				)
			_mode = "mesh"
			_apply_shadow_only_if_set(visual)
			_sync_position()
			return

	# Tier 3 — bare colored box
	var color := _parse_color(visual.get("color", fallback_color))
	var size := float(visual.get("size", fallback_size))
	var mi_box := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(size, size, size)
	mi_box.mesh = box
	mi_box.material_override = _make_material(color)
	add_child(mi_box)
	_mode = "bare"
	_apply_shadow_only_if_set(visual)
	_sync_position()


# ============================================================
# ADR 0072 — per-entity light source
# ============================================================


## Mount an OmniLight3D / SpotLight3D child from visual.light.
## Shadows default OFF — per-light shadow maps are the expensive half;
## enabling them per-lamp is the author's informed choice. Spot lights
## aim their -Z along `direction` (default straight down).
func _mount_light(cfg: Dictionary) -> void:
	var light: Light3D
	if str(cfg.get("type", "omni")).to_lower() == "spot":
		var spot := SpotLight3D.new()
		spot.spot_range = float(cfg.get("range", 10.0))
		spot.spot_angle = float(cfg.get("angle", 45.0))
		light = spot
	else:
		var omni := OmniLight3D.new()
		omni.omni_range = float(cfg.get("range", 10.0))
		light = omni
	light.name = "EntityLight"
	light.light_color = _parse_color(cfg.get("color", "#ffffff"))
	light.light_energy = float(cfg.get("energy", 1.0))
	light.shadow_enabled = bool(cfg.get("shadow", false))
	var pos = cfg.get("position", [0, 1, 0])
	var world_off := Vector3(0, 1, 0)
	if pos is Array and (pos as Array).size() >= 3:
		world_off = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	light.position = world_off
	add_child(light)
	# visual.light offsets are WORLD units. The renderer node carries
	# state.scale, which would otherwise scale the light's offset AND its
	# cone/range geometry (a [0.16, 5, 0.16] pole catapults a y=4 light
	# to world y=20 and crushes the cone 0.16x — empirical 2026-06-13,
	# lightlab theater spot lit NOTHING). _apply_light_counter_scale
	# inverts the node scale per light after every _sync_scale.
	_light_world_offsets.append({"light": light, "offset": world_off})
	_apply_light_counter_scale()
	# ADR 0072 addendum — rule-DRIVEN lights: optional state bindings.
	#   "energy_binds": "<state field>"  → light_energy follows the field
	#   "color_binds":  "<state field>"  → light_color follows (hex string)
	# Rules mutate the state; the renderer reads it per frame (the same
	# state-read contract as position/yaw/scale). Enables flicker,
	# day-gated lamps, dimmer switches — all pure JSON rules. Per-light
	# records so multi-light fixtures bind independently.
	var ef := str(cfg.get("energy_binds", ""))
	var cf := str(cfg.get("color_binds", ""))
	if ef != "" or cf != "":
		_light_binds.append({"light": light, "energy": ef, "color": cf})
	if light is SpotLight3D:
		var dir = cfg.get("direction", [0, -1, 0])
		if dir is Array and (dir as Array).size() >= 3:
			var v := Vector3(float(dir[0]), float(dir[1]), float(dir[2])).normalized()
			if v.length() > 0.5:
				var up := Vector3.UP if absf(v.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
				light.look_at(light.global_position + v, up)


var _light_binds: Array = []  # [{light: Light3D, energy: String, color: String}]
var _light_world_offsets: Array = []  # [{light: Light3D, offset: Vector3 (world units)}]


## Counter-scale mounted lights so visual.light offsets + cone/range
## geometry stay in WORLD units regardless of the prop's state.scale.
func _apply_light_counter_scale() -> void:
	var s := scale
	if absf(s.x) < 0.0001 or absf(s.y) < 0.0001 or absf(s.z) < 0.0001:
		return
	for rec in _light_world_offsets:
		var light: Light3D = rec["light"]
		if light == null:
			continue
		var off: Vector3 = rec["offset"]
		light.position = Vector3(off.x / s.x, off.y / s.y, off.z / s.z)
		light.scale = Vector3(1.0 / s.x, 1.0 / s.y, 1.0 / s.z)


## Per-frame state→light sync (only for lights with declared bindings —
## zero cost otherwise).
func _sync_light() -> void:
	if _light_binds.is_empty() or _entity_ref == null:
		return
	for b in _light_binds:
		var light: Light3D = b["light"]
		if light == null:
			continue
		var ef := str(b["energy"])
		if ef != "":
			var e = _entity_ref.get_state(ef, null)
			if e != null:
				light.light_energy = maxf(0.0, float(e))
		var cf := str(b["color"])
		if cf != "":
			var c = _entity_ref.get_state(cf, null)
			if c != null:
				light.light_color = _parse_color(c)


# ============================================================
# .glb / .gltf LOADING (ADR 0046 Phase B)
# ============================================================


## Load a .glb / .gltf scene file as the entity's mesh + wire its
## embedded AnimationPlayer to the state-rule bridge. Mirrors the
## mesh-lib tier 2 path: register the AnimationDirector, ensure an
## AnimationPlayer is available, attach. Difference from tier 2:
##   - No primitive-assembly via mesh_lib.gd
##   - AnimationPlayer + clips come PRE-BAKED in the .glb (Godot's
##     GLTF importer auto-creates one). Translator doesn't run.
##   - state_rules live on `visual` (no separate mesh_def).
##   - clip_alias resolves engine-side state names → .glb clip names.
##
## Falls back to a colored box if the .glb fails to load (instead of
## leaving the entity invisible). Surfaces a push_warning so authors
## see the failure in stdout.
func _load_glb_mesh(path: String, visual: Dictionary, ent: Entity) -> void:
	if not ResourceLoader.exists(path):
		push_warning("EntityMesh3D: .glb path not found: %s" % path)
		_build_bare_box(visual)
		return
	var packed = load(path)
	if not (packed is PackedScene):
		push_warning("EntityMesh3D: .glb did not load as PackedScene: %s" % path)
		_build_bare_box(visual)
		return
	var imported: Node = (packed as PackedScene).instantiate()
	# Wrap in a normalizer so a static .glb can be fit to unit-height /
	# base-on-ground without disturbing the imported scene's own transform.
	var norm := Node3D.new()
	norm.name = "GlbNormalizer"
	add_child(norm)
	norm.add_child(imported)
	_mode = "glb"

	# Apply material overrides — `visual.material_overrides` is a dict
	# of {surface_name: color_string} that re-skins named surfaces.
	var overrides = visual.get("material_overrides", null)
	if overrides is Dictionary:
		_apply_material_overrides(imported, overrides as Dictionary)

	# Locate the embedded AnimationPlayer. Godot's GLTF importer puts it
	# directly under the scene root and names it "AnimationPlayer".
	var ap: AnimationPlayer = _find_imported_animation_player(imported)
	if ap != null:
		# Force every imported clip to loop. Tripo/Blender-export GLBs
		# default to loop_mode=LOOP_NONE; without this, AnimationPlayer
		# plays the clip once and stops. State-driven animation_state_rules
		# rely on the clip looping while the state condition holds (e.g.
		# walk continues while velocity > 0.1). Set unconditionally — Yume's
		# clips are all gameplay-state-driven, none are one-shots.
		# Empirical case 2026-05-18: morwen + player walked one cycle then
		# froze even though player kept moving.
		for clip_name in ap.get_animation_list():
			var anim := ap.get_animation(clip_name)
			if anim != null:
				anim.loop_mode = Animation.LOOP_LINEAR
	var rules = visual.get("animation_state_rules", null)
	if ap != null and rules is Array:
		# Build a virtual mesh_def from the visual block so
		# AnimationDirector.from_mesh_def can construct + register rules.
		# `animations` is empty on the def (clips live in the imported
		# library) but the director only needs animation_state_rules to
		# evaluate; clips are resolved at play-time via clip_alias.
		var virtual_mesh_def: Dictionary = {
			"_origin": "glb:" + path,
			"animations": {},  # presence required; can be empty
			"animation_state_rules": rules,
			"animation_blend_seconds": visual.get("animation_blend_seconds", 0.15),
		}
		_animation_director = AnimationDirector.from_mesh_def(
			virtual_mesh_def, self, ent, {}
		)
		if _animation_director != null:
			_animation_director.attach_player(ap)
			_animation_director.set_clip_aliases(_build_clip_alias_map(rules))

	# Static .glb (no embedded AnimationPlayer): normalize so the SAME
	# fitted state.scale that places code-kits also places this mesh.
	# Tripo/most exporters center the mesh in an arbitrary bbox (e.g.
	# 2×2×2 at origin); without this it'd render mis-sized + half-buried.
	# Animated meshes (player) are authored to their scale + pivot — skip.
	# `visual.normalize: false` ALSO skips it — for a pre-authored world
	# mesh (e.g. an imported city/terrain) that must render at its NATIVE
	# scale + origin so a matching trimesh collider aligns 1:1. ADR 0062.
	if ap == null and bool(visual.get("normalize", true)):
		_normalize_glb(norm, imported)

	_apply_shadow_only_if_set(visual)
	_sync_position()


## Walk the imported scene tree top-down for an AnimationPlayer node.
## Godot's GLTF importer always names it "AnimationPlayer" and parents
## it directly to the scene root, so the search is shallow. Returns
## the first one found or null if the .glb has no animations.
func _find_imported_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var found := _find_imported_animation_player(child)
		if found != null:
			return found
	return null


## Normalize a static .glb (held under `norm`) so its bbox becomes
## unit-HEIGHT, base at y=0, centred in X/Z — in this entity's local
## space. After this, applying state.scale as a UNIFORM height multiplier
## (see _sync_scale) sizes the mesh to the fitted height with its native
## proportions preserved and its base on the ground. Derived entirely
## from the mesh bbox — no per-def scale/offset authoring (no escape hatch).
func _normalize_glb(norm: Node3D, imported: Node) -> void:
	if not (imported is Node3D):
		return
	var aabb: AABB = (imported as Node3D).transform * _local_aabb(imported as Node3D)
	if aabb.size.y <= 0.0001:
		return
	var s: float = 1.0 / aabb.size.y
	norm.scale = Vector3(s, s, s)
	# Map current bbox → base at y=0, centred in X/Z (offsets are in the
	# pre-scale frame, so multiply by s to land in norm's scaled output).
	norm.position = Vector3(
		-(aabb.position.x + aabb.size.x * 0.5) * s,
		-aabb.position.y * s,
		-(aabb.position.z + aabb.size.z * 0.5) * s)
	_glb_normalized = true


## Combined AABB of every MeshInstance3D under `node`, in `node`'s OWN
## local space (accumulating child transforms). Pure read; no scene mutation.
func _local_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var seeded := false
	if node is MeshInstance3D:
		out = (node as MeshInstance3D).get_aabb()
		seeded = true
	for c in node.get_children():
		if c is Node3D:
			var child_aabb: AABB = (c as Node3D).transform * _local_aabb(c as Node3D)
			if child_aabb.size == Vector3.ZERO:
				continue
			if seeded:
				out = out.merge(child_aabb)
			else:
				out = child_aabb
				seeded = true
	return out


## Walk every MeshInstance3D under the imported scene. For each
## surface whose material has a `resource_name` matching a key in
## `overrides`, duplicate the material (so the override is per-entity,
## not shared with other instances) and apply the override patch.
##
## Surface name resolution order:
##   1. material.resource_name (set by the GLTF importer to the
##      material name from Blender/Maya)
##   2. surface index ("surface_0", "surface_1", ...)
##
## Override values may be:
##   - a string color ("#RRGGBB" hex, "white" Godot named, [r,g,b,a])
##     → applied as albedo_color (legacy shorthand)
##   - a dict with any of:
##       albedo_color:     color string/array
##       albedo_texture:   res:// path to a PNG → loaded + set
##       roughness:        0..1 float
##       metallic:         0..1 float
##       normal_texture:   res:// path to a normal map
##     → fine-grained material control. Enables AI-generated textures
##       (task #116) to flow into the imported mesh's surfaces.
func _apply_material_overrides(scene_root: Node, overrides: Dictionary) -> void:
	if overrides.is_empty():
		return
	_apply_material_overrides_recursive(scene_root, overrides)


func _apply_material_overrides_recursive(node: Node, overrides: Dictionary) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var mesh := mi.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				var mat: Material = mesh.surface_get_material(i)
				var resolved_key := ""
				if mat != null and mat.resource_name != "":
					if overrides.has(mat.resource_name):
						resolved_key = mat.resource_name
				if resolved_key == "":
					var idx_key := "surface_%d" % i
					if overrides.has(idx_key):
						resolved_key = idx_key
				if resolved_key == "":
					continue
				# Duplicate so we don't mutate the shared imported resource.
				var dup: StandardMaterial3D
				if mat is StandardMaterial3D:
					dup = (mat as StandardMaterial3D).duplicate(true)
				else:
					dup = StandardMaterial3D.new()
				_apply_override_patch(dup, overrides[resolved_key])
				mi.set_surface_override_material(i, dup)
	for child in node.get_children():
		_apply_material_overrides_recursive(child, overrides)


## Apply a single override entry to a StandardMaterial3D. Accepts
## both the legacy color-string shorthand AND the new dict form
## with explicit fields. Texture paths are loaded via ResourceLoader.
func _apply_override_patch(dup: StandardMaterial3D, override) -> void:
	# Legacy shorthand: a bare color (string / Color / Array) sets
	# albedo_color only. Kept for backwards-compat with material_
	# overrides authored before task #117.
	if not (override is Dictionary):
		dup.albedo_color = _parse_color(override)
		return
	var od: Dictionary = override
	if od.has("albedo_color"):
		dup.albedo_color = _parse_color(od["albedo_color"])
	if od.has("albedo_texture"):
		var tex_path := str(od["albedo_texture"])
		if tex_path != "" and ResourceLoader.exists(tex_path):
			var tex = load(tex_path)
			if tex is Texture2D:
				dup.albedo_texture = tex
		else:
			push_warning(
				"material_overrides: albedo_texture not found: %s" % tex_path
			)
	if od.has("normal_texture"):
		var npath := str(od["normal_texture"])
		if npath != "" and ResourceLoader.exists(npath):
			var ntex = load(npath)
			if ntex is Texture2D:
				dup.normal_texture = ntex
				dup.normal_enabled = true
	# Roughness / metallic override. In Godot StandardMaterial3D, the
	# final value = factor * texture_sample. Tripo3D bakes an ORM texture
	# (Occlusion/Roughness/Metallic) into its outputs; setting only the
	# factor leaves the texture in play and the override is partial.
	# Clearing the texture as well makes the factor authoritative.
	# Empirical case 2026-05-18: user reported "everything looks
	# reflective" — Tripo3D's baked ORM was making roughness override
	# silently partial.
	if od.has("roughness"):
		dup.roughness = float(od["roughness"])
		dup.roughness_texture = null
	if od.has("metallic"):
		dup.metallic = float(od["metallic"])
		dup.metallic_texture = null


## Build a {state_name: clip_name} map from animation_state_rules,
## using `clip_alias` where present and falling back to the state name.
## AnimationDirector uses this at tick time to translate its resolved
## state name into the AnimationPlayer's clip name.
func _build_clip_alias_map(rules: Array) -> Dictionary:
	var out: Dictionary = {}
	for rule in rules:
		if not (rule is Dictionary):
			continue
		var rd: Dictionary = rule
		var state_name := ""
		if rd.has("default"):
			var dv = rd["default"]
			state_name = str(dv) if dv is String else str(rd.get("state", ""))
		else:
			state_name = str(rd.get("state", ""))
		if state_name == "":
			continue
		if rd.has("clip_alias"):
			out[state_name] = str(rd["clip_alias"])
	return out


## Fallback bare-box renderer when .glb load fails. Same shape as the
## Tier 3 path below but factored out so _load_glb_mesh can call it
## without duplicating the inline code.
func _build_bare_box(visual: Dictionary) -> void:
	var color := _parse_color(visual.get("color", fallback_color))
	var size := float(visual.get("size", fallback_size))
	var mi_box := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(size, size, size)
	mi_box.mesh = box
	mi_box.material_override = _make_material(color)
	add_child(mi_box)
	_mode = "bare"
	_apply_shadow_only_if_set(visual)
	_sync_position()


## If `visual.hide_for_camera_attach=true`, recursively set all
## MeshInstance3D children to SHADOWS_ONLY — the mesh casts a shadow
## on the ground but doesn't render to any camera. Doom/CSGO viewmodel
## pattern: the player's own body is invisible from their first-person
## view (the viewmodel weapon overlay handles "what the player sees of
## themselves") but still has a presence on the ground for atmosphere.
func _apply_shadow_only_if_set(visual: Dictionary) -> void:
	if not bool(visual.get("hide_for_camera_attach", false)):
		return
	_set_shadow_only_recursive(self)


func _set_shadow_only_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			)
		_set_shadow_only_recursive(child)


func _process(_dt: float) -> void:
	_sync_position()
	_sync_yaw()
	_sync_scale()
	_sync_light()
	# ADR 0035 — animate addressable mesh pieces per-frame.
	if _animation_director != null:
		_animation_director.tick(Time.get_ticks_msec() / 1000.0)


# ============================================================
# POSITION SYNC — engine state → 3D transform
# ============================================================


func _sync_position() -> void:
	if _entity_ref == null:
		return
	var p = _entity_ref.get_position()
	if p is Vector3:
		position = p * position_scale
	elif p is Vector2:
		# 2D position → XZ plane, Y=0 (W5.0 coordinate convention).
		# Scale applies because the same data files are authored in 2D pixel
		# units; 3D scenes scale them down to fit world-unit conventions.
		position = Vector3(p.x, 0, p.y) * position_scale
	# Optional Y-offset for AI-gen meshes whose pivot isn't at the
	# base (added 2026-05-17). Tripo3D outputs often have origin at
	# the mesh's geometric center, so placing at y=0 sinks half the
	# mesh underground.
	#
	# TWO fields supported (post-mortem 2026-05-18):
	#   visual.y_offset_mesh — preferred. Authored in MESH-space units
	#     (= -bbox.min.y). Engine multiplies by current state.scale
	#     so pattern-spawned variants at non-default scale still land
	#     with their base at y=0.
	#   visual.y_offset — legacy. World-space constant. Correct only
	#     when state.scale matches the def's state_init.scale. Pattern
	#     scatters with scale_min/scale_max produce floaters/sinkers.
	#     Kept for back-compat; new entities should use y_offset_mesh.
	#
	# Empirical case 2026-05-18: prop_tree_fruit def authored
	# y_offset=1.337 for state_init.scale=3.5 (mesh min.y=-0.382).
	# Pattern spawned bushes at scale 0.3-0.55 inherited the 1.337
	# constant → bushes floated ~1.15m above ground. Two were visible
	# enough that the user counted them. Migrated to y_offset_mesh=0.382.
	var v = _entity_ref.visual
	if v is Dictionary:
		if v.has("y_offset_mesh"):
			position.y += float(v["y_offset_mesh"]) * _read_y_scale()
		elif v.has("y_offset"):
			position.y += float(v["y_offset"])

	# Optional ground-snap (2026-05-18, ADR 0052 extension). When set,
	# the entity follows the GROUND's displaced height at its (x, z)
	# instead of sitting at world y=0. Required when the ground shader
	# does vertex displacement (heightmap-based bumps) — otherwise
	# entities float above or sink below the bumpy ground.
	# GroundRenderer caches the heightmap as a CPU-side Image at boot
	# and exposes sample_y(x, z) as a static method.
	if v is Dictionary and bool(v.get("snap_to_ground", false)):
		position.y += GroundRenderer.sample_y(position.x, position.z)


## Read state.scale if set. Accepts:
##   - float / int  → uniform scale (Vector3(s, s, s))
##   - Vector3      → per-axis scale
##   - Array [x,y,z] → per-axis scale
##   - Array [x,y]   → 2D — treated as (x, x, y) so the same authoring
##     works in iso views (x = horizontal, y = depth)
## Idempotent — when state.scale is unset, scale is left at (1,1,1).
## Used to vary tree size, prop sizes for visual density without
## authoring multiple mesh defs. Empirical case 2026-05-11: Aldenmere
## forest needed 2x-3x scale variation on trees for natural look.
func _sync_scale() -> void:
	if _entity_ref == null:
		return
	var s = _entity_ref.get_state("scale", null)
	if s == null:
		return
	# A normalized static .glb is unit-height with native proportions, so
	# size it UNIFORMLY by the fitted HEIGHT (state.scale's Y) — anisotropic
	# [W,H,D] would distort a real mesh. Kits keep the anisotropic tile-fit.
	if _glb_normalized:
		var h := 1.0
		if s is float or s is int:
			h = float(s)
		elif s is Vector3:
			h = (s as Vector3).y
		elif s is Array and (s as Array).size() >= 2:
			h = float((s as Array)[1])
		scale = Vector3(h, h, h)
		_apply_light_counter_scale()
		return
	if s is float or s is int:
		var f := float(s)
		scale = Vector3(f, f, f)
	elif s is Vector3:
		scale = s
	elif s is Array:
		var a := s as Array
		if a.size() == 3:
			scale = Vector3(float(a[0]), float(a[1]), float(a[2]))
		elif a.size() == 2:
			scale = Vector3(float(a[0]), float(a[0]), float(a[1]))
	_apply_light_counter_scale()


## Read the Y-component of state.scale for visual.y_offset_mesh
## multiplication (post-mortem 2026-05-18). Mirrors _sync_scale's
## parsing but returns just the Y factor since y_offset is vertical.
## Defaults to 1.0 when state.scale is unset.
func _read_y_scale() -> float:
	if _entity_ref == null:
		return 1.0
	var s = _entity_ref.get_state("scale", 1.0)
	if s is float or s is int:
		return float(s)
	if s is Vector3:
		return (s as Vector3).y
	if s is Array:
		var a := s as Array
		if a.size() == 3:
			return float(a[1])
		if a.size() == 2:
			return float(a[0])
		if a.size() == 1:
			return float(a[0])
	return 1.0


## Read state.yaw (radians, rotation around the Y axis) if set, and apply.
## Falls back to state.facing when yaw is unset — this bridges the FPS
## input → mesh-orientation gap (camera_director writes state.facing on
## mouse-look; without this fallback, the player mesh stays at its spawn
## yaw while the camera rotates independently).
##
## Authoring use:
##   - Static props use state.yaw for explicit rotation
##     (e.g. `state: {yaw: 0.26}` ~15° on cottages — visual-density axis 6).
##   - FPS players + camera-rotating actors use state.facing implicitly
##     (camera_director writes it on mouse-look).
##   - NPCs with their own face-toward-move-direction logic can set
##     either; yaw takes precedence.
##
## When BOTH are unset, rotation is left untouched (idempotent — existing
## entities without yaw render identically).
##
## Empirical case 2026-05-18: aldenmere player_marken's animated mesh
## (visible only as shadow in FPS due to hide_for_camera_attach=true)
## stayed pointing north regardless of mouse-look. Cause: camera wrote
## state.facing but mesh only read state.yaw. Shadow gave away the bug.
func _sync_yaw() -> void:
	if _entity_ref == null:
		return
	var raw = _entity_ref.get_state("yaw", null)
	if raw == null:
		# Fallback to state.facing for FPS players + camera-driven actors.
		raw = _entity_ref.get_state("facing", null)
	if raw == null:
		return
	# Per-entity yaw offset compensates for meshes whose authored "forward"
	# axis isn't the Yume convention (-Z). Quadrupeds (deer, rabbit, wolf)
	# often have heads along +X — set property `mesh_yaw_offset: -1.5708`
	# (= -π/2) so state.yaw=0 still points the head north. Default 0 keeps
	# humanoids unchanged. Empirical case 2026-05-16: animals walked
	# perpendicular to their body axis because the mesh-forward mismatch
	# wasn't compensated.
	var offset := float(_entity_ref.get_property("mesh_yaw_offset", 0.0))
	rotation.y = float(raw) + offset


# ============================================================
# MESH PRIMITIVE INTERPRETER (W5.0a + W5.0b)
# ============================================================


func _build_mesh_children() -> void:
	# Shared helper — same primitive vocabulary used by game_shell viewmodels.
	# Mesh-def `cast_shadow: false` (default true) propagates as the default
	# for every primitive — per-primitive overrides still win. Used to skip
	# the shadow pass on grass / clouds / distant decoration where the
	# shadow contribution costs more than it visually adds.
	MeshLib.build_primitives_into(self, _mesh_primitives, _mesh_params, _mesh_cast_shadow)


## Task #117: paint every primitive's material with a shared albedo
## texture. Called when entity_def.visual.albedo_texture is set —
## typically the resolved output of the asset-gen pipeline (#116).
## Walks all child MeshInstance3D nodes, duplicates each one's
## material, and sets albedo_texture. The flat colors authored in
## meshes.json stay as multiplicative tint atop the texture.
func _apply_albedo_texture_to_primitives(tex_path: String) -> void:
	if tex_path == "" or not ResourceLoader.exists(tex_path):
		if tex_path != "":
			push_warning(
				"EntityMesh3D: visual.albedo_texture not found: %s" % tex_path
			)
		return
	var tex = load(tex_path)
	if not (tex is Texture2D):
		return
	# Optional WORLD-TRIPLANAR mapping (2026-06-11): anisotropically
	# scaled prims (road segments, walls — each instance a different
	# length) stretch per-face UVs differently per instance. With
	# `visual.texture_triplanar: true` the texture tiles in WORLD units
	# (StandardMaterial3D uv1_world_triplanar), so texel density is
	# uniform across every segment regardless of scale/yaw.
	# `visual.texture_scale` = Godot's uv1_scale (higher = smaller
	# texture; repeats every 1/scale world units). Pure Godot exposure.
	if _entity_ref != null and _entity_ref.visual is Dictionary:
		var vis: Dictionary = _entity_ref.visual
		_paint_triplanar = bool(vis.get("texture_triplanar", false))
		_paint_uv_scale = float(vis.get("texture_scale", 1.0))
	for child in get_children():
		_paint_albedo_texture_recursive(child, tex)


var _paint_triplanar: bool = false
var _paint_uv_scale: float = 1.0


## Apply the optional triplanar flags to a freshly-duplicated material.
func _paint_apply_mapping(mat: StandardMaterial3D) -> void:
	if not _paint_triplanar:
		return
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3(_paint_uv_scale, _paint_uv_scale, _paint_uv_scale)


func _paint_albedo_texture_recursive(node: Node, tex: Texture2D) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var mesh := mi.mesh
		if mesh != null:
			# MeshLib-built primitives (code-drawn meshes from
			# meshes.json) attach materials via mi.material_override,
			# NOT per-surface. Check that first; fall back to
			# per-surface for .glb-imported meshes (their materials
			# live on surfaces). Empirical case 2026-05-17: oak A/B/C
			# Plan C looked identical to baseline because every
			# primitive's material_override was being read as null +
			# replaced by a textureless StandardMaterial3D.
			if mi.material_override != null:
				var src_override: Material = mi.material_override
				var dup_override: StandardMaterial3D
				if src_override is StandardMaterial3D:
					dup_override = (src_override as StandardMaterial3D).duplicate(true)
				else:
					dup_override = StandardMaterial3D.new()
				dup_override.albedo_texture = tex
				_paint_apply_mapping(dup_override)
				mi.material_override = dup_override
				# Continue to children, skip the per-surface path
				# (would no-op anyway since this MeshInstance3D's
				# materials are already overridden uniformly).
				for child in node.get_children():
					_paint_albedo_texture_recursive(child, tex)
				return
			for i in mesh.get_surface_count():
				var mat: Material = mi.get_surface_override_material(i)
				if mat == null:
					mat = mesh.surface_get_material(i)
				var dup: StandardMaterial3D
				if mat is StandardMaterial3D:
					dup = (mat as StandardMaterial3D).duplicate(true)
				else:
					dup = StandardMaterial3D.new()
				dup.albedo_texture = tex
				_paint_apply_mapping(dup)
				mi.set_surface_override_material(i, dup)
	for child in node.get_children():
		_paint_albedo_texture_recursive(child, tex)


## ADR 0052: replace every primitive's material with a ShaderMaterial
## backed by `shader_path`. Uniforms come from `shader_params` (dict
## of param-name → value). Applied uniformly across all primitives
## (e.g. river bands all become water). For per-band shaders, use
## `material_overrides` instead — that path is for .glb meshes; code-
## drawn primitives don't have material name slots.
func _apply_shader_to_primitives(shader_path: String, shader_params: Variant) -> void:
	if shader_path == "" or not ResourceLoader.exists(shader_path):
		if shader_path != "":
			push_warning(
				"EntityMesh3D: visual.shader not found: %s" % shader_path
			)
		return
	var shader = load(shader_path)
	if not (shader is Shader):
		push_warning(
			"EntityMesh3D: visual.shader did not load as Shader: %s" % shader_path
		)
		return
	var params: Dictionary = shader_params if shader_params is Dictionary else {}
	for child in get_children():
		_paint_shader_recursive(child, shader, params)


func _paint_shader_recursive(node: Node, shader: Shader, params: Dictionary) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var sm := ShaderMaterial.new()
		sm.shader = shader
		for k in params:
			sm.set_shader_parameter(str(k), params[k])
		mi.material_override = sm
	for child in node.get_children():
		_paint_shader_recursive(child, shader, params)


# ============================================================
# PARAM RESOLUTION — `$name` references
# ============================================================


func _param_resolve(v):
	if v is String and (v as String).begins_with("$"):
		var key := (v as String).substr(1)
		return _mesh_params.get(key, v)
	return v


func _resolve_color(v) -> Color:
	var resolved = _param_resolve(v)
	return _parse_color(resolved)


# ============================================================
# UTIL
# ============================================================


static func _to_vec3(v) -> Vector3:
	if v is Vector3:
		return v
	if v is Vector2:
		return Vector3(v.x, v.y, 0)
	if v is Array:
		var a := v as Array
		if a.size() >= 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2:
			return Vector3(float(a[0]), float(a[1]), 0)
	if v is float or v is int:
		return Vector3(float(v), float(v), float(v))
	return Vector3.ZERO


static func _to_vec2(v) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is float or v is int:
		return Vector2(float(v), float(v))
	return Vector2.ONE


static func _parse_color(v) -> Color:
	if v is Color:
		return v
	if v is String:
		return Color(str(v))
	if v is Array and (v as Array).size() >= 3:
		return Color(
			float(v[0]), float(v[1]), float(v[2]), 1.0 if (v as Array).size() < 4 else float(v[3])
		)
	return Color(0.7, 0.7, 0.7)


static func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


func _get_mesh_lib() -> MeshLib:
	if _mesh_lib_cache == null:
		_mesh_lib_cache = MeshLib.load_from_file(meshes_path)
	return _mesh_lib_cache
