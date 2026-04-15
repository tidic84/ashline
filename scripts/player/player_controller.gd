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

var current_speed: float = WALK_SPEED
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var current_weapon: Node3D = null
var is_local: bool = false
var _ambient_timer: float = 0.0

func _enter_tree() -> void:
	if not multiplayer.has_multiplayer_peer():
		is_local = true
	else:
		var my_id := multiplayer.get_unique_id()
		is_local = (str(my_id) == name)

func _ready() -> void:
	add_to_group("player")
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if not is_local:
		camera.current = false
		set_physics_process(false)
		set_process_unhandled_input(false)
		hud.visible = false
		return

	camera.current = true
	hud.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	GraphicsSettings.set_fov_on_camera(camera)
	hud.settings_menu.closed.connect(func():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		GraphicsSettings.set_fov_on_camera(camera)
	)

	# Connect build menu signals
	hud.build_menu.item_selected.connect(_on_build_item_selected)
	hud.build_menu.mode_selected.connect(_on_build_mode_selected)
	hud.build_menu.exit_build_requested.connect(_on_build_exit_requested)
	hud.build_menu.close_requested.connect(_close_build_menu)

func _unhandled_input(event: InputEvent) -> void:
	if not is_local:
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
