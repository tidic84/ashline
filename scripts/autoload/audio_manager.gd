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
const TRAIN_AMBIENT_STREAM: AudioStream = preload("res://assets/audio/ambient/train_ambience.wav")
const AMBIENT_FALLBACK_PATHS: Dictionary = {
	"train_ambience": "res://assets/audio/ambient/train_ambience.wav",
}

var _sfx_cache: Dictionary = {}   # name -> AudioStream
var _ambient_cache: Dictionary = {}
var _ambient_player: AudioStreamPlayer = null
var _current_ambient: String = ""
var _requested_ambient: String = ""
var _sfx_pool: Array[AudioStreamPlayer] = []
var master_volume: float = 0.18
const POOL_SIZE: int = 8

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()
	load_settings()
	set_master_volume(master_volume)
	_build_sfx_pool()
	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.process_mode = Node.PROCESS_MODE_ALWAYS
	_ambient_player.bus = "Master"
	_ambient_player.volume_db = 0.0
	_ambient_player.finished.connect(_on_ambient_finished)
	add_child(_ambient_player)
	_scan_folder(SFX_DIR, _sfx_cache)
	_scan_folder(AMBIENT_DIR, _ambient_cache)
	if TRAIN_AMBIENT_STREAM != null:
		_ambient_cache["train_ambience"] = TRAIN_AMBIENT_STREAM
	_requested_ambient = "train_ambience"
	_play_ambient_now(_requested_ambient)

func _process(_delta: float) -> void:
	if _requested_ambient.is_empty():
		return
	if _ambient_player == null:
		return
	if not _ambient_player.playing or _current_ambient != _requested_ambient:
		_play_ambient_now(_requested_ambient)

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

func play_ambient(name: String) -> void:
	_requested_ambient = name
	if _ambient_player == null:
		return
	if _current_ambient == name and _ambient_player.playing:
		return
	_play_ambient_now(name)

func _play_ambient_now(name: String) -> void:
	if _ambient_player == null:
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
	_requested_ambient = name
	_current_ambient = ""
	if _ambient_player != null:
		_ambient_player.stop()
	_play_ambient_now(name)

func stop_ambient() -> void:
	_requested_ambient = ""
	if _ambient_player == null:
		return
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
