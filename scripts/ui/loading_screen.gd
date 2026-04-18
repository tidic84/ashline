extends Control

const DEFAULT_TARGET_SCENE: String = "res://scenes/main/main.tscn"
const DEFAULT_MESSAGE: String = "La locomotive se met en route..."
const MIN_DISPLAY_TIME: float = 0.8

@onready var loading_overlay: Control = $LoadingOverlay

var _target_scene_path: String = DEFAULT_TARGET_SCENE
var _message: String = DEFAULT_MESSAGE
var _elapsed: float = 0.0
var _ready_to_swap: bool = false
var _swap_started: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var transition := GameManager.consume_scene_transition()
	_target_scene_path = String(transition.get("scene_path", DEFAULT_TARGET_SCENE))
	_message = String(transition.get("message", DEFAULT_MESSAGE))
	if _target_scene_path.is_empty():
		_target_scene_path = DEFAULT_TARGET_SCENE
	if _message.is_empty():
		_message = DEFAULT_MESSAGE
	loading_overlay.call("set_status", _message, true, 0.0)
	var error := ResourceLoader.load_threaded_request(_target_scene_path, "", false)
	if error != OK:
		_swap_to_scene_file()

func _process(delta: float) -> void:
	_elapsed += delta
	if _swap_started:
		return
	var progress: Array = []
	var status := ResourceLoader.load_threaded_get_status(_target_scene_path, progress)
	var progress_ratio := float(progress[0]) if not progress.is_empty() else 0.0
	loading_overlay.call("set_status", _message, true, progress_ratio)
	match status:
		ResourceLoader.THREAD_LOAD_LOADED:
			if _elapsed >= MIN_DISPLAY_TIME:
				_swap_to_loaded_scene()
			else:
				_ready_to_swap = true
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_swap_to_scene_file()
		_:
			if _ready_to_swap and _elapsed >= MIN_DISPLAY_TIME:
				_swap_to_loaded_scene()

func _swap_to_loaded_scene() -> void:
	if _swap_started:
		return
	var packed_scene := ResourceLoader.load_threaded_get(_target_scene_path) as PackedScene
	if packed_scene == null:
		_swap_to_scene_file()
		return
	_swap_started = true
	get_tree().change_scene_to_packed(packed_scene)

func _swap_to_scene_file() -> void:
	if _swap_started:
		return
	_swap_started = true
	get_tree().change_scene_to_file(_target_scene_path)
