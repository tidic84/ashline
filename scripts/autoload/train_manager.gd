extends Node

signal wagon_added(wagon: Wagon)
signal wagon_removed(wagon_index: int)
signal train_speed_changed(speed: float)
signal train_started
signal train_stopped

const WAGON_LENGTH: float = 12.0
const WAGON_SPACING: float = 1.5
const MAX_WAGONS: int = 10
const SNAPSHOT_INTERVAL: float = 0.1

var train_speed: float = 0.0
var max_speed: float = 30.0
var locomotive: Node3D = null
var wagons: Array[Wagon] = []
var rail_path: Path3D = null
var path_progress: float = 0.0
var is_moving: bool = false
var train_container: Node3D = null
# 1 = forward (toward end), -1 = backward (toward start)
var _direction: int = 1

# Network sync
var _snapshot_timer: float = 0.0
var _target_progress: float = 0.0
var _target_speed: float = 0.0
var _target_is_moving: bool = false
var _target_direction: int = 1
var _target_rail_path: Path3D = null
var _has_received_snapshot: bool = false

func _ready() -> void:
	pass

func _physics_process(delta: float) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		_interpolate_to_target(delta)
		return
	# Host: simulate normally
	if not is_moving or rail_path == null:
		return
	path_progress += train_speed * delta
	_check_junction()
	_update_train_positions()
	_snapshot_timer += delta
	if _snapshot_timer >= SNAPSHOT_INTERVAL and multiplayer.has_multiplayer_peer():
		_snapshot_timer = 0.0
		_broadcast_snapshot()

func _check_junction() -> void:
	if rail_path == null or rail_path.curve == null:
		return
	var length := rail_path.curve.get_baked_length()
	if length == 0.0:
		return

	if path_progress >= length:
		var route := RailNetwork.get_active_route(rail_path, 1)
		if route.is_empty():
			path_progress = length
			stop_train()
			return
		var next_path: Path3D = route.path
		var next_length := next_path.curve.get_baked_length() if next_path.curve else 0.0
		var overflow := path_progress - length
		rail_path = next_path
		if route.end == 1:
			path_progress = next_length - overflow
			train_speed = -abs(train_speed)
			_direction = -1
		else:
			path_progress = overflow
			train_speed = abs(train_speed)
			_direction = 1

	elif path_progress < 0.0:
		var route := RailNetwork.get_active_route(rail_path, 0)
		if route.is_empty():
			path_progress = 0.0
			stop_train()
			return
		var next_path: Path3D = route.path
		var next_length := next_path.curve.get_baked_length() if next_path.curve else 0.0
		var overflow := -path_progress
		rail_path = next_path
		if route.end == 0:
			path_progress = overflow
			train_speed = abs(train_speed)
			_direction = 1
		else:
			path_progress = next_length - overflow
			train_speed = -abs(train_speed)
			_direction = -1

func set_rail_path(path: Path3D) -> void:
	rail_path = path

func register_locomotive(loco: Node3D, container: Node3D) -> void:
	locomotive = loco
	train_container = container

func start_train() -> void:
	is_moving = true
	train_speed = max_speed * _direction
	train_speed_changed.emit(train_speed)
	train_started.emit()
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_broadcast_snapshot()

func stop_train() -> void:
	is_moving = false
	train_speed = 0.0
	train_speed_changed.emit(train_speed)
	train_stopped.emit()
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_broadcast_snapshot()

func add_wagon_scene(wagon_scene: PackedScene) -> Wagon:
	if wagons.size() >= MAX_WAGONS or train_container == null:
		return null
	var wagon := wagon_scene.instantiate() as Wagon
	if wagon == null:
		return null
	wagon.wagon_index = wagons.size()
	wagons.append(wagon)
	train_container.add_child(wagon)
	_update_train_positions()
	wagon_added.emit(wagon)

	if wagons.size() > 1:
		_spawn_connector(wagons.size() - 2)
	return wagon

func remove_wagon(index: int) -> void:
	if index < 0 or index >= wagons.size():
		return
	var wagon := wagons[index]
	wagons.remove_at(index)
	wagon.queue_free()
	for i in wagons.size():
		wagons[i].wagon_index = i
	_update_train_positions()
	wagon_removed.emit(index)

func get_wagon_at(index: int) -> Wagon:
	if index < 0 or index >= wagons.size():
		return null
	return wagons[index]

func get_wagon_count() -> int:
	return wagons.size()

func get_total_offset(index: int) -> float:
	var loco_length := 15.0
	return loco_length + WAGON_SPACING + index * (WAGON_LENGTH + WAGON_SPACING) + WAGON_LENGTH / 2.0

func _update_train_positions() -> void:
	if rail_path == null:
		return
	var curve := rail_path.curve
	if curve == null or curve.get_baked_length() == 0:
		return

	if locomotive:
		var loco_offset := clampf(path_progress, 0.0, curve.get_baked_length())
		var loco_pos := curve.sample_baked(loco_offset)
		var loco_fwd := curve.sample_baked(minf(loco_offset + 1.0, curve.get_baked_length()))
		locomotive.global_position = rail_path.to_global(loco_pos)
		if loco_pos.distance_to(loco_fwd) > 0.01:
			locomotive.look_at(rail_path.to_global(loco_fwd), Vector3.UP)

	for i in wagons.size():
		var total_offset := get_total_offset(i)
		var wagon_progress := path_progress - total_offset
		wagon_progress = clampf(wagon_progress, 0.0, curve.get_baked_length())
		var pos := curve.sample_baked(wagon_progress)
		var fwd := curve.sample_baked(minf(wagon_progress + 1.0, curve.get_baked_length()))
		wagons[i].global_position = rail_path.to_global(pos)
		if pos.distance_to(fwd) > 0.01:
			wagons[i].look_at(rail_path.to_global(fwd), Vector3.UP)

func _spawn_connector(between_index: int) -> void:
	var connector_scene_path := "res://assets/models/train/train-connector.glb"
	if not ResourceLoader.exists(connector_scene_path):
		return
	var connector := load(connector_scene_path).instantiate() as Node3D
	train_container.add_child(connector)
	connector.set_meta("connector_index", between_index)


# --- Network sync ---

func _broadcast_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var rail_ref: NodePath = rail_path.get_path() if rail_path != null else NodePath()
	_apply_train_snapshot.rpc(rail_ref, path_progress, train_speed, is_moving, _direction)
	WorldSync.broadcast_train_entity_snapshots()

@rpc("authority", "unreliable")
func _apply_train_snapshot(rail_ref: NodePath, progress: float, speed: float, moving: bool, direction: int) -> void:
	_target_rail_path = get_node_or_null(rail_ref) as Path3D
	_target_progress = progress
	_target_speed = speed
	_target_is_moving = moving
	_target_direction = direction
	_has_received_snapshot = true

func _interpolate_to_target(delta: float) -> void:
	if not _has_received_snapshot:
		return
	if _target_rail_path != null:
		rail_path = _target_rail_path
	is_moving = _target_is_moving
	_direction = _target_direction
	train_speed = _target_speed
	var diff := _target_progress - path_progress
	if absf(diff) > 50.0:
		path_progress = _target_progress
	else:
		path_progress = lerpf(path_progress, _target_progress, minf(delta * 10.0, 1.0))
	if is_moving:
		path_progress += train_speed * delta
	_update_train_positions()

func sync_state_to_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var rail_ref: NodePath = rail_path.get_path() if rail_path != null else NodePath()
	_apply_train_snapshot.rpc_id(peer_id, rail_ref, path_progress, train_speed, is_moving, _direction)
