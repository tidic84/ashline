extends Node
class_name BuildController

# Lightweight standalone build/interact controller that plugs into the
# UP_FPSController (uniplayer) prefab. Handles:
#  - Opening the build menu (B)
#  - Raycasting from the FPS camera for build preview + placement
#  - Interaction hint + E key
#  - Hosting the HUD CanvasLayer

@export var fps_controller_path: NodePath
@export var hud_scene: PackedScene = preload("res://scenes/ui/hud.tscn")

var _fps: CharacterBody3D = null
var _camera: Camera3D = null
var _hud: Control = null
var _hud_layer: CanvasLayer = null
var _ambient_timer: float = 0.0
var _ray_exclude: Array[RID] = []
var _build_preview_accum: float = 0.0
var _interact_check_accum: float = 0.0
const BUILD_RAY_LENGTH: float = 8.0
const INTERACT_RAY_LENGTH: float = 4.0
const BUILD_COLLISION_MASK: int = 9
const INTERACT_COLLISION_MASK: int = 48
const BUILD_PREVIEW_INTERVAL: float = 0.033
const INTERACT_CHECK_INTERVAL: float = 0.05


func _ready() -> void:
	if fps_controller_path != NodePath():
		_fps = get_node_or_null(fps_controller_path) as CharacterBody3D
	if _fps == null:
		push_warning("BuildController: fps_controller_path not set or invalid")
		return

	var cam_node: Node = _fps.get_node_or_null("RotationHelper/Camera")
	_camera = cam_node as Camera3D
	if _camera == null:
		push_warning("BuildController: could not find UP_FPSController camera")
		return

	_ray_exclude = [_fps.get_rid()]

	# Spawn HUD on its own CanvasLayer so it isn't tied to the player transform
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "HUDLayer"
	add_child(_hud_layer)
	_hud = hud_scene.instantiate() as Control
	_hud_layer.add_child(_hud)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Wire build menu signals
	var build_menu: Node = _hud.get_node_or_null("BuildMenu")
	if build_menu:
		build_menu.item_selected.connect(_on_build_item_selected)
		build_menu.mode_selected.connect(_on_build_mode_selected)
		build_menu.exit_build_requested.connect(_on_build_exit_requested)
		build_menu.close_requested.connect(_close_build_menu)

	var settings_menu: Node = _hud.get_node_or_null("SettingsMenu")
	if settings_menu and settings_menu.has_signal("closed"):
		settings_menu.closed.connect(func():
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		)


func _unhandled_input(event: InputEvent) -> void:
	if _camera == null:
		return

	if event.is_action_pressed("build_mode"):
		if BuildSystem.is_building:
			var bm: Node = _hud.get_node_or_null("BuildMenu")
			if bm and bm.visible:
				_close_build_menu()
			else:
				_open_build_menu()
		else:
			BuildSystem.enter_build_mode()
			_open_build_menu()

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		var bm2: Node = _hud.get_node_or_null("BuildMenu")
		if bm2 and bm2.visible:
			_close_build_menu()
		elif BuildSystem.is_building:
			_on_build_exit_requested()

	if event.is_action_pressed("interact"):
		_try_interact()

	if event.is_action_pressed("shoot"):
		var bm3: Node = _hud.get_node_or_null("BuildMenu")
		if bm3 and bm3.visible:
			return
		if BuildSystem.is_building:
			_try_build()

	# Right-click while building: cancel selection (or exit build mode if none)
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		var bm4: Node = _hud.get_node_or_null("BuildMenu")
		if bm4 and bm4.visible:
			return
		if BuildSystem.is_building:
			if BuildSystem.mode != BuildSystem.BuildMode.OFF:
				BuildSystem.set_mode(BuildSystem.BuildMode.OFF)
			else:
				_on_build_exit_requested()

	# X key: deconstruct whatever build piece we're looking at
	if event.is_action_pressed("deconstruct"):
		if BuildSystem.is_building:
			_try_deconstruct()


func _physics_process(delta: float) -> void:
	if _camera == null:
		return
	if BuildSystem.is_building:
		_build_preview_accum += delta
		if _build_preview_accum >= BUILD_PREVIEW_INTERVAL:
			_build_preview_accum = 0.0
			_update_build_preview()
	_interact_check_accum += delta
	if _interact_check_accum >= INTERACT_CHECK_INTERVAL:
		_interact_check_accum = 0.0
		_update_interact_hint()
	_update_ambient(delta)


func _camera_ray(length: float, mask: int) -> Dictionary:
	var from: Vector3 = _camera.global_position
	var to: Vector3 = from + -_camera.global_transform.basis.z * length
	var params := PhysicsRayQueryParameters3D.create(from, to, mask)
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.exclude = _ray_exclude
	return _fps.get_world_3d().direct_space_state.intersect_ray(params)


func _try_interact() -> void:
	var hit := _camera_ray(INTERACT_RAY_LENGTH, INTERACT_COLLISION_MASK)
	if hit.is_empty():
		return
	var collider: Object = hit.get("collider")
	if collider and collider.has_method("interact"):
		collider.interact(_fps)


func _try_build() -> void:
	var hit := _camera_ray(BUILD_RAY_LENGTH, BUILD_COLLISION_MASK)
	if hit.is_empty():
		return
	var hit_point: Vector3 = hit["position"]
	var hit_normal: Vector3 = hit["normal"]
	var collider: Object = hit["collider"]
	if collider == null:
		return

	match BuildSystem.mode:
		BuildSystem.BuildMode.CHASSIS:
			BuildSystem.try_place_chassis(hit_point)
		BuildSystem.BuildMode.FLOOR:
			var chassis := _find_chassis(collider)
			if chassis:
				var p: Variant = _get_build_point_on_chassis(chassis)
				if p is Vector3:
					hit_point = p
					hit_normal = chassis.get_build_surface_normal_world()
				BuildSystem.try_place_floor(hit_point, chassis)
		BuildSystem.BuildMode.ITEM:
			var chassis2 := _find_chassis(collider)
			if chassis2:
				var p2: Variant = _get_build_point_on_chassis(chassis2)
				if p2 is Vector3:
					hit_point = p2
					hit_normal = chassis2.get_build_surface_normal_world()
				BuildSystem.try_place_item(hit_point, chassis2)
		BuildSystem.BuildMode.DEMOLISH:
			var chassis3 := _find_chassis(collider)
			if chassis3:
				var p3: Variant = _get_build_point_on_chassis(chassis3)
				if p3 is Vector3:
					hit_point = p3
					hit_normal = chassis3.get_build_surface_normal_world()
				BuildSystem.try_demolish(hit_point, chassis3)


func _update_build_preview() -> void:
	var hit := _camera_ray(BUILD_RAY_LENGTH, BUILD_COLLISION_MASK)
	if hit.is_empty():
		BuildSystem.hide_preview()
		return
	var hit_point: Vector3 = hit["position"]
	var hit_normal: Vector3 = hit["normal"]
	var collider: Object = hit["collider"]
	if collider == null:
		BuildSystem.hide_preview()
		return

	match BuildSystem.mode:
		BuildSystem.BuildMode.CHASSIS:
			BuildSystem.update_preview_on_ground(hit_point, hit_normal)
		BuildSystem.BuildMode.FLOOR, BuildSystem.BuildMode.ITEM:
			var chassis := _find_chassis(collider)
			if chassis:
				var p: Variant = _get_build_point_on_chassis(chassis)
				if p is Vector3:
					hit_point = p
					hit_normal = chassis.get_build_surface_normal_world()
				BuildSystem.update_preview_on_chassis(hit_point, hit_normal, chassis)
			else:
				BuildSystem.hide_preview()
		BuildSystem.BuildMode.DEMOLISH:
			var chassis2 := _find_chassis(collider)
			if chassis2:
				var p2: Variant = _get_build_point_on_chassis(chassis2)
				if p2 is Vector3:
					hit_point = p2
					hit_normal = chassis2.get_build_surface_normal_world()
				BuildSystem.update_preview_on_chassis(hit_point, hit_normal, chassis2)
			else:
				BuildSystem.hide_preview()
		_:
			BuildSystem.hide_preview()


func _try_deconstruct() -> void:
	var hit := _camera_ray(BUILD_RAY_LENGTH, BUILD_COLLISION_MASK)
	if hit.is_empty():
		return
	var hit_point: Vector3 = hit["position"]
	var collider: Object = hit.get("collider")
	if collider == null or not (collider is Node):
		return
	var node: Node = collider as Node

	# Walk up to find what we're deconstructing: a placed item, a floor piece, or a chassis
	var chassis := _find_chassis(node)
	if chassis == null:
		return
	BuildSystem.try_demolish(hit_point, chassis)


func _find_chassis(node: Node) -> TrainChassis:
	var current: Node = node
	while current:
		if current is TrainChassis:
			return current
		current = current.get_parent()
	return null


func _get_build_point_on_chassis(chassis: TrainChassis) -> Variant:
	var origin: Vector3 = _camera.global_transform.origin
	var dir: Vector3 = -_camera.global_transform.basis.z
	if dir.length_squared() < 0.0001:
		return null
	dir = dir.normalized()
	return _ray_plane_intersection(
		origin,
		dir,
		chassis.get_build_surface_point_world(),
		chassis.get_build_surface_normal_world(),
		BUILD_RAY_LENGTH + 0.25
	)


func _ray_plane_intersection(
	ray_origin: Vector3,
	ray_dir: Vector3,
	plane_point: Vector3,
	plane_normal: Vector3,
	max_distance: float
) -> Variant:
	var denom: float = plane_normal.dot(ray_dir)
	if absf(denom) < 0.0001:
		return null
	var t: float = plane_normal.dot(plane_point - ray_origin) / denom
	if t < 0.0 or t > max_distance:
		return null
	return ray_origin + ray_dir * t


func _update_interact_hint() -> void:
	var hit := _camera_ray(INTERACT_RAY_LENGTH, INTERACT_COLLISION_MASK)
	if not hit.is_empty():
		var collider: Object = hit.get("collider")
		if collider and collider.has_method("interact"):
			var text := "[E] Interact"
			if collider is PumpLever:
				text = "[E] Pump"
			elif collider is Harvestable:
				text = "[E] Harvest"
			_hud.show_interact_hint(text)
			return
	_hud.hide_interact_hint()


func _update_ambient(delta: float) -> void:
	_ambient_timer += delta
	if _ambient_timer < 1.0:
		return
	_ambient_timer = 0.0
	var terrain_nodes := get_tree().get_nodes_in_group("terrain")
	if terrain_nodes.is_empty():
		return
	var terrain: TerrainGenerator = terrain_nodes[0] as TerrainGenerator
	if terrain == null:
		return
	var pos: Vector3 = _fps.global_position
	var biome: int = terrain.get_biome_at(pos.x, pos.z)
	var main: Node = get_tree().current_scene
	var is_night: bool = false
	if main and "is_night" in main:
		is_night = bool(main.get("is_night"))
	if is_night:
		AudioManager.play_ambient("night")
		return
	match biome:
		TerrainGenerator.Biome.FOREST: AudioManager.play_ambient("forest")
		TerrainGenerator.Biome.DESERT: AudioManager.play_ambient("desert")
		TerrainGenerator.Biome.SNOW: AudioManager.play_ambient("snow")
		_: AudioManager.play_ambient("plains")


func _set_player_look_enabled(enabled: bool) -> void:
	if _fps == null:
		return
	# UP_HeadRotation reads mouse motion in _input() regardless of mouse mode,
	# so we have to disable its input processing while a menu is open.
	var head_rot: Node = _fps.get_node_or_null("HeadRotation")
	if head_rot:
		head_rot.set_process_input(enabled)
		head_rot.set_process_unhandled_input(enabled)


func _open_build_menu() -> void:
	var bm: Node = _hud.get_node_or_null("BuildMenu")
	if bm:
		bm.show_menu()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_set_player_look_enabled(false)
	BuildSystem.hide_preview()


func _close_build_menu() -> void:
	var bm: Node = _hud.get_node_or_null("BuildMenu")
	if bm:
		bm.hide_menu()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_set_player_look_enabled(true)


func _on_build_item_selected(buildable_id: String) -> void:
	BuildSystem.select_buildable(buildable_id)
	_close_build_menu()


func _on_build_mode_selected(mode: int) -> void:
	BuildSystem.set_mode(mode)
	_close_build_menu()


func _on_build_exit_requested() -> void:
	var bm: Node = _hud.get_node_or_null("BuildMenu")
	if bm:
		bm.hide_menu()
	BuildSystem.exit_build_mode()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_set_player_look_enabled(true)
