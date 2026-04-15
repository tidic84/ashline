extends StaticBody3D
class_name TrainChassis

signal floor_placed(grid_pos: Vector2i)
signal speed_changed(speed: float)
signal direction_changed(dir: float)

const GRID_SIZE: float = 1.0
const BUILD_SURFACE_LOCAL_Y: float = 0.22
const EDGE_NORTH: int = 1
const EDGE_SOUTH: int = 2
const EDGE_EAST: int = 3
const EDGE_WEST: int = 4

@export var max_width: int = 3
@export var max_length: int = 1

var grid_cells: Dictionary = {} # Vector2i -> { "floor": bool, "item": Node3D, "edges": {}, "floor_node": Node3D }
var floor_count: int = 0
var is_on_rails: bool = false

# Movement
var travel_direction: float = 1.0  # 1.0 = forward, -1.0 = reverse
var speed: float = 0.0
#var max_speed: float = 4.0  # Handcar cap — upgrade to engine for more
var max_speed: float = 400.0  # Handcar cap — upgrade to engine for more
#var pump_impulse: float = 0.45  # Small per-pump kick
var pump_impulse: float = 1  # Small per-pump kick
var friction: float = 0.35  # Low — momentum carries between pumps
var distance_traveled: float = 0.0

# Path following
var rail_curve: Curve3D = null
var rail_progress: float = 0.0
var current_rail_path: Node = null  # RailPath node we're currently on

var _basis_scale: Vector3 = Vector3.ONE  # preserved from tscn
var _just_transitioned: bool = false  # skip velocity spike on path transition
var _last_transition_target_end: int = -1  # which end of the next path we entered (0=start, 1=end)

func _ready() -> void:
	_basis_scale = basis.get_scale()
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
	# Realism: a lone bogie (no WagonFrame linking the two chassis) cannot move on its own.
	if not (get_parent() is WagonFrame):
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
		var raw_progress: float = rail_progress + ds
		# Try path transition at boundaries
		if raw_progress < 0.0 or raw_progress > total:
			var at_end: int = 0 if raw_progress < 0.0 else 1
			var overflow: float = -raw_progress if at_end == 0 else raw_progress - total
			if _try_path_transition(at_end, overflow):
				# Transition succeeded — skip normal clamped movement
				pass
			else:
				# No connected path — stop at boundary
				rail_progress = 0.0 if at_end == 0 else total
				speed = 0.0
				speed_changed.emit(0.0)
				_set_platform_velocity(Vector3.ZERO)
				return
		else:
			rail_progress = raw_progress
		# Sample position and derive forward from nearby points (avoids look_at jumps)
		var pos: Vector3 = rail_curve.sample_baked(rail_progress)
		var ahead: float = minf(rail_progress + 1.0, total)
		var behind: float = maxf(rail_progress - 1.0, 0.0)
		var fwd: Vector3 = rail_curve.sample_baked(ahead) - rail_curve.sample_baked(behind)
		global_position = pos
		if fwd.length_squared() > 0.0001:
			fwd = _stabilize_curve_forward(fwd)
			var rt: Vector3 = Vector3.UP.cross(fwd)
			if rt.length_squared() < 0.0001:
				rt = Vector3.RIGHT
			rt = rt.normalized()
			var up_v: Vector3 = fwd.cross(rt).normalized()
			var target_basis := Basis(rt, up_v, fwd)
			basis = basis.orthonormalized().slerp(target_basis, minf(delta * 8.0, 1.0)).scaled(_basis_scale)
	else:
		global_position.z += ds

	# Platform velocity — use curve tangent on transition frame to avoid spike
	if _just_transitioned:
		_just_transitioned = false
		var total_t: float = rail_curve.get_baked_length()
		var ahead_t: float = minf(rail_progress + 1.0, total_t)
		var behind_t: float = maxf(rail_progress - 1.0, 0.0)
		var fwd_t: Vector3 = rail_curve.sample_baked(ahead_t) - rail_curve.sample_baked(behind_t)
		if fwd_t.length_squared() > 0.0001:
			fwd_t = fwd_t.normalized()
		else:
			fwd_t = Vector3.FORWARD
		_set_platform_velocity(fwd_t * speed)
	else:
		var actual_vel: Vector3 = (global_position - old_pos) / delta
		_set_platform_velocity(actual_vel)

func pump() -> void:
	if not is_on_rails:
		return
	# Realism: a lone bogie cannot be pumped — needs a frame connecting both chassis.
	if not (get_parent() is WagonFrame):
		return
	speed = clampf(speed + pump_impulse * travel_direction, -max_speed, max_speed)
	speed_changed.emit(speed)

func set_direction(dir: float) -> void:
	travel_direction = signf(dir) if dir != 0.0 else 1.0
	direction_changed.emit(travel_direction)

func _try_path_transition(at_end: int, overflow: float) -> bool:
	if current_rail_path == null:
		return false
	var route: Dictionary = RailNetwork.get_active_route(current_rail_path, at_end)
	if route.is_empty():
		return false
	var next_path: Node = route.path
	if not is_instance_valid(next_path) or not next_path.has_method("get_rail_curve"):
		return false
	var next_curve: Curve3D = next_path.get_rail_curve()
	if next_curve == null or next_curve.get_baked_length() < 0.1:
		return false
	var world_curve := _build_world_curve(next_path)
	if world_curve == null:
		return false
	var next_total: float = world_curve.get_baked_length()
	var target_end: int = route.end
	_last_transition_target_end = target_end
	if target_end == 0:
		rail_progress = overflow
	else:
		rail_progress = next_total - overflow
	# Flip speed when connecting same-side endpoints (start→start or end→end)
	# so the train continues in the same real-world direction.
	if at_end == target_end:
		speed = -speed
		speed_changed.emit(speed)
	rail_progress = clampf(rail_progress, 0.0, next_total)
	rail_curve = world_curve
	current_rail_path = next_path
	_just_transitioned = true
	return true


func _build_world_curve(path_node: Node) -> Curve3D:
	var src_curve: Curve3D = path_node.get_rail_curve()
	if src_curve == null or src_curve.point_count < 2:
		return null
	var world_curve := Curve3D.new()
	world_curve.bake_interval = src_curve.bake_interval
	for i in range(src_curve.point_count):
		var p: Vector3 = path_node.to_global(src_curve.get_point_position(i))
		var t_in: Vector3 = path_node.global_basis * src_curve.get_point_in(i)
		var t_out: Vector3 = path_node.global_basis * src_curve.get_point_out(i)
		world_curve.add_point(p, t_in, t_out)
	return world_curve


func snap_to_rails() -> void:
	is_on_rails = true
	# First try to find the closest RailPath directly
	var best_path: Node = null
	var best_curve: Curve3D = null
	var best_progress: float = 0.0
	var best_dist: float = INF
	var rail_paths := get_tree().get_nodes_in_group("rail_path")
	for rp in rail_paths:
		if not rp.has_method("get_rail_curve"):
			continue
		var wc := _build_world_curve(rp)
		if wc == null or wc.get_baked_length() < 0.1:
			continue
		var offset: float = wc.get_closest_offset(global_position)
		var closest: Vector3 = wc.sample_baked(offset)
		var d: float = global_position.distance_to(closest)
		if d < best_dist:
			best_dist = d
			best_path = rp
			best_curve = wc
			best_progress = offset
	if best_curve != null:
		rail_curve = best_curve
		rail_progress = best_progress
		current_rail_path = best_path
		global_position = rail_curve.sample_baked(rail_progress)
		_orient_to_curve()
	else:
		# Fallback: use terrain's single curve (backwards compat)
		var terrain: TerrainGenerator = _find_terrain()
		if terrain:
			rail_curve = terrain.get_rail_curve()
			if rail_curve and rail_curve.get_baked_length() > 0.0:
				rail_progress = rail_curve.get_closest_offset(global_position)
				global_position = rail_curve.sample_baked(rail_progress)
				_orient_to_curve()


func _orient_to_curve() -> void:
	if rail_curve == null:
		return
	var total: float = rail_curve.get_baked_length()
	var ahead: float = minf(rail_progress + 1.0, total)
	var behind: float = maxf(rail_progress - 1.0, 0.0)
	var fwd: Vector3 = rail_curve.sample_baked(ahead) - rail_curve.sample_baked(behind)
	if fwd.length_squared() > 0.0001:
		fwd = _stabilize_curve_forward(fwd)
		var rt: Vector3 = Vector3.UP.cross(fwd)
		if rt.length_squared() < 0.0001:
			rt = Vector3.RIGHT
		rt = rt.normalized()
		var up_v: Vector3 = fwd.cross(rt).normalized()
		basis = Basis(rt, up_v, fwd).scaled(_basis_scale)


func _stabilize_curve_forward(candidate: Vector3, reference: Vector3 = Vector3.ZERO) -> Vector3:
	var fwd := candidate.normalized()
	if fwd.length_squared() < 0.0001:
		return Vector3.ZERO
	var desired := reference.normalized() if reference.length_squared() > 0.0001 else basis.z.normalized()
	if desired.length_squared() > 0.0001 and fwd.dot(desired) < 0.0:
		fwd = -fwd
	return fwd

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
	return -int(floor(float(size) / 2.0))

func _grid_max(size: int) -> int:
	return int(floor(float(size - 1) / 2.0))

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
	if cell.edges.has(edge):
		return false
	var mirrored := _get_mirrored_edge_slot(grid_pos, edge)
	return mirrored.is_empty()

func place_item(grid_pos: Vector2i, item: Node3D) -> void:
	grid_cells[grid_pos].item = item

func place_edge_item(grid_pos: Vector2i, edge: int, item: Node3D) -> void:
	var cell := _ensure_cell(grid_pos)
	cell.edges[edge] = item
	var mirrored := _get_mirrored_edge_slot(grid_pos, edge)
	if not mirrored.is_empty():
		var mirrored_grid: Vector2i = mirrored["grid_pos"]
		var mirrored_edge: int = mirrored["edge"]
		var mirrored_cell := _ensure_cell(mirrored_grid)
		mirrored_cell.edges[mirrored_edge] = item

func remove_item(grid_pos: Vector2i) -> void:
	if grid_cells.has(grid_pos) and grid_cells[grid_pos].item:
		grid_cells[grid_pos].item = null

func remove_edge_item(grid_pos: Vector2i, edge: int) -> void:
	if grid_cells.has(grid_pos):
		var cell := _ensure_cell(grid_pos)
		cell.edges.erase(edge)
	var mirrored := _get_mirrored_edge_slot(grid_pos, edge)
	if not mirrored.is_empty():
		var mirrored_grid: Vector2i = mirrored["grid_pos"]
		var mirrored_edge: int = mirrored["edge"]
		if grid_cells.has(mirrored_grid):
			var mirrored_cell := _ensure_cell(mirrored_grid)
			mirrored_cell.edges.erase(mirrored_edge)

func has_floor_at(grid_pos: Vector2i) -> bool:
	return grid_cells.has(grid_pos) and grid_cells[grid_pos].floor

func _get_mirrored_edge_slot(grid_pos: Vector2i, edge: int) -> Dictionary:
	var mirrored_grid := grid_pos
	var mirrored_edge := edge
	match edge:
		EDGE_NORTH:
			mirrored_grid = Vector2i(grid_pos.x, grid_pos.y - 1)
			mirrored_edge = EDGE_SOUTH
		EDGE_SOUTH:
			mirrored_grid = Vector2i(grid_pos.x, grid_pos.y + 1)
			mirrored_edge = EDGE_NORTH
		EDGE_EAST:
			mirrored_grid = Vector2i(grid_pos.x + 1, grid_pos.y)
			mirrored_edge = EDGE_WEST
		EDGE_WEST:
			mirrored_grid = Vector2i(grid_pos.x - 1, grid_pos.y)
			mirrored_edge = EDGE_EAST
		_:
			return {}
	if not has_floor_at(mirrored_grid):
		return {}
	return {
		"grid_pos": mirrored_grid,
		"edge": mirrored_edge,
	}

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

func take_damage(_amount: float) -> void:
	pass # TODO: chassis durability
