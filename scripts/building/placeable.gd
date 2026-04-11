extends StaticBody3D

@export var data: BuildableData
@export var max_health: float = 50.0

var current_health: float

func _ready() -> void:
	if data:
		max_health = data.health
	current_health = max_health
	add_to_group("placeable")

func take_damage(amount: float) -> void:
	current_health -= amount
	if current_health <= 0:
		_on_destroyed()

func repair(amount: float) -> void:
	current_health = minf(current_health + amount, max_health)

func _on_destroyed() -> void:
	var wagon := _find_wagon()
	if wagon and wagon.has_method("unregister_built_item"):
		wagon.unregister_built_item(self)
	queue_free()

func _find_wagon() -> Node3D:
	var parent := get_parent()
	while parent:
		if parent.is_in_group("wagon"):
			return parent as Node3D
		parent = parent.get_parent()
	return null
