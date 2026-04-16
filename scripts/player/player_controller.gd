extends CharacterBody3D

const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 8.0
const CROUCH_SPEED: float = 2.5
const JUMP_VELOCITY: float = 5.0
const JUMP_VELOCITY_SPRINT: float = 5.5
const MOUSE_SENSITIVITY: float = 0.002
const ACCEL: float = 0.8
const FRICTION: float = 0.2
const CROUCH_HEIGHT_FACTOR: float = 0.6
const CROUCH_CAMERA_LERP_SPEED: float = 10.0
const GAME_AMBIENT_NAME: String = "train_ambience"
const BOB_WALK_STRENGTH: float = 0.03
const BOB_SPRINT_STRENGTH: float = 0.05
const BOB_CROUCH_STRENGTH: float = 0.015
const BOB_WALK_FREQ: float = 10.0
const BOB_SPRINT_FREQ: float = 14.0
const BOB_CROUCH_FREQ: float = 6.0
const BOB_IDLE_STRENGTH: float = 0.003
const BOB_IDLE_FREQ: float = 1.5

@onready var camera: Camera3D = $Head/Camera3D
@onready var head: Node3D = $Head
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var interact_ray: RayCast3D = $Head/Camera3D/InteractRay
@onready var build_ray: RayCast3D = $Head/Camera3D/BuildRay
@onready var weapon_holder: Node3D = $Head/Camera3D/WeaponHolder
@onready var hud: Control = $HUD
@onready var name_label: Label3D = $NameLabel
@onready var visual_root: Node3D = $VisualRoot
@onready var multiplayer_sync: MultiplayerSynchronizer = $MultiplayerSynchronizer

var current_speed: float = WALK_SPEED
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var current_weapon: Node3D = null
var is_local: bool = false
var display_name: String = ""
var _ambient_timer: float = 0.0
var _is_crouching: bool = false
var _is_sprinting: bool = false
var _default_head_y: float = 0.0
var _target_head_y: float = 0.0
var _default_collision_height: float = 0.0
var _bob_time: float = 0.0
var _camera_default_y: float = 0.0
var _camera_default_x: float = 0.0
var _camera_default_roll: float = 0.0
var _camera_default_fov: float = 0.0
var _wagon_platform: Node3D = null
var _last_wagon_basis: Basis = Basis.IDENTITY
var _remote_target_position: Vector3 = Vector3.ZERO
var _remote_target_head_yaw: float = 0.0
var _remote_target_camera_pitch: float = 0.0
var _remote_state_initialized: bool = false

func _enter_tree() -> void:
	is_local = not multiplayer.has_multiplayer_peer() or get_multiplayer_authority() == multiplayer.get_unique_id()

func _ready() -> void:
	add_to_group("player")
	if multiplayer_sync != null:
		multiplayer_sync.set_multiplayer_authority(get_multiplayer_authority())
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
	AudioManager.play_ambient(GAME_AMBIENT_NAME)
	_default_head_y = head.position.y
	_target_head_y = _default_head_y
	_camera_default_x = camera.position.x
	_camera_default_y = camera.position.y
	_camera_default_roll = camera.rotation.z
	_camera_default_fov = camera.fov
	floor_snap_length = 0.3
	if collision_shape and collision_shape.shape is CapsuleShape3D:
		_default_collision_height = collision_shape.shape.height
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
	_broadcast_network_state()

func _process(delta: float) -> void:
	if not is_local and _remote_state_initialized:
		global_position = global_position.lerp(_remote_target_position, clampf(delta * 12.0, 0.0, 1.0))
		head.rotation.y = lerp_angle(head.rotation.y, _remote_target_head_yaw, clampf(delta * 14.0, 0.0, 1.0))
		camera.rotation.x = lerp_angle(camera.rotation.x, _remote_target_camera_pitch, clampf(delta * 14.0, 0.0, 1.0))
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

	if event.is_action_pressed("drop_item"):
		_try_drop_item()

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
	if _apply_blocked_movement(delta):
		return

	if not is_on_floor():
		velocity.y -= gravity * delta

	_is_sprinting = Input.is_action_pressed("sprint") and not _is_crouching
	if Input.is_action_just_pressed("crouch"):
		_is_crouching = not _is_crouching
		_update_crouch_state()

	if _is_crouching:
		current_speed = CROUCH_SPEED
	elif _is_sprinting:
		current_speed = SPRINT_SPEED
	else:
		current_speed = WALK_SPEED

	if Input.is_action_just_pressed("jump") and is_on_floor() and not _is_crouching:
		velocity.y = JUMP_VELOCITY_SPRINT if _is_sprinting else JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (head.global_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if is_on_floor():
		if direction:
			velocity.x = lerpf(velocity.x, direction.x * current_speed, 10.0 * ACCEL * delta)
			velocity.z = lerpf(velocity.z, direction.z * current_speed, 10.0 * ACCEL * delta)
		else:
			velocity.x = lerpf(velocity.x, 0.0, FRICTION) if absf(velocity.x) > 0.05 else 0.0
			velocity.z = lerpf(velocity.z, 0.0, FRICTION) if absf(velocity.z) > 0.05 else 0.0
	else:
		if direction:
			velocity.x = lerpf(velocity.x, direction.x * current_speed, 2.0 * delta)
			velocity.z = lerpf(velocity.z, direction.z * current_speed, 2.0 * delta)

	head.position.y = lerpf(head.position.y, _target_head_y, CROUCH_CAMERA_LERP_SPEED * delta)
	move_and_slide()
	_update_wagon_platform(delta)
	_update_head_bob(delta, direction.length() > 0.1)
	_broadcast_network_state()

	if BuildSystem.is_building:
		_update_build_preview()

	_update_interact_hint()
	_update_ambient()

func _update_crouch_state() -> void:
	if _is_crouching:
		_target_head_y = _default_head_y * CROUCH_HEIGHT_FACTOR
		if collision_shape and collision_shape.shape is CapsuleShape3D and _default_collision_height > 0.0:
			collision_shape.shape.height = _default_collision_height * 0.5
			collision_shape.position.y = collision_shape.shape.height * 0.5
	else:
		_target_head_y = _default_head_y
		if collision_shape and collision_shape.shape is CapsuleShape3D and _default_collision_height > 0.0:
			collision_shape.shape.height = _default_collision_height
			collision_shape.position.y = collision_shape.shape.height * 0.5

func _update_head_bob(delta: float, is_moving: bool) -> void:
	var bob_strength: float
	var bob_freq: float
	if is_moving and is_on_floor():
		if _is_sprinting:
			bob_strength = BOB_SPRINT_STRENGTH
			bob_freq = BOB_SPRINT_FREQ
		elif _is_crouching:
			bob_strength = BOB_CROUCH_STRENGTH
			bob_freq = BOB_CROUCH_FREQ
		else:
			bob_strength = BOB_WALK_STRENGTH
			bob_freq = BOB_WALK_FREQ
		_bob_time += delta * bob_freq
	else:
		bob_strength = BOB_IDLE_STRENGTH
		bob_freq = BOB_IDLE_FREQ
		_bob_time += delta * bob_freq
	var bob_y := sin(_bob_time) * bob_strength
	var bob_x := cos(_bob_time * 0.5) * bob_strength * 0.5
	var bob_roll := sin(_bob_time * 0.5) * bob_strength * 0.25
	var target_fov := _camera_default_fov + (3.0 if _is_sprinting and is_moving and is_on_floor() else 0.0)
	camera.position.y = lerpf(camera.position.y, _camera_default_y + bob_y, 10.0 * delta)
	camera.position.x = lerpf(camera.position.x, _camera_default_x + bob_x, 10.0 * delta)
	camera.rotation.z = lerpf(camera.rotation.z, _camera_default_roll + bob_roll, 10.0 * delta)
	camera.fov = lerpf(camera.fov, target_fov, 8.0 * delta)

func _update_wagon_platform(delta: float) -> void:
	var current_wagon: Node3D = null
	if is_on_floor():
		for i in range(get_slide_collision_count()):
			var col := get_slide_collision(i)
			var collider := col.get_collider()
			if collider:
				var wagon := _find_wagon_parent(collider as Node)
				if wagon:
					current_wagon = wagon
					break
	if current_wagon != _wagon_platform:
		_wagon_platform = current_wagon
		if _wagon_platform:
			_last_wagon_basis = _wagon_platform.global_basis
	if _wagon_platform and is_instance_valid(_wagon_platform):
		var current_basis := _wagon_platform.global_basis
		var old_fwd := _last_wagon_basis.z
		var new_fwd := current_basis.z
		old_fwd.y = 0.0
		new_fwd.y = 0.0
		if old_fwd.length_squared() > 0.0001 and new_fwd.length_squared() > 0.0001:
			var angle := old_fwd.signed_angle_to(new_fwd, Vector3.UP)
			if absf(angle) > 0.0001:
				head.rotate_y(angle)
		_last_wagon_basis = current_basis

func _update_ambient() -> void:
	_ambient_timer += get_physics_process_delta_time()
	if _ambient_timer < 1.0:
		return
	_ambient_timer = 0.0
	AudioManager.play_ambient(GAME_AMBIENT_NAME)


func _broadcast_network_state() -> void:
	if not is_local or not multiplayer.has_multiplayer_peer():
		return
	_receive_network_state.rpc(global_position, head.rotation.y, camera.rotation.x)


@rpc("any_peer", "unreliable")
func _receive_network_state(pos: Vector3, head_yaw: float, camera_pitch: float) -> void:
	if is_local:
		return
	_remote_target_position = pos
	_remote_target_head_yaw = head_yaw
	_remote_target_camera_pitch = camera_pitch
	if not _remote_state_initialized:
		_remote_state_initialized = true
		global_position = pos
		head.rotation.y = head_yaw
		camera.rotation.x = camera_pitch

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

func _apply_blocked_movement(delta: float) -> bool:
	if not _controls_blocked():
		return false
	velocity.x = move_toward(velocity.x, 0.0, current_speed)
	velocity.z = move_toward(velocity.z, 0.0, current_speed)
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = minf(velocity.y, 0.0)
	move_and_slide()
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
			elif collider.is_in_group("dropped_item"):
				hud.show_interact_hint("[E] Ramasser")
			else:
				hud.show_interact_hint("[E] Interact")
			return
	hud.hide_interact_hint()

func _try_drop_item() -> void:
	var slot_index := Inventory.selected_hotbar_index
	var slot := Inventory.get_slot_data(slot_index)
	if slot.item_id == "" or int(slot.amount) <= 0:
		return
	var drop_pos := global_position + head.global_basis * Vector3(0, 0, -1.5)
	Inventory.drop_slot(slot_index, -1, drop_pos)

func _find_wagon_parent(node: Node) -> Node3D:
	var current: Node = node
	while current:
		if current.is_in_group("wagon"):
			return current as Node3D
		current = current.get_parent()
	return null
