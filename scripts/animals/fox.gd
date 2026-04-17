extends CharacterBody3D
class_name Fox

@export var move_speed: float = 1.7
@export var turn_speed: float = 6.0
@export var wander_radius: float = 12.0
@export var min_wait_time: float = 0.8
@export var max_wait_time: float = 2.4
@export var ground_offset: float = 0.08
@export var target_reached_distance: float = 0.7

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _home_position: Vector3 = Vector3.ZERO
var _wander_target: Vector3 = Vector3.ZERO
var _wait_timer: float = 0.0
var _terrain: TerrainGenerator = null
var _animation_player: AnimationPlayer = null


func _ready() -> void:
	_rng.randomize()
	add_to_group("animal")
	add_to_group("fox")
	collision_layer = 0
	collision_mask = 1
	_terrain = _find_terrain()
	_snap_to_ground()
	_home_position = global_position
	_wander_target = global_position
	_setup_animation_player()
	_choose_next_target()


func set_home_position_to_current() -> void:
	_snap_to_ground()
	_home_position = global_position
	_wander_target = global_position
	_choose_next_target()


func teleport_to(world_position: Vector3) -> void:
	global_position = world_position
	velocity = Vector3.ZERO
	set_home_position_to_current()


func _physics_process(delta: float) -> void:
	_snap_to_ground()

	if _wait_timer > 0.0:
		_wait_timer -= delta
		velocity.x = 0.0
		velocity.y = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	var to_target: Vector3 = _wander_target - global_position
	to_target.y = 0.0

	if to_target.length() <= target_reached_distance:
		_wait_timer = _rng.randf_range(min_wait_time, max_wait_time)
		_choose_next_target()
		velocity.x = 0.0
		velocity.y = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	var direction: Vector3 = to_target.normalized()
	velocity.x = direction.x * move_speed
	velocity.y = 0.0
	velocity.z = direction.z * move_speed

	var target_yaw: float = atan2(direction.x, direction.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, clampf(turn_speed * delta, 0.0, 1.0))

	move_and_slide()
	_snap_to_ground()


func _choose_next_target() -> void:
	var angle: float = _rng.randf_range(0.0, TAU)
	var distance: float = _rng.randf_range(wander_radius * 0.25, wander_radius)
	var candidate: Vector3 = _home_position + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
	candidate.y = _get_ground_y(candidate) + ground_offset
	_wander_target = candidate


func _snap_to_ground() -> void:
	if _terrain == null:
		return

	var current_position: Vector3 = global_position
	current_position.y = _get_ground_y(current_position) + ground_offset
	global_position = current_position


func _get_ground_y(world_position: Vector3) -> float:
	if _terrain == null:
		return world_position.y

	return _terrain.get_height_at(world_position.x, world_position.z)


func _setup_animation_player() -> void:
	_animation_player = _find_animation_player(self)
	if _animation_player == null:
		return

	var animation_names: PackedStringArray = _animation_player.get_animation_list()
	if animation_names.size() == 0:
		return

	var selected_animation: StringName = StringName(animation_names[0])
	for animation_name in animation_names:
		if animation_name.to_lower() != "reset":
			selected_animation = StringName(animation_name)
			break

	_animation_player.play(selected_animation)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer

	var children: Array[Node] = node.get_children()
	for child in children:
		var found: AnimationPlayer = _find_animation_player(child)
		if found != null:
			return found

	return null


func _find_terrain() -> TerrainGenerator:
	var terrain_nodes: Array[Node] = get_tree().get_nodes_in_group("terrain")
	for node in terrain_nodes:
		if node is TerrainGenerator:
			return node as TerrainGenerator

	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		return null

	return _find_terrain_recursive(scene_root)


func _find_terrain_recursive(node: Node) -> TerrainGenerator:
	if node is TerrainGenerator:
		return node as TerrainGenerator

	var children: Array[Node] = node.get_children()
	for child in children:
		var found: TerrainGenerator = _find_terrain_recursive(child)
		if found != null:
			return found

	return null
