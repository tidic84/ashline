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
const BUILD_COLLISION_MASK: int = 137  # World (1) + Train (8) + BuildDetect (128)
const INTERACT_COLLISION_MASK: int = 48
const LOOK_COLLISION_MASK: int = 57  # World (1) + Train (8) + Placeables (16) + Interactable (32)
const BUILD_PREVIEW_INTERVAL: float = 0.033
const INTERACT_CHECK_INTERVAL: float = 0.05
const GAME_AMBIENT_NAME: String = "train_ambience"


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
	if _hud.has_signal("inventory_toggle_requested"):
		_hud.connect("inventory_toggle_requested", _on_inventory_toggle_requested)

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

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			Inventory.cycle_hotbar(-1)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			Inventory.cycle_hotbar(1)
			return

	if event is InputEventKey and event.pressed and not event.echo:
		var hotbar_index: int = _hotbar_index_from_key(event.keycode)
		if hotbar_index >= 0:
			Inventory.select_hotbar_slot(hotbar_index)
			return

	if event.is_action_pressed("inventory"):
		_toggle_inventory_panel()
		return

	if _is_inventory_open():
		if event is InputEventKey and event.pressed and not event.echo:
			match event.keycode:
				KEY_LEFT, KEY_Q:
					_hud.select_previous_recipe()
				KEY_RIGHT, KEY_D:
					_hud.select_next_recipe()
				KEY_ENTER, KEY_KP_ENTER, KEY_F:
					_hud.craft_selected_recipe()
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
		if _is_inventory_open():
			return
		_try_interact()

	if event.is_action_pressed("shoot"):
		if _is_inventory_open():
			return
		var bm3: Node = _hud.get_node_or_null("BuildMenu")
		if bm3 and bm3.visible:
			return
		if BuildSystem.is_building:
			_try_build()
		elif _try_use_equipped_tool():
			return

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
		if _is_inventory_open():
			BuildSystem.hide_preview()
			return
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
	if collider and collider.has_method("interact_at"):
		collider.interact_at(_fps, hit)
	elif collider and collider.has_method("interact"):
		collider.interact(_fps)


func _try_use_equipped_tool() -> bool:
	var selected_item: String = Inventory.get_selected_item()
	if selected_item != "axe" and selected_item != "pickaxe" and selected_item != "hammer":
		return false
	var hit := _camera_ray(INTERACT_RAY_LENGTH, INTERACT_COLLISION_MASK)
	if hit.is_empty():
		return false
	var collider: Object = hit.get("collider")
	if collider and collider.has_method("interact_at"):
		collider.interact_at(_fps, hit)
		return true
	if collider and collider.has_method("interact"):
		collider.interact(_fps)
		return true
	return false


func _try_build() -> void:
	var hit := _camera_ray(BUILD_RAY_LENGTH, BUILD_COLLISION_MASK)
	if hit.is_empty():
		return
	var hit_point: Vector3 = hit["position"]
	var collider: Object = hit["collider"]
	if collider == null:
		return

	match BuildSystem.mode:
		BuildSystem.BuildMode.CHASSIS:
			BuildSystem.try_place_chassis(hit_point)
		BuildSystem.BuildMode.FLOOR:
			var target := _find_build_target(collider as Node)
			if target:
				var p: Variant = _get_build_point_on_target(target)
				if p is Vector3:
					hit_point = p
				BuildSystem.try_place_floor(hit_point, target)
		BuildSystem.BuildMode.ITEM:
			var target2 := _find_build_target(collider as Node)
			if target2:
				var p2: Variant = _get_build_point_on_target(target2)
				if p2 is Vector3:
					hit_point = p2
				BuildSystem.try_place_item(hit_point, target2)
		BuildSystem.BuildMode.DEMOLISH:
			var target3 := _find_build_target(collider as Node)
			if target3:
				var p3: Variant = _get_build_point_on_target(target3)
				if p3 is Vector3:
					hit_point = p3
				BuildSystem.try_demolish(hit_point, target3)


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
			var target := _find_build_target(collider as Node)
			if target:
				var p: Variant = _get_build_point_on_target(target)
				if p is Vector3:
					hit_point = p
					hit_normal = target.get_build_surface_normal_world()
				BuildSystem.update_preview_on_target(hit_point, hit_normal, target)
			else:
				BuildSystem.hide_preview()
		BuildSystem.BuildMode.DEMOLISH:
			var target2 := _find_build_target(collider as Node)
			if target2:
				var p2: Variant = _get_build_point_on_target(target2)
				if p2 is Vector3:
					hit_point = p2
					hit_normal = target2.get_build_surface_normal_world()
				BuildSystem.update_preview_on_target(hit_point, hit_normal, target2)
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
	var target := _find_build_target(node)
	if target == null:
		return
	BuildSystem.try_demolish(hit_point, target)


func _find_chassis(node: Node) -> TrainChassis:
	var current: Node = node
	while current:
		if current is TrainChassis:
			return current
		current = current.get_parent()
	return null


func _find_build_target(node: Node) -> Node:
	# Walk up parents looking for WagonFrame or TrainChassis.
	# WagonFrame takes priority (its build surface is what raycasts hit).
	var current: Node = node
	while current:
		if current is WagonFrame:
			return current
		if current is TrainChassis:
			var p: Node = current.get_parent()
			if p is WagonFrame:
				return p
			return current
		current = current.get_parent()
	return null


func _get_build_point_on_target(target: Node) -> Variant:
	var origin: Vector3 = _camera.global_transform.origin
	var dir: Vector3 = -_camera.global_transform.basis.z
	if dir.length_squared() < 0.0001:
		return null
	dir = dir.normalized()
	var plane_point: Vector3
	var plane_normal: Vector3
	if target is WagonFrame:
		var wf := target as WagonFrame
		plane_point = wf.to_global(Vector3(0.0, WagonFrame.BUILD_SURFACE_LOCAL_Y, 0.0))
		plane_normal = wf.get_build_surface_normal_world()
	elif target is TrainChassis:
		plane_point = (target as TrainChassis).get_build_surface_point_world()
		plane_normal = (target as TrainChassis).get_build_surface_normal_world()
	else:
		return null
	return _ray_plane_intersection(origin, dir, plane_point, plane_normal, BUILD_RAY_LENGTH + 0.25)


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
	if _is_inventory_open():
		_hud.hide_interact_hint()
		_hud.hide_target_name()
		return
	var look_hit := _camera_ray(INTERACT_RAY_LENGTH, LOOK_COLLISION_MASK)
	if not look_hit.is_empty():
		var looked_name := _get_target_display_name(look_hit)
		if not looked_name.is_empty():
			_hud.show_target_name(looked_name)
		else:
			_hud.hide_target_name()
	else:
		_hud.hide_target_name()
	var hit := _camera_ray(INTERACT_RAY_LENGTH, INTERACT_COLLISION_MASK)
	if not hit.is_empty():
		var collider: Object = hit.get("collider")
		if collider and (collider.has_method("interact_at") or collider.has_method("interact")):
			var text := "[E] Interact"
			if collider is PumpLever:
				text = "[E] Pump"
			elif collider is DirectionLever:
				text = "[E] Direction"
			elif collider is RailSwitch:
				text = "[E] Switch"
			elif collider.has_method("get_interact_text_at"):
				text = collider.get_interact_text_at(hit)
			elif collider.has_method("get_interact_text"):
				text = collider.get_interact_text()
			elif collider is Harvestable:
				text = "[E] Harvest"
			_hud.show_interact_hint(text)
			return
	_hud.hide_interact_hint()

func _get_target_display_name(hit: Dictionary) -> String:
	var collider: Object = hit.get("collider")
	if collider == null or not (collider is Node):
		return ""
	if collider.has_method("get_target_name_at"):
		var target_name: String = collider.get_target_name_at(hit)
		if not target_name.is_empty():
			return target_name
	var node := collider as Node
	var current: Node = node
	while current:
		if current.has_meta("buildable_id"):
			var buildable_id: String = str(current.get_meta("buildable_id"))
			if BuildSystem.buildable_catalog.has(buildable_id):
				var data: BuildableData = BuildSystem.buildable_catalog[buildable_id]
				return data.display_name
		if current is PumpLever:
			return "Pump Lever"
		if current is DirectionLever:
			return "Direction Lever"
		if current is RailSwitch:
			return "Rail Switch"
		if current is Harvestable:
			return _get_harvestable_name(current as Harvestable)
		if current is WagonFrame:
			return "Wagon"
		if current is TrainChassis:
			return "Train Chassis"
		current = current.get_parent()
	return _prettify_node_name(node.name)

func _get_harvestable_name(harvestable: Harvestable) -> String:
	if harvestable.required_tool_id == "axe":
		return "Tree"
	if harvestable.required_tool_id == "pickaxe":
		return "Rock"
	var item_id: String = harvestable.drop_item_id if not harvestable.drop_item_id.is_empty() else harvestable.resource_id
	if not item_id.is_empty():
		return Inventory.get_item_name(item_id)
	return _prettify_node_name(harvestable.name)

func _prettify_node_name(raw_name: String) -> String:
	var cleaned := raw_name.replace("_", " ").replace("-", " ").strip_edges()
	if cleaned.is_empty():
		return ""
	return cleaned.capitalize()


func _update_ambient(delta: float) -> void:
	_ambient_timer += delta
	if _ambient_timer < 1.0:
		return
	_ambient_timer = 0.0
	AudioManager.play_ambient(GAME_AMBIENT_NAME)


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
	if _is_inventory_open():
		_hud.toggle_inventory_panel(false)
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


func _hotbar_index_from_key(keycode: Key) -> int:
	match keycode:
		KEY_1: return 0
		KEY_2: return 1
		KEY_3: return 2
		KEY_4: return 3
		KEY_5: return 4
		KEY_6: return 5
		KEY_7: return 6
		KEY_8: return 7
		KEY_9: return 8
		_: return -1


func _is_inventory_open() -> bool:
	if _hud == null or not _hud.has_method("is_inventory_open"):
		return false
	return _hud.is_inventory_open()


func _toggle_inventory_panel() -> void:
	if _hud == null or not _hud.has_method("toggle_inventory_panel"):
		return
	var open: bool = _hud.toggle_inventory_panel()
	if open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_set_player_look_enabled(false)
		BuildSystem.hide_preview()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_set_player_look_enabled(true)

func _on_inventory_toggle_requested() -> void:
	_toggle_inventory_panel()


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
