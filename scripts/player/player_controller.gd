extends CharacterBody3D

const FootstepAudioHelper = preload("res://scripts/player/footstep_audio.gd")

const WALK_SPEED: float = 3.4
const SPRINT_SPEED: float = 5.4
const CROUCH_SPEED: float = 1.8
const JUMP_VELOCITY: float = 4.0
const JUMP_VELOCITY_SPRINT: float = 4.3
const MOUSE_SENSITIVITY: float = 0.002
const ACCEL: float = 0.8
const FRICTION: float = 0.2
const CROUCH_HEIGHT_FACTOR: float = 0.6
const CROUCH_CAMERA_LERP_SPEED: float = 10.0
const GAME_AMBIENT_NAME: String = ""
const BOB_WALK_STRENGTH: float = 0.03
const BOB_SPRINT_STRENGTH: float = 0.05
const BOB_CROUCH_STRENGTH: float = 0.015
const BOB_WALK_FREQ: float = 10.0
const BOB_SPRINT_FREQ: float = 14.0
const BOB_CROUCH_FREQ: float = 6.0
const BOB_IDLE_STRENGTH: float = 0.003
const BOB_IDLE_FREQ: float = 1.5
const PLAYER_SYNC_INTERVAL: float = 0.033
const FOOTSTEP_WALK_INTERVAL: float = 0.46
const FOOTSTEP_SPRINT_INTERVAL: float = 0.32
const FOOTSTEP_CROUCH_INTERVAL: float = 0.62
const BUILD_COLLISION_MASK: int = 153  # World (1) + Train (8) + built placeables (16) + BuildDetect (128)
const MAX_WALKABLE_SLOPE_DEGREES: float = 55.0
const WALKABLE_FLOOR_SNAP_LENGTH: float = 0.6
const WALKABLE_PLATFORM_LAYERS: int = 24  # Train floor (8) + built placeables (16)
const PLAYER_REMOTE_EXTRAPOLATION: float = 0.12
const PLAYER_ANIM_IDLE: String = "idle"
const PLAYER_ANIM_WALK: String = "walk"
const PLAYER_ANIM_RUN: String = "run"
const PLAYER_ANIM_JUMP: String = "jump"
const PLAYER_ANIM_CROUCH: String = "crouch"
const PLAYER_ANIM_BLEND: float = 0.16
const PLAYER_ANIM_WALK_SPEED: float = 0.35
const PLAYER_ANIM_RUN_SPEED: float = 4.4
const PLAYER_ANIM_AIR_SPEED: float = 0.45
const WEAPON_VIEWMODELS: Dictionary = {
	"pistol": "res://scenes/weapons/pistol_viewmodel.tscn",
	"axe": "res://scenes/weapons/axe_viewmodel.tscn",
}

const PLAYER_ANIMATION_SOURCES: Dictionary = {
	PLAYER_ANIM_IDLE: {
		"path": "res://assets/models/player/animations/Idle.glb",
		"loop": true,
	},
	PLAYER_ANIM_WALK: {
		"path": "res://assets/models/player/animations/Walking.glb",
		"loop": true,
	},
	PLAYER_ANIM_RUN: {
		"path": "res://assets/models/player/animations/Run3.glb",
		"loop": true,
	},
	PLAYER_ANIM_JUMP: {
		"path": "res://assets/models/player/animations/JumpRegular.glb",
		"loop": false,
	},
	PLAYER_ANIM_CROUCH: {
		"path": "res://assets/models/player/animations/Crouch.glb",
		"loop": true,
	},
}

@onready var camera: Camera3D = $Head/Camera3D
@onready var head: Node3D = $Head
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var interact_ray: RayCast3D = $Head/Camera3D/InteractRay
@onready var build_ray: RayCast3D = $Head/Camera3D/BuildRay
@onready var viewmodel_viewport: SubViewport = $Head/Camera3D/ViewModelViewport
@onready var viewmodel_camera: Camera3D = $Head/Camera3D/ViewModelViewport/ViewModelCamera
@onready var weapon_holder: Node3D = $Head/Camera3D/ViewModelViewport/ViewModelCamera/WeaponHolder
@onready var viewmodel_canvas: CanvasLayer = $ViewModelCanvas
@onready var viewmodel_display: TextureRect = $ViewModelCanvas/ViewModelDisplay
@onready var name_label: Label3D = $NameLabel
@onready var visual_root: Node3D = $VisualRoot
@onready var multiplayer_sync: MultiplayerSynchronizer = get_node_or_null("MultiplayerSynchronizer") as MultiplayerSynchronizer

var hud: Control = null
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
var _last_wagon_transform: Transform3D = Transform3D.IDENTITY
var _platform_velocity_carry: Vector3 = Vector3.ZERO
var _pitch: float = 0.0
var _remote_target_position: Vector3 = Vector3.ZERO
var _remote_target_head_yaw: float = 0.0
var _remote_target_camera_pitch: float = 0.0
var _remote_velocity: Vector3 = Vector3.ZERO
var _remote_is_crouching: bool = false
var _network_sync_accum: float = 0.0
var _remote_state_initialized: bool = false
var _model_animation_player: AnimationPlayer = null
var _model_animation_library: AnimationLibrary = null
var _current_model_animation: String = ""
var _ignore_shoot_until_msec: int = 0
var _batch_build_active: bool = false
var _batch_build_mode: int = BuildSystem.BuildMode.OFF
var _batch_build_target: Node = null
var _batch_build_start_grid: Vector3i = Vector3i.ZERO
var _batch_build_end_grid: Vector3i = Vector3i.ZERO
var _batch_build_edge: int = BuildSystem.EdgeSide.NONE
var _hovered_switch: RailSwitch = null
var _footstep_timer: float = 0.0
var _debug_cam: Camera3D = null

func _enter_tree() -> void:
	is_local = not multiplayer.has_multiplayer_peer() or get_multiplayer_authority() == multiplayer.get_unique_id()

func _ready() -> void:
	add_to_group("player")
	if multiplayer_sync != null:
		multiplayer_sync.set_multiplayer_authority(get_multiplayer_authority())
	_apply_display_name()
	_update_visual_visibility()
	_setup_player_model_animation()

	if not is_local:
		camera.current = false
		set_process_unhandled_input(false)
		name_label.visible = true
		viewmodel_canvas.visible = false
		viewmodel_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return

	_setup_viewmodel_viewport()
	Inventory.selected_hotbar_changed.connect(_on_selected_hotbar_changed)
	_equip_viewmodel_for_item(Inventory.get_selected_item())

	hud = _resolve_hud()
	if hud == null:
		push_error("PlayerController: HUD introuvable dans la scene main")
		return
	hud.visible = true
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	camera.current = true
	hud.visible = true
	name_label.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	GraphicsSettings.set_fov_on_camera(camera)
	AudioManager.stop_ambient()
	_default_head_y = head.position.y
	_target_head_y = _default_head_y
	_camera_default_x = camera.position.x
	_camera_default_y = camera.position.y
	_camera_default_roll = camera.rotation.z
	_camera_default_fov = camera.fov
	_pitch = camera.rotation.x
	floor_max_angle = deg_to_rad(MAX_WALKABLE_SLOPE_DEGREES)
	floor_snap_length = WALKABLE_FLOOR_SNAP_LENGTH
	platform_floor_layers = WALKABLE_PLATFORM_LAYERS
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


func _resolve_hud() -> Control:
	var scene := get_tree().current_scene
	if scene:
		var main_hud := scene.get_node_or_null("HUDLayer/HUD") as Control
		if main_hud:
			return main_hud
	var layered_hud := get_node_or_null("HUDLayer/HUD") as Control
	if layered_hud:
		return layered_hud
	return get_node_or_null("HUD") as Control

func _process(delta: float) -> void:
	_update_visual_rotation()
	if is_local:
		_sync_viewmodel_viewport()

func _setup_viewmodel_viewport() -> void:
	viewmodel_canvas.visible = true
	viewmodel_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewmodel_display.texture = viewmodel_viewport.get_texture()
	viewmodel_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_viewport().size_changed.connect(_on_main_viewport_resized)
	_on_main_viewport_resized()

func _on_main_viewport_resized() -> void:
	var size: Vector2i = get_viewport().get_visible_rect().size
	if size.x <= 0 or size.y <= 0:
		return
	viewmodel_viewport.size = size

func _sync_viewmodel_viewport() -> void:
	if viewmodel_camera == null or camera == null:
		return
	viewmodel_camera.fov = camera.fov

func _on_selected_hotbar_changed(_index: int, item_id: String) -> void:
	_equip_viewmodel_for_item(item_id)

func _equip_viewmodel_for_item(item_id: String) -> void:
	if weapon_holder == null:
		return
	_clear_current_weapon()
	if not WEAPON_VIEWMODELS.has(item_id):
		return
	var scene: PackedScene = load(WEAPON_VIEWMODELS[item_id]) as PackedScene
	if scene == null:
		push_warning("PlayerController: viewmodel introuvable pour %s" % item_id)
		return
	var instance := scene.instantiate() as Node3D
	if instance == null:
		return
	weapon_holder.add_child(instance)
	current_weapon = instance

func _toggle_debug_cam() -> void:
	if _debug_cam != null and is_instance_valid(_debug_cam):
		_debug_cam.queue_free()
		_debug_cam = null
		camera.current = true
		return
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var cam_script := load("res://scripts/debug/free_cam.gd")
	_debug_cam = Camera3D.new()
	_debug_cam.set_script(cam_script)
	_debug_cam.fov = camera.fov
	scene_root.add_child(_debug_cam)
	_debug_cam.global_transform = camera.global_transform
	_debug_cam.current = true

func _clear_current_weapon() -> void:
	if current_weapon and is_instance_valid(current_weapon):
		current_weapon.queue_free()
	current_weapon = null

func _unhandled_input(event: InputEvent) -> void:
	if not is_local:
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
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENSITIVITY, deg_to_rad(-89), deg_to_rad(89))
		camera.rotation.x = _pitch

	if event is InputEventKey and event.pressed and event.keycode == KEY_F10:
		_toggle_settings_menu()
		return

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F4:
		_toggle_debug_cam()
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
			_cancel_batch_build()
			_on_build_exit_requested()
		elif _is_holding_hammer():
			BuildSystem.enter_build_mode()
			_open_build_menu()
		else:
			_try_secondary_interact()

	if event.is_action_pressed("interact"):
		_try_interact()

	if event.is_action_pressed("drop_item"):
		_try_drop_item()

	if event.is_action_pressed("shoot"):
		if _is_inventory_open():
			return
		if hud.build_menu.visible:
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
		else:
			_try_shoot()

	if event.is_action_pressed("reload") and current_weapon and current_weapon.has_method("reload"):
		current_weapon.reload()

func _physics_process(delta: float) -> void:
	if not is_local:
		if _remote_state_initialized:
			var predicted_position := _remote_target_position + _remote_velocity * PLAYER_REMOTE_EXTRAPOLATION
			global_position = global_position.lerp(predicted_position, clampf(delta * 18.0, 0.0, 1.0))
			head.rotation.y = lerp_angle(head.rotation.y, _remote_target_head_yaw, clampf(delta * 18.0, 0.0, 1.0))
			camera.rotation.x = lerp_angle(camera.rotation.x, _remote_target_camera_pitch, clampf(delta * 18.0, 0.0, 1.0))
			_update_player_model_animation()
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

	_update_wagon_platform(delta)

	head.position.y = lerpf(head.position.y, _target_head_y, CROUCH_CAMERA_LERP_SPEED * delta)
	move_and_slide()
	_update_head_bob(delta, direction.length() > 0.1)
	_update_footsteps(delta, direction.length() > 0.1)
	_network_sync_accum += delta
	if _network_sync_accum >= PLAYER_SYNC_INTERVAL:
		_network_sync_accum = 0.0
		_broadcast_network_state()

	if BuildSystem.is_building:
		if not _batch_build_active:
			_update_build_preview()
		_update_batch_build()
	else:
		_cancel_batch_build()

	_update_player_model_animation()
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


func _update_footsteps(delta: float, is_moving: bool) -> void:
	if not is_local:
		return
	if not is_on_floor() or not is_moving:
		_footstep_timer = 0.0
		return
	var horizontal_speed: float = Vector2(velocity.x, velocity.z).length()
	if horizontal_speed < 0.75:
		_footstep_timer = 0.0
		return
	_footstep_timer -= delta
	if _footstep_timer > 0.0:
		return
	FootstepAudioHelper.play_local_footstep(self, self)
	if _is_crouching:
		_footstep_timer = FOOTSTEP_CROUCH_INTERVAL
	elif _is_sprinting:
		_footstep_timer = FOOTSTEP_SPRINT_INTERVAL
	else:
		_footstep_timer = FOOTSTEP_WALK_INTERVAL

func _update_wagon_platform(delta: float) -> void:
	var current_wagon := _find_wagon_underfoot()
	if current_wagon != _wagon_platform:
		if _wagon_platform != null and current_wagon == null:
			# Just left the wagon — inherit horizontal motion as inertia.
			velocity.x += _platform_velocity_carry.x
			velocity.z += _platform_velocity_carry.z
		_wagon_platform = current_wagon
		_platform_velocity_carry = Vector3.ZERO
		if _wagon_platform and is_instance_valid(_wagon_platform):
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
	# Rigid transform carry: keep the player at the same local spot on the wagon
	# by reprojecting their position through the wagon's frame-to-frame delta.
	var local_pos: Vector3 = previous_transform.affine_inverse() * global_position
	var target_pos: Vector3 = current_transform * local_pos
	if delta > 0.0:
		_platform_velocity_carry = (target_pos - global_position) / delta
	global_position = target_pos
	# Yaw-only rotation so the camera stays upright through banked curves.
	var old_fwd: Vector3 = previous_transform.basis.orthonormalized().z
	var new_fwd: Vector3 = current_transform.basis.orthonormalized().z
	old_fwd.y = 0.0
	new_fwd.y = 0.0
	if old_fwd.length_squared() > 0.0001 and new_fwd.length_squared() > 0.0001:
		var angle := old_fwd.signed_angle_to(new_fwd, Vector3.UP)
		if absf(angle) > 0.0001:
			rotate_y(angle)
	_last_wagon_transform = current_transform

func _find_wagon_underfoot() -> Node3D:
	if not is_on_floor() and _wagon_platform == null:
		return _find_wagon_below_player()
	var from := global_position + Vector3.UP * 0.3
	var to := global_position + Vector3.DOWN * 1.8
	var query := PhysicsRayQueryParameters3D.create(from, to, BUILD_COLLISION_MASK)
	query.exclude = [self]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
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
	var from := global_position + Vector3.UP * 0.5
	var to := global_position + Vector3.DOWN * 4.0
	var query := PhysicsRayQueryParameters3D.create(from, to, BUILD_COLLISION_MASK)
	query.exclude = [self]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	var collider: Variant = hit.get("collider", null)
	if collider == null or not (collider is Node):
		return null
	return _find_wagon_parent(collider as Node)


func _update_ambient() -> void:
	if GAME_AMBIENT_NAME.is_empty():
		return
	_ambient_timer += get_physics_process_delta_time()
	if _ambient_timer < 1.0:
		return
	_ambient_timer = 0.0
	AudioManager.play_ambient(GAME_AMBIENT_NAME)


func _broadcast_network_state() -> void:
	if not is_local or not multiplayer.has_multiplayer_peer():
		return
	_receive_network_state.rpc(global_position, head.rotation.y, _pitch, velocity, _is_crouching)


func respawn_to_spawn() -> void:
	var main_scene := get_tree().current_scene
	if main_scene == null or not main_scene.has_method("get_spawn_position_for_peer"):
		return
	var spawn_position: Vector3 = main_scene.get_spawn_position_for_peer(get_multiplayer_authority())
	velocity = Vector3.ZERO
	global_position = spawn_position
	_wagon_platform = null
	_last_wagon_transform = Transform3D.IDENTITY
	_platform_velocity_carry = Vector3.ZERO
	_is_crouching = false
	_footstep_timer = 0.0
	_update_crouch_state()
	head.rotation = Vector3.ZERO
	_pitch = 0.0
	camera.rotation.x = _pitch
	camera.rotation.z = _camera_default_roll
	camera.position.x = _camera_default_x
	camera.position.y = _camera_default_y
	_broadcast_network_state()


@rpc("any_peer", "unreliable")
func _receive_network_state(
	pos: Vector3,
	head_yaw: float,
	camera_pitch: float,
	linear_velocity: Vector3,
	is_crouching_remote: bool = false
) -> void:
	if is_local:
		return
	_remote_target_position = pos
	_remote_target_head_yaw = head_yaw
	_remote_target_camera_pitch = camera_pitch
	_remote_velocity = linear_velocity
	_remote_is_crouching = is_crouching_remote
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

func _try_secondary_interact() -> void:
	if not interact_ray.is_colliding():
		return
	var collider: Object = interact_ray.get_collider()
	if collider and collider.has_method("secondary_interact"):
		collider.secondary_interact(self)

func _try_shoot() -> void:
	if current_weapon and current_weapon.has_method("shoot"):
		current_weapon.shoot()

func _try_build() -> void:
	var hit_point: Vector3 = Vector3.ZERO
	var collider: Object = null
	if build_ray.is_colliding():
		hit_point = build_ray.get_collision_point()
		collider = build_ray.get_collider()

	if BuildSystem.mode == BuildSystem.BuildMode.CEILING:
		var ceil_target: Node = _find_build_target(collider as Node) if collider != null else null
		if ceil_target == null:
			ceil_target = _find_wagon_underfoot()
		if ceil_target != null and ceil_target.has_method("get_ceiling_surface_local_y"):
			var ref_point: Variant = hit_point if collider != null else null
			var p_ceil: Variant = _get_build_point_on_target(ceil_target, ref_point, 1)
			if p_ceil is Vector3:
				BuildSystem.try_place_ceiling(p_ceil, ceil_target)
		return

	if collider == null:
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
		BuildSystem.BuildMode.ITEM:
			var target := _find_build_target(collider as Node)
			if target:
				var p: Variant = _get_build_point_on_target(target, hit_point)
				if p is Vector3:
					hit_point = p
				BuildSystem.try_place_item(hit_point, target)
		BuildSystem.BuildMode.DEMOLISH:
			var hit_chassis := _find_chassis(collider as Node)
			if hit_chassis != null:
				BuildSystem.try_demolish_train_part(hit_chassis)
				return
			var target := _find_build_target(collider as Node)
			if target:
				var p: Variant = _get_build_point_on_target(target, hit_point)
				if p is Vector3:
					hit_point = p
				BuildSystem.try_demolish(hit_point, target)

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
	var hit_point: Vector3 = Vector3.ZERO
	var collider: Object = null
	var has_hit: bool = build_ray.is_colliding()
	if has_hit:
		hit_point = build_ray.get_collision_point()
		collider = build_ray.get_collider()
	var target: Node = _find_build_target(collider as Node) if collider != null else null
	if target == null and BuildSystem.mode == BuildSystem.BuildMode.CEILING:
		target = _find_wagon_underfoot()
	if target == null:
		return {}
	var ref_point: Variant = hit_point if has_hit else null
	var level_offset: int = 1 if BuildSystem.mode == BuildSystem.BuildMode.CEILING else 0
	var p: Variant = _get_build_point_on_target(target, ref_point, level_offset)
	if p is Vector3:
		hit_point = p
	elif not has_hit:
		return {}
	var grid_pos: Vector3i = target.get_grid_position(hit_point)
	return {
		"hit_point": hit_point,
		"target": target,
		"grid_pos": grid_pos,
	}

func _get_wall_build_context() -> Dictionary:
	if not build_ray.is_colliding():
		return {}
	var hit_point: Vector3 = build_ray.get_collision_point()
	var collider: Object = build_ray.get_collider()
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
	if not build_ray.is_colliding():
		return {}
	var hit_point: Vector3 = build_ray.get_collision_point()
	var collider: Object = build_ray.get_collider()
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
		if hud != null and hud.has_method("show_build_drag_info"):
			hud.show_build_drag_info("Floors: %dx%d (%d) - relache pour construire" % [width, length, width * length])
		BuildSystem.show_batch_floor_preview(_batch_build_target, _get_floor_batch_positions())
	elif _batch_build_mode == BuildSystem.BuildMode.CEILING:
		var cwidth: int = absi(_batch_build_end_grid.x - _batch_build_start_grid.x) + 1
		var clength: int = absi(_batch_build_end_grid.y - _batch_build_start_grid.y) + 1
		if hud != null and hud.has_method("show_build_drag_info"):
			hud.show_build_drag_info("Plafonds: %dx%d (%d) - relache pour construire" % [cwidth, clength, cwidth * clength])
		BuildSystem.show_batch_ceiling_preview(_batch_build_target, _get_floor_batch_positions())
	elif _batch_build_mode == BuildSystem.BuildMode.ITEM:
		var count: int = _get_wall_batch_positions().size()
		if hud != null and hud.has_method("show_build_drag_info"):
			hud.show_build_drag_info("Walls: 1x%d - relache pour construire" % count)
		BuildSystem.show_batch_wall_preview(_batch_build_target, _get_wall_batch_positions(), _batch_build_edge)
	elif _batch_build_mode == BuildSystem.BuildMode.DEMOLISH:
		var demolish_entries: Array[Dictionary] = _get_demolish_batch_entries()
		if hud != null and hud.has_method("show_build_drag_info"):
			if _batch_build_edge == BuildSystem.DEMOLISH_FLOOR_EDGE:
				var demolish_width: int = absi(_batch_build_end_grid.x - _batch_build_start_grid.x) + 1
				var demolish_length: int = absi(_batch_build_end_grid.y - _batch_build_start_grid.y) + 1
				hud.show_build_drag_info("Demolish floors: %dx%d (%d) - relache pour casser" % [demolish_width, demolish_length, demolish_entries.size()])
			else:
				hud.show_build_drag_info("Demolish walls: %d - relache pour casser" % demolish_entries.size())
		BuildSystem.show_batch_demolish_preview(_batch_build_target, demolish_entries)

func _cancel_batch_build() -> void:
	_batch_build_active = false
	_batch_build_mode = BuildSystem.BuildMode.OFF
	_batch_build_target = null
	_batch_build_start_grid = Vector3i.ZERO
	_batch_build_end_grid = Vector3i.ZERO
	_batch_build_edge = BuildSystem.EdgeSide.NONE
	BuildSystem.clear_batch_preview()
	if hud != null and hud.has_method("hide_build_drag_info"):
		hud.hide_build_drag_info()

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
	var has_hit: bool = build_ray.is_colliding()
	var hit_point: Vector3 = Vector3.ZERO
	var hit_normal: Vector3 = Vector3.UP
	var collider: Object = null
	if has_hit:
		hit_point = build_ray.get_collision_point()
		hit_normal = build_ray.get_collision_normal()
		collider = build_ray.get_collider()

	if BuildSystem.mode == BuildSystem.BuildMode.CEILING:
		var ceil_target: Node = _find_build_target(collider as Node) if collider != null else null
		if ceil_target == null:
			ceil_target = _find_wagon_underfoot()
		if ceil_target != null and ceil_target.has_method("get_ceiling_surface_local_y"):
			var ref_point: Variant = hit_point if has_hit else null
			var p_ceil: Variant = _get_build_point_on_target(ceil_target, ref_point, 1)
			if p_ceil is Vector3:
				BuildSystem.update_preview_on_target(p_ceil, ceil_target.get_build_surface_normal_world(), ceil_target)
				return
		BuildSystem.hide_preview()
		return

	if not has_hit or collider == null:
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
			var target := _find_build_target(collider as Node)
			if target:
				var p: Variant = _get_build_point_on_target(target, hit_point)
				if p is Vector3:
					hit_point = p
					hit_normal = target.get_build_surface_normal_world()
				BuildSystem.update_preview_on_target(hit_point, hit_normal, target)
			else:
				BuildSystem.hide_preview()
		_:
			BuildSystem.hide_preview()

func _find_chassis(node: Node) -> TrainChassis:
	var current: Node = node
	while current:
		if current is TrainChassis:
			return current
		current = current.get_parent()
	return null

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

func _get_build_point_on_target(target: Node, reference_world_point: Variant = null, level_offset: int = 0) -> Variant:
	var origin: Vector3 = build_ray.global_transform.origin
	var dir: Vector3 = -build_ray.global_transform.basis.z
	if dir.length_squared() < 0.0001:
		return null
	dir = dir.normalized()
	if not (target is WagonFrame or target is TrainChassis):
		return null
	var ref_local: Vector3
	if reference_world_point is Vector3:
		ref_local = target.to_local(reference_world_point)
	else:
		ref_local = target.to_local(global_position)
	var level: int = target.detect_level_from_local_y(ref_local.y) + level_offset
	if level < 0:
		level = 0
	var surface_y: float = target.get_surface_local_y(level)
	var plane_point: Vector3 = target.to_global(Vector3(0.0, surface_y, 0.0))
	var plane_normal: Vector3 = target.get_build_surface_normal_world()
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

func _is_build_menu_open() -> bool:
	return hud != null and hud.build_menu != null and hud.build_menu.visible

func _is_holding_hammer() -> bool:
	var id := Inventory.get_selected_item()
	return id in Inventory.HAMMER_ITEMS

func _controls_blocked() -> bool:
	return GameManager.current_state == GameManager.GameState.PAUSED or _is_chat_open()

func _apply_blocked_movement(delta: float) -> bool:
	if not _controls_blocked():
		return false
	_cancel_batch_build()
	_update_wagon_platform(delta)
	if is_on_floor() and velocity.y <= 0.0:
		velocity.x = move_toward(velocity.x, 0.0, current_speed)
		velocity.z = move_toward(velocity.z, 0.0, current_speed)
	if not is_on_floor() or velocity.y > 0.0:
		velocity.y -= gravity * delta
	else:
		velocity.y = minf(velocity.y, 0.0)
	move_and_slide()
	_update_player_model_animation()
	_network_sync_accum += delta
	if _network_sync_accum >= PLAYER_SYNC_INTERVAL:
		_network_sync_accum = 0.0
		_broadcast_network_state()
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

func _setup_player_model_animation() -> void:
	_model_animation_player = _find_animation_player(visual_root)
	if _model_animation_player == null:
		push_warning("PlayerController: aucun AnimationPlayer trouve sur le modele joueur.")
		return
	_model_animation_player.playback_default_blend_time = PLAYER_ANIM_BLEND
	_model_animation_library = _get_or_create_animation_library(_model_animation_player)
	for animation_id in PLAYER_ANIMATION_SOURCES.keys():
		var config: Dictionary = PLAYER_ANIMATION_SOURCES[animation_id]
		_load_model_animation(String(animation_id), String(config.get("path", "")), bool(config.get("loop", true)))
	_play_player_model_animation(PLAYER_ANIM_IDLE)

func _get_or_create_animation_library(player: AnimationPlayer) -> AnimationLibrary:
	var library_name := StringName("")
	if player.has_animation_library(library_name):
		return player.get_animation_library(library_name)
	var library := AnimationLibrary.new()
	player.add_animation_library(library_name, library)
	return library

func _load_model_animation(animation_id: String, source_path: String, should_loop: bool) -> void:
	if source_path.is_empty() or _model_animation_library == null:
		return
	var source_scene := load(source_path) as PackedScene
	if source_scene == null:
		push_warning("PlayerController: animation introuvable: %s" % source_path)
		return
	var source_root := source_scene.instantiate()
	var source_player := _find_animation_player(source_root)
	if source_player == null:
		push_warning("PlayerController: aucun AnimationPlayer dans %s" % source_path)
		source_root.free()
		return
	var animation_names := source_player.get_animation_list()
	if animation_names.is_empty():
		push_warning("PlayerController: aucune animation dans %s" % source_path)
		source_root.free()
		return
	var source_animation := source_player.get_animation(animation_names[0])
	if source_animation == null:
		source_root.free()
		return
	var copied_animation := source_animation.duplicate(true) as Animation
	copied_animation.loop_mode = Animation.LOOP_LINEAR if should_loop else Animation.LOOP_NONE
	if _model_animation_library.has_animation(animation_id):
		_model_animation_library.remove_animation(animation_id)
	_model_animation_library.add_animation(animation_id, copied_animation)
	source_root.free()

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node == null:
		return null
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null

func _update_player_model_animation() -> void:
	if _model_animation_player == null:
		return
	var animation_velocity := _remote_velocity if not is_local else velocity
	var horizontal_speed := Vector2(animation_velocity.x, animation_velocity.z).length()
	var target_animation := PLAYER_ANIM_IDLE
	var target_speed_scale := 1.0
	if _should_play_jump_animation(animation_velocity):
		target_animation = PLAYER_ANIM_JUMP
	elif _is_animation_crouching():
		target_animation = PLAYER_ANIM_CROUCH
		target_speed_scale = clampf(maxf(horizontal_speed, CROUCH_SPEED) / CROUCH_SPEED, 0.75, 1.15)
	elif horizontal_speed >= PLAYER_ANIM_RUN_SPEED:
		target_animation = PLAYER_ANIM_RUN
		target_speed_scale = clampf(horizontal_speed / SPRINT_SPEED, 0.85, 1.35)
	elif horizontal_speed >= PLAYER_ANIM_WALK_SPEED:
		target_animation = PLAYER_ANIM_WALK
		target_speed_scale = clampf(horizontal_speed / WALK_SPEED, 0.75, 1.25)
	_play_player_model_animation(target_animation, target_speed_scale)

func _should_play_jump_animation(animation_velocity: Vector3) -> bool:
	if is_local:
		return not is_on_floor()
	return absf(animation_velocity.y) >= PLAYER_ANIM_AIR_SPEED

func _is_animation_crouching() -> bool:
	return _is_crouching if is_local else _remote_is_crouching

func _play_player_model_animation(animation_name: String, speed_scale: float = 1.0) -> void:
	if _model_animation_player == null or not _model_animation_player.has_animation(animation_name):
		return
	_model_animation_player.speed_scale = speed_scale
	if _current_model_animation == animation_name and _model_animation_player.is_playing():
		return
	_current_model_animation = animation_name
	_model_animation_player.play(animation_name, PLAYER_ANIM_BLEND)

func _toggle_inventory_panel() -> void:
	if hud == null or not hud.has_method("toggle_inventory_panel"):
		return
	var open: bool = hud.toggle_inventory_panel()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	BuildSystem.hide_preview()

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
	hud.build_menu.hide_menu()
	BuildSystem.exit_build_mode()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _update_interact_hint() -> void:
	if _is_inventory_open():
		_clear_hovered_switch()
		hud.hide_interact_hint()
		hud.hide_harvest_hp()
		return
	if interact_ray.is_colliding():
		var collider: Object = interact_ray.get_collider()
		var hit: Dictionary = {
			"position": interact_ray.get_collision_point(),
			"collider": collider,
		}
		if collider and collider.has_method("interact"):
			if collider is RailSwitch:
				_set_hovered_switch(collider as RailSwitch)
			else:
				_clear_hovered_switch()
			if collider is PumpLever:
				hud.show_interact_hint("[E] Pump")
				hud.hide_harvest_hp()
			elif collider.has_method("get_interact_text_at"):
				hud.show_interact_hint(collider.get_interact_text_at(hit))
				if collider.is_in_group("harvestable"):
					hud.show_harvest_hp(collider.hits_remaining, collider.hits_to_harvest)
				else:
					hud.hide_harvest_hp()
			elif collider.has_method("get_interact_text"):
				hud.show_interact_hint(collider.get_interact_text())
				if collider.is_in_group("harvestable"):
					hud.show_harvest_hp(collider.hits_remaining, collider.hits_to_harvest)
				else:
					hud.hide_harvest_hp()
			elif collider is Harvestable or collider.is_in_group("harvestable"):
				hud.show_interact_hint("[E] Harvest")
				hud.show_harvest_hp(collider.hits_remaining, collider.hits_to_harvest)
			elif collider.is_in_group("dropped_item"):
				hud.show_interact_hint("[E] Ramasser")
				hud.hide_harvest_hp()
			else:
				hud.show_interact_hint("[E] Interact")
				hud.hide_harvest_hp()
			return
	_clear_hovered_switch()
	hud.hide_interact_hint()
	hud.hide_harvest_hp()


func _exit_tree() -> void:
	_clear_hovered_switch()
	if is_local and Inventory.selected_hotbar_changed.is_connected(_on_selected_hotbar_changed):
		Inventory.selected_hotbar_changed.disconnect(_on_selected_hotbar_changed)


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

func _try_drop_item() -> void:
	var slot_index := Inventory.selected_hotbar_index
	var slot := Inventory.get_slot_data(slot_index)
	if slot.item_id == "" or int(slot.amount) <= 0:
		return
	var drop_pos := global_position + head.global_basis * Vector3(0, 0, -1.5)
	Inventory.drop_slot(slot_index, -1, drop_pos)

func _find_wagon_parent(node: Node) -> Node3D:
	var current: Node = node
	var fallback: Node3D = null
	while current:
		if current.is_in_group("wagon_frame"):
			return current as Node3D
		if fallback == null and (current.is_in_group("chassis") or current.is_in_group("wagon")):
			fallback = current as Node3D
		current = current.get_parent()
	return fallback
