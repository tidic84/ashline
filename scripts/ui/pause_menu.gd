extends PanelContainer
class_name PauseMenu

signal resume_requested
signal respawn_requested

const FPS_LIMITS: Array[int] = [30, 60, 90, 120, 240]

@onready var _resume_button: Button = $Margin/VBox/Tabs/Resume/ResumeButton
@onready var _respawn_button: Button = $Margin/VBox/Tabs/Resume/RespawnButton
@onready var _volume_label: Label = $Margin/VBox/Tabs/Parametres/SettingsGrid/MasterVolumeLabel
@onready var _volume_slider: HSlider = $Margin/VBox/Tabs/Parametres/SettingsGrid/MasterVolumeSlider
@onready var _fps_limit_option: OptionButton = $Margin/VBox/Tabs/Parametres/SettingsGrid/FpsLimitOption
@onready var _resolution_option: OptionButton = $Margin/VBox/Tabs/Parametres/SettingsGrid/ResolutionOption
@onready var _apply_settings_button: Button = $Margin/VBox/Tabs/Parametres/ApplySettingsButton

var _syncing: bool = false
var _pending_fps_limit: int = 120
var _pending_resolution: Vector2i = Vector2i(1920, 1080)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	for fps in FPS_LIMITS:
		_fps_limit_option.add_item("%d FPS" % fps, fps)
	for i in range(GraphicsSettings.RESOLUTIONS.size()):
		var resolution: Vector2i = GraphicsSettings.RESOLUTIONS[i]
		_resolution_option.add_item(GraphicsSettings.get_resolution_label(resolution), i)

	_resume_button.pressed.connect(func(): resume_requested.emit())
	_respawn_button.pressed.connect(func(): respawn_requested.emit())
	_volume_slider.value_changed.connect(_on_master_volume_changed)
	_fps_limit_option.item_selected.connect(_on_fps_limit_selected)
	_resolution_option.item_selected.connect(_on_resolution_selected)
	_apply_settings_button.pressed.connect(_apply_pending_settings)
	_sync_controls()

func open() -> void:
	_sync_controls()
	visible = true
	_resume_button.grab_focus()

func close() -> void:
	visible = false

func _sync_controls() -> void:
	_syncing = true
	_volume_slider.value = AudioManager.get_master_volume() * 100.0
	_update_volume_label(_volume_slider.value)
	_fps_limit_option.select(_get_fps_limit_index(GraphicsSettings.fps_limit))
	_resolution_option.select(GraphicsSettings.get_resolution_index(GraphicsSettings.resolution))
	_pending_fps_limit = GraphicsSettings.fps_limit
	_pending_resolution = GraphicsSettings.resolution
	_syncing = false

func _on_master_volume_changed(value: float) -> void:
	if _syncing:
		return
	AudioManager.set_master_volume(value / 100.0)
	AudioManager.save_settings()
	_update_volume_label(value)

func _on_fps_limit_selected(index: int) -> void:
	if _syncing:
		return
	_pending_fps_limit = _fps_limit_option.get_item_id(index)

func _on_resolution_selected(index: int) -> void:
	if _syncing:
		return
	var resolution_index := _resolution_option.get_item_id(index)
	if resolution_index < 0 or resolution_index >= GraphicsSettings.RESOLUTIONS.size():
		return
	_pending_resolution = GraphicsSettings.RESOLUTIONS[resolution_index]

func _apply_pending_settings() -> void:
	GraphicsSettings.fps_limit = _pending_fps_limit
	GraphicsSettings.resolution = _pending_resolution
	GraphicsSettings.apply_all()
	GraphicsSettings.save_settings()

func _update_volume_label(value: float) -> void:
	_volume_label.text = "Master Volume (%d%%)" % int(roundf(value))

func _get_fps_limit_index(fps_limit: int) -> int:
	for i in range(_fps_limit_option.item_count):
		if _fps_limit_option.get_item_id(i) == fps_limit:
			return i
	return max(0, _fps_limit_option.item_count - 1)
