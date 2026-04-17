extends Node3D
class_name AnimalSpawner

@export var fox_scene: PackedScene
@export var animal_count: int = 6
@export var spawn_area: Vector2 = Vector2(90.0, 90.0)
@export var min_distance_to_rails: float = 8.0
@export var spawn_y_offset: float = 0.08
@export var spawn_attempts_per_animal: int = 40
@export var spawn_at_player_on_start: bool = true
@export var player_path: NodePath = NodePath("")
@export var teleport_key: int = KEY_F
@export var teleport_distance_from_player: float = 3.0

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _terrain: TerrainGenerator = null
var _foxes: Array[Fox] = []


func _ready() -> void:
	_rng.randomize()
	add_to_group("animal_spawner")
	call_deferred("_spawn_animals")


func _spawn_animals() -> void:
	if fox_scene == null:
		return

	_terrain = _find_terrain()

	for _index in range(animal_count):
		var spawn_position: Vector3 = _get_start_spawn_position(_index)
		_spawn_fox_at(spawn_position)


func _input(event: InputEvent) -> void:
	var key_event: InputEventKey = event as InputEventKey
	if key_event == null:
		return

	if key_event.pressed and not key_event.echo and (key_event.keycode == teleport_key or key_event.physical_keycode == teleport_key):
		_teleport_foxes_to_player()


func _teleport_foxes_to_player() -> void:
	var player: Node3D = _get_player_node()
	if player == null:
		return

	_refresh_foxes_from_group()
	var teleport_position: Vector3 = _get_visible_position_near_player(player)

	if _foxes.is_empty():
		_spawn_fox_at(teleport_position)
		return

	for fox in _foxes:
		if not is_instance_valid(fox):
			continue

		fox.teleport_to(teleport_position)


func _spawn_fox_at(spawn_position: Vector3) -> Fox:
	if fox_scene == null:
		return null

	var fox: Node3D = fox_scene.instantiate() as Node3D
	if fox == null:
		return null

	fox.global_position = spawn_position
	add_child(fox)
	fox.global_position = spawn_position

	var fox_animal: Fox = fox as Fox
	if fox_animal == null:
		return null

	_foxes.append(fox_animal)
	fox_animal.set_home_position_to_current()
	return fox_animal


func _refresh_foxes_from_group() -> void:
	var refreshed_foxes: Array[Fox] = []
	for fox in _foxes:
		if is_instance_valid(fox):
			refreshed_foxes.append(fox)

	var fox_nodes: Array[Node] = get_tree().get_nodes_in_group("fox")
	for node in fox_nodes:
		if node is Fox and not refreshed_foxes.has(node):
			refreshed_foxes.append(node as Fox)

	_foxes = refreshed_foxes


func _get_visible_position_near_player(player: Node3D) -> Vector3:
	var forward: Vector3 = _get_player_forward(player)
	var teleport_position: Vector3 = player.global_position + forward * teleport_distance_from_player

	if _terrain != null:
		teleport_position.y = _terrain.get_height_at(teleport_position.x, teleport_position.z) + spawn_y_offset

	return teleport_position


func _get_player_forward(player: Node3D) -> Vector3:
	var camera: Camera3D = get_viewport().get_camera_3d()
	var forward: Vector3 = Vector3.ZERO

	if camera != null:
		forward = -camera.global_transform.basis.z
	else:
		forward = -player.global_transform.basis.z

	forward.y = 0.0
	if forward.length_squared() < 0.001:
		return Vector3.FORWARD

	return forward.normalized()


func _get_start_spawn_position(index: int) -> Vector3:
	if spawn_at_player_on_start and index == 0:
		var player: Node3D = _get_player_node()
		if player != null:
			return player.global_position

	return _sample_spawn_position()


func _sample_spawn_position() -> Vector3:
	var fallback_position: Vector3 = Vector3.ZERO

	for _attempt in range(spawn_attempts_per_animal):
		var candidate: Vector3 = _random_position_in_area()
		fallback_position = candidate
		if _is_spawn_position_valid(candidate):
			return candidate

	return fallback_position


func _random_position_in_area() -> Vector3:
	var half_width: float = spawn_area.x * 0.5
	var half_depth: float = spawn_area.y * 0.5
	var x: float = global_position.x + _rng.randf_range(-half_width, half_width)
	var z: float = global_position.z + _rng.randf_range(-half_depth, half_depth)
	var y: float = global_position.y + spawn_y_offset

	if _terrain != null:
		y = _terrain.get_height_at(x, z) + spawn_y_offset

	return Vector3(x, y, z)


func _is_spawn_position_valid(world_position: Vector3) -> bool:
	if _terrain != null and _terrain.distance_to_rails(world_position) < min_distance_to_rails:
		return false

	return true


func _find_terrain() -> TerrainGenerator:
	var terrain_nodes: Array[Node] = get_tree().get_nodes_in_group("terrain")
	for node in terrain_nodes:
		if node is TerrainGenerator:
			return node as TerrainGenerator

	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		return null

	return _find_terrain_recursive(scene_root)


func _get_player_node() -> Node3D:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null:
		var camera_player: Node3D = _find_player_parent(camera)
		if camera_player != null:
			return camera_player

	if player_path != NodePath(""):
		var path_node: Node = get_node_or_null(player_path)
		if path_node is Node3D:
			return path_node as Node3D

	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		return null

	return _find_player_recursive(scene_root)


func _find_player_parent(node: Node) -> Node3D:
	var current: Node = node
	while current != null:
		if current is CharacterBody3D and _looks_like_player(current):
			return current as Node3D

		current = current.get_parent()

	return null


func _find_player_recursive(node: Node) -> Node3D:
	if node is CharacterBody3D and _looks_like_player(node):
		return node as Node3D

	var children: Array[Node] = node.get_children()
	for child in children:
		var found: Node3D = _find_player_recursive(child)
		if found != null:
			return found

	return null


func _looks_like_player(node: Node) -> bool:
	var node_name: String = String(node.name).to_lower()
	return node.is_in_group("player") or node_name.find("player") != -1 or node_name.find("fpscontroller") != -1


func _find_terrain_recursive(node: Node) -> TerrainGenerator:
	if node is TerrainGenerator:
		return node as TerrainGenerator

	var children: Array[Node] = node.get_children()
	for child in children:
		var found: TerrainGenerator = _find_terrain_recursive(child)
		if found != null:
			return found

	return null
