extends Node

const NET_ID_META: StringName = &"net_id"
const TRAIN_ENTITY_EXTRAPOLATION: float = 0.20
const TRAIN_ENTITY_SMOOTH_RATE: float = 14.0
const TRAIN_SNAPSHOT_POS_EPSILON: float = 0.25
const TRAIN_SNAPSHOT_ROT_EPSILON: float = 0.035
const TRAIN_SNAPSHOT_VEL_EPSILON: float = 0.35
const TRAIN_SNAPSHOT_MAX_SILENCE: float = 0.18
const TRAIN_CLIENT_IGNORE_DISTANCE: float = 0.18
const TRAIN_CLIENT_IGNORE_ROTATION: float = 0.05
const TRAIN_CLIENT_IGNORE_VELOCITY: float = 0.35
const TRAIN_CLIENT_SNAP_DISTANCE: float = 2.5
const TRAIN_CLIENT_SNAP_ROTATION: float = 0.60
const TRAIN_LOW_SPEED_THRESHOLD: float = 4.0
const TRAIN_SNAPSHOT_POS_EPSILON_SLOW: float = 0.04
const TRAIN_SNAPSHOT_ROT_EPSILON_SLOW: float = 0.010
const TRAIN_SNAPSHOT_VEL_EPSILON_SLOW: float = 0.08
const TRAIN_SNAPSHOT_MAX_SILENCE_SLOW: float = 0.06
const TRAIN_CLIENT_IGNORE_DISTANCE_SLOW: float = 0.04
const TRAIN_CLIENT_IGNORE_ROTATION_SLOW: float = 0.015
const TRAIN_CLIENT_IGNORE_VELOCITY_SLOW: float = 0.10
const TRAIN_AUDIO_TRIGGER_SPEED: float = 0.1

var _next_net_id: int = 1000
var _entities: Dictionary = {}
var _is_applying_remote: bool = false
var _train_entity_targets: Dictionary = {}
var _train_entity_snapshot_state: Dictionary = {}
var _train_entity_sent_state: Dictionary = {}


func _ready() -> void:
	process_physics_priority = -20


func is_networked() -> bool:
	return multiplayer.has_multiplayer_peer()


func is_host() -> bool:
	return not is_networked() or multiplayer.is_server()


func should_request_host() -> bool:
	return is_networked() and not multiplayer.is_server() and not _is_applying_remote


func _physics_process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		return
	var stale_ids: Array[int] = []
	for net_id_variant in _train_entity_targets.keys():
		var net_id := int(net_id_variant)
		var node := get_entity(net_id)
		if node == null or not is_instance_valid(node) or not (node is Node3D):
			stale_ids.append(net_id)
			continue
		var state: Dictionary = _train_entity_targets[net_id]
		state["age"] = float(state.get("age", 0.0)) + delta
		_train_entity_targets[net_id] = state
		var node_3d := node as Node3D
		var target_transform: Transform3D = state.get("transform", node_3d.global_transform)
		var velocity: Vector3 = state.get("velocity", Vector3.ZERO)
		var extrapolation := minf(float(state.get("age", 0.0)), TRAIN_ENTITY_EXTRAPOLATION)
		var target_origin := target_transform.origin + velocity * extrapolation
		var factor := clampf(delta * TRAIN_ENTITY_SMOOTH_RATE, 0.0, 1.0)
		node_3d.global_position = node_3d.global_position.lerp(target_origin, factor)
		var target_scale: Vector3 = target_transform.basis.get_scale()
		var current_basis: Basis = node_3d.global_basis.orthonormalized()
		var target_basis: Basis = target_transform.basis.orthonormalized()
		node_3d.global_basis = current_basis.slerp(target_basis, factor).scaled(target_scale)
		if node_3d is StaticBody3D:
			(node_3d as StaticBody3D).constant_linear_velocity = velocity
		if node_3d.has_method("_set_platform_velocity"):
			node_3d.call("_set_platform_velocity", velocity)
	for net_id in stale_ids:
		_train_entity_targets.erase(net_id)


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
	_train_entity_targets.erase(net_id)
	_train_entity_snapshot_state.erase(net_id)
	_train_entity_sent_state.erase(net_id)


func unregister_entity_tree(root: Node) -> void:
	if root == null:
		return
	if root.has_meta(NET_ID_META):
		unregister_entity(int(root.get_meta(NET_ID_META)))
	for child in root.get_children():
		unregister_entity_tree(child)


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


func request_place_floor(target_net_id: int, grid_pos: Vector3i) -> void:
	if should_request_host():
		_request_place_floor.rpc_id(1, target_net_id, grid_pos)


func request_place_ceiling(target_net_id: int, grid_pos: Vector3i) -> void:
	if should_request_host():
		_request_place_ceiling.rpc_id(1, target_net_id, grid_pos)


func request_place_item(target_net_id: int, buildable_id: String, grid_pos: Vector3i, rotation_y: float, edge: int) -> void:
	if should_request_host():
		_request_place_item.rpc_id(1, target_net_id, buildable_id, grid_pos, rotation_y, edge)


func request_demolish(target_net_id: int, grid_pos: Vector3i, edge: int) -> void:
	if should_request_host():
		_request_demolish.rpc_id(1, target_net_id, grid_pos, edge)


func request_damage(target_net_id: int, amount: float) -> void:
	if should_request_host():
		_request_damage.rpc_id(1, target_net_id, amount)


func replicate_place_floor(target_net_id: int, floor_net_id: int, grid_pos: Vector3i) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_place_floor.rpc(target_net_id, floor_net_id, grid_pos)


func replicate_place_ceiling(target_net_id: int, ceiling_net_id: int, grid_pos: Vector3i) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_place_ceiling.rpc(target_net_id, ceiling_net_id, grid_pos)


func replicate_place_item(target_net_id: int, item_net_id: int, buildable_id: String, grid_pos: Vector3i, rotation_y: float, edge: int) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_place_item.rpc(target_net_id, item_net_id, buildable_id, grid_pos, rotation_y, edge)


func replicate_demolish(target_net_id: int, grid_pos: Vector3i, edge: int) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_demolish.rpc(target_net_id, grid_pos, edge)


func replicate_despawn(net_id: int) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_despawn.rpc(net_id)


func replicate_interact(net_id: int) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_interact.rpc(net_id)

func replicate_spatial_sfx(name: String, world_position: Vector3, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_spatial_sfx.rpc(name, world_position, volume_db, pitch)


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
	rear_progress: float,
	owner_peer_id: int = 0
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
			rear_progress,
			owner_peer_id
		)


func broadcast_coupling(wagon_net_id: int, other_net_id: int, my_side: int, other_side: int, couple: bool) -> void:
	if is_networked() and multiplayer.is_server():
		_apply_coupling.rpc(wagon_net_id, other_net_id, my_side, other_side, couple)


@rpc("authority", "reliable")
func _apply_coupling(wagon_net_id: int, other_net_id: int, my_side: int, other_side: int, couple: bool) -> void:
	if multiplayer.is_server():
		return
	var a := get_entity(wagon_net_id) as WagonFrame
	var b := get_entity(other_net_id) as WagonFrame
	if a == null or b == null:
		return
	if couple:
		a.couple_to(b, my_side, other_side)
	else:
		a.uncouple(my_side)


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
func _request_place_floor(target_net_id: int, grid_pos: Vector3i) -> void:
	if not multiplayer.is_server():
		return
	BuildSystem.server_try_place_floor(multiplayer.get_remote_sender_id(), target_net_id, grid_pos)


@rpc("any_peer", "reliable")
func _request_place_ceiling(target_net_id: int, grid_pos: Vector3i) -> void:
	if not multiplayer.is_server():
		return
	BuildSystem.server_try_place_ceiling(multiplayer.get_remote_sender_id(), target_net_id, grid_pos)


@rpc("any_peer", "reliable")
func _request_place_item(target_net_id: int, buildable_id: String, grid_pos: Vector3i, rotation_y: float, edge: int) -> void:
	if not multiplayer.is_server():
		return
	BuildSystem.server_try_place_item(multiplayer.get_remote_sender_id(), target_net_id, buildable_id, grid_pos, rotation_y, edge)


@rpc("any_peer", "reliable")
func _request_demolish(target_net_id: int, grid_pos: Vector3i, edge: int) -> void:
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
func _apply_place_floor(target_net_id: int, floor_net_id: int, grid_pos: Vector3i) -> void:
	run_remote_apply(func(): return BuildSystem.apply_network_floor(target_net_id, floor_net_id, grid_pos))


@rpc("authority", "reliable")
func _apply_place_ceiling(target_net_id: int, ceiling_net_id: int, grid_pos: Vector3i) -> void:
	run_remote_apply(func(): return BuildSystem.apply_network_ceiling(target_net_id, ceiling_net_id, grid_pos))


@rpc("authority", "reliable")
func _apply_place_item(target_net_id: int, item_net_id: int, buildable_id: String, grid_pos: Vector3i, rotation_y: float, edge: int) -> void:
	run_remote_apply(func(): return BuildSystem.apply_network_item(target_net_id, item_net_id, buildable_id, grid_pos, rotation_y, edge))


@rpc("authority", "reliable")
func _apply_demolish(target_net_id: int, grid_pos: Vector3i, edge: int) -> void:
	run_remote_apply(func(): return BuildSystem.apply_network_demolish(target_net_id, grid_pos, edge))


@rpc("authority", "reliable")
func _apply_despawn(net_id: int) -> void:
	var node := get_entity(net_id)
	if node != null and is_instance_valid(node):
		unregister_entity_tree(node)
		node.queue_free()
	else:
		unregister_entity(net_id)


@rpc("authority", "reliable")
func _apply_interact(net_id: int) -> void:
	var node := get_entity(net_id)
	if node != null and node.has_method("apply_network_interact"):
		run_remote_apply(func(): return node.apply_network_interact())

@rpc("authority", "unreliable")
func _apply_spatial_sfx(name: String, world_position: Vector3, volume_db: float, pitch: float) -> void:
	if AudioManager != null and AudioManager.has_method("play_sfx_3d"):
		AudioManager.play_sfx_3d(name, world_position, volume_db, pitch)


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
		frame.rear_bogie.rail_progress,
		int(frame.get_meta("owner_peer_id", 0))
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
				var grid_pos := _infer_grid_pos_from_child(root, child)
				if child.has_meta("is_ceiling") and bool(child.get_meta("is_ceiling")):
					_apply_place_ceiling.rpc_id(peer_id, parent_net_id, child_net_id, grid_pos)
				else:
					_apply_place_floor.rpc_id(peer_id, parent_net_id, child_net_id, grid_pos)
			else:
				var grid_pos2 := _infer_grid_pos_from_child(root, child)
				var edge := int(child.get_meta("edge_side", -1))
				_apply_place_item.rpc_id(peer_id, parent_net_id, child_net_id, build_id, grid_pos2, child.rotation.y, edge)
		_stream_children_placeables_to_peer(peer_id, child)


func _infer_grid_pos_from_child(parent: Node, child: Node) -> Vector3i:
	if child.has_meta("grid_pos_x") and child.has_meta("grid_pos_y"):
		var level: int = int(child.get_meta("grid_pos_z", 0))
		return Vector3i(int(child.get_meta("grid_pos_x")), int(child.get_meta("grid_pos_y")), level)
	if parent.has_method("get_grid_position") and child is Node3D:
		return parent.get_grid_position((child as Node3D).global_position)
	return Vector3i.ZERO


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


func broadcast_train_entity_snapshots(force: bool = false) -> void:
	if not multiplayer.is_server():
		return
	for net_id in _entities.keys():
		var node := get_entity(int(net_id))
		if node == null or not is_instance_valid(node):
			continue
		if not _is_train_snapshot_entity(node):
			continue
		var node_3d := node as Node3D
		var velocity := _get_train_snapshot_velocity(int(net_id), node_3d)
		if not force and not _should_send_train_snapshot(int(net_id), node_3d.global_transform, velocity):
			continue
		_record_train_snapshot_sent(int(net_id), node_3d.global_transform, velocity)
		_apply_entity_transform.rpc(int(net_id), node_3d.global_transform, velocity)


func send_train_entity_snapshots_to_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	for net_id in _entities.keys():
		var node := get_entity(int(net_id))
		if node == null or not is_instance_valid(node):
			continue
		if node is WagonFrame:
			_send_wagon_rail_snapshot_to_peer(peer_id, int(net_id), node as WagonFrame)
			continue
		if not _is_train_snapshot_entity(node):
			continue
		var node_3d := node as Node3D
		var velocity := _get_train_snapshot_velocity(int(net_id), node_3d)
		_record_train_snapshot_sent(int(net_id), node_3d.global_transform, velocity)
		_apply_entity_transform.rpc_id(peer_id, int(net_id), node_3d.global_transform, velocity)


func _get_train_snapshot_velocity(net_id: int, node: Node3D) -> Vector3:
	if node.has_method("get_platform_velocity"):
		var value: Variant = node.call("get_platform_velocity")
		if value is Vector3:
			return value
	if node is StaticBody3D:
		return (node as StaticBody3D).constant_linear_velocity
	var now := Time.get_ticks_usec() / 1000000.0
	var velocity := Vector3.ZERO
	var previous: Variant = _train_entity_snapshot_state.get(net_id, null)
	if previous is Dictionary:
		var previous_state := previous as Dictionary
		var previous_origin: Variant = previous_state.get("origin", node.global_position)
		var previous_time := float(previous_state.get("time", now))
		if previous_origin is Vector3:
			var elapsed := maxf(now - previous_time, 0.0001)
			velocity = (node.global_position - previous_origin) / elapsed
	_train_entity_snapshot_state[net_id] = {
		"origin": node.global_position,
		"time": now,
	}
	return velocity


func _get_train_slow_factor(speed: float) -> float:
	return 1.0 - clampf(speed / TRAIN_LOW_SPEED_THRESHOLD, 0.0, 1.0)


func _should_send_train_snapshot(net_id: int, transform: Transform3D, velocity: Vector3) -> bool:
	var now := Time.get_ticks_usec() / 1000000.0
	var previous: Variant = _train_entity_sent_state.get(net_id, null)
	if not (previous is Dictionary):
		return true
	var sent_state := previous as Dictionary
	var previous_transform: Transform3D = sent_state.get("transform", transform)
	var previous_velocity: Vector3 = sent_state.get("velocity", velocity)
	var elapsed := now - float(sent_state.get("time", now))
	var slow_factor := _get_train_slow_factor(velocity.length())
	var pos_epsilon := lerpf(TRAIN_SNAPSHOT_POS_EPSILON, TRAIN_SNAPSHOT_POS_EPSILON_SLOW, slow_factor)
	var rot_epsilon := lerpf(TRAIN_SNAPSHOT_ROT_EPSILON, TRAIN_SNAPSHOT_ROT_EPSILON_SLOW, slow_factor)
	var vel_epsilon := lerpf(TRAIN_SNAPSHOT_VEL_EPSILON, TRAIN_SNAPSHOT_VEL_EPSILON_SLOW, slow_factor)
	var max_silence := lerpf(TRAIN_SNAPSHOT_MAX_SILENCE, TRAIN_SNAPSHOT_MAX_SILENCE_SLOW, slow_factor)
	if elapsed >= max_silence:
		return true
	var moved := previous_transform.origin.distance_to(transform.origin)
	if moved >= pos_epsilon:
		return true
	var rotated := previous_transform.basis.orthonormalized().get_rotation_quaternion().angle_to(
		transform.basis.orthonormalized().get_rotation_quaternion()
	)
	if rotated >= rot_epsilon:
		return true
	if previous_velocity.distance_to(velocity) >= vel_epsilon:
		return true
	return false


func _record_train_snapshot_sent(net_id: int, transform: Transform3D, velocity: Vector3) -> void:
	_train_entity_sent_state[net_id] = {
		"transform": transform,
		"velocity": velocity,
		"time": Time.get_ticks_usec() / 1000000.0,
	}


func _is_train_snapshot_entity(node: Node) -> bool:
	if not (node is Node3D):
		return false
	if node is TrainChassis and node.get_parent() is WagonFrame:
		return false
	if node is WagonFrame:
		# WagonFrames sync via rail snapshot (see broadcast_wagon_rail_snapshot).
		return false
	if node is TrainChassis:
		return true
	if node.is_in_group("wagon_frame"):
		return false
	if node.is_in_group("wagon") or node.is_in_group("chassis"):
		return true
	return false


func broadcast_wagon_rail_snapshot(
	net_id: int,
	rail_ref: NodePath,
	rail_progress: float,
	speed: float,
	travel_direction: float,
	curve_reversed: bool,
	split_mode: bool,
	old_rail_ref: NodePath,
	junction_at_old_end: bool,
	front_entered_at_start: bool
) -> void:
	if not (is_networked() and multiplayer.is_server()):
		return
	_apply_wagon_rail_snapshot.rpc(
		net_id, rail_ref, rail_progress, speed, travel_direction, curve_reversed,
		split_mode, old_rail_ref, junction_at_old_end, front_entered_at_start
	)


func _send_wagon_rail_snapshot_to_peer(peer_id: int, net_id: int, frame: WagonFrame) -> void:
	if frame == null or frame.front_bogie == null:
		return
	var rail_ref: NodePath = NodePath()
	if frame.front_bogie.current_rail_path != null:
		rail_ref = frame.front_bogie.current_rail_path.get_path()
	var old_ref: NodePath = NodePath()
	if frame._rear_old_rail_path != null and is_instance_valid(frame._rear_old_rail_path):
		old_ref = (frame._rear_old_rail_path as Node).get_path()
	_apply_wagon_rail_snapshot.rpc_id(
		peer_id,
		net_id,
		rail_ref,
		frame.front_bogie.rail_progress,
		frame.front_bogie.speed,
		frame.front_bogie.travel_direction,
		frame.front_bogie._curve_reversed,
		frame._split_mode,
		old_ref,
		frame._junction_at_old_end,
		frame._front_entered_at_start
	)


@rpc("authority", "unreliable")
func _apply_wagon_rail_snapshot(
	net_id: int,
	rail_ref: NodePath,
	rail_progress: float,
	speed: float,
	travel_direction: float,
	curve_reversed: bool,
	split_mode: bool,
	old_rail_ref: NodePath,
	junction_at_old_end: bool,
	front_entered_at_start: bool
) -> void:
	var node := get_entity(net_id)
	if node == null or not (node is WagonFrame):
		return
	(node as WagonFrame).apply_rail_snapshot(
		rail_ref, rail_progress, speed, travel_direction, curve_reversed,
		split_mode, old_rail_ref, junction_at_old_end, front_entered_at_start
	)


@rpc("authority", "reliable")
func _snapshot_complete() -> void:
	var main_scene := get_tree().current_scene
	if main_scene != null and main_scene.has_method("hide_loading_overlay"):
		main_scene.hide_loading_overlay()


@rpc("authority", "unreliable")
func _apply_entity_transform(net_id: int, transform: Transform3D, platform_velocity: Vector3) -> void:
	var node := get_entity(net_id)
	if node == null or not is_instance_valid(node):
		return
	if not (node is Node3D):
		return
	var node_3d := node as Node3D
	var previous_transform := node_3d.global_transform
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		var predicted_transform: Transform3D = transform
		var predicted_velocity := platform_velocity
		var last_target: Variant = _train_entity_targets.get(net_id, null)
		if last_target is Dictionary:
			var target_state := last_target as Dictionary
			predicted_transform = target_state.get("transform", previous_transform)
			predicted_velocity = target_state.get("velocity", platform_velocity)
			predicted_transform.origin += predicted_velocity * float(target_state.get("age", 0.0))
		var position_error := predicted_transform.origin.distance_to(transform.origin)
		var rotation_error := predicted_transform.basis.orthonormalized().get_rotation_quaternion().angle_to(
			transform.basis.orthonormalized().get_rotation_quaternion()
		)
		var velocity_error := predicted_velocity.distance_to(platform_velocity)
		var motion_speed := maxf(predicted_velocity.length(), platform_velocity.length())
		var slow_factor := _get_train_slow_factor(motion_speed)
		var ignore_distance := lerpf(TRAIN_CLIENT_IGNORE_DISTANCE, TRAIN_CLIENT_IGNORE_DISTANCE_SLOW, slow_factor)
		var ignore_rotation := lerpf(TRAIN_CLIENT_IGNORE_ROTATION, TRAIN_CLIENT_IGNORE_ROTATION_SLOW, slow_factor)
		var ignore_velocity := lerpf(TRAIN_CLIENT_IGNORE_VELOCITY, TRAIN_CLIENT_IGNORE_VELOCITY_SLOW, slow_factor)
		var should_ignore := (
			_train_entity_targets.has(net_id)
			and position_error < ignore_distance
			and rotation_error < ignore_rotation
			and velocity_error < ignore_velocity
		)
		if should_ignore:
			return
		var should_snap := (
			not _train_entity_targets.has(net_id)
			or position_error > TRAIN_CLIENT_SNAP_DISTANCE
			or rotation_error > TRAIN_CLIENT_SNAP_ROTATION
		)
		_train_entity_targets[net_id] = {
			"transform": transform,
			"velocity": platform_velocity,
			"age": 0.0,
		}
		if should_snap:
			node_3d.global_transform = transform
			if node_3d is StaticBody3D:
				(node_3d as StaticBody3D).constant_linear_velocity = platform_velocity
			if node_3d.has_method("_set_platform_velocity"):
				node_3d.call("_set_platform_velocity", platform_velocity)
		return
	node_3d.global_transform = transform
	if node_3d is StaticBody3D:
		(node_3d as StaticBody3D).constant_linear_velocity = platform_velocity
	if node_3d.has_method("_set_platform_velocity"):
		node_3d.call("_set_platform_velocity", platform_velocity)
	_update_local_train_audio_from_snapshot(node, transform.origin, platform_velocity)


func _update_local_train_audio_from_snapshot(node: Node, train_position: Vector3, platform_velocity: Vector3) -> void:
	if multiplayer.is_server():
		return
	if not _should_drive_local_train_audio(node):
		return
	var speed := platform_velocity.length()
	if speed > TRAIN_AUDIO_TRIGGER_SPEED:
		if AudioManager != null and AudioManager.has_method("play_train_move_sound"):
			AudioManager.play_train_move_sound(speed, train_position)
		return
	if AudioManager != null and AudioManager.has_method("stop_train_move_sound"):
		AudioManager.stop_train_move_sound()


func _should_drive_local_train_audio(node: Node) -> bool:
	if node is WagonFrame:
		return true
	if node is TrainChassis:
		var parent := node.get_parent()
		return not (parent is WagonFrame)
	return node.is_in_group("wagon_frame")


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
	rear_progress: float,
	owner_peer_id: int = 0
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
	if owner_peer_id > 0:
		frame.set_meta("owner_peer_id", owner_peer_id)
	frame.global_transform = frame_transform
	var front := scene.instantiate() as TrainChassis
	var rear := scene.instantiate() as TrainChassis
	frame.add_child(front)
	frame.add_child(rear)
	register_entity(front, front_net_id)
	register_entity(rear, rear_net_id)
	if owner_peer_id > 0:
		front.set_meta("owner_peer_id", owner_peer_id)
		rear.set_meta("owner_peer_id", owner_peer_id)
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
