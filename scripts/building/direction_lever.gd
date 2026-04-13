extends StaticBody3D
class_name DirectionLever

@export var switch_cooldown: float = 0.3

var can_switch: bool = true
var _target: Node = null  # WagonFrame or TrainChassis

func _ready() -> void:
	collision_layer = 32  # Layer 6 = Interactable
	collision_mask = 0
	add_to_group("interactable")
	var current: Node = get_parent()
	while current:
		if current is WagonFrame:
			_target = current
			break
		if current is TrainChassis:
			_target = current
			break
		current = current.get_parent()

func interact(_player: CharacterBody3D) -> void:
	if not can_switch or _target == null:
		return
	can_switch = false
	var current_dir: float = 1.0
	if _target is WagonFrame:
		if _target.front_bogie:
			current_dir = _target.front_bogie.travel_direction
	elif _target is TrainChassis:
		current_dir = _target.travel_direction
	var new_dir: float = -current_dir
	_target.set_direction(new_dir)
	AudioManager.play_sfx("lever", 0.0, randf_range(0.95, 1.05))
	_animate_switch(new_dir)
	await get_tree().create_timer(switch_cooldown).timeout
	can_switch = true

func get_interact_text() -> String:
	return "[E] Direction"

func _animate_switch(dir: float) -> void:
	var handle: Node3D = get_node_or_null("Handle") as Node3D
	if handle == null:
		return
	var target_angle: float = deg_to_rad(30.0) if dir > 0.0 else deg_to_rad(-30.0)
	var tween := create_tween()
	tween.tween_property(handle, "rotation:z", target_angle, 0.2).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
