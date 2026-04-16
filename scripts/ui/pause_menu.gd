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

var _syncing: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	for fps in FPS_LIMITS:
		_fps_limit_option.add_item("%d FPS" % fps, fps)

	_resume_button.pressed.connect(func(): resume_requested.emit())
	_respawn_button.pressed.connect(func(): respawn_requested.emit())
	_volume_slider.value_changed.connect(_on_master_volume_changed)
	_fps_limit_option.item_selected.connect(_on_fps_limit_selected)
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
	GraphicsSettings.fps_limit = _fps_limit_option.get_item_id(index)
	GraphicsSettings.apply_all()
	GraphicsSettings.save_settings()

func _update_volume_label(value: float) -> void:
	_volume_label.text = "Master Volume (%d%%)" % int(roundf(value))

func _get_fps_limit_index(fps_limit: int) -> int:
	for i in range(_fps_limit_option.item_count):
		if _fps_limit_option.get_item_id(i) == fps_limit:
			return i
	return max(0, _fps_limit_option.item_count - 1)
