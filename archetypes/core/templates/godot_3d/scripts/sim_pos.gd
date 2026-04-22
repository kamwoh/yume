extends RefCounted

## NOTE: deliberately NOT using class_name. New class_name registrations
## require an editor scan/import to be visible at runtime, which makes
## headless CLI runs flaky. Consumers do `const SimPos = preload(...)`
## at file top — explicit and zero registration friction.

## Dimension-agnostic position adapter.
## Brain + rules engine treat 2D (Node2D) and 3D (Node3D) entities uniformly
## via Vector2 (top-down ground plane). Renderer scripts (entity_3d, world_elements)
## stay aware of the third axis; everything else doesn't.
##
## 3D convention: Vector2.y = world Z (the floor plane is XZ, Y is up).
## 2D convention: Vector2 = node.global_position directly.

static func of(node: Node) -> Vector2:
	if node is Node2D:
		return node.global_position
	if node is Node3D:
		return Vector2(node.global_position.x, node.global_position.z)
	return Vector2.ZERO


static func set_at(node: Node, p: Vector2) -> void:
	if node is Node2D:
		node.global_position = p
	elif node is Node3D:
		node.global_position.x = p.x
		node.global_position.z = p.y


static func dist(a: Node, b: Node) -> float:
	return of(a).distance_to(of(b))
