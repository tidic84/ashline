extends Node

# Central audio manager. Files can be dropped into res://audio/sfx and res://audio/ambient
# and they will be auto-loaded by filename (minus extension).
#
# play_sfx("pump") — plays audio/sfx/pump.ogg if present, silent fallback otherwise.
# play_ambient("forest") — loops an ambient loop.

const SFX_DIR: String = "res://audio/sfx/"
const AMBIENT_DIR: String = "res://audio/ambient/"
const MUSIC_DIR: String = "res://audio/music/"

var _sfx_cache: Dictionary = {}   # name -> AudioStream
var _ambient_cache: Dictionary = {}
var _ambient_player: AudioStreamPlayer = null
var _current_ambient: String = ""
var _sfx_pool: Array[AudioStreamPlayer] = []
const POOL_SIZE: int = 8

func _ready() -> void:
	_ensure_buses()
	_build_sfx_pool()
	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.bus = "Ambient"
	_ambient_player.volume_db = -6.0
	add_child(_ambient_player)
	_scan_folder(SFX_DIR, _sfx_cache)
	_scan_folder(AMBIENT_DIR, _ambient_cache)

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
	if _current_ambient == name:
		return
	if not _ambient_cache.has(name):
		_ambient_player.stop()
		_current_ambient = ""
		return
	_ambient_player.stream = _ambient_cache[name]
	_ambient_player.play()
	_current_ambient = name

func stop_ambient() -> void:
	_ambient_player.stop()
	_current_ambient = ""
