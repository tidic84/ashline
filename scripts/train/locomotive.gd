extends Node3D

@export var acceleration: float = 5.0
@export var brake_force: float = 10.0
@export var max_speed: float = 30.0

var current_speed: float = 0.0
var fuel: float = 100.0
var max_fuel: float = 100.0

func _ready() -> void:
	add_to_group("wagon")

func _physics_process(delta: float) -> void:
	if fuel <= 0:
		current_speed = move_toward(current_speed, 0, brake_force * delta)
		TrainManager.train_speed = current_speed
		return
	if TrainManager.is_moving:
		current_speed = move_toward(current_speed, max_speed, acceleration * delta)
		fuel -= delta * 0.5
	else:
		current_speed = move_toward(current_speed, 0, brake_force * delta)
	TrainManager.train_speed = current_speed

func add_fuel(amount: float) -> void:
	fuel = minf(fuel + amount, max_fuel)

func get_fuel_percent() -> float:
	return fuel / max_fuel * 100.0

func interact(_player: CharacterBody3D) -> void:
	if TrainManager.is_moving:
		TrainManager.stop_train()
	else:
		TrainManager.start_train()
