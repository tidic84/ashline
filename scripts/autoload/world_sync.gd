extends Node

const NET_ID_META: StringName = &"net_id"

var _next_net_id: int = 1000
var _entities: Dictionary = {}
var _is_applying_remote: bool = false


func is_networked() -> bool:
	return multiplayer.has_multiplayer_peer()


func is_host() -> bool:
	return not is_networked() or multiplayer.is_server()


func should_request_host() -> bool:
	return is_networked() and not multiplayer.is_server() and not _is_applying_remote


func register_entity(node: Node, net_id: int = 0) -> int:
	if node == null:
		return 0
	var assigned_id := net_id
	if assigned_id <= 0:
		assigned_id = _next_net_id
		_next_net_id += 1
	node.set_meta(NET_ID_META, assigned_id)
	node.add_to_group("net_entity")
	_entities[assigned_id] = node
	return assigned_id


func get_net_id(node: Node) -> int:
	if node == null:
		return 0
	if node.has_meta(NET_ID_META):
		return int(node.get_meta(NET_ID_META))
	if is_host():
		return register_entity(node)
	return 0


func get_entity(net_id: int) -> Node:
	if net_id <= 0:
		return null
	var cached: Node = _entities.get(net_id)
	if cached != null and is_instance_valid(cached):
		return cached
	for node in get_tree().get_nodes_in_group("net_entity"):
		if node.has_meta(NET_ID_META) and int(node.get_meta(NET_ID_META)) == net_id:
			_entities[net_id] = node
			return node
	return null


func unregister_entity(net_id: int) -> void:
	_entities.erase(net_id)


func run_remote_apply(action: Callable) -> Variant:
	_is_applying_remote = true
	var result: Variant = action.call()
	_is_applying_remote = false
	return result


func request_select_hotbar(index: int) -> void:
	if should_request_host():
		_request_select_hotbar.rpc_id(1, index)


func request_move_slot(source_index: int, target_index: int) -> void:
	if should_request_host():
		_request_move_slot.rpc_id(1, source_index, target_index)


func request_craft(recipe_id: String) -> void:
	if should_request_host():
		_request_craft.rpc_id(1, recipe_id)


func request_harvest(harvestable_net_id: int) -> void:
	if should_request_host():
		_request_harvest.rpc_id(1, harvestable_net_id)


func request_interact(target_net_id: int) -> void:
	if should_request_host():
		_request_interact.rpc_id(1, target_net_id)


func request_place_chassis(hit_point: Vector3) -> void:
	if should_request_host():
		_request_place_chassis.rpc_id(1, hit_point)


func request_place_floor(target_net_id: int, grid_pos: Vector2i) -> void:
	if should_request_host():
		_request_place_floor.rpc_id(1, target_net_id, grid_pos)


func request_place_item(target_net_id: int, buildable_id: String, grid_pos: Vector2i, rotation_y: float, edge: int) -> void:
	if should_request_host():
		_request_place_item.rpc_id(1, target_net_id, buildable_id, grid_pos, rotation_y, edge)


func request_demolish(target_net_id: int, grid_pos: Vector2i, edge: int) -> void:
	if should_request_host():
		_request_demolish.rpc_id(1, target_net_id, grid_pos, edge)


func request_damage(target_net_id: int, amount: float) -> void:
	if should_request_host():
		_request_damage.rpc_id(1, target_net_id, amount)


func replicate_place_floor(target_net_id: int, grid_pos: Vector2i) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_place_floor.rpc(target_net_id, grid_pos)


func replicate_place_item(target_net_id: int, item_net_id: int, buildable_id: String, grid_pos: Vector2i, rotation_y: float, edge: int) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_place_item.rpc(target_net_id, item_net_id, buildable_id, grid_pos, rotation_y, edge)


func replicate_demolish(target_net_id: int, grid_pos: Vector2i, edge: int) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_demolish.rpc(target_net_id, grid_pos, edge)


func replicate_despawn(net_id: int) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_despawn.rpc(net_id)


func replicate_interact(net_id: int) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_interact.rpc(net_id)


func replicate_spawn_chassis(net_id: int, transform: Transform3D, rail_path: NodePath, rail_progress: float) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_spawn_chassis.rpc(net_id, transform, rail_path, rail_progress)


func replicate_spawn_scene(net_id: int, scene_path: String, transform: Transform3D) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_spawn_scene.rpc(net_id, scene_path, transform)


func replicate_spawn_wagon_frame(
	frame_net_id: int,
	front_net_id: int,
	rear_net_id: int,
	previous_first_net_id: int,
	frame_transform: Transform3D,
	front_transform: Transform3D,
	rear_transform: Transform3D,
	wagon_length: int,
	rail_path: NodePath,
	front_progress: float,
	rear_progress: float
) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_spawn_wagon_frame.rpc(
			frame_net_id,
			front_net_id,
			rear_net_id,
			previous_first_net_id,
			frame_transform,
			front_transform,
			rear_transform,
			wagon_length,
			rail_path,
			front_progress,
			rear_progress
		)


@rpc("any_peer", "reliable")
func _request_select_hotbar(index: int) -> void:
	if not multiplayer.is_server():
		return
	Inventory.server_select_hotbar(multiplayer.get_remote_sender_id(), index)


@rpc("any_peer", "reliable")
func _request_move_slot(source_index: int, target_index: int) -> void:
	if not multiplayer.is_server():
		return
	Inventory.server_move_slot(multiplayer.get_remote_sender_id(), source_index, target_index)


@rpc("any_peer", "reliable")
func _request_craft(recipe_id: String) -> void:
	if not multiplayer.is_server():
		return
	CraftingSystem.server_craft(multiplayer.get_remote_sender_id(), recipe_id)


@rpc("any_peer", "reliable")
func _request_harvest(harvestable_net_id: int) -> void:
	if not multiplayer.is_server():
		return
	var node := get_entity(harvestable_net_id)
	if node != null and node.has_method("server_harvest"):
		node.server_harvest(multiplayer.get_remote_sender_id())


@rpc("any_peer", "reliable")
func _request_interact(target_net_id: int) -> void:
	if not multiplayer.is_server():
		return
	var node := get_entity(target_net_id)
	if node != null and node.has_method("server_interact"):
		node.server_interact(multiplayer.get_remote_sender_id())


@rpc("any_peer", "reliable")
func _request_place_chassis(hit_point: Vector3) -> void:
	if not multiplayer.is_server():
		return
	BuildSystem.server_try_place_chassis(multiplayer.get_remote_sender_id(), hit_point)


@rpc("any_peer", "reliable")
func _request_place_floor(target_net_id: int, grid_pos: Vector2i) -> void:
	if not multiplayer.is_server():
		return
	BuildSystem.server_try_place_floor(multiplayer.get_remote_sender_id(), target_net_id, grid_pos)


@rpc("any_peer", "reliable")
func _request_place_item(target_net_id: int, buildable_id: String, grid_pos: Vector2i, rotation_y: float, edge: int) -> void:
	if not multiplayer.is_server():
		return
	BuildSystem.server_try_place_item(multiplayer.get_remote_sender_id(), target_net_id, buildable_id, grid_pos, rotation_y, edge)


@rpc("any_peer", "reliable")
func _request_demolish(target_net_id: int, grid_pos: Vector2i, edge: int) -> void:
	if not multiplayer.is_server():
		return
	BuildSystem.server_try_demolish(multiplayer.get_remote_sender_id(), target_net_id, grid_pos, edge)


@rpc("any_peer", "reliable")
func _request_damage(target_net_id: int, amount: float) -> void:
	if not multiplayer.is_server():
		return
	var node := get_entity(target_net_id)
	if node != null and node.has_method("take_damage"):
		node.take_damage(amount)


@rpc("authority", "reliable")
func _apply_place_floor(target_net_id: int, grid_pos: Vector2i) -> void:
	run_remote_apply(func(): return BuildSystem.apply_network_floor(target_net_id, grid_pos))


@rpc("authority", "reliable")
func _apply_place_item(target_net_id: int, item_net_id: int, buildable_id: String, grid_pos: Vector2i, rotation_y: float, edge: int) -> void:
	run_remote_apply(func(): return BuildSystem.apply_network_item(target_net_id, item_net_id, buildable_id, grid_pos, rotation_y, edge))


@rpc("authority", "reliable")
func _apply_demolish(target_net_id: int, grid_pos: Vector2i, edge: int) -> void:
	run_remote_apply(func(): return BuildSystem.apply_network_demolish(target_net_id, grid_pos, edge))


@rpc("authority", "reliable")
func _apply_despawn(net_id: int) -> void:
	var node := get_entity(net_id)
	if node != null and is_instance_valid(node):
		node.queue_free()
	unregister_entity(net_id)


@rpc("authority", "reliable")
func _apply_interact(net_id: int) -> void:
	var node := get_entity(net_id)
	if node != null and node.has_method("apply_network_interact"):
		run_remote_apply(func(): return node.apply_network_interact())


@rpc("authority", "reliable")
func _apply_spawn_chassis(net_id: int, transform: Transform3D, rail_path: NodePath, rail_progress: float) -> void:
	if get_entity(net_id) != null:
		return
	var scene := load("res://scenes/train/chassis.tscn") as PackedScene
	if scene == null or get_tree().current_scene == null:
		return
	var chassis := scene.instantiate() as TrainChassis
	get_tree().current_scene.add_child(chassis)
	register_entity(chassis, net_id)
	chassis.global_transform = transform
	chassis.rail_progress = rail_progress
	chassis.current_rail_path = get_node_or_null(rail_path)
	if chassis.current_rail_path != null:
		chassis.rail_curve = BuildSystem._build_world_curve(chassis.current_rail_path)


@rpc("authority", "reliable")
func _apply_spawn_scene(net_id: int, scene_path: String, transform: Transform3D) -> void:
	if get_entity(net_id) != null:
		return
	var scene := load(scene_path) as PackedScene
	if scene == null or get_tree().current_scene == null:
		return
	var node := scene.instantiate() as Node3D
	if node == null:
		return
	get_tree().current_scene.add_child(node)
	register_entity(node, net_id)
	node.global_transform = transform


@rpc("authority", "reliable")
func _apply_spawn_wagon_frame(
	frame_net_id: int,
	front_net_id: int,
	rear_net_id: int,
	previous_first_net_id: int,
	frame_transform: Transform3D,
	front_transform: Transform3D,
	rear_transform: Transform3D,
	wagon_length: int,
	rail_path: NodePath,
	front_progress: float,
	rear_progress: float
) -> void:
	var old_first := get_entity(previous_first_net_id)
	if old_first != null and is_instance_valid(old_first):
		old_first.queue_free()
		unregister_entity(previous_first_net_id)
	if get_entity(frame_net_id) != null:
		return
	var scene := load("res://scenes/train/chassis.tscn") as PackedScene
	if scene == null or get_tree().current_scene == null:
		return
	var frame := WagonFrame.new()
	frame.wagon_length = wagon_length
	get_tree().current_scene.add_child(frame)
	register_entity(frame, frame_net_id)
	frame.global_transform = frame_transform
	var front := scene.instantiate() as TrainChassis
	var rear := scene.instantiate() as TrainChassis
	frame.add_child(front)
	frame.add_child(rear)
	register_entity(front, front_net_id)
	register_entity(rear, rear_net_id)
	front.global_transform = front_transform
	rear.global_transform = rear_transform
	frame.front_bogie = front
	frame.rear_bogie = rear
	frame._setup_bogies()
	frame._build_frame_visuals()
	frame._build_collision_surface()
	var rail_node := get_node_or_null(rail_path)
	var curve := BuildSystem._build_world_curve(rail_node) if rail_node != null else null
	front.current_rail_path = rail_node
	rear.current_rail_path = rail_node
	front.rail_curve = curve
	rear.rail_curve = curve
	front.rail_progress = front_progress
	rear.rail_progress = rear_progress
	frame.is_on_rails = true
