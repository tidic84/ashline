extends Node3D
class_name Wagon

signal health_changed(current: float, max_hp: float)
signal wagon_destroyed

enum WagonType { FLATBED, ARMORED, STORAGE, WORKSHOP }

@export var wagon_type: WagonType = WagonType.FLATBED
@export var max_health: float = 100.0
@export var grid_width: int = 4
@export var grid_length: int = 8
@export var max_build_weight: int = 20

var current_health: float
var built_items: Array[Node3D] = []
var current_weight: int = 0
var wagon_index: int = -1
var grid_cells: Dictionary = {} # Vector2i -> Node3D

@onready var build_area: Area3D = $BuildArea
@onready var snap_grid: Node3D = $SnapGrid
@onready var connector_front: Marker3D = $ConnectorFront
@onready var connector_back: Marker3D = $ConnectorBack

func _ready() -> void:
	current_health = max_health
	add_to_group("wagon")
	_init_grid()

func _init_grid() -> void:
	grid_cells.clear()
	for x in grid_width:
		for z in grid_length:
			grid_cells[Vector2i(x, z)] = null

func get_grid_position(world_pos: Vector3) -> Vector2i:
	var local_pos := to_local(world_pos)
	var gx := int(round(local_pos.x + grid_width / 2.0 - 0.5))
	var gz := int(round(local_pos.z + grid_length / 2.0 - 0.5))
	return Vector2i(clampi(gx, 0, grid_width - 1), clampi(gz, 0, grid_length - 1))

func grid_to_world(grid_pos: Vector2i) -> Vector3:
	var local_x := grid_pos.x - grid_width / 2.0 + 0.5
	var local_z := grid_pos.y - grid_length / 2.0 + 0.5
	return to_global(Vector3(local_x, 0.2, local_z))

func is_cell_free(grid_pos: Vector2i) -> bool:
	if not grid_cells.has(grid_pos):
		return false
	return grid_cells[grid_pos] == null

func occupy_cell(grid_pos: Vector2i, item: Node3D) -> void:
	grid_cells[grid_pos] = item

func free_cell(grid_pos: Vector2i) -> void:
	if grid_cells.has(grid_pos):
		grid_cells[grid_pos] = null

func can_build(weight: int) -> bool:
	return current_weight + weight <= max_build_weight

func register_built_item(item: Node3D, weight: int = 1) -> void:
	built_items.append(item)
	current_weight += weight

func unregister_built_item(item: Node3D, weight: int = 1) -> void:
	built_items.erase(item)
	current_weight -= weight

func take_damage(amount: float) -> void:
	current_health -= amount
	health_changed.emit(current_health, max_health)
	if current_health <= 0:
		_on_destroyed()

func repair(amount: float) -> void:
	current_health = minf(current_health + amount, max_health)
	health_changed.emit(current_health, max_health)

func _on_destroyed() -> void:
	wagon_destroyed.emit()
	for item in built_items.duplicate():
		if is_instance_valid(item):
			item.queue_free()
	built_items.clear()
	grid_cells.clear()
	current_weight = 0

func get_connector_front_pos() -> Vector3:
	return connector_front.global_position

func get_connector_back_pos() -> Vector3:
	return connector_back.global_position
