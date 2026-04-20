extends Node
class_name BuildController

const FootstepAudioHelper = preload("res://scripts/player/footstep_audio.gd")

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
var _controls_were_blocked: bool = false
var _ignore_shoot_until_msec: int = 0
var _wagon_platform: Node3D = null
var _last_wagon_transform: Transform3D = Transform3D.IDENTITY
var _platform_velocity_carry: Vector3 = Vector3.ZERO
var _batch_build_active: bool = false
var _batch_build_mode: int = BuildSystem.BuildMode.OFF
var _batch_build_target: Node = null
var _batch_build_start_grid: Vector3i = Vector3i.ZERO
var _batch_build_end_grid: Vector3i = Vector3i.ZERO
var _batch_build_edge: int = BuildSystem.EdgeSide.NONE
var _hovered_switch: RailSwitch = null
const BUILD_RAY_LENGTH: float = 8.0
const INTERACT_RAY_LENGTH: float = 4.0
const BUILD_COLLISION_MASK: int = 137  # World (1) + Train (8) + BuildDetect (128)
const INTERACT_COLLISION_MASK: int = 48
const LOOK_COLLISION_MASK: int = 57  # World (1) + Train (8) + Placeables (16) + Interactable (32)
const BUILD_PREVIEW_INTERVAL: float = 0.033
const INTERACT_CHECK_INTERVAL: float = 0.05
const GAME_AMBIENT_NAME: String = ""


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

	_hud = _find_existing_hud()
	if _hud == null:
		_hud_layer = CanvasLayer.new()
		_hud_layer.name = "HUDLayer"
		add_child(_hud_layer)
		_hud = hud_scene.instantiate() as Control
		_hud_layer.add_child(_hud)
	else:
		_hud_layer = _hud.get_parent() as CanvasLayer
	_hud.visible = true
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
			if GameManager.current_state == GameManager.GameState.PLAYING:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_set_player_look_enabled(true)
		)
	GameManager.game_state_changed.connect(_on_game_state_changed)
	AudioManager.stop_ambient()
	if _fps.has_signal("footstep"):
		_fps.connect("footstep", Callable(self, "_on_footstep"))


func _find_existing_hud() -> Control:
	var scene := get_tree().current_scene
	if scene:
		var scene_hud := scene.get_node_or_null("HUDLayer/HUD") as Control
		if scene_hud:
			return scene_hud
	var sibling_hud := get_node_or_null("../HUDLayer/HUD") as Control
	if sibling_hud:
		return sibling_hud
	return null


func _on_footstep(_leg: int) -> void:
	if _fps == null or not is_instance_valid(_fps):
		return
	FootstepAudioHelper.play_local_footstep(_fps, _fps)


func _unhandled_input(event: InputEvent) -> void:
	if _camera == null:
		return
	if _controls_blocked():
		_cancel_batch_build()
		return

	if event.is_action_released("shoot"):
		if _batch_build_active:
			_commit_batch_build()
			_cancel_batch_build()
		return

	if event is InputEventMouseButton and event.pressed:
		if _is_build_menu_open() and (
			event.button_index == MOUSE_BUTTON_WHEEL_UP
			or event.button_index == MOUSE_BUTTON_WHEEL_DOWN
		):
			return
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
		if Time.get_ticks_msec() < _ignore_shoot_until_msec:
			return
		if BuildSystem.is_building:
			if _can_batch_build_current_mode():
				if not _begin_batch_build():
					_cancel_batch_build()
					_try_build()
			else:
				_cancel_batch_build()
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
				_cancel_batch_build()
				BuildSystem.set_mode(BuildSystem.BuildMode.OFF)
			else:
				_on_build_exit_requested()
		elif not _is_inventory_open():
			_try_secondary_interact()

	# X key: deconstruct whatever build piece we're looking at
	if event.is_action_pressed("deconstruct"):
		if BuildSystem.is_building:
			_try_deconstruct()


func _physics_process(delta: float) -> void:
	if _camera == null:
		return
	if _apply_blocked_controls():
		_clear_hovered_switch()
		_cancel_batch_build()
		BuildSystem.hide_preview()
		return
	if BuildSystem.is_building:
		if _is_inventory_open():
			_clear_hovered_switch()
			_cancel_batch_build()
			BuildSystem.hide_preview()
			return
		_build_preview_accum += delta
		if _build_preview_accum >= BUILD_PREVIEW_INTERVAL:
			_build_preview_accum = 0.0
			if not _batch_build_active:
				_update_build_preview()
		_update_batch_build()
	else:
		_cancel_batch_build()
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


func _try_secondary_interact() -> void:
	var hit := _camera_ray(INTERACT_RAY_LENGTH, INTERACT_COLLISION_MASK)
	if hit.is_empty():
		return
	var collider: Object = hit.get("collider")
	if collider and collider.has_method("secondary_interact"):
		collider.secondary_interact(_fps)


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
	var hit_point: Vector3 = Vector3.ZERO
	var collider: Object = null
	if not hit.is_empty():
		hit_point = hit["position"]
		collider = hit["collider"]

	if BuildSystem.mode == BuildSystem.BuildMode.CEILING:
		var ceil_target: Node = _find_build_target(collider as Node) if collider != null else null
		if ceil_target == null:
			ceil_target = _find_wagon_underfoot()
		if ceil_target != null and ceil_target.has_method("get_ceiling_surface_local_y"):
			var ceil_ref_try: Variant = hit_point if not hit.is_empty() else null
			var p_ceil: Variant = _get_build_point_on_target(ceil_target, ceil_ref_try, 1)
			if p_ceil is Vector3:
				BuildSystem.try_place_ceiling(p_ceil, ceil_target)
		return

	if hit.is_empty() or collider == null:
		return

	match BuildSystem.mode:
		BuildSystem.BuildMode.CHASSIS:
			BuildSystem.try_place_chassis(hit_point)
		BuildSystem.BuildMode.FLOOR:
			var target := _find_build_target(collider as Node)
			if target:
				var p: Variant = _get_build_point_on_target(target, hit_point)
				if p is Vector3:
					hit_point = p
				BuildSystem.try_place_floor(hit_point, target)
		BuildSystem.BuildMode.CEILING:
			var target_c := _find_build_target(collider as Node)
			if target_c:
				var pc: Variant = _get_build_point_on_target(target_c, hit_point)
				if pc is Vector3:
					hit_point = pc
				BuildSystem.try_place_ceiling(hit_point, target_c)
		BuildSystem.BuildMode.ITEM:
			var target2 := _find_build_target(collider as Node)
			if target2:
				var p2: Variant = _get_build_point_on_target(target2, hit_point)
				if p2 is Vector3:
					hit_point = p2
				BuildSystem.try_place_item(hit_point, target2)
		BuildSystem.BuildMode.DEMOLISH:
			var hit_chassis := _find_chassis(collider as Node)
			if hit_chassis != null:
				BuildSystem.try_demolish_train_part(hit_chassis)
				return
			var target3 := _find_build_target(collider as Node)
			if target3:
				var p3: Variant = _get_build_point_on_target(target3, hit_point)
				if p3 is Vector3:
					hit_point = p3
				BuildSystem.try_demolish(hit_point, target3)


func _can_batch_build_current_mode() -> bool:
	return BuildSystem.mode == BuildSystem.BuildMode.FLOOR or BuildSystem.mode == BuildSystem.BuildMode.CEILING or _is_wall_batch_mode() or BuildSystem.mode == BuildSystem.BuildMode.DEMOLISH


func _is_wall_batch_mode() -> bool:
	if BuildSystem.mode != BuildSystem.BuildMode.ITEM or BuildSystem.current_buildable_data == null:
		return false
	return BuildSystem.current_buildable_data.category in [
		BuildableData.Category.WALL,
		BuildableData.Category.BARRICADE,
	]


func _begin_batch_build() -> bool:
	var context: Dictionary = _get_batch_build_context()
	if context.is_empty():
		return false
	_batch_build_active = true
	_batch_build_mode = BuildSystem.mode
	_batch_build_target = context["target"] as Node
	_batch_build_start_grid = context["grid_pos"]
	_batch_build_end_grid = _batch_build_start_grid
	_batch_build_edge = int(context.get("edge", BuildSystem.EdgeSide.NONE))
	_update_batch_build_text()
	return true


func _update_batch_build() -> void:
	if not _batch_build_active:
		return
	if _is_build_menu_open() or _is_inventory_open():
		_cancel_batch_build()
		return
	if BuildSystem.mode != _batch_build_mode or not is_instance_valid(_batch_build_target):
		_cancel_batch_build()
		return
	var context: Dictionary = _get_batch_build_context()
	if context.is_empty() or context["target"] != _batch_build_target:
		return
	_batch_build_end_grid = context["grid_pos"]
	_update_batch_build_text()


func _commit_batch_build() -> void:
	if not _batch_build_active or not is_instance_valid(_batch_build_target):
		return
	if not BuildSystem.can_place:
		return
	BuildSystem.begin_build_place_sfx_batch()
	if _batch_build_mode == BuildSystem.BuildMode.FLOOR:
		for grid_pos in BuildSystem.get_batch_floor_order(_batch_build_target, _get_floor_batch_positions()):
			BuildSystem.try_place_floor(_batch_build_target.grid_to_world(grid_pos), _batch_build_target)
	elif _batch_build_mode == BuildSystem.BuildMode.CEILING:
		for grid_pos in BuildSystem.get_batch_ceiling_order(_batch_build_target, _get_floor_batch_positions()):
			BuildSystem.try_place_ceiling(_batch_build_target.grid_to_world(grid_pos), _batch_build_target)
	elif _batch_build_mode == BuildSystem.BuildMode.ITEM and _batch_build_edge != BuildSystem.EdgeSide.NONE:
		for grid_pos in _get_wall_batch_positions():
			BuildSystem.try_place_item(_edge_hit_point(_batch_build_target, grid_pos, _batch_build_edge), _batch_build_target)
	elif _batch_build_mode == BuildSystem.BuildMode.DEMOLISH:
		for entry in _get_demolish_batch_entries():
			var demolish_grid_pos: Vector3i = entry["grid_pos"]
			var edge: int = int(entry["edge"])
			BuildSystem.try_demolish_entry(_batch_build_target, demolish_grid_pos, edge)
	BuildSystem.end_build_place_sfx_batch()


func _get_batch_build_context() -> Dictionary:
	if BuildSystem.mode == BuildSystem.BuildMode.FLOOR:
		return _get_floor_build_context()
	if BuildSystem.mode == BuildSystem.BuildMode.CEILING:
		return _get_floor_build_context()
	if _is_wall_batch_mode():
		return _get_wall_build_context()
	if BuildSystem.mode == BuildSystem.BuildMode.DEMOLISH:
		return _get_demolish_build_context()
	return {}


func _get_floor_build_context() -> Dictionary:
	var hit: Dictionary = _camera_ray(BUILD_RAY_LENGTH, BUILD_COLLISION_MASK)
	var hit_point: Vector3 = Vector3.ZERO
	var collider: Object = null
	if not hit.is_empty():
		hit_point = hit["position"]
		collider = hit["collider"]
	var target: Node = _find_build_target(collider as Node) if collider != null else null
	if target == null and BuildSystem.mode == BuildSystem.BuildMode.CEILING:
		target = _find_wagon_underfoot()
	if target == null:
		return {}
	var ref_point: Variant = hit_point if not hit.is_empty() else null
	var level_offset: int = 1 if BuildSystem.mode == BuildSystem.BuildMode.CEILING else 0
	var p: Variant = _get_build_point_on_target(target, ref_point, level_offset)
	if p is Vector3:
		hit_point = p
	elif hit.is_empty():
		return {}
	var grid_pos: Vector3i = target.get_grid_position(hit_point)
	return {
		"hit_point": hit_point,
		"target": target,
		"grid_pos": grid_pos,
	}


func _get_wall_build_context() -> Dictionary:
	var hit: Dictionary = _camera_ray(BUILD_RAY_LENGTH, BUILD_COLLISION_MASK)
	if hit.is_empty():
		return {}
	var hit_point: Vector3 = hit["position"]
	var collider: Object = hit["collider"]
	if collider == null:
		return {}
	var target: Node = _find_build_target(collider as Node)
	if target == null:
		return {}
	var p: Variant = _get_build_point_on_target(target, hit_point)
	if p is Vector3:
		hit_point = p
	var grid_pos: Vector3i = target.get_grid_position(hit_point)
	return {
		"hit_point": hit_point,
		"target": target,
		"grid_pos": grid_pos,
		"edge": _detect_edge_from_hit_for_batch(target, hit_point, grid_pos),
	}


func _get_demolish_build_context() -> Dictionary:
	var hit: Dictionary = _camera_ray(BUILD_RAY_LENGTH, BUILD_COLLISION_MASK)
	if hit.is_empty():
		return {}
	var hit_point: Vector3 = hit["position"]
	var collider: Object = hit["collider"]
	if collider == null:
		return {}
	var target: Node = _find_build_target(collider as Node)
	if target == null:
		return {}
	var p: Variant = _get_build_point_on_target(target)
	if p is Vector3:
		hit_point = p
	return BuildSystem.get_demolish_context_at(target, hit_point)


func _get_floor_batch_positions() -> Array[Vector3i]:
	var positions: Array[Vector3i] = []
	var level: int = _batch_build_start_grid.z
	var step_x: int = 1 if _batch_build_end_grid.x >= _batch_build_start_grid.x else -1
	var step_y: int = 1 if _batch_build_end_grid.y >= _batch_build_start_grid.y else -1
	for y in range(_batch_build_start_grid.y, _batch_build_end_grid.y + step_y, step_y):
		for x in range(_batch_build_start_grid.x, _batch_build_end_grid.x + step_x, step_x):
			positions.append(Vector3i(x, y, level))
	return positions


func _get_wall_batch_positions() -> Array[Vector3i]:
	var positions: Array[Vector3i] = []
	var level: int = _batch_build_start_grid.z
	if _batch_build_edge == BuildSystem.EdgeSide.NORTH or _batch_build_edge == BuildSystem.EdgeSide.SOUTH:
		var step_x: int = 1 if _batch_build_end_grid.x >= _batch_build_start_grid.x else -1
		for x in range(_batch_build_start_grid.x, _batch_build_end_grid.x + step_x, step_x):
			positions.append(Vector3i(x, _batch_build_start_grid.y, level))
	else:
		var step_y: int = 1 if _batch_build_end_grid.y >= _batch_build_start_grid.y else -1
		for y in range(_batch_build_start_grid.y, _batch_build_end_grid.y + step_y, step_y):
			positions.append(Vector3i(_batch_build_start_grid.x, y, level))
	return positions


func _get_demolish_batch_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if _batch_build_edge == BuildSystem.DEMOLISH_FLOOR_EDGE:
		for grid_pos in _get_floor_batch_positions():
			entries.append({
				"grid_pos": grid_pos,
				"edge": BuildSystem.DEMOLISH_FLOOR_EDGE,
			})
	else:
		for grid_pos in _get_wall_batch_positions():
			entries.append({
				"grid_pos": grid_pos,
				"edge": _batch_build_edge,
			})
	return entries


func _update_batch_build_text() -> void:
	if _batch_build_mode == BuildSystem.BuildMode.FLOOR:
		var width: int = absi(_batch_build_end_grid.x - _batch_build_start_grid.x) + 1
		var length: int = absi(_batch_build_end_grid.y - _batch_build_start_grid.y) + 1
		if _hud != null and _hud.has_method("show_build_drag_info"):
			_hud.show_build_drag_info("Floors: %dx%d (%d) - relache pour construire" % [width, length, width * length])
		BuildSystem.show_batch_floor_preview(_batch_build_target, _get_floor_batch_positions())
	elif _batch_build_mode == BuildSystem.BuildMode.CEILING:
		var cwidth: int = absi(_batch_build_end_grid.x - _batch_build_start_grid.x) + 1
		var clength: int = absi(_batch_build_end_grid.y - _batch_build_start_grid.y) + 1
		if _hud != null and _hud.has_method("show_build_drag_info"):
			_hud.show_build_drag_info("Plafonds: %dx%d (%d) - relache pour construire" % [cwidth, clength, cwidth * clength])
		BuildSystem.show_batch_ceiling_preview(_batch_build_target, _get_floor_batch_positions())
	elif _batch_build_mode == BuildSystem.BuildMode.ITEM:
		var count: int = _get_wall_batch_positions().size()
		if _hud != null and _hud.has_method("show_build_drag_info"):
			_hud.show_build_drag_info("Walls: 1x%d - relache pour construire" % count)
		BuildSystem.show_batch_wall_preview(_batch_build_target, _get_wall_batch_positions(), _batch_build_edge)
	elif _batch_build_mode == BuildSystem.BuildMode.DEMOLISH:
		var demolish_entries: Array[Dictionary] = _get_demolish_batch_entries()
		if _hud != null and _hud.has_method("show_build_drag_info"):
			if _batch_build_edge == BuildSystem.DEMOLISH_FLOOR_EDGE:
				var demolish_width: int = absi(_batch_build_end_grid.x - _batch_build_start_grid.x) + 1
				var demolish_length: int = absi(_batch_build_end_grid.y - _batch_build_start_grid.y) + 1
				_hud.show_build_drag_info("Demolish floors: %dx%d (%d) - relache pour casser" % [demolish_width, demolish_length, demolish_entries.size()])
			else:
				_hud.show_build_drag_info("Demolish walls: %d - relache pour casser" % demolish_entries.size())
		BuildSystem.show_batch_demolish_preview(_batch_build_target, demolish_entries)


func _cancel_batch_build() -> void:
	_batch_build_active = false
	_batch_build_mode = BuildSystem.BuildMode.OFF
	_batch_build_target = null
	_batch_build_start_grid = Vector3i.ZERO
	_batch_build_end_grid = Vector3i.ZERO
	_batch_build_edge = BuildSystem.EdgeSide.NONE
	BuildSystem.clear_batch_preview()
	if _hud != null and _hud.has_method("hide_build_drag_info"):
		_hud.hide_build_drag_info()


func _detect_edge_from_hit_for_batch(target: Node, hit_point: Vector3, grid_pos: Vector3i) -> int:
	var hit_local: Vector3 = target.to_local(hit_point)
	var cell_center: Vector3 = target.grid_to_local(grid_pos)
	var local_offset: Vector3 = hit_local - cell_center
	local_offset.y = 0.0
	if local_offset.length_squared() < 0.0001:
		return BuildSystem.EdgeSide.NORTH
	if absf(local_offset.x) > absf(local_offset.z):
		return BuildSystem.EdgeSide.EAST if local_offset.x > 0.0 else BuildSystem.EdgeSide.WEST
	return BuildSystem.EdgeSide.SOUTH if local_offset.z > 0.0 else BuildSystem.EdgeSide.NORTH


func _edge_hit_point(target: Node, grid_pos: Vector3i, edge: int) -> Vector3:
	var local_pos: Vector3 = target.grid_to_local(grid_pos)
	match edge:
		BuildSystem.EdgeSide.NORTH:
			local_pos.z -= 0.45
		BuildSystem.EdgeSide.SOUTH:
			local_pos.z += 0.45
		BuildSystem.EdgeSide.EAST:
			local_pos.x += 0.45
		BuildSystem.EdgeSide.WEST:
			local_pos.x -= 0.45
	return target.to_global(local_pos)


func _update_build_preview() -> void:
	var hit := _camera_ray(BUILD_RAY_LENGTH, BUILD_COLLISION_MASK)
	var hit_point: Vector3 = Vector3.ZERO
	var hit_normal: Vector3 = Vector3.UP
	var collider: Object = null
	if not hit.is_empty():
		hit_point = hit["position"]
		hit_normal = hit["normal"]
		collider = hit["collider"]

	# CEILING fallback: if nothing hit (looking up), use wagon/chassis underfoot.
	if BuildSystem.mode == BuildSystem.BuildMode.CEILING:
		var ceil_target: Node = _find_build_target(collider as Node) if collider != null else null
		if ceil_target == null:
			ceil_target = _find_wagon_underfoot()
		if ceil_target != null and ceil_target.has_method("get_ceiling_surface_local_y"):
			var ceil_ref: Variant = hit_point if not hit.is_empty() else null
			var p_ceil: Variant = _get_build_point_on_target(ceil_target, ceil_ref, 1)
			if p_ceil is Vector3:
				BuildSystem.update_preview_on_target(p_ceil, ceil_target.get_build_surface_normal_world(), ceil_target)
				return
		BuildSystem.hide_preview()
		return

	if hit.is_empty() or collider == null:
		BuildSystem.hide_preview()
		return

	match BuildSystem.mode:
		BuildSystem.BuildMode.CHASSIS:
			BuildSystem.update_preview_on_ground(hit_point, hit_normal)
		BuildSystem.BuildMode.FLOOR, BuildSystem.BuildMode.CEILING, BuildSystem.BuildMode.ITEM:
			var target := _find_build_target(collider as Node)
			if target:
				var p: Variant = _get_build_point_on_target(target, hit_point)
				if p is Vector3:
					hit_point = p
					hit_normal = target.get_build_surface_normal_world()
				BuildSystem.update_preview_on_target(hit_point, hit_normal, target)
			else:
				BuildSystem.hide_preview()
		BuildSystem.BuildMode.DEMOLISH:
			var hit_chassis := _find_chassis(collider as Node)
			if hit_chassis != null:
				BuildSystem.update_train_demolish_preview(hit_chassis)
				return
			var target2 := _find_build_target(collider as Node)
			if target2:
				var p2: Variant = _get_build_point_on_target(target2, hit_point)
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
	var hit_chassis := _find_chassis(node)
	if hit_chassis != null:
		BuildSystem.try_demolish_train_part(hit_chassis)
		return
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


func _get_build_point_on_target(target: Node, reference_world_point: Variant = null, level_offset: int = 0) -> Variant:
	var origin: Vector3 = _camera.global_transform.origin
	var dir: Vector3 = -_camera.global_transform.basis.z
	if dir.length_squared() < 0.0001:
		return null
	dir = dir.normalized()
	if not (target is WagonFrame or target is TrainChassis):
		return null
	var ref_local: Vector3
	if reference_world_point is Vector3:
		ref_local = target.to_local(reference_world_point)
	else:
		ref_local = target.to_local(_fps.global_position)
	var level: int = target.detect_level_from_local_y(ref_local.y) + level_offset
	if level < 0:
		level = 0
	var surface_y: float = target.get_surface_local_y(level)
	var plane_point: Vector3 = target.to_global(Vector3(0.0, surface_y, 0.0))
	var plane_normal: Vector3 = target.get_build_surface_normal_world()
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
		_clear_hovered_switch()
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
			if collider is RailSwitch:
				_set_hovered_switch(collider as RailSwitch)
			else:
				_clear_hovered_switch()
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
	_clear_hovered_switch()
	_hud.hide_interact_hint()


func _exit_tree() -> void:
	_clear_hovered_switch()


func _set_hovered_switch(rail_switch: RailSwitch) -> void:
	if _hovered_switch == rail_switch:
		return
	_clear_hovered_switch()
	_hovered_switch = rail_switch
	if _hovered_switch != null and is_instance_valid(_hovered_switch):
		_hovered_switch.set_hovered(true)


func _clear_hovered_switch() -> void:
	if _hovered_switch != null and is_instance_valid(_hovered_switch):
		_hovered_switch.set_hovered(false)
	_hovered_switch = null

func _get_target_display_name(hit: Dictionary) -> String:
	var collider: Object = hit.get("collider")
	if collider == null or not (collider is Node):
		return ""
	if collider.has_method("get_target_name_at"):
		var target_name: String = collider.get_target_name_at(hit)
		if not target_name.is_empty():
			return target_name
		return ""
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
	if GAME_AMBIENT_NAME.is_empty():
		return
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


func _set_player_controllable(enabled: bool) -> void:
	if _fps == null:
		return
	if _fps is UP_PlayerBase:
		(_fps as UP_PlayerBase).controllable = enabled


func _on_game_state_changed(new_state: int) -> void:
	if new_state == GameManager.GameState.PAUSED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_set_player_look_enabled(false)
		_set_player_controllable(false)
	elif new_state == GameManager.GameState.PLAYING:
		if _is_inventory_open() or _is_build_menu_open():
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			_set_player_look_enabled(false)
			_set_player_controllable(false)
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_set_player_look_enabled(true)
			_set_player_controllable(true)


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

func _is_chat_open() -> bool:
	if _hud == null or not _hud.has_method("is_chat_open"):
		return false
	return _hud.is_chat_open()


func _controls_blocked() -> bool:
	return GameManager.current_state == GameManager.GameState.PAUSED or _is_chat_open()


func _apply_blocked_controls() -> bool:
	if not _controls_blocked():
		if _controls_were_blocked and not _is_inventory_open() and not _is_build_menu_open():
			_set_player_look_enabled(true)
			_set_player_controllable(true)
		_controls_were_blocked = false
		return false
	if not _controls_were_blocked:
		_set_player_controllable(false)
		_controls_were_blocked = true
	_update_wagon_platform(get_physics_process_delta_time())
	if _fps.is_on_floor() and _fps.velocity.y <= 0.0:
		_fps.velocity.x = 0.0
		_fps.velocity.z = 0.0
	_set_player_look_enabled(false)
	return true


func _is_build_menu_open() -> bool:
	var bm: Node = _hud.get_node_or_null("BuildMenu") if _hud else null
	return bm != null and bm.visible


func _update_wagon_platform(delta: float) -> void:
	var current_wagon := _find_wagon_underfoot()
	if current_wagon != _wagon_platform:
		if _wagon_platform != null and current_wagon == null:
			_fps.velocity.x += _platform_velocity_carry.x
			_fps.velocity.z += _platform_velocity_carry.z
		_wagon_platform = current_wagon
		_platform_velocity_carry = Vector3.ZERO
		if _wagon_platform != null and is_instance_valid(_wagon_platform):
			_last_wagon_transform = _wagon_platform.global_transform
		else:
			_last_wagon_transform = Transform3D.IDENTITY
		return
	if _wagon_platform == null:
		_last_wagon_transform = Transform3D.IDENTITY
		_platform_velocity_carry = Vector3.ZERO
		return
	if not is_instance_valid(_wagon_platform):
		_wagon_platform = null
		_last_wagon_transform = Transform3D.IDENTITY
		_platform_velocity_carry = Vector3.ZERO
		return
	var current_transform: Transform3D = _wagon_platform.global_transform
	var previous_transform: Transform3D = _last_wagon_transform
	var local_pos: Vector3 = previous_transform.affine_inverse() * _fps.global_position
	var target_pos: Vector3 = current_transform * local_pos
	if delta > 0.0:
		_platform_velocity_carry = (target_pos - _fps.global_position) / delta
	_fps.global_position = target_pos
	var old_fwd: Vector3 = previous_transform.basis.orthonormalized().z
	var new_fwd: Vector3 = current_transform.basis.orthonormalized().z
	old_fwd.y = 0.0
	new_fwd.y = 0.0
	if old_fwd.length_squared() > 0.0001 and new_fwd.length_squared() > 0.0001:
		var angle := old_fwd.signed_angle_to(new_fwd, Vector3.UP)
		if absf(angle) > 0.0001:
			_fps.rotate_y(angle)
	_last_wagon_transform = current_transform


func _find_wagon_underfoot() -> Node3D:
	if _fps == null:
		return null
	if not _fps.is_on_floor() and _wagon_platform == null:
		return _find_wagon_below_player()
	var from := _fps.global_position + Vector3.UP * 0.3
	var to := _fps.global_position + Vector3.DOWN * 1.8
	var query := PhysicsRayQueryParameters3D.create(from, to, BUILD_COLLISION_MASK)
	query.exclude = [_fps.get_rid()]
	var hit := _fps.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return _wagon_platform if _wagon_platform != null and is_instance_valid(_wagon_platform) else _find_wagon_below_player()
	var collider: Variant = hit.get("collider", null)
	if collider == null or not (collider is Node):
		return _wagon_platform if _wagon_platform != null and is_instance_valid(_wagon_platform) else _find_wagon_below_player()
	var found := _find_wagon_parent(collider as Node)
	if found != null:
		return found
	return _find_wagon_below_player()


func _find_wagon_below_player() -> Node3D:
	# Longer downward probe against train/build layers; covers cases where
	# is_on_floor is false (train moving) and _wagon_platform is not tracked.
	if _fps == null:
		return null
	var from := _fps.global_position + Vector3.UP * 0.5
	var to := _fps.global_position + Vector3.DOWN * 4.0
	var query := PhysicsRayQueryParameters3D.create(from, to, BUILD_COLLISION_MASK)
	query.exclude = [_fps.get_rid()]
	var hit := _fps.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	var collider: Variant = hit.get("collider", null)
	if collider == null or not (collider is Node):
		return null
	return _find_wagon_parent(collider as Node)


func _find_wagon_parent(node: Node) -> Node3D:
	var current: Node = node
	while current != null:
		if current is WagonFrame:
			return current as Node3D
		if current is TrainChassis:
			var parent := current.get_parent()
			if parent is WagonFrame:
				return parent as Node3D
			return current as Node3D
		current = current.get_parent()
	return null


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
	_ignore_shoot_until_msec = Time.get_ticks_msec() + 250
	_close_build_menu()


func _on_build_mode_selected(mode: int) -> void:
	BuildSystem.set_mode(mode)
	_ignore_shoot_until_msec = Time.get_ticks_msec() + 250
	_close_build_menu()


func _on_build_exit_requested() -> void:
	_cancel_batch_build()
	var bm: Node = _hud.get_node_or_null("BuildMenu")
	if bm:
		bm.hide_menu()
	BuildSystem.exit_build_mode()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_set_player_look_enabled(true)
