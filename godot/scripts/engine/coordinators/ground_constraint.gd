extends RefCounted
class_name GroundConstraint

## Scene ground constraint — extracted from world.gd on 2026-05-12.
##
## A scene's optional `ground.y` config (loaded by WorldLoader.load_ground_cfg)
## defines a horizontal floor plane. Each frame, after motion integration:
##   - Entities with any `clamp_tag` whose y dropped below ground.y get
##     clamped back UP to the ground line (creatures stay on floor).
##   - Entities with any `despawn_tag` whose y dropped below ground.y get
##     removed (projectiles that miss).
##
## Config is loaded lazily on first apply() call via WorldLoader (so games
## that don't declare a `ground` block in scene.json pay zero overhead).
##
## Despawn routes through SpawnManager.despawn — the unified path that
## also frees the physics body (ADR 0044 Condition 4). Direct entities.erase
## bypasses that and leaks physics bodies (caught 2026-05-12 audit).
##
## Pattern matches MotionIntegrator / LevelTransitionCoordinator —
## RefCounted, per-World instance, constructor takes a world reference.

var _world: World
## Loaded from scene.json's ground block via WorldLoader. Sentinel value
## -INF means no ground constraint (most demos — ground is optional).
var ground_y: float = -INF
var clamp_tags: Array = []
var despawn_tags: Array = []


func _init(world: World) -> void:
	_world = world


## Apply ground constraint to all entities. Called from World._process
## each frame, AFTER MotionIntegrator.integrate.
func apply() -> void:
	# Loader sets ground_y / clamp_tags / despawn_tags on this coordinator.
	# Lazy: re-checked each frame so a runtime level swap can update config.
	_world._loader.load_ground_cfg()
	if ground_y == -INF:
		return
	var entities: Dictionary = _world.entities
	var to_remove: Array[String] = []
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity):
			continue
		var p = (ent as Entity).get_position()
		var py: float = p.y if p is Vector3 else 0.0
		if py >= ground_y:
			continue
		# Below ground. Despawn projectiles, clamp creatures.
		var despawn := false
		for t in despawn_tags:
			if (ent as Entity).has_tag(str(t)):
				despawn = true
				break
		if despawn:
			to_remove.append(str(id))
			continue
		var clamp_match := false
		for t in clamp_tags:
			if (ent as Entity).has_tag(str(t)):
				clamp_match = true
				break
		if clamp_match and p is Vector3:
			(ent as Entity).set_position(Vector3(p.x, ground_y, p.z))
	# Route through SpawnManager.despawn for unified cleanup
	# (relations + spatial_index + physics body + queue_free).
	for rid in to_remove:
		_world._spawn_manager.despawn(rid)
