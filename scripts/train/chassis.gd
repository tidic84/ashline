extends StaticBody3D
class_name TrainChassis

signal floor_placed(grid_pos: Vector2i)
signal speed_changed(speed: float)

const GRID_SIZE: float = 1.0
const BUILD_SURFACE_LOCAL_Y: float = 0.28

@export var max_width: int = 5
@export var max_length: int = 3

var grid_cells: Dictionary = {} # Vector2i -> { "floor": bool, "item": Node3D, "edges": {}, "floor_node": Node3D }
var floor_count: int = 0
var is_on_rails: bool = false

# Movement
var speed: float = 0.0
var max_speed: float = 4.0  # Handcar cap — upgrade to engine for more
var pump_impulse: float = 0.45  # Small per-pump kick
var friction: float = 0.35  # Low — momentum carries between pumps
var distance_traveled: float = 0.0

# Path following
var rail_curve: Curve3D = null
var rail_progress: float = 0.0

func _ready() -> void:
	if get_meta("is_preview", false):
		collision_layer = 0
		collision_mask = 0
		return
	add_to_group("wagon")
	add_to_group("chassis")
	collision_layer = 8  # Layer 4 = Train
	collision_mask = 1
	# Run BEFORE the player (default=0) so constant_linear_velocity is set
	# before CharacterBody3D.move_and_slide() reads get_platform_velocity().
	process_physics_priority = -1

func _physics_process(delta: float) -> void:
	if get_meta("is_preview", false):
		return
	if not is_on_rails:
		return
	if absf(speed) < 0.01:
		if speed != 0.0:
			speed = 0.0
			speed_changed.emit(0.0)
			_set_platform_velocity(Vector3.ZERO)
		return

	speed = move_toward(speed, 0.0, friction * delta)
	var ds: float = speed * delta
	distance_traveled += absf(ds)

	var old_pos: Vector3 = global_position

	if rail_curve != null and rail_curve.get_baked_length() > 0.0:
		var total: float = rail_curve.get_baked_length()
		var new_progress: float = clampf(rail_progress + ds, 0.0, total)
		# Blocked at rail boundary — stop the train
		if is_equal_approx(new_progress, rail_progress):
			speed = 0.0
			speed_changed.emit(0.0)
			_set_platform_velocity(Vector3.ZERO)
			return
		rail_progress = new_progress
		# Sample position and derive forward from nearby points (avoids look_at jumps)
		var pos: Vector3 = rail_curve.sample_baked(rail_progress)
		var ahead: float = minf(rail_progress + 1.0, total)
		var behind: float = maxf(rail_progress - 1.0, 0.0)
		var fwd: Vector3 = rail_curve.sample_baked(ahead) - rail_curve.sample_baked(behind)
		fwd.y = 0.0
		global_position = pos
		if fwd.length_squared() > 0.0001:
			fwd = fwd.normalized()
			var target_basis := Basis.looking_at(fwd, Vector3.UP)
			basis = basis.slerp(target_basis, minf(delta * 8.0, 1.0))
	else:
		global_position.z += ds

	# Platform velocity from actual displacement so it matches curves
	var actual_vel: Vector3 = (global_position - old_pos) / delta
	_set_platform_velocity(actual_vel)

func pump(direction: float = 1.0) -> void:
	if not is_on_rails:
		return
	speed = clampf(speed + pump_impulse * direction, -max_speed, max_speed)
	speed_changed.emit(speed)

func snap_to_rails() -> void:
	is_on_rails = true
	var terrain: TerrainGenerator = _find_terrain()
	if terrain:
		rail_curve = terrain.get_rail_curve()
		if rail_curve and rail_curve.get_baked_length() > 0.0:
			rail_progress = rail_curve.get_closest_offset(global_position)
			global_position = rail_curve.sample_baked(rail_progress)
			var total: float = rail_curve.get_baked_length()
			var ahead: float = minf(rail_progress + 1.0, total)
			var behind: float = maxf(rail_progress - 1.0, 0.0)
			var fwd: Vector3 = rail_curve.sample_baked(ahead) - rail_curve.sample_baked(behind)
			fwd.y = 0.0
			if fwd.length_squared() > 0.0001:
				basis = Basis.looking_at(fwd.normalized(), Vector3.UP)

func _find_terrain() -> TerrainGenerator:
	var nodes := get_tree().get_nodes_in_group("terrain")
	if nodes.size() > 0:
		return nodes[0] as TerrainGenerator
	return null

func _set_platform_velocity(vel: Vector3) -> void:
	constant_linear_velocity = vel
	for child in get_children():
		if child is StaticBody3D:
			child.constant_linear_velocity = vel

# --- Grid system ---

func get_build_surface_point_world() -> Vector3:
	return to_global(Vector3(0.0, BUILD_SURFACE_LOCAL_Y, 0.0))

func get_build_surface_local_y() -> float:
	return BUILD_SURFACE_LOCAL_Y

func get_build_surface_normal_world() -> Vector3:
	return global_basis.y.normalized()

func is_grid_in_bounds(grid_pos: Vector2i) -> bool:
	return (
		grid_pos.x >= _grid_min(max_width) and grid_pos.x <= _grid_max(max_width)
		and grid_pos.y >= _grid_min(max_length) and grid_pos.y <= _grid_max(max_length)
	)

func get_grid_position(world_pos: Vector3) -> Vector2i:
	var local_pos := to_local(world_pos)
	var gx := _round_to_int(local_pos.x / GRID_SIZE)
	var gz := _round_to_int(local_pos.z / GRID_SIZE)
	return Vector2i(gx, gz)

func _round_to_int(v: float) -> int:
	# Round halves away from zero so boundaries behave symmetrically.
	return int(floor(v + 0.5)) if v >= 0.0 else int(ceil(v - 0.5))

func _grid_min(size: int) -> int:
	return -(size / 2)

func _grid_max(size: int) -> int:
	return (size - 1) / 2

func grid_to_local(grid_pos: Vector2i) -> Vector3:
	return Vector3(
		grid_pos.x * GRID_SIZE,
		0.0,
		grid_pos.y * GRID_SIZE
	)

func grid_to_world(grid_pos: Vector2i) -> Vector3:
	return to_global(grid_to_local(grid_pos))

func can_place_floor(grid_pos: Vector2i) -> bool:
	if grid_pos.x < _grid_min(max_width) or grid_pos.x > _grid_max(max_width):
		return false
	if grid_pos.y < _grid_min(max_length) or grid_pos.y > _grid_max(max_length):
		return false
	if grid_cells.has(grid_pos) and grid_cells[grid_pos].floor:
		return false
	if floor_count == 0:
		return true
	return _has_adjacent_floor(grid_pos)

func _ensure_cell(grid_pos: Vector2i) -> Dictionary:
	if not grid_cells.has(grid_pos):
		grid_cells[grid_pos] = { "floor": false, "item": null, "edges": {}, "floor_node": null }
	elif not grid_cells[grid_pos].has("edges"):
		grid_cells[grid_pos].edges = {}
	elif not grid_cells[grid_pos].has("floor_node"):
		grid_cells[grid_pos].floor_node = null
	return grid_cells[grid_pos]

func place_floor(grid_pos: Vector2i, floor_node: Node3D = null) -> void:
	var cell := _ensure_cell(grid_pos)
	cell.floor = true
	cell.floor_node = floor_node
	floor_count += 1
	floor_placed.emit(grid_pos)

func get_floor_node(grid_pos: Vector2i) -> Node3D:
	if not grid_cells.has(grid_pos):
		return null
	var cell := _ensure_cell(grid_pos)
	var floor_node: Node3D = cell.floor_node
	if floor_node != null and is_instance_valid(floor_node):
		return floor_node
	cell.floor_node = null
	return null

func can_place_item(grid_pos: Vector2i) -> bool:
	if not grid_cells.has(grid_pos):
		return false
	if not grid_cells[grid_pos].floor:
		return false
	if grid_cells[grid_pos].item != null:
		return false
	return true

func can_place_edge(grid_pos: Vector2i, edge: int) -> bool:
	if not grid_cells.has(grid_pos):
		return false
	if not grid_cells[grid_pos].floor:
		return false
	var cell := _ensure_cell(grid_pos)
	return not cell.edges.has(edge)

func place_item(grid_pos: Vector2i, item: Node3D) -> void:
	grid_cells[grid_pos].item = item

func place_edge_item(grid_pos: Vector2i, edge: int, item: Node3D) -> void:
	var cell := _ensure_cell(grid_pos)
	cell.edges[edge] = item

func remove_item(grid_pos: Vector2i) -> void:
	if grid_cells.has(grid_pos) and grid_cells[grid_pos].item:
		grid_cells[grid_pos].item = null

func remove_edge_item(grid_pos: Vector2i, edge: int) -> void:
	if grid_cells.has(grid_pos):
		var cell := _ensure_cell(grid_pos)
		cell.edges.erase(edge)

func has_floor_at(grid_pos: Vector2i) -> bool:
	return grid_cells.has(grid_pos) and grid_cells[grid_pos].floor

func _has_adjacent_floor(grid_pos: Vector2i) -> bool:
	var neighbors: Array[Vector2i] = [
		Vector2i(grid_pos.x + 1, grid_pos.y),
		Vector2i(grid_pos.x - 1, grid_pos.y),
		Vector2i(grid_pos.x, grid_pos.y + 1),
		Vector2i(grid_pos.x, grid_pos.y - 1),
	]
	for n in neighbors:
		if grid_cells.has(n) and grid_cells[n].floor:
			return true
	return false

func take_damage(amount: float) -> void:
	pass # TODO: chassis durability
