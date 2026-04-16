extends Node

const NET_ID_META: StringName = &"net_id"
const TRAIN_TRANSFORM_INTERVAL: float = 0.1

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
	elif assigned_id >= _next_net_id:
		_next_net_id = assigned_id + 1
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
	var cached: Variant = _entities.get(net_id, null)
	if cached != null:
		if is_instance_valid(cached):
			return cached as Node
		_entities.erase(net_id)
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


func replicate_place_floor(target_net_id: int, floor_net_id: int, grid_pos: Vector2i) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_place_floor.rpc(target_net_id, floor_net_id, grid_pos)


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
func _apply_place_floor(target_net_id: int, floor_net_id: int, grid_pos: Vector2i) -> void:
	run_remote_apply(func(): return BuildSystem.apply_network_floor(target_net_id, floor_net_id, grid_pos))


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


func request_world_snapshot_from_host() -> void:
	if should_request_host():
		_request_world_snapshot.rpc_id(1)


@rpc("any_peer", "reliable")
func _request_world_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_send_world_snapshot_to_peer(sender_id)


func _send_world_snapshot_to_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	# Ensure the late-joiner has an inventory (restores preserved if matching name)
	Inventory.ensure_peer_inventory(peer_id)
	var main_scene: Node = get_tree().current_scene
	if main_scene != null and main_scene.has_method("spawn_player_for_late_join"):
		main_scene.spawn_player_for_late_join(peer_id)
	_stream_entities_to_peer(peer_id)
	TrainManager.sync_state_to_peer(peer_id)
	send_train_entity_snapshots_to_peer(peer_id)
	_snapshot_complete.rpc_id(peer_id)


func _stream_entities_to_peer(peer_id: int) -> void:
	# Stream all registered entities in a stable order: chassis first (so floors/items
	# can attach to them), then wagons, then placeables, then dropped items.
	var chassis_list: Array = []
	var wagon_list: Array = []
	var placeables: Array = []
	var drops: Array = []
	var players: Array = []
	for net_id in _entities:
		var node: Node = _entities[net_id]
		if node == null or not is_instance_valid(node):
			continue
		if node is WagonFrame:
			wagon_list.append(node)
		elif node is TrainChassis:
			chassis_list.append(node)
		elif node.is_in_group("dropped_item"):
			drops.append(node)
		elif node.is_in_group("player"):
			players.append(node)
		elif node.has_method("get_build_surface_local_y"):
			# Chassis-like stationary builds are covered above; treat as placeable.
			placeables.append(node)
		else:
			placeables.append(node)
	for chassis in chassis_list:
		_stream_chassis_spawn(peer_id, chassis)
	for wagon in wagon_list:
		_stream_wagon_frame_spawn(peer_id, wagon)
	for placed in placeables:
		_stream_placeable_spawn(peer_id, placed)
	for drop in drops:
		_stream_drop_spawn(peer_id, drop)


func _stream_chassis_spawn(peer_id: int, chassis: Node) -> void:
	var net_id := int(chassis.get_meta(NET_ID_META, 0))
	if net_id <= 0:
		return
	var chassis_node := chassis as TrainChassis
	if chassis_node == null:
		return
	# Skip bogies already parented under a WagonFrame — wagon stream handles them.
	var parent := chassis_node.get_parent()
	if parent is WagonFrame:
		return
	var rail_path_ref: NodePath = NodePath()
	if chassis_node.current_rail_path != null:
		rail_path_ref = chassis_node.current_rail_path.get_path()
	_apply_spawn_chassis.rpc_id(peer_id, net_id, chassis_node.global_transform, rail_path_ref, chassis_node.rail_progress)


func _stream_wagon_frame_spawn(peer_id: int, wagon: Node) -> void:
	var frame := wagon as WagonFrame
	if frame == null:
		return
	var frame_net_id := int(frame.get_meta(NET_ID_META, 0))
	if frame_net_id <= 0 or frame.front_bogie == null or frame.rear_bogie == null:
		return
	var front_net_id := int(frame.front_bogie.get_meta(NET_ID_META, 0))
	var rear_net_id := int(frame.rear_bogie.get_meta(NET_ID_META, 0))
	if front_net_id <= 0 or rear_net_id <= 0:
		return
	var rail_path_ref: NodePath = NodePath()
	if frame.front_bogie.current_rail_path != null:
		rail_path_ref = frame.front_bogie.current_rail_path.get_path()
	_apply_spawn_wagon_frame.rpc_id(
		peer_id,
		frame_net_id,
		front_net_id,
		rear_net_id,
		0,
		frame.global_transform,
		frame.front_bogie.global_transform,
		frame.rear_bogie.global_transform,
		frame.wagon_length,
		rail_path_ref,
		frame.front_bogie.rail_progress,
		frame.rear_bogie.rail_progress
	)
	# After frame spawn, stream its attached floors/items (children of its bogies or the frame itself)
	_stream_children_placeables_to_peer(peer_id, frame)


func _stream_children_placeables_to_peer(peer_id: int, root: Node) -> void:
	for child in root.get_children():
		if child is Node3D and child.has_meta(NET_ID_META):
			var build_id := ""
			if child.has_meta("buildable_id"):
				build_id = String(child.get_meta("buildable_id"))
			var parent_net_id := int(root.get_meta(NET_ID_META, 0))
			var child_net_id := int(child.get_meta(NET_ID_META))
			if parent_net_id <= 0 or child_net_id <= 0:
				continue
			if build_id.is_empty():
				# Assume floor piece
				var grid_pos := _infer_grid_pos_from_child(root, child)
				_apply_place_floor.rpc_id(peer_id, parent_net_id, child_net_id, grid_pos)
			else:
				var grid_pos2 := _infer_grid_pos_from_child(root, child)
				var edge := int(child.get_meta("edge_side", -1))
				_apply_place_item.rpc_id(peer_id, parent_net_id, child_net_id, build_id, grid_pos2, child.rotation.y, edge)
		_stream_children_placeables_to_peer(peer_id, child)


func _infer_grid_pos_from_child(parent: Node, child: Node) -> Vector2i:
	if child.has_meta("grid_pos_x") and child.has_meta("grid_pos_y"):
		return Vector2i(int(child.get_meta("grid_pos_x")), int(child.get_meta("grid_pos_y")))
	if parent.has_method("get_grid_position") and child is Node3D:
		return parent.get_grid_position((child as Node3D).global_position)
	return Vector2i.ZERO


func _stream_placeable_spawn(_peer_id: int, _node: Node) -> void:
	# Standalone placeables covered via parent-stream. Hook for future scene-based entities.
	pass


func _stream_drop_spawn(peer_id: int, drop: Node) -> void:
	var drop_node := drop as Node3D
	if drop_node == null:
		return
	var net_id := int(drop_node.get_meta(NET_ID_META, 0))
	if net_id <= 0:
		return
	var item_id := String(drop_node.get_meta("item_id", ""))
	var amount := int(drop_node.get_meta("amount", 0))
	if item_id.is_empty() or amount <= 0:
		return
	_apply_spawn_drop.rpc_id(peer_id, net_id, item_id, amount, drop_node.global_transform)


func broadcast_train_entity_snapshots() -> void:
	if not multiplayer.is_server():
		return
	for net_id in _entities.keys():
		var node := get_entity(int(net_id))
		if node == null or not is_instance_valid(node):
			continue
		if not _is_train_snapshot_entity(node):
			continue
		_apply_entity_transform.rpc(int(net_id), (node as Node3D).global_transform)


func send_train_entity_snapshots_to_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	for net_id in _entities.keys():
		var node := get_entity(int(net_id))
		if node == null or not is_instance_valid(node):
			continue
		if not _is_train_snapshot_entity(node):
			continue
		_apply_entity_transform.rpc_id(peer_id, int(net_id), (node as Node3D).global_transform)


func _is_train_snapshot_entity(node: Node) -> bool:
	if not (node is Node3D):
		return false
	if node is WagonFrame:
		return true
	if node is TrainChassis:
		return true
	if node.is_in_group("wagon") or node.is_in_group("wagon_frame") or node.is_in_group("chassis"):
		return true
	return false


@rpc("authority", "reliable")
func _snapshot_complete() -> void:
	var main_scene := get_tree().current_scene
	if main_scene != null and main_scene.has_method("hide_loading_overlay"):
		main_scene.hide_loading_overlay()


@rpc("authority", "reliable")
func _apply_entity_transform(net_id: int, transform: Transform3D) -> void:
	var node := get_entity(net_id)
	if node == null or not is_instance_valid(node):
		return
	if not (node is Node3D):
		return
	var node_3d := node as Node3D
	var previous_transform := node_3d.global_transform
	node_3d.global_transform = transform
	var platform_velocity := (transform.origin - previous_transform.origin) / TRAIN_TRANSFORM_INTERVAL
	if node_3d is StaticBody3D:
		(node_3d as StaticBody3D).constant_linear_velocity = platform_velocity
	if node_3d.has_method("_set_platform_velocity"):
		node_3d.call("_set_platform_velocity", platform_velocity)


# --- Dropped items ---

func replicate_spawn_drop(net_id: int, item_id: String, amount: int, transform: Transform3D) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_spawn_drop.rpc(net_id, item_id, amount, transform)


@rpc("authority", "reliable")
func _apply_spawn_drop(net_id: int, item_id: String, amount: int, transform: Transform3D) -> void:
	if get_entity(net_id) != null:
		return
	var scene := load("res://scenes/world/dropped_item.tscn") as PackedScene
	if scene == null or get_tree().current_scene == null:
		return
	var drop := scene.instantiate() as Node3D
	if drop == null:
		return
	get_tree().current_scene.add_child(drop)
	register_entity(drop, net_id)
	drop.global_transform = transform
	if drop.has_method("setup"):
		drop.setup(item_id, amount)


func request_drop_slot(slot_index: int, amount: int, drop_transform: Transform3D) -> void:
	if should_request_host():
		_request_drop_slot.rpc_id(1, slot_index, amount, drop_transform)


func request_pickup_drop(net_id: int) -> void:
	if should_request_host():
		_request_pickup_drop.rpc_id(1, net_id)


@rpc("any_peer", "reliable")
func _request_drop_slot(slot_index: int, amount: int, drop_transform: Transform3D) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = 1
	Inventory.server_drop_slot(sender_id, slot_index, amount, drop_transform)


@rpc("any_peer", "reliable")
func _request_pickup_drop(net_id: int) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = 1
	var drop_node := get_entity(net_id)
	if drop_node == null or not drop_node.has_method("server_pickup"):
		return
	drop_node.server_pickup(sender_id)


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
