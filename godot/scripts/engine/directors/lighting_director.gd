extends Node
class_name LightingDirector

## ADR 0025 — Day/night cycle exposed via scene.json.
##
## Reads `<data_root>/scene.json`'s `lighting` block (if present) and
## drives a DirectionalLight3D + WorldEnvironment so the 3D scene
## visibly transitions through dawn/noon/dusk/night based on a
## binding (typically `world_clock.time_of_day` — a 0.0..24.0 value
## set by content rules).
##
## Per ADR 0021, we EXPOSE Godot's Light3D, WorldEnvironment, Sky,
## ProceduralSkyMaterial — we do NOT reimplement color curves or
## tweening. Color blending uses `Color.lerp()`; sun rotation uses
## `Basis.from_euler()`. Both are stock Godot.
##
## Wiring: LightingDirector expects to be a child of a Node whose
## script is `World`. Sibling of GameShell + ScreenFlow.
##
## Lifecycle:
## 1. Boot: read scene.json's lighting block. If absent → no-op forever.
## 2. Boot (once env exists): create DirectionalLight3D + WorldEnvironment
##    children of self IF none already in the scene. If a .tscn already
##    declares them (like doomarena3d.tscn), we adopt those instead.
## 3. Per-frame: resolve current binding value (e.g. world_clock state),
##    interpolate sun rotation + color + sky horizon, write to nodes.
##
## 2D scenes simply leave the lighting block out of scene.json — the
## director sees no config and does nothing.

# ============================================================
# CONSTANTS
# ============================================================

# Default angular sweep: at midnight (t=0) the sun is "below" pointing up;
# at noon (t=12) the sun is overhead pointing down; at 6am/6pm it's at the
# horizon. We rotate around X axis so the sun arcs across the sky.
const HOURS_PER_DAY: float = 24.0

# ============================================================
# STATE
# ============================================================

var _world: Node = null
var _config_loaded: bool = false
var _config: Dictionary = {}  # parsed lighting block

# Cached Godot nodes we drive. Either adopted from the scene tree (if a
# .tscn pre-declares them) or created on first config-load.
var _sun: DirectionalLight3D = null
var _world_env: WorldEnvironment = null
var _owns_sun: bool = false  # true if we created _sun
var _owns_env: bool = false  # true if we created _world_env

# Bind path (e.g. "world_clock.time_of_day"). Parsed once on load.
var _bind_tag: String = ""
var _bind_field: String = ""

# ============================================================
# LIFECYCLE
# ============================================================


func _ready() -> void:
	_world = get_parent()
	if _world == null or not _world.has_method("_build_env"):
		push_error("LightingDirector must be a child of a World node")
		return
	_load_config()


func _process(_delta: float) -> void:
	if not _config_loaded:
		return
	if _config.is_empty():
		return
	if _world == null:
		return
	var sched = _world.get("scheduler")
	if sched == null:
		return  # env not built yet
	# Adopt or create lighting nodes lazily — _world's own _ready() may not
	# have built the scene tree's lighting children yet on our first tick.
	if _sun == null and _world_env == null:
		_attach_lighting_nodes()
	_update_lighting(sched.env)


# ============================================================
# CONFIG LOAD
# ============================================================


func _load_config() -> void:
	if _config_loaded:
		return
	_config_loaded = true
	var root := str(_world.get("data_root")).rstrip("/")
	if root == "":
		return
	var path := root + "/scene.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return
	var lighting = (data as Dictionary).get("lighting", null)
	if not (lighting is Dictionary):
		return
	_config = lighting
	# Parse binding "tag.field" once. Default: world_clock.time_of_day.
	var dl: Dictionary = _config.get("directional_light", {})
	var bind_path := str(dl.get("binds_to", "world_clock.time_of_day"))
	var dot := bind_path.find(".")
	if dot > 0:
		_bind_tag = bind_path.substr(0, dot)
		_bind_field = bind_path.substr(dot + 1)
	else:
		_bind_tag = "world_clock"
		_bind_field = "time_of_day"


# ============================================================
# NODE ATTACH (adopt-or-create)
# ============================================================


func _attach_lighting_nodes() -> void:
	# Search scene tree (siblings of self under _world) for existing nodes.
	# Per-game .tscn files (e.g. doomarena3d.tscn) may pre-declare these
	# with their own initial transforms — we adopt and override per-tick.
	for child in _world.get_children():
		if _sun == null and child is DirectionalLight3D:
			_sun = child
		elif _world_env == null and child is WorldEnvironment:
			_world_env = child

	# Create sun if missing AND the config wants one.
	var dl_cfg: Dictionary = _config.get("directional_light", {})
	if _sun == null and bool(dl_cfg.get("enabled", true)):
		_sun = DirectionalLight3D.new()
		_sun.name = "LightingDirectorSun"
		_sun.shadow_enabled = bool(dl_cfg.get("shadow_enabled", true))
		_world.add_child(_sun)
		_owns_sun = true

	# Create WorldEnvironment if missing AND ambient/sky config exists.
	var has_env_cfg := _config.has("ambient") or _config.has("sky")
	if _world_env == null and has_env_cfg:
		_world_env = WorldEnvironment.new()
		_world_env.name = "LightingDirectorEnv"
		_world_env.environment = Environment.new()
		_world.add_child(_world_env)
		_owns_env = true

	# If we created the env, set up a procedural sky so horizon color
	# interpolation has something to tweak. Do nothing if .tscn pre-declared
	# its own (Sky asset / HDR / etc.) — author chose explicitly.
	if _owns_env and _world_env != null and _config.has("sky"):
		var env: Environment = _world_env.environment
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		var sky := Sky.new()
		var sky_mat := ProceduralSkyMaterial.new()
		sky.sky_material = sky_mat
		env.sky = sky


# ============================================================
# PER-FRAME UPDATE
# ============================================================


func _update_lighting(env: Dictionary) -> void:
	var t := _resolve_time_of_day(env)
	# Normalize to 0..24
	t = fposmod(t, HOURS_PER_DAY)

	if _sun != null:
		_apply_sun(t)
	if _world_env != null:
		_apply_environment(t)


## Resolve the bound value from world_clock entity state.
## Falls back to 12.0 (noon) if no matching entity.
func _resolve_time_of_day(env: Dictionary) -> float:
	# First check world_state dict (env.world) — some games store
	# time_of_day there directly via state_set target=world.
	var ws = env.get("world", null)
	if ws is Dictionary and (ws as Dictionary).has(_bind_field):
		return float((ws as Dictionary)[_bind_field])

	# Then look up by tag in entities dict.
	var entities = env.get("entities", null)
	if entities is Dictionary:
		for ent in (entities as Dictionary).values():
			if ent != null and ent.has_method("has_tag") and ent.has_tag(_bind_tag):
				var v = ent.get_state(_bind_field, null)
				if v != null:
					return float(v)
	# No clock entity present — assume noon. Lets the director "work"
	# in static-lighting demos without a clock.
	return 12.0


# ============================================================
# SUN POSITIONING + COLOR
# ============================================================


## At t=0 (midnight): sun below the horizon, light direction points UP (night).
## At t=6 (dawn): sun at east horizon, light points horizontally (+X).
## At t=12 (noon): sun overhead, light points DOWN (-Y).
## At t=18 (dusk): sun at west horizon, light points horizontally (-X).
##
## DirectionalLight3D's light direction is -basis.z. We construct a basis
## whose -Z axis points along our desired light direction.
func _apply_sun(t: float) -> void:
	var dir := sun_direction_at(t)
	var up := Vector3(0, 0, 1)
	# If light direction is parallel to our chosen up, pick a different up.
	if abs(dir.dot(up)) > 0.99:
		up = Vector3(1, 0, 0)
	_sun.transform.basis = Basis.looking_at(dir, up)

	# Color: blend night → dawn/dusk → noon → dawn/dusk → night.
	var dl_cfg: Dictionary = _config.get("directional_light", {})
	var c_noon := Color(dl_cfg.get("color_at_noon", "#fff8e0"))
	var c_horizon := Color(dl_cfg.get("color_at_dawn_dusk", "#ff9060"))
	var c_night := Color(dl_cfg.get("color_at_night", "#3050a0"))
	_sun.light_color = sun_color_at(t, c_noon, c_horizon, c_night)
	_sun.light_energy = sun_energy_at(
		t,
		float(dl_cfg.get("energy_noon", 1.0)),
		float(dl_cfg.get("energy_horizon", 0.7)),
		float(dl_cfg.get("energy_night", 0.05))
	)


# ============================================================
# AMBIENT + SKY
# ============================================================


func _apply_environment(t: float) -> void:
	var env_obj: Environment = _world_env.environment
	if env_obj == null:
		return

	var amb: Dictionary = _config.get("ambient", {})
	if not amb.is_empty():
		var c_day := Color(amb.get("color_day", "#a0a0c0"))
		var c_night := Color(amb.get("color_night", "#202040"))
		var e_day := float(amb.get("energy_day", 0.4))
		var e_night := float(amb.get("energy_night", 0.1))
		var f := day_factor(t)
		env_obj.ambient_light_color = c_night.lerp(c_day, f)
		env_obj.ambient_light_energy = lerp(e_night, e_day, f)

	var sky_cfg: Dictionary = _config.get("sky", {})
	if not sky_cfg.is_empty() and env_obj.sky != null:
		var mat = env_obj.sky.sky_material
		if mat is ProceduralSkyMaterial:
			var psm: ProceduralSkyMaterial = mat
			var f := day_factor(t)
			var h_day := Color(sky_cfg.get("horizon_day", "#80a0e0"))
			var h_night := Color(sky_cfg.get("horizon_night", "#101020"))
			psm.sky_horizon_color = h_night.lerp(h_day, f)
			if sky_cfg.has("ground_day") and sky_cfg.has("ground_night"):
				var g_day := Color(sky_cfg.get("ground_day", "#404040"))
				var g_night := Color(sky_cfg.get("ground_night", "#101010"))
				psm.ground_horizon_color = g_night.lerp(g_day, f)


# ============================================================
# STATIC HELPERS (testable without a SceneTree)
# ============================================================


## day_factor: 0 = full night (midnight), 1 = full day (noon).
## Sinusoidal so dawn/dusk feel smooth, not a sharp cutoff.
##   t=0   → 0   (midnight, full night)
##   t=6   → 0.5 (dawn, halfway)
##   t=12  → 1   (noon, full day)
##   t=18  → 0.5 (dusk, halfway)
static func day_factor(t: float) -> float:
	# (1 - cos(2π · t/24)) / 2: smooth 0..1..0..1 over 24h
	var n := fposmod(t, HOURS_PER_DAY) / HOURS_PER_DAY
	return (1.0 - cos(n * TAU)) * 0.5


## Sun color blend across the day:
##   night-zone (t in [0,4] ∪ [20,24]) → c_night
##   horizon-zone (t in [4,8] ∪ [16,20]) → blend night ↔ horizon ↔ noon
##   noon-zone (t in [8,16]) → c_noon
##
## Implementation: piecewise lerp keyed off day_factor.
##   f < 0.25 → c_night ↔ c_horizon
##   f >= 0.25 → c_horizon ↔ c_noon
## Boundary at f=0.25 corresponds to t≈4.7h (early dawn).
static func sun_color_at(t: float, c_noon: Color, c_horizon: Color, c_night: Color) -> Color:
	var f := day_factor(t)
	if f < 0.25:
		# 0..0.25 → night → horizon
		return c_night.lerp(c_horizon, f / 0.25)
	# 0.25..1 → horizon → noon
	return c_horizon.lerp(c_noon, (f - 0.25) / 0.75)


## Sun energy: piecewise to give bright noon, dim dawn/dusk, near-zero night.
static func sun_energy_at(t: float, e_noon: float, e_horizon: float, e_night: float) -> float:
	var f := day_factor(t)
	if f < 0.25:
		return lerp(e_night, e_horizon, f / 0.25)
	return lerp(e_horizon, e_noon, (f - 0.25) / 0.75)


## Sun direction unit-vector at time t — direction LIGHT TRAVELS (not sun
## position; negate to get sun-position).
##   t=0  (midnight) → (0, +1, 0) light going up = sun below ground
##   t=6  (dawn)     → (+1, 0, 0) light going east-to-west horizontally
##   t=12 (noon)     → (0, -1, 0) light going down from overhead
##   t=18 (dusk)     → (-1, 0, 0) light going west-to-east horizontally
##
## Mapping: angle = (t/12)·π − π/2; dir = (cos(angle), -sin(angle), 0).
static func sun_direction_at(t: float) -> Vector3:
	var n := fposmod(t, HOURS_PER_DAY)
	var angle := (n / 12.0) * PI - PI * 0.5
	return Vector3(cos(angle), -sin(angle), 0).normalized()
