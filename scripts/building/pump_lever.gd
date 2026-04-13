extends StaticBody3D
class_name PumpLever

@export var pump_cooldown: float = 0.22

var can_pump: bool = true
var _pump_target: Node = null  # WagonFrame or TrainChassis

func _ready() -> void:
	collision_layer = 32  # Layer 6 = Interactable
	collision_mask = 0
	add_to_group("interactable")
	# Find parent wagon frame or chassis
	var current: Node = get_parent()
	while current:
		if current is WagonFrame:
			_pump_target = current
			current.is_on_rails = true
			break
		if current is TrainChassis:
			_pump_target = current
			current.is_on_rails = true
			break
		current = current.get_parent()

func interact(_player: CharacterBody3D) -> void:
	if not can_pump or _pump_target == null:
		return
	can_pump = false
	_pump_target.pump()
	AudioManager.play_sfx("pump", 0.0, randf_range(0.95, 1.05))
	_animate_pump()
	await get_tree().create_timer(pump_cooldown).timeout
	can_pump = true

var _pump_down: bool = false

func _animate_pump() -> void:
	var handle: Node3D = get_node_or_null("Handle") as Node3D
	if handle == null:
		return
	_pump_down = not _pump_down
	var target_angle: float = deg_to_rad(20.0) if _pump_down else deg_to_rad(-20.0)
	var tween := create_tween()
	tween.tween_property(handle, "rotation:x", target_angle, 0.18).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
