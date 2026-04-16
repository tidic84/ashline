extends PanelContainer
class_name SettingsMenu

signal closed

const FPS_LIMITS: Array[int] = [30, 60, 90, 120, 240]

@onready var _shadow_option: OptionButton = $Margin/VBox/Grid/ShadowOption
@onready var _msaa_option: OptionButton = $Margin/VBox/Grid/MsaaOption
@onready var _ssao_check: CheckButton = $Margin/VBox/Grid/SsaoCheck
@onready var _ssr_check: CheckButton = $Margin/VBox/Grid/SsrCheck
@onready var _glow_check: CheckButton = $Margin/VBox/Grid/GlowCheck
@onready var _vsync_check: CheckButton = $Margin/VBox/Grid/VsyncCheck
@onready var _fullscreen_check: CheckButton = $Margin/VBox/Grid/FullscreenCheck
@onready var _scale_label: Label = $Margin/VBox/Grid/ScaleLabel
@onready var _scale_slider: HSlider = $Margin/VBox/Grid/ScaleSlider
@onready var _fov_label: Label = $Margin/VBox/Grid/FovLabel
@onready var _fov_slider: HSlider = $Margin/VBox/Grid/FovSlider
@onready var _volume_label: Label = $Margin/VBox/Grid/MasterVolumeLabel
@onready var _volume_slider: HSlider = $Margin/VBox/Grid/MasterVolumeSlider
@onready var _fps_limit_option: OptionButton = $Margin/VBox/Grid/FpsLimitOption
@onready var _close_button: Button = $Margin/VBox/CloseButton

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	_shadow_option.add_item("Low", 0)
	_shadow_option.add_item("Medium", 1)
	_shadow_option.add_item("High", 2)
	_shadow_option.add_item("Ultra", 3)

	_msaa_option.add_item("Off", 0)
	_msaa_option.add_item("2x", 1)
	_msaa_option.add_item("4x", 2)
	_msaa_option.add_item("8x", 3)
	for fps in FPS_LIMITS:
		_fps_limit_option.add_item("%d FPS" % fps, fps)

	_shadow_option.item_selected.connect(func(idx: int): GraphicsSettings.shadow_quality = idx; _apply())
	_msaa_option.item_selected.connect(func(idx: int): GraphicsSettings.msaa = idx; _apply())
	_ssao_check.toggled.connect(func(on: bool): GraphicsSettings.ssao_enabled = on; _apply())
	_ssr_check.toggled.connect(func(on: bool): GraphicsSettings.ssr_enabled = on; _apply())
	_glow_check.toggled.connect(func(on: bool): GraphicsSettings.glow_enabled = on; _apply())
	_vsync_check.toggled.connect(func(on: bool): GraphicsSettings.vsync = on; _apply())
	_fullscreen_check.toggled.connect(func(on: bool): GraphicsSettings.fullscreen = on; _apply())
	_scale_slider.value_changed.connect(func(v: float):
		GraphicsSettings.render_scale = v
		_scale_label.text = "Render Scale (%.2f)" % v
		_apply()
	)
	_fov_slider.value_changed.connect(func(v: float):
		GraphicsSettings.fov = v
		_fov_label.text = "FOV (%d)" % int(v)
		_apply()
	)
	_volume_slider.value_changed.connect(_on_master_volume_changed)
	_fps_limit_option.item_selected.connect(_on_fps_limit_selected)
	_close_button.pressed.connect(_close)
	_refresh()

func _refresh() -> void:
	_shadow_option.select(GraphicsSettings.shadow_quality)
	_msaa_option.select(GraphicsSettings.msaa)
	_ssao_check.button_pressed = GraphicsSettings.ssao_enabled
	_ssr_check.button_pressed = GraphicsSettings.ssr_enabled
	_glow_check.button_pressed = GraphicsSettings.glow_enabled
	_vsync_check.button_pressed = GraphicsSettings.vsync
	_fullscreen_check.button_pressed = GraphicsSettings.fullscreen
	_scale_slider.value = GraphicsSettings.render_scale
	_scale_label.text = "Render Scale (%.2f)" % GraphicsSettings.render_scale
	_fov_slider.value = GraphicsSettings.fov
	_fov_label.text = "FOV (%d)" % int(GraphicsSettings.fov)
	_volume_slider.value = AudioManager.get_master_volume() * 100.0
	_update_volume_label(_volume_slider.value)
	_fps_limit_option.select(_get_fps_limit_index(GraphicsSettings.fps_limit))

func _apply() -> void:
	GraphicsSettings.apply_all()
	GraphicsSettings.save_settings()

func _on_master_volume_changed(value: float) -> void:
	AudioManager.set_master_volume(value / 100.0)
	AudioManager.save_settings()
	_update_volume_label(value)

func _on_fps_limit_selected(index: int) -> void:
	GraphicsSettings.fps_limit = _fps_limit_option.get_item_id(index)
	_apply()

func _update_volume_label(value: float) -> void:
	_volume_label.text = "Master Volume (%d%%)" % int(roundf(value))

func _get_fps_limit_index(fps_limit: int) -> int:
	for i in range(_fps_limit_option.item_count):
		if _fps_limit_option.get_item_id(i) == fps_limit:
			return i
	return max(0, _fps_limit_option.item_count - 1)

func open() -> void:
	_refresh()
	visible = true

func _close() -> void:
	visible = false
	closed.emit()
