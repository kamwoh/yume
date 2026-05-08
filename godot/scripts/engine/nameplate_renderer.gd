extends Node
class_name NameplateRenderer

## Floating-name labels above `named_npc`-tagged entities (Tier 2.6 NPC
## identity layer). Surfaces the entity's `properties.display_name` (or
## fallback to instance_id) as a small label hovering ~2m above the
## entity's world position, projected to screen space each frame.
##
## Per ADR 0021, this exposes Godot's Camera3D.unproject_position /
## Camera2D positioning — we don't reimplement projection. Style is a
## thin wrapper over Label with outline (same idiom as GameShell HUD
## labels).
##
## Wiring: NameplateRenderer expects to be a child of a Node whose
## script is `World`. Sibling of GameShell + ScreenFlow. No-op when no
## entity carries the `named_npc` tag (most demos).
##
## Lifecycle:
## 1. _ready: build a CanvasLayer (layer 11 — above HUD's 10, below
##    fade overlay's 20) holding a pool of Label children. Pool is
##    sized lazily as visible NPCs grow.
## 2. _process: for each `named_npc`, world-pos → screen-pos via the
##    parent's camera, sort by camera distance, take top
##    MAX_VISIBLE_NAMEPLATES, write into the label pool.
## 3. Labels not assigned this frame are hidden (visible=false) — keeps
##    the pool stable across frames without rebuild churn.
##
## 2D scenes: parent owns a Camera2D. We project entity world pos
## through the camera transform: screen = (world - cam.position) *
## cam.zoom + viewport_size/2. Y-offset is interpreted as pixels in 2D.
##
## 3D scenes: parent owns a Camera3D. We use Camera3D.unproject_position()
## for accurate perspective/ortho projection. Y-offset is meters (world
## units). Skip nameplates for entities behind the camera
## (is_position_behind() check).


# ============================================================
# CONSTANTS
# ============================================================

# Hard cap on labels rendered per frame. If more named_npc entities
# exist, the closest MAX_VISIBLE get drawn; the rest are culled. Keeps
# screen tidy + framerate predictable in dense towns.
const MAX_VISIBLE_NAMEPLATES: int = 20

# Pixel offset above projected entity position (so the label floats
# clearly above head, not on the body). Applied in screen space after
# projection.
const SCREEN_Y_PIXEL_OFFSET: float = -8.0

# Default world-space height above entity origin. 3D: meters. 2D: pixels.
# Tuned for ~1.7m human-scale entities so the label clears head/hat.
const DEFAULT_Y_OFFSET_3D: float = 2.0
const DEFAULT_Y_OFFSET_2D: float = 32.0

# Style — off-white parchment text, dark outline for legibility on any
# background (grass, sky, stone). Matches merchant palette.
const NAMEPLATE_FONT_SIZE: int = 13
const NAMEPLATE_COLOR: Color = Color(0.910, 0.847, 0.722, 1.0)   # #e8d8b8
const NAMEPLATE_OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
const NAMEPLATE_OUTLINE_SIZE: int = 3

# Tag a nameplate is keyed off. Content opts in by tagging an entity
# `named_npc`; otherwise the renderer ignores it. Matches the data-demo
# convention (named_regulars.json tags this; ambient_npc / villagers
# don't).
const NAMEPLATE_TAG: String = "named_npc"


# ============================================================
# STATE
# ============================================================

var _world: Node = null
var _camera2d: Camera2D = null
var _camera3d: Camera3D = null

# Label pool — Labels live here even when unused (visible=false). We
# grow on demand up to MAX_VISIBLE_NAMEPLATES; never shrink.
var _layer: CanvasLayer = null
var _label_pool: Array = []     # Array[Label]


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	_world = get_parent()
	if _world == null or not _world.has_method("_build_env"):
		push_error("NameplateRenderer must be a child of a World node")
		return
	_camera2d = _world.get_node_or_null("Camera2D")
	_camera3d = _world.get_node_or_null("Camera3D")
	_build_layer()


func _process(_delta: float) -> void:
	if _world == null or _layer == null: return
	var sched = _world.get("scheduler")
	if sched == null: return    # env not built yet
	var env: Dictionary = sched.env
	# Camera nodes may have been added after _ready (e.g. if a scene-spec
	# script instantiates them). Re-look-up if missing.
	if _camera3d == null and _camera2d == null:
		_camera2d = _world.get_node_or_null("Camera2D")
		_camera3d = _world.get_node_or_null("Camera3D")
	_render_nameplates(env)


# ============================================================
# LAYER + POOL
# ============================================================

func _build_layer() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 11    # above HUD (10), below fade overlay (20)
	_layer.name = "NameplateLayer"
	add_child(_layer)


## Grow the pool to at least `count` labels. Existing labels keep their
## state (text, position) — we just add fresh hidden ones at the tail.
func _ensure_pool_size(count: int) -> void:
	while _label_pool.size() < count:
		var lbl := Label.new()
		_apply_nameplate_style(lbl)
		lbl.visible = false
		# Anchor each label so its CENTER sits at the assigned position
		# (not its top-left). Achieved by letting the Label auto-size and
		# manually offsetting position by half-size at apply time.
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_layer.add_child(lbl)
		_label_pool.append(lbl)


func _apply_nameplate_style(lbl: Label) -> void:
	lbl.add_theme_color_override("font_color", NAMEPLATE_COLOR)
	lbl.add_theme_color_override("font_outline_color", NAMEPLATE_OUTLINE_COLOR)
	lbl.add_theme_constant_override("outline_size", NAMEPLATE_OUTLINE_SIZE)
	lbl.add_theme_font_size_override("font_size", NAMEPLATE_FONT_SIZE)


# ============================================================
# PER-FRAME RENDER
# ============================================================

func _render_nameplates(env: Dictionary) -> void:
	var entities = env.get("entities", null)
	if not (entities is Dictionary):
		_hide_pool_from(0)
		return

	# Collect candidate (entity, world_pos, distance²) tuples. We keep
	# only entities tagged `named_npc`. Distance to camera lets us cull
	# the farthest when count > MAX_VISIBLE_NAMEPLATES.
	var candidates: Array = collect_named_npcs(entities)
	if candidates.is_empty():
		_hide_pool_from(0)
		return

	var cam_pos := _camera_world_position()
	for c in candidates:
		c["dist2"] = (c["world_pos"] - cam_pos).length_squared() if c["world_pos"] is Vector3 \
			else (Vector2(c["world_pos"].x, c["world_pos"].y) - Vector2(cam_pos.x, cam_pos.z)).length_squared()

	# Sort ascending by distance — closest first. Take the closest N.
	candidates.sort_custom(func(a, b): return a["dist2"] < b["dist2"])
	var visible_count: int = min(candidates.size(), MAX_VISIBLE_NAMEPLATES)
	_ensure_pool_size(visible_count)

	# Project + assign. Track how many slots we actually wrote so we can
	# hide the unused tail (e.g. when count drops between frames).
	var written: int = 0
	for i in range(visible_count):
		var c = candidates[i]
		var screen_pos = _project_to_screen(c["world_pos"])
		if screen_pos == null:
			continue   # entity behind camera — skip slot, don't waste a label
		var lbl: Label = _label_pool[written]
		lbl.text = str(c["display_name"])
		lbl.visible = true
		# Reset size so Label re-fits text (prevents stale-bounds drift).
		lbl.size = Vector2.ZERO
		# Offset by half label size so the text is HORIZONTALLY centered on
		# the projected point. Pool labels auto-size after text assignment;
		# we read size() AFTER setting text. Vertical offset moves it up.
		var half := lbl.get_minimum_size() * 0.5
		lbl.position = Vector2(screen_pos.x - half.x,
			screen_pos.y - half.y + SCREEN_Y_PIXEL_OFFSET)
		written += 1

	_hide_pool_from(written)


## Hide every pool label at index >= start. Used to clean up frames
## where fewer NPCs are visible than the previous frame painted.
func _hide_pool_from(start: int) -> void:
	for i in range(start, _label_pool.size()):
		(_label_pool[i] as Label).visible = false


# ============================================================
# CANDIDATE COLLECTION
# ============================================================

## Walk the entity dict, return Array of {entity, world_pos, display_name}
## dicts for every entity carrying NAMEPLATE_TAG. world_pos is shifted
## up by Y_OFFSET so the projected point is "above the head."
##
## display_name precedence: properties.display_name > instance_id.
## Static helper so test_runner can call it without a SceneTree.
static func collect_named_npcs(entities: Dictionary) -> Array:
	var out: Array = []
	for ent in entities.values():
		if ent == null: continue
		if not ent.has_method("has_tag"): continue
		if not ent.has_tag(NAMEPLATE_TAG): continue
		var world_pos = _entity_anchor_position(ent)
		if world_pos == null: continue
		var name_str := str(ent.get_property("display_name", ""))
		if name_str == "":
			# Fallback: instance_id (e.g. "npc_garron") so a misconfigured
			# entity still renders SOMETHING legible — debug aid for
			# content authors who tag named_npc but forget display_name.
			var iid = ent.get("instance_id")
			name_str = str(iid) if iid != null and str(iid) != "" else "?"
		out.append({
			"entity": ent,
			"world_pos": world_pos,
			"display_name": name_str,
		})
	return out


## Compute the world-space anchor (head-top) for an entity. 3D entities
## give Vector3, 2D give Vector2. Y/Z offset goes into the world pos so
## the projection is accurate (don't shift in screen space alone — at
## oblique camera angles a constant pixel offset wouldn't track the
## perceived head).
static func _entity_anchor_position(ent) -> Variant:
	if not ent.has_method("get_position"): return null
	var p = ent.get_position()
	if p is Vector3:
		return Vector3(p.x, p.y + DEFAULT_Y_OFFSET_3D, p.z)
	if p is Vector2:
		# 2D: nameplates float ABOVE the sprite. In Godot 2D, +Y is down,
		# so subtract DEFAULT_Y_OFFSET_2D to move up.
		return Vector2(p.x, p.y - DEFAULT_Y_OFFSET_2D)
	return null


# ============================================================
# CAMERA / PROJECTION
# ============================================================

## Project a world position to screen-space pixels. Returns null when
## the point is behind the 3D camera (so caller can skip it). 2D path
## returns the standard transform; world points "behind" don't apply.
func _project_to_screen(world_pos) -> Variant:
	if _camera3d != null and world_pos is Vector3:
		if _camera3d.is_position_behind(world_pos):
			return null
		return _camera3d.unproject_position(world_pos as Vector3)
	if _camera2d != null and world_pos is Vector2:
		return _project_2d(world_pos as Vector2)
	# 2D entity rendered in 3D scene? Promote to Vector3(x, 0, y) and try.
	if _camera3d != null and world_pos is Vector2:
		var v := world_pos as Vector2
		var v3 := Vector3(v.x, 0.0, v.y)
		if _camera3d.is_position_behind(v3): return null
		return _camera3d.unproject_position(v3)
	return null


## Manual 2D world → screen projection. Camera2D.position is the world
## point centered in viewport; zoom scales world units → pixels;
## viewport center is the screen origin of that center. Result is in
## the same coordinate space the CanvasLayer expects.
func _project_2d(world_pos: Vector2) -> Vector2:
	var vp := _camera2d.get_viewport_rect().size
	var cam_pos := _camera2d.position + _camera2d.offset
	var zoom := _camera2d.zoom
	# Avoid divide-by-zero on misconfigured zoom.
	if zoom.x == 0.0 or zoom.y == 0.0:
		return vp * 0.5
	return (world_pos - cam_pos) * zoom + vp * 0.5


## Camera position in world space. Used purely for distance-to-camera
## culling. 2D: returns Vector3(x, 0, y) so the same length_squared
## logic works for both modes.
func _camera_world_position() -> Vector3:
	if _camera3d != null:
		return _camera3d.global_position
	if _camera2d != null:
		return Vector3(_camera2d.position.x, 0.0, _camera2d.position.y)
	return Vector3.ZERO
