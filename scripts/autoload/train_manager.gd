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
const TRAIN_ROLL_LOOP_PATH: String = "res://assets/audio/sfx/train_roll_loop.wav"
const TRAIN_ROLL_LOOP_FALLBACK_PATH: String = "C:/Users/Thomas/Desktop/JEU TRAIN/SFX/TRAIN/BruitsTrain.wav"
const TRAIN_AUDIO_TRIGGER_SPEED: float = 0.1
const TRAIN_AUDIO_FULL_SPEED: float = 30.0
const TRAIN_AUDIO_SMOOTH_RATE: float = 4.5
const TRAIN_AUDIO_VOLUME_SMOOTH_RATE: float = 7.0
const TRAIN_AUDIO_SILENT_DB: float = -80.0
const TRAIN_AUDIO_MIN_DB: float = -3.0
const TRAIN_AUDIO_MAX_DB: float = 8.0
const TRAIN_AUDIO_MIN_PITCH: float = 0.85
const TRAIN_AUDIO_MAX_PITCH: float = 1.22
const TRAIN_AUDIO_FULL_DISTANCE: float = 10.0
const TRAIN_AUDIO_MAX_DISTANCE: float = 75.0

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
var _train_loop_player: AudioStreamPlayer = null
var _train_loop_smoothed_speed: float = 0.0
var _train_loop_volume_db: float = TRAIN_AUDIO_SILENT_DB
var _train_expected_motion_logged: bool = false

func _ready() -> void:
	pass

func _process(delta: float) -> void:
	pass

func _physics_process(delta: float) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		_interpolate_to_target(delta)
		return
	# Host: simulate normally
	if not is_moving or rail_path == null:
		return
	_play_train_move_sound(absf(train_speed))
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
	_log_train_expected_motion("start_train", absf(train_speed))
	_play_train_move_sound(absf(train_speed))
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_broadcast_snapshot()

func stop_train() -> void:
	is_moving = false
	train_speed = 0.0
	_train_expected_motion_logged = false
	_stop_train_move_sound()
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
		_play_train_move_sound(absf(train_speed))
		path_progress += train_speed * delta
	_update_train_positions()

func sync_state_to_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var rail_ref: NodePath = rail_path.get_path() if rail_path != null else NodePath()
	_apply_train_snapshot.rpc_id(peer_id, rail_ref, path_progress, train_speed, is_moving, _direction)

func _setup_train_loop_audio() -> void:
	pass

func _load_train_loop_stream() -> AudioStream:
	var stream := ResourceLoader.load(TRAIN_ROLL_LOOP_PATH, "AudioStream") as AudioStream
	if stream != null:
		return stream
	var raw_stream := AudioStreamWAV.load_from_file(TRAIN_ROLL_LOOP_PATH)
	if raw_stream != null:
		return raw_stream
	raw_stream = AudioStreamWAV.load_from_file(TRAIN_ROLL_LOOP_FALLBACK_PATH)
	if raw_stream != null:
		return raw_stream
	return null

func _configure_train_loop_stream(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = -1
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true

func _update_train_loop_audio(delta: float) -> void:
	pass

func _apply_train_loop_volume(delta: float, target_volume_db: float) -> void:
	var volume_weight := 1.0 - exp(-delta * TRAIN_AUDIO_VOLUME_SMOOTH_RATE)
	_train_loop_volume_db = lerpf(_train_loop_volume_db, target_volume_db, volume_weight)
	_train_loop_player.volume_db = _train_loop_volume_db

func _play_train_move_sound(speed: float = 0.0) -> void:
	if AudioManager != null and AudioManager.has_method("play_train_move_sound"):
		AudioManager.play_train_move_sound(speed, _get_train_move_sound_position())

func _get_train_move_sound_position() -> Vector3:
	if locomotive != null:
		return locomotive.global_position
	if train_container != null:
		return train_container.global_position
	return Vector3.ZERO

func _stop_train_move_sound() -> void:
	if AudioManager != null and AudioManager.has_method("stop_train_move_sound"):
		AudioManager.stop_train_move_sound()

func _get_train_loop_distance_gain() -> float:
	if locomotive == null:
		return 0.0
	var listener_pos := _get_audio_listener_position()
	var distance := locomotive.global_position.distance_to(listener_pos)
	if distance <= TRAIN_AUDIO_FULL_DISTANCE:
		return 1.0
	if distance >= TRAIN_AUDIO_MAX_DISTANCE:
		return 0.0
	var t := (distance - TRAIN_AUDIO_FULL_DISTANCE) / (TRAIN_AUDIO_MAX_DISTANCE - TRAIN_AUDIO_FULL_DISTANCE)
	return pow(1.0 - clampf(t, 0.0, 1.0), 2.0)

func _get_audio_listener_position() -> Vector3:
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		return camera.global_position
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player != null:
		return player.global_position
	return locomotive.global_position if locomotive != null else Vector3.ZERO

func _kick_train_loop_audio() -> void:
	pass

func _update_train_expected_motion_debug(speed_value: float) -> void:
	if speed_value > TRAIN_AUDIO_TRIGGER_SPEED:
		_log_train_expected_motion("movement", speed_value)
	else:
		_train_expected_motion_logged = false

func _log_train_expected_motion(source: String, speed_value: float) -> void:
	if _train_expected_motion_logged:
		return
	_train_expected_motion_logged = true
	print("[TRAIN DEBUG] Le train est cense avancer (%s) | speed=%.3f" % [source, speed_value])
