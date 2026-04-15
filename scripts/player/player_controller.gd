extends CharacterBody3D

const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 8.0
const JUMP_VELOCITY: float = 5.0
const MOUSE_SENSITIVITY: float = 0.002
const GAME_AMBIENT_NAME: String = "train_ambience"

@onready var camera: Camera3D = $Head/Camera3D
@onready var head: Node3D = $Head
@onready var interact_ray: RayCast3D = $Head/Camera3D/InteractRay
@onready var build_ray: RayCast3D = $Head/Camera3D/BuildRay
@onready var weapon_holder: Node3D = $Head/Camera3D/WeaponHolder
@onready var hud: Control = $HUD
@onready var name_label: Label3D = $NameLabel
@onready var visual_root: Node3D = $VisualRoot

var current_speed: float = WALK_SPEED
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var current_weapon: Node3D = null
var is_local: bool = false
var display_name: String = ""
var _ambient_timer: float = 0.0
var _controls_locked_position: Vector3 = Vector3.ZERO
var _controls_were_locked: bool = false

func _enter_tree() -> void:
	if not multiplayer.has_multiplayer_peer():
		is_local = true
	else:
		var my_id := multiplayer.get_unique_id()
		is_local = name == str(my_id) or name == "Player_%d" % my_id

func _ready() -> void:
	add_to_group("player")
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_display_name()
	_update_visual_visibility()

	if not is_local:
		camera.current = false
		set_physics_process(false)
		set_process_unhandled_input(false)
		hud.visible = false
		name_label.visible = true
		return

	camera.current = true
	hud.visible = true
	name_label.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	GraphicsSettings.set_fov_on_camera(camera)
	hud.settings_menu.closed.connect(func():
		if GameManager.current_state == GameManager.GameState.PLAYING:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		GraphicsSettings.set_fov_on_camera(camera)
	)
	GameManager.game_state_changed.connect(_on_game_state_changed)

	# Connect build menu signals
	hud.build_menu.item_selected.connect(_on_build_item_selected)
	hud.build_menu.mode_selected.connect(_on_build_mode_selected)
	hud.build_menu.exit_build_requested.connect(_on_build_exit_requested)
	hud.build_menu.close_requested.connect(_close_build_menu)

func _process(_delta: float) -> void:
	_update_visual_rotation()

func _unhandled_input(event: InputEvent) -> void:
	if not is_local:
		return
	if _controls_blocked():
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			Inventory.cycle_hotbar(-1)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			Inventory.cycle_hotbar(1)
			return

	if event is InputEventKey and event.pressed and not event.echo:
		var hotbar_index := _hotbar_index_from_key(event.keycode)
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
					hud.select_previous_recipe()
				KEY_RIGHT, KEY_D:
					hud.select_next_recipe()
				KEY_ENTER, KEY_KP_ENTER, KEY_F:
					hud.craft_selected_recipe()
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		head.rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		camera.rotation.x = clampf(camera.rotation.x, deg_to_rad(-89), deg_to_rad(89))

	if event.is_action_pressed("build_mode"):
		if BuildSystem.is_building:
			if hud.build_menu.visible:
				_close_build_menu()
			else:
				_open_build_menu()
		else:
			BuildSystem.enter_build_mode()
			_open_build_menu()

	if event is InputEventKey and event.pressed and event.keycode == KEY_F10:
		_toggle_settings_menu()
		return

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if hud.build_menu.visible:
			_close_build_menu()
		elif BuildSystem.is_building:
			_on_build_exit_requested()

	if event.is_action_pressed("aim"):
		if hud.build_menu.visible:
			_close_build_menu()
		elif BuildSystem.is_building:
			_on_build_exit_requested()

	if event.is_action_pressed("interact"):
		_try_interact()

	if event.is_action_pressed("shoot"):
		if _is_inventory_open():
			return
		if hud.build_menu.visible:
			return
		if BuildSystem.is_building:
			_try_build()
		else:
			_try_shoot()

	if event.is_action_pressed("reload") and current_weapon and current_weapon.has_method("reload"):
		current_weapon.reload()

func _physics_process(delta: float) -> void:
	if not is_local:
		return
	if _lock_position_while_blocked():
		return

	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (head.global_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if direction:
		velocity.x = direction.x * current_speed
		velocity.z = direction.z * current_speed
	else:
		velocity.x = move_toward(velocity.x, 0, current_speed)
		velocity.z = move_toward(velocity.z, 0, current_speed)

	move_and_slide()

	if BuildSystem.is_building:
		_update_build_preview()

	_update_interact_hint()
	_update_ambient()

func _update_ambient() -> void:
	_ambient_timer += get_physics_process_delta_time()
	if _ambient_timer < 1.0:
		return
	_ambient_timer = 0.0
	AudioManager.play_ambient(GAME_AMBIENT_NAME)

func _try_interact() -> void:
	if not interact_ray.is_colliding():
		return
	var collider: Object = interact_ray.get_collider()
	if collider and collider.has_method("interact"):
		collider.interact(self)

func _try_shoot() -> void:
	if current_weapon and current_weapon.has_method("shoot"):
		current_weapon.shoot()

func _try_build() -> void:
	if not build_ray.is_colliding():
		return
	var hit_point := build_ray.get_collision_point()
	var collider: Object = build_ray.get_collider()
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
			var target := _find_build_target(collider as Node)
			if target:
				var p: Variant = _get_build_point_on_target(target)
				if p is Vector3:
					hit_point = p
				BuildSystem.try_place_item(hit_point, target)
		BuildSystem.BuildMode.DEMOLISH:
			var target := _find_build_target(collider as Node)
			if target:
				var p: Variant = _get_build_point_on_target(target)
				if p is Vector3:
					hit_point = p
				BuildSystem.try_demolish(hit_point, target)

func _update_build_preview() -> void:
	if not build_ray.is_colliding():
		BuildSystem.hide_preview()
		return
	var hit_point := build_ray.get_collision_point()
	var hit_normal := build_ray.get_collision_normal()
	var collider: Object = build_ray.get_collider()
	if collider == null:
		BuildSystem.hide_preview()
		return

	match BuildSystem.mode:
		BuildSystem.BuildMode.CHASSIS:
			if collider.is_in_group("ground"):
				BuildSystem.update_preview_on_ground(hit_point, hit_normal)
			else:
				BuildSystem.hide_preview()
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
			var target := _find_build_target(collider as Node)
			if target:
				var p: Variant = _get_build_point_on_target(target)
				if p is Vector3:
					hit_point = p
					hit_normal = target.get_build_surface_normal_world()
				BuildSystem.update_preview_on_target(hit_point, hit_normal, target)
			else:
				BuildSystem.hide_preview()
		_:
			BuildSystem.hide_preview()

func _find_build_target(node: Node) -> Node:
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

func _on_game_state_changed(new_state: int) -> void:
	if new_state == GameManager.GameState.PAUSED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif new_state == GameManager.GameState.PLAYING:
		if hud.build_menu.visible or hud.settings_menu.visible or _is_chat_open():
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _get_build_point_on_target(target: Node) -> Variant:
	var origin: Vector3 = build_ray.global_transform.origin
	var dir: Vector3 = -build_ray.global_transform.basis.z
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
	return _ray_plane_intersection(origin, dir, plane_point, plane_normal, build_ray.target_position.length() + 0.25)

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

func _open_build_menu() -> void:
	hud.build_menu.show_menu()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	BuildSystem.hide_preview()

func _close_build_menu() -> void:
	hud.build_menu.hide_menu()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _toggle_settings_menu() -> void:
	if hud.settings_menu.visible:
		hud.settings_menu._close()
	else:
		hud.settings_menu.open()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

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
	return hud != null and hud.has_method("is_inventory_open") and hud.is_inventory_open()

func _is_chat_open() -> bool:
	return hud != null and hud.has_method("is_chat_open") and hud.is_chat_open()

func _controls_blocked() -> bool:
	return GameManager.current_state == GameManager.GameState.PAUSED or _is_chat_open()

func _lock_position_while_blocked() -> bool:
	if not _controls_blocked():
		_controls_were_locked = false
		return false
	if not _controls_were_locked:
		_controls_locked_position = global_position
		_controls_were_locked = true
	global_position = _controls_locked_position
	velocity = Vector3.ZERO
	BuildSystem.hide_preview()
	return true

func set_display_name(new_name: String) -> void:
	display_name = new_name.strip_edges()
	_apply_display_name()

func _apply_display_name() -> void:
	if name_label == null:
		return
	var label_text := display_name
	if label_text.is_empty() and multiplayer.has_multiplayer_peer():
		var peer_id := _peer_id_from_name()
		if NetworkManager.players_info.has(peer_id):
			label_text = String(NetworkManager.players_info[peer_id].get("name", "Player %d" % peer_id))
	if label_text.is_empty():
		label_text = "Player"
	name_label.text = label_text

func _peer_id_from_name() -> int:
	if name.begins_with("Player_"):
		return int(name.substr("Player_".length()))
	if name.is_valid_int():
		return int(name)
	return 1

func _update_visual_visibility() -> void:
	if visual_root == null:
		return
	visual_root.visible = not is_local

func _update_visual_rotation() -> void:
	if visual_root == null or head == null:
		return
	visual_root.rotation.y = head.rotation.y

func _toggle_inventory_panel() -> void:
	if hud == null or not hud.has_method("toggle_inventory_panel"):
		return
	var open: bool = hud.toggle_inventory_panel()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	BuildSystem.hide_preview()

func _on_build_item_selected(buildable_id: String) -> void:
	BuildSystem.select_buildable(buildable_id)
	_close_build_menu()

func _on_build_mode_selected(mode: int) -> void:
	BuildSystem.set_mode(mode)
	_close_build_menu()

func _on_build_exit_requested() -> void:
	hud.build_menu.hide_menu()
	BuildSystem.exit_build_mode()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _update_interact_hint() -> void:
	if interact_ray.is_colliding():
		var collider: Object = interact_ray.get_collider()
		if collider and collider.has_method("interact"):
			if collider is PumpLever:
				hud.show_interact_hint("[E] Pump")
			elif collider is Harvestable:
				hud.show_interact_hint("[E] Harvest")
			else:
				hud.show_interact_hint("[E] Interact")
			return
	hud.hide_interact_hint()

func _find_wagon_parent(node: Node) -> Node3D:
	var current: Node = node
	while current:
		if current.is_in_group("wagon"):
			return current as Node3D
		current = current.get_parent()
	return null
