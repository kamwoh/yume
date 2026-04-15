extends Node

## World environment — sun, sky, ambient, fog, and the day/night cycle.
## Lives as a child of sim_world. Owns its own sun_node and Environment.

var sun_node: DirectionalLight3D
var env: Environment
var world_data: Dictionary = {}
var day_night_enabled: bool = true
var cycle_seconds: float = 300.0
var day_ratio: float = 0.7
var time_of_day: float = 0.5  # noon


func build(world: Node3D, wd: Dictionary, sky_cfg: Dictionary) -> void:
	world_data = wd
	var atmo: Dictionary = wd.get("atmosphere", {})
	var bg = atmo.get("bg_color", [0.47, 0.65, 1.0])
	var amb = atmo.get("ambient_light", [0.4, 0.45, 0.35])
	var sun_col = atmo.get("sun_color", [1.0, 0.9, 0.7])
	var sun_rot = atmo.get("sun_rotation", [-45, 30, 0])

	sun_node = DirectionalLight3D.new()
	sun_node.name = "Sun"
	sun_node.rotation_degrees = Vector3(sun_rot[0], sun_rot[1], sun_rot[2])
	sun_node.light_energy = atmo.get("sun_energy", 0.8)
	sun_node.light_color = Color(sun_col[0], sun_col[1], sun_col[2])
	sun_node.shadow_enabled = true
	world.add_child(sun_node)

	var env_node := WorldEnvironment.new()
	env = Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	var st = sky_cfg.get("top_color", [0.3, 0.5, 0.9])
	var sh = sky_cfg.get("horizon_color", [0.65, 0.75, 0.95])
	var gb = sky_cfg.get("ground_bottom_color", [0.35, 0.55, 0.25])
	var gh = sky_cfg.get("ground_horizon_color", [0.6, 0.7, 0.85])
	sky_mat.sky_top_color = Color(st[0], st[1], st[2])
	sky_mat.sky_horizon_color = Color(sh[0], sh[1], sh[2])
	sky_mat.ground_bottom_color = Color(gb[0], gb[1], gb[2])
	sky_mat.ground_horizon_color = Color(gh[0], gh[1], gh[2])
	sky_mat.sun_angle_max = sky_cfg.get("sun_angle_max", 30.0)
	sky_mat.sun_curve = sky_cfg.get("sun_curve", 0.1)
	sky.sky_material = sky_mat
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(amb[0], amb[1], amb[2])
	env.ambient_light_energy = atmo.get("ambient_energy", 0.7)
	env.fog_enabled = true
	env.fog_light_color = Color(atmo.get("fog_color", [0.65, 0.72, 0.82])[0], atmo.get("fog_color", [0.65, 0.72, 0.82])[1], atmo.get("fog_color", [0.65, 0.72, 0.82])[2])
	env.fog_density = atmo.get("fog_density", 0.015)
	env.fog_sky_affect = 0.8
	env_node.environment = env
	world.add_child(env_node)

	var dn: Dictionary = wd.get("day_night", {})
	day_night_enabled = dn.get("enabled", true)
	cycle_seconds = dn.get("cycle_seconds", 300.0)
	day_ratio = dn.get("day_ratio", 0.7)


func _process(delta: float) -> void:
	if day_night_enabled and sun_node and env:
		_update_day_night(delta)


func _update_day_night(delta: float) -> void:
	time_of_day += delta / cycle_seconds
	if time_of_day > 1.0:
		time_of_day -= 1.0

	var sun_angle: float = (time_of_day - 0.25) * 360.0
	sun_node.rotation_degrees.x = -sun_angle

	var day_start: float = 0.2
	var day_end: float = day_start + day_ratio
	var sun_energy: float
	if time_of_day > day_start and time_of_day < day_end:
		var day_progress: float = (time_of_day - day_start) / (day_end - day_start)
		sun_energy = sin(day_progress * PI) * 0.8
	else:
		sun_energy = 0.05

	sun_node.light_energy = sun_energy

	if time_of_day > day_start and time_of_day < day_end:
		var t: float = (time_of_day - day_start) / (day_end - day_start)
		if t < 0.1:
			env.background_color = Color(0.8, 0.5, 0.3).lerp(Color(0.47, 0.65, 1.0), t / 0.1)
		elif t > 0.9:
			env.background_color = Color(0.47, 0.65, 1.0).lerp(Color(0.8, 0.4, 0.2), (t - 0.9) / 0.1)
		else:
			env.background_color = Color(0.47, 0.65, 1.0)
		var base_ambient: float = world_data.get("atmosphere", {}).get("ambient_energy", 0.7)
		env.ambient_light_energy = base_ambient * (0.6 + sun_energy * 0.5)
	else:
		env.background_color = Color(0.04, 0.04, 0.12)
		env.ambient_light_energy = 0.12

	if sun_energy > 0.1:
		var warmth: float = 1.0 - sun_energy
		sun_node.light_color = Color(1.0, 0.95 - warmth * 0.3, 0.8 - warmth * 0.4)
