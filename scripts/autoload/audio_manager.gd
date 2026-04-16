extends Node

# Central audio manager. Files can be dropped into res://assets/audio/sfx and res://assets/audio/ambient
# and they will be auto-loaded by filename (minus extension).
#
# play_sfx("pump") — plays audio/sfx/pump.ogg if present, silent fallback otherwise.
# play_ambient("forest") — loops an ambient loop.

const SFX_DIR: String = "res://assets/audio/sfx/"
const AMBIENT_DIR: String = "res://assets/audio/ambient/"
const MUSIC_DIR: String = "res://assets/audio/music/"
const CONFIG_PATH: String = "user://settings.cfg"
const DEFAULT_MASTER_VOLUME_DB: float = -15.0
const MIN_VOLUME_LINEAR: float = 0.0001
const TRAIN_MOVE_SOUND_NAME: String = "train_roll_loop"
const TRAIN_MOVE_SOUND_FALLBACK_PATH: String = "C:/Users/Thomas/Desktop/JEU TRAIN/SFX/TRAIN/BruitsTrain.wav"
const TRAIN_MOVE_SOUND_FULL_SPEED: float = 12.0
const TRAIN_MOVE_SOUND_MIN_PITCH: float = 0.72
const TRAIN_MOVE_SOUND_MAX_PITCH: float = 1.45
const TRAIN_MOVE_SOUND_PITCH_SMOOTH: float = 0.35
const TRAIN_MOVE_SOUND_UNIT_SIZE: float = 12.0
const TRAIN_MOVE_SOUND_MAX_DISTANCE: float = 95.0
const TRAIN_FADE_OUT_DURATION: float = 0.9
const WOODLAND_AMBIENT_PATH: String = "C:/Users/Thomas/Desktop/JEU TRAIN/SFX/Ambiance/Quiet_woodland_copse_#3-1776360977539.wav"
const AMBIENT_FALLBACK_PATHS: Dictionary = {
	"train_ambience": "res://assets/audio/ambient/train_ambience.wav",
}

var _sfx_cache: Dictionary = {}   # name -> AudioStream
var _ambient_cache: Dictionary = {}
var _ambient_player: AudioStreamPlayer = null
var _current_ambient: String = ""
var _sfx_pool: Array[AudioStreamPlayer] = []
var _train_move_player: AudioStreamPlayer3D = null
var _train_move_should_loop: bool = false
var _train_move_pitch: float = 1.0
var _train_fading_out: bool = false
var _train_fade_elapsed: float = 0.0
var _train_fade_start_db: float = 0.0
var _woodland_player: AudioStreamPlayer = null
var master_volume: float = 0.18
const POOL_SIZE: int = 8

func _ready() -> void:
	_ensure_buses()
	load_settings()
	set_master_volume(master_volume)
	_build_sfx_pool()
	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.bus = "Ambient"
	_ambient_player.volume_db = 6.0
	_ambient_player.finished.connect(_on_ambient_finished)
	add_child(_ambient_player)
	_scan_folder(SFX_DIR, _sfx_cache)
	_scan_folder(AMBIENT_DIR, _ambient_cache)
	_start_woodland_ambient()

func _process(delta: float) -> void:
	if not _train_fading_out:
		return
	_train_fade_elapsed += delta
	var t := clampf(_train_fade_elapsed / TRAIN_FADE_OUT_DURATION, 0.0, 1.0)
	var db := lerpf(_train_fade_start_db, -80.0, t)
	if _train_move_player != null:
		_train_move_player.volume_db = db
	if t >= 1.0:
		_train_fading_out = false
		if _train_move_player != null and _train_move_player.playing:
			_train_move_player.stop()
			_train_move_player.volume_db = 0.0

func _start_woodland_ambient() -> void:
	print("[AUDIO] Chargement woodland: ", WOODLAND_AMBIENT_PATH)
	if not FileAccess.file_exists(WOODLAND_AMBIENT_PATH):
		print("[AUDIO] ERREUR: fichier woodland introuvable sur disque")
		return
	var stream := AudioStreamWAV.load_from_file(WOODLAND_AMBIENT_PATH)
	if stream == null:
		print("[AUDIO] ERREUR: load_from_file a retourne null")
		return
	print("[AUDIO] Stream woodland OK | format=%d | stereo=%s | data_size=%d" % [stream.format, str(stream.stereo), stream.data.size()])
	stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
	_woodland_player = AudioStreamPlayer.new()
	_woodland_player.name = "WoodlandAmbient"
	_woodland_player.bus = "Ambient"
	_woodland_player.volume_db = 10.0
	_woodland_player.stream = stream
	_woodland_player.process_mode = Node.PROCESS_MODE_ALWAYS
	_woodland_player.finished.connect(_on_woodland_finished)
	add_child(_woodland_player)
	_woodland_player.play()
	print("[AUDIO] Woodland ambient demarre | volume_db=%.1f | bus=%s" % [_woodland_player.volume_db, _woodland_player.bus])

func _on_woodland_finished() -> void:
	if _woodland_player != null:
		_woodland_player.play()

func set_global_volume_db(volume_db: float) -> void:
	var master_idx: int = AudioServer.get_bus_index("Master")
	if master_idx == -1:
		return
	AudioServer.set_bus_volume_db(master_idx, volume_db)

func set_master_volume(volume: float) -> void:
	master_volume = clampf(volume, 0.0, 1.0)
	var master_idx: int = AudioServer.get_bus_index("Master")
	if master_idx == -1:
		return
	AudioServer.set_bus_mute(master_idx, master_volume <= 0.0)
	AudioServer.set_bus_volume_db(master_idx, linear_to_db(maxf(master_volume, MIN_VOLUME_LINEAR)))

func get_master_volume() -> float:
	return master_volume

func load_settings() -> void:
	master_volume = db_to_linear(DEFAULT_MASTER_VOLUME_DB)
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	master_volume = cfg.get_value("audio", "master_volume", master_volume)

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.save(CONFIG_PATH)

func _ensure_buses() -> void:
	var desired: Array[String] = ["SFX", "Ambient", "Music"]
	for bus_name in desired:
		if AudioServer.get_bus_index(bus_name) == -1:
			var idx: int = AudioServer.bus_count
			AudioServer.add_bus(idx)
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")

func _build_sfx_pool() -> void:
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_sfx_pool.append(p)

func _scan_folder(path: String, cache: Dictionary) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and (file_name.ends_with(".ogg") or file_name.ends_with(".wav") or file_name.ends_with(".mp3")):
			var key: String = file_name.get_basename()
			var stream: AudioStream = load(path + file_name) as AudioStream
			if stream:
				cache[key] = stream
		file_name = dir.get_next()

func play_sfx(name: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if not _sfx_cache.has(name):
		return  # Silent fallback — drop a file in audio/sfx to enable
	var stream: AudioStream = _sfx_cache[name]
	for p in _sfx_pool:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = pitch
			p.play()
			return
	# Pool exhausted — reuse first
	var first: AudioStreamPlayer = _sfx_pool[0]
	first.stop()
	first.stream = stream
	first.volume_db = volume_db
	first.pitch_scale = pitch
	first.play()

func play_train_move_sound(speed: float = 0.0, world_position: Vector3 = Vector3.ZERO) -> void:
	if not _ensure_train_move_player():
		print("[TRAIN AUDIO] Impossible de lancer le son du train: stream introuvable")
		return
	_train_move_should_loop = true
	_train_fading_out = false
	_train_move_player.volume_db = 0.0
	_train_move_player.global_position = world_position
	_update_train_move_pitch(speed)
	if not _train_move_player.playing:
		print("[TRAIN AUDIO] Play son train 3D | bus=%s | volume_db=%.2f | pitch=%.2f | speed=%.3f | pos=%s" % [
			_train_move_player.bus,
			_train_move_player.volume_db,
			_train_move_player.pitch_scale,
			absf(speed),
			str(world_position)
		])
		_train_move_player.play()

func stop_train_move_sound() -> void:
	_train_move_should_loop = false
	if _train_move_player != null and _train_move_player.playing and not _train_fading_out:
		print("[TRAIN AUDIO] Fondu sortie son train")
		_train_fading_out = true
		_train_fade_elapsed = 0.0
		_train_fade_start_db = _train_move_player.volume_db

func _ensure_train_move_player() -> bool:
	if _train_move_player != null:
		return true
	var stream := _get_train_move_stream()
	if stream == null:
		return false
	_configure_restarting_stream(stream)
	_train_move_player = AudioStreamPlayer3D.new()
	_train_move_player.name = "TrainMoveSound"
	_train_move_player.process_mode = Node.PROCESS_MODE_ALWAYS
	_train_move_player.stream = stream
	_train_move_player.bus = "SFX" if AudioServer.get_bus_index("SFX") != -1 else "Master"
	_train_move_player.volume_db = 0.0
	_train_move_player.pitch_scale = _train_move_pitch
	_train_move_player.unit_size = TRAIN_MOVE_SOUND_UNIT_SIZE
	_train_move_player.max_distance = TRAIN_MOVE_SOUND_MAX_DISTANCE
	_train_move_player.finished.connect(_on_train_move_sound_finished)
	add_child(_train_move_player)
	print("[TRAIN AUDIO] Player son train 3D cree | bus=%s | stream=%s | max_distance=%.1f" % [
		_train_move_player.bus,
		stream.get_class(),
		TRAIN_MOVE_SOUND_MAX_DISTANCE
	])
	return true

func _update_train_move_pitch(speed: float) -> void:
	var speed_ratio := clampf(absf(speed) / TRAIN_MOVE_SOUND_FULL_SPEED, 0.0, 1.0)
	var target_pitch := lerpf(TRAIN_MOVE_SOUND_MIN_PITCH, TRAIN_MOVE_SOUND_MAX_PITCH, speed_ratio)
	_train_move_pitch = lerpf(_train_move_pitch, target_pitch, TRAIN_MOVE_SOUND_PITCH_SMOOTH)
	if _train_move_player != null:
		_train_move_player.pitch_scale = _train_move_pitch

func _get_train_move_stream() -> AudioStream:
	if _sfx_cache.has(TRAIN_MOVE_SOUND_NAME):
		return _sfx_cache[TRAIN_MOVE_SOUND_NAME] as AudioStream
	var path := SFX_DIR + TRAIN_MOVE_SOUND_NAME + ".wav"
	if ResourceLoader.exists(path):
		var stream := load(path) as AudioStream
		if stream != null:
			_sfx_cache[TRAIN_MOVE_SOUND_NAME] = stream
			return stream
	var raw_stream := AudioStreamWAV.load_from_file(TRAIN_MOVE_SOUND_FALLBACK_PATH)
	if raw_stream != null:
		_sfx_cache[TRAIN_MOVE_SOUND_NAME] = raw_stream
		return raw_stream
	return null

func _configure_restarting_stream(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
		wav.loop_begin = 0
		wav.loop_end = -1
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = false
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = false

func _on_train_move_sound_finished() -> void:
	if _train_move_player == null:
		return
	if not _train_move_should_loop:
		return
	print("[TRAIN AUDIO] Son train termine, relance")
	_train_move_player.play()

func play_ambient(name: String) -> void:
	if _current_ambient == name and _ambient_player.playing:
		return
	if not _ambient_cache.has(name):
		_try_load_ambient(name)
	if not _ambient_cache.has(name):
		return
	var stream: AudioStream = _ambient_cache[name]
	_configure_ambient_loop(stream)
	_ambient_player.stream = stream
	_ambient_player.play()
	_current_ambient = name

func force_play_ambient(name: String) -> void:
	_current_ambient = ""
	if _ambient_player != null:
		_ambient_player.stop()
	play_ambient(name)

func stop_ambient() -> void:
	_ambient_player.stop()
	_current_ambient = ""

func _configure_ambient_loop(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true

func _try_load_ambient(name: String) -> void:
	if AMBIENT_FALLBACK_PATHS.has(name):
		var fallback_path: String = String(AMBIENT_FALLBACK_PATHS[name])
		if ResourceLoader.exists(fallback_path):
			var fallback_stream: AudioStream = load(fallback_path) as AudioStream
			if fallback_stream != null:
				_ambient_cache[name] = fallback_stream
				return
	for ext in [".wav", ".ogg", ".mp3"]:
		var path: String = AMBIENT_DIR + name + ext
		if ResourceLoader.exists(path):
			var stream: AudioStream = load(path) as AudioStream
			if stream:
				_ambient_cache[name] = stream
				return

func _on_ambient_finished() -> void:
	if _current_ambient.is_empty():
		return
	if not _ambient_cache.has(_current_ambient):
		_current_ambient = ""
		return
	_ambient_player.play()
