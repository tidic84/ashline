extends StaticBody3D

@export var damage: float = 15.0
@export var fire_rate: float = 0.5
@export var turret_range: float = 20.0
@export var max_health: float = 60.0

var current_health: float
var target: Node3D = null
var can_fire: bool = true

@onready var barrel: Node3D = $Barrel
@onready var fire_timer: Timer = $FireTimer
@onready var detection_area: Area3D = $DetectionArea

func _ready() -> void:
	current_health = max_health
	add_to_group("placeable")
	fire_timer.wait_time = fire_rate
	fire_timer.one_shot = true
	fire_timer.timeout.connect(func() -> void: can_fire = true)
	detection_area.body_entered.connect(_on_body_entered)
	detection_area.body_exited.connect(_on_body_exited)

func _physics_process(_delta: float) -> void:
	if target and is_instance_valid(target):
		var look_pos := target.global_position
		look_pos.y = barrel.global_position.y
		barrel.look_at(look_pos, Vector3.UP)
		if can_fire:
			_fire()
	else:
		target = _find_closest_enemy()

func _fire() -> void:
	can_fire = false
	fire_timer.start()
	if target and target.has_method("take_damage"):
		target.take_damage(damage)

func _find_closest_enemy() -> Node3D:
	var closest: Node3D = null
	var min_dist := turret_range
	for body in detection_area.get_overlapping_bodies():
		if body.is_in_group("enemy"):
			var dist := global_position.distance_to(body.global_position)
			if dist < min_dist:
				min_dist = dist
				closest = body
	return closest

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("enemy") and target == null:
		target = body

func _on_body_exited(body: Node3D) -> void:
	if body == target:
		target = _find_closest_enemy()

func take_damage(amount: float) -> void:
	current_health -= amount
	if current_health <= 0:
		_on_destroyed()

func _on_destroyed() -> void:
	var wagon := get_parent()
	if wagon and wagon.has_method("unregister_built_item"):
		wagon.unregister_built_item(self)
	BuildSystem.remove_placed_item(self)
