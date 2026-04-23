extends Camera3D

const SPEED: float = 8.0
const BOOST_MULTIPLIER: float = 3.5
const MOUSE_SENSITIVITY: float = 0.002

var _pitch: float = 0.0
var _yaw: float = 0.0

func _ready() -> void:
	_pitch = rotation.x
	_yaw = rotation.y
	set_process_unhandled_input(true)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * MOUSE_SENSITIVITY
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENSITIVITY, deg_to_rad(-89), deg_to_rad(89))
		rotation = Vector3(_pitch, _yaw, 0)

func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		dir.z += 1.0
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_SPACE):
		dir.y += 1.0
	if Input.is_key_pressed(KEY_CTRL):
		dir.y -= 1.0
	if dir == Vector3.ZERO:
		return
	var speed: float = SPEED
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= BOOST_MULTIPLIER
	var world_dir: Vector3 = (global_basis * dir).normalized()
	global_position += world_dir * speed * delta
