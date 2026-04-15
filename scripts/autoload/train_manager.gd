extends Node

signal wagon_added(wagon: Wagon)
signal wagon_removed(wagon_index: int)
signal train_speed_changed(speed: float)
signal train_started
signal train_stopped

const WAGON_LENGTH: float = 12.0
const WAGON_SPACING: float = 1.5
const MAX_WAGONS: int = 10

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

func _ready() -> void:
	pass

func _physics_process(delta: float) -> void:
	if not is_moving or rail_path == null:
		return
	path_progress += train_speed * delta
	_check_junction()
	_update_train_positions()

func _check_junction() -> void:
	if rail_path == null or rail_path.curve == null:
		return
	var length := rail_path.curve.get_baked_length()
	if length == 0.0:
		return

	if path_progress >= length:
		# Reached end (endpoint 1)
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
			# Enter next path from its end — reverse
			path_progress = next_length - overflow
			train_speed = -abs(train_speed)
			_direction = -1
		else:
			# Enter next path from its start — continue forward
			path_progress = overflow
			train_speed = abs(train_speed)
			_direction = 1

	elif path_progress < 0.0:
		# Reached start (endpoint 0)
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
			# Enter next path from its start — reverse (now going forward)
			path_progress = overflow
			train_speed = abs(train_speed)
			_direction = 1
		else:
			# Enter next path from its end — continue backward
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

func stop_train() -> void:
	is_moving = false
	train_speed = 0.0
	train_speed_changed.emit(train_speed)
	train_stopped.emit()

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

	# Spawn connector between wagons
	if wagons.size() > 1:
		_spawn_connector(wagons.size() - 2)
	return wagon

func remove_wagon(index: int) -> void:
	if index < 0 or index >= wagons.size():
		return
	var wagon := wagons[index]
	wagons.remove_at(index)
	wagon.queue_free()
	# Re-index remaining wagons
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
	# Locomotive length + gap + wagon offsets
	var loco_length := 15.0
	return loco_length + WAGON_SPACING + index * (WAGON_LENGTH + WAGON_SPACING) + WAGON_LENGTH / 2.0

func _update_train_positions() -> void:
	if rail_path == null:
		return
	var curve := rail_path.curve
	if curve == null or curve.get_baked_length() == 0:
		return

	# Update locomotive
	if locomotive:
		var loco_offset := clampf(path_progress, 0.0, curve.get_baked_length())
		var loco_pos := curve.sample_baked(loco_offset)
		var loco_fwd := curve.sample_baked(minf(loco_offset + 1.0, curve.get_baked_length()))
		locomotive.global_position = rail_path.to_global(loco_pos)
		if loco_pos.distance_to(loco_fwd) > 0.01:
			locomotive.look_at(rail_path.to_global(loco_fwd), Vector3.UP)

	# Update each wagon
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
