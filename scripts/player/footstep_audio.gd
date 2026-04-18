extends RefCounted
class_name FootstepAudio

const FOOTSTEP_COLLISION_MASK: int = 9  # World (1) + Train (8)
const FOOTSTEP_GRASS_PREFIX: String = "footstep_grass_"
const FOOTSTEP_WOOD_PREFIX: String = "footstep_wood_"
const FOOTSTEP_VARIANT_COUNT: int = 5


static func play_local_footstep(source: Node3D, exclude_body: CollisionObject3D = null, volume_db: float = -14.0) -> void:
	if source == null or not is_instance_valid(source):
		return
	var prefix: String = FOOTSTEP_GRASS_PREFIX
	var collider: Node = _raycast_floor_collider(source, exclude_body)
	if _is_wood_floor_collider(collider):
		prefix = FOOTSTEP_WOOD_PREFIX
	elif _is_terrain_collider(collider):
		prefix = FOOTSTEP_GRASS_PREFIX
	var variant_index: int = randi() % FOOTSTEP_VARIANT_COUNT
	AudioManager.play_sfx("%s%03d" % [prefix, variant_index], volume_db, randf_range(0.96, 1.04))


static func _raycast_floor_collider(source: Node3D, exclude_body: CollisionObject3D = null) -> Node:
	var from: Vector3 = source.global_position + Vector3.UP * 0.35
	var to: Vector3 = source.global_position + Vector3.DOWN * 2.2
	var query := PhysicsRayQueryParameters3D.create(from, to, FOOTSTEP_COLLISION_MASK)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	if exclude_body != null:
		query.exclude = [exclude_body.get_rid()]
	var hit: Dictionary = source.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	var collider: Variant = hit.get("collider", null)
	if collider is Node:
		return collider as Node
	return null


static func _is_wood_floor_collider(node: Node) -> bool:
	var current: Node = node
	while current != null:
		if String(current.name) == "FloorPiece":
			return true
		current = current.get_parent()
	return false


static func _is_terrain_collider(node: Node) -> bool:
	var current: Node = node
	while current != null:
		var current_name: String = String(current.name)
		if current_name == "Terrain" or current_name == "__terrain_body":
			return true
		current = current.get_parent()
	return false
