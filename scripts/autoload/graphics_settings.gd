extends Node

const CONFIG_PATH: String = "user://settings.cfg"
const FPS_LIMITS: Array[int] = [60, 75, 90, 120]

enum Quality { LOW, MEDIUM, HIGH, ULTRA }

@export var shadow_quality: Quality = Quality.MEDIUM
@export var msaa: int = 0  # 0=off, 1=2x, 2=4x, 3=8x
@export var ssao_enabled: bool = false
@export var ssr_enabled: bool = false
@export var glow_enabled: bool = true
@export var vsync: bool = true
@export var fullscreen: bool = false
@export var render_scale: float = 0.85
@export var fov: float = 75.0
@export var fps_limit: int = 120
@export var sun_shafts_enabled: bool = false
@export var clouds_enabled: bool = false

func _ready() -> void:
	load_settings()
	call_deferred("apply_all")

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	shadow_quality = cfg.get_value("graphics", "shadow_quality", shadow_quality)
	msaa = cfg.get_value("graphics", "msaa", msaa)
	ssao_enabled = cfg.get_value("graphics", "ssao_enabled", ssao_enabled)
	ssr_enabled = cfg.get_value("graphics", "ssr_enabled", ssr_enabled)
	glow_enabled = cfg.get_value("graphics", "glow_enabled", glow_enabled)
	vsync = cfg.get_value("graphics", "vsync", vsync)
	fullscreen = cfg.get_value("graphics", "fullscreen", fullscreen)
	render_scale = cfg.get_value("graphics", "render_scale", render_scale)
	fov = cfg.get_value("graphics", "fov", fov)
	fps_limit = cfg.get_value("graphics", "fps_limit", fps_limit)
	if not FPS_LIMITS.has(fps_limit):
		fps_limit = 120

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("graphics", "shadow_quality", shadow_quality)
	cfg.set_value("graphics", "msaa", msaa)
	cfg.set_value("graphics", "ssao_enabled", ssao_enabled)
	cfg.set_value("graphics", "ssr_enabled", ssr_enabled)
	cfg.set_value("graphics", "glow_enabled", glow_enabled)
	cfg.set_value("graphics", "vsync", vsync)
	cfg.set_value("graphics", "fullscreen", fullscreen)
	cfg.set_value("graphics", "render_scale", render_scale)
	cfg.set_value("graphics", "fov", fov)
	cfg.set_value("graphics", "fps_limit", fps_limit)
	cfg.save(CONFIG_PATH)

func apply_all() -> void:
	Engine.max_fps = fps_limit
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED
	)
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	)

	var viewport: Viewport = get_viewport()
	if viewport:
		viewport.msaa_3d = msaa
		viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		viewport.use_taa = false
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2 if render_scale < 1.0 else Viewport.SCALING_3D_MODE_BILINEAR
		viewport.scaling_3d_scale = render_scale
		viewport.use_occlusion_culling = true

	_apply_environment()
	_apply_shadows()
	_apply_scene_effects()

func _apply_scene_effects() -> void:
	var main: Node = get_tree().current_scene
	if main == null:
		return
	# Disable SunShafts compositor effect if present
	var we: WorldEnvironment = main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we and we.compositor:
		for fx in we.compositor.compositor_effects:
			if fx:
				fx.enabled = sun_shafts_enabled
	# Disable SunshineClouds driver if present
	var clouds: Node = main.get_node_or_null("SunshineCloudsDriverGD")
	if clouds:
		clouds.process_mode = Node.PROCESS_MODE_INHERIT if clouds_enabled else Node.PROCESS_MODE_DISABLED
		if clouds is Node3D:
			(clouds as Node3D).visible = clouds_enabled

func _apply_environment() -> void:
	var world: World3D = get_viewport().find_world_3d()
	if world == null:
		return
	var env: Environment = world.environment
	if env == null:
		# Try scene's WorldEnvironment
		var main: Node = get_tree().current_scene
		if main:
			var we: WorldEnvironment = main.get_node_or_null("WorldEnvironment")
			if we:
				env = we.environment
	if env == null:
		return
	env.ssao_enabled = ssao_enabled
	env.ssr_enabled = ssr_enabled
	env.glow_enabled = glow_enabled

func _apply_shadows() -> void:
	var size: int = 1024
	match shadow_quality:
		Quality.LOW: size = 512
		Quality.MEDIUM: size = 1024
		Quality.HIGH: size = 2048
		Quality.ULTRA: size = 4096
	ProjectSettings.set_setting("rendering/lights_and_shadows/directional_shadow/size", size)
	ProjectSettings.set_setting("rendering/lights_and_shadows/positional_shadow/atlas_size", size)
	# Apply to active directional light so max_distance stays tight
	var main: Node = get_tree().current_scene
	if main:
		var dl: DirectionalLight3D = main.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
		if dl:
			dl.directional_shadow_max_distance = 80.0 if shadow_quality <= Quality.MEDIUM else 130.0

func set_fov_on_camera(camera: Camera3D) -> void:
	if camera:
		camera.fov = fov
