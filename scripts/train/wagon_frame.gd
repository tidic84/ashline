extends Node3D
class_name WagonFrame

signal floor_placed(grid_pos: Vector2i)

const GRID_SIZE: float = 1.0
const BUILD_SURFACE_LOCAL_Y: float = 0.4
const EDGE_NORTH: int = 1
const EDGE_SOUTH: int = 2
const EDGE_EAST: int = 3
const EDGE_WEST: int = 4
const NETWORK_SNAPSHOT_INTERVAL: float = 0.1

## Distance in grid tiles between the two bogies (even only, min 2, max 6).
@export_range(2, 6, 2) var wagon_length: int = 4
## Extra floor tiles on each side beyond the bogie width.
@export_range(0, 2) var extra_width: int = 1

var front_bogie: TrainChassis = null
var rear_bogie: TrainChassis = null
var is_on_rails: bool = false

# Grid: width = bogie_width (3) + extra_width * 2, length = wagon_length
var grid_cells: Dictionary = {}  # Vector2i -> { "floor": bool, "item": Node3D, "edges": {}, "floor_node": Node3D }
var floor_count: int = 0

var _frame_visuals: Array[Node3D] = []
var _build_surface: StaticBody3D = null
var _floor_bodies: Array[StaticBody3D] = []
var _network_snapshot_accum: float = 0.0

# Split-path transition: rear bogie stays on old curve while front is on new curve
var _split_mode: bool = false
var _rear_old_curve: Curve3D = null
var _rear_old_total: float = 0.0
var _rear_old_rail_path: Node = null
var _junction_at_old_end: bool = true  # true = junction was at old curve's end
# Persistent direction flag for the current curve. True = front entered at
# rail_progress=0 (forward travel increases progress). False = front entered
# at rail_progress=total (forward travel decreases progress). Used so the
# rear bogie sits at the correct side of the front bogie on any curve, even
# after same-side junction transitions where the curve is traversed backward.
var _front_entered_at_start: bool = true


func _ready() -> void:
	if get_meta("is_preview", false):
		return
	add_to_group("wagon_frame")
	# Find bogies among children
	for child in get_children():
		if child is TrainChassis:
			if front_bogie == null:
				front_bogie = child
			elif rear_bogie == null:
				rear_bogie = child
	if front_bogie and rear_bogie:
		_setup_bogies()
		_build_frame_visuals()
		_build_collision_surface()


func _setup_bogies() -> void:
	# WagonFrame owns all movement — disable both bogies' independent physics.
	front_bogie.is_on_rails = false
	rear_bogie.is_on_rails = false
	# Front bogie runs before player for platform velocity
	process_physics_priority = -1


func _physics_process(delta: float) -> void:
	if get_meta("is_preview", false):
		return
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	if front_bogie == null or rear_bogie == null:
		return
	if not is_on_rails:
		return
	if front_bogie.rail_curve == null or front_bogie.rail_curve.get_baked_length() < 0.1:
		return

	# Movement (uses front bogie's speed/direction/friction)
	if absf(front_bogie.speed) < 0.01:
		if front_bogie.speed != 0.0:
			front_bogie.speed = 0.0
			front_bogie.speed_changed.emit(0.0)
			_set_platform_velocity(Vector3.ZERO)
		return

	front_bogie.speed = move_toward(front_bogie.speed, 0.0, front_bogie.friction * delta)
	var ds: float = front_bogie.speed * delta
	front_bogie.distance_traveled += absf(ds)

	var old_pos: Vector3 = global_position
	var curve: Curve3D = front_bogie.rail_curve
	var total: float = curve.get_baked_length()
	var spacing: float = float(wagon_length) * GRID_SIZE

	# Advance front bogie progress
	var raw_progress: float = front_bogie.rail_progress + ds
	# Bounds depend on direction flag: if front entered at start, rear sits
	# at front_progress - spacing, so we need front_progress >= spacing.
	# If front entered at end, rear sits at front_progress + spacing, so we
	# need front_progress <= total - spacing.  In split mode the rear is on
	# the old curve, so only the curve endpoints (0 / total) matter.
	var lower_bound: float
	var upper_bound: float
	if _split_mode:
		lower_bound = 0.0
		upper_bound = total
	elif _front_entered_at_start:
		lower_bound = spacing
		upper_bound = total
	else:
		lower_bound = 0.0
		upper_bound = total - spacing
	if raw_progress < lower_bound or raw_progress > upper_bound:
		var at_end: int = 0 if raw_progress < lower_bound else 1
		if _split_mode:
			# Already straddling a junction — stop rather than chain transitions
			front_bogie.rail_progress = 0.0 if at_end == 0 else total
			front_bogie.speed = 0.0
			front_bogie.speed_changed.emit(0.0)
			_set_platform_velocity(Vector3.ZERO)
			return
		# Compute overflow past the exited endpoint, and the endpoint index
		# (0=curve start, 1=curve end) for the transition call.
		var exit_end: int
		var overflow: float
		if at_end == 1:
			exit_end = 1
			overflow = raw_progress - upper_bound
		else:
			exit_end = 0
			overflow = lower_bound - raw_progress
		var old_curve_save: Curve3D = curve
		var old_total_save: float = total
		var old_path_save: Node = front_bogie.current_rail_path
		if front_bogie._try_path_transition(exit_end, overflow):
			_split_mode = true
			_rear_old_curve = old_curve_save
			_rear_old_total = old_total_save
			_rear_old_rail_path = old_path_save
			_junction_at_old_end = (exit_end == 1)
			_front_entered_at_start = front_bogie._last_transition_target_end == 0
			curve = front_bogie.rail_curve
			total = curve.get_baked_length()
		else:
			front_bogie.rail_progress = upper_bound if at_end == 1 else lower_bound
			front_bogie.speed = 0.0
			front_bogie.speed_changed.emit(0.0)
			_set_platform_velocity(Vector3.ZERO)
			return
	else:
		front_bogie.rail_progress = raw_progress

	# Sample positions
	var front_pos: Vector3 = curve.sample_baked(front_bogie.rail_progress)
	var rear_progress: float = 0.0
	var rear_pos: Vector3
	var rear_on_old_curve: bool = false
	var rear_old_progress: float = 0.0

	if _split_mode:
		# Compute how far the front bogie is from the junction along the new curve
		var front_dist: float
		if _front_entered_at_start:
			front_dist = front_bogie.rail_progress
		else:
			front_dist = total - front_bogie.rail_progress
		var rear_dist: float = spacing - front_dist

		if rear_dist <= 0.0:
			# Rear has crossed the junction — end split mode
			_split_mode = false
			_rear_old_curve = null
			_rear_old_rail_path = null
			if _front_entered_at_start:
				rear_progress = clampf(front_bogie.rail_progress - spacing, 0.0, total)
			else:
				rear_progress = clampf(front_bogie.rail_progress + spacing, 0.0, total)
			rear_pos = curve.sample_baked(rear_progress)
		else:
			rear_on_old_curve = true
			if _junction_at_old_end:
				rear_old_progress = clampf(_rear_old_total - rear_dist, 0.0, _rear_old_total)
			else:
				rear_old_progress = clampf(rear_dist, 0.0, _rear_old_total)
			rear_pos = _rear_old_curve.sample_baked(rear_old_progress)
	else:
		if _front_entered_at_start:
			rear_progress = clampf(front_bogie.rail_progress - spacing, 0.0, total)
		else:
			rear_progress = clampf(front_bogie.rail_progress + spacing, 0.0, total)
		rear_pos = curve.sample_baked(rear_progress)

	# Position WagonFrame at midpoint
	var mid: Vector3 = (front_pos + rear_pos) * 0.5
	global_position = mid

	# Orient WagonFrame along the line between bogies
	var frame_fwd: Vector3 = front_pos - rear_pos
	if frame_fwd.length_squared() > 0.001:
		frame_fwd = _stabilize_frame_forward(frame_fwd)
		var rt: Vector3 = Vector3.UP.cross(frame_fwd)
		if rt.length_squared() < 0.0001:
			rt = Vector3.RIGHT
		rt = rt.normalized()
		var up_v: Vector3 = frame_fwd.cross(rt).normalized()
		var target_basis := Basis(rt, up_v, frame_fwd)
		basis = basis.slerp(target_basis, minf(delta * 8.0, 1.0))

	# Position bogies relative to WagonFrame (local space)
	front_bogie.position = to_local(front_pos)
	rear_bogie.position = to_local(rear_pos)

	# Orient bogies to follow the curve (trucks pivot).
	# Use frame_fwd as the reference so bogies never flip 180° at junctions
	# where curve tangent direction reverses (same-side connections).
	var ref_fwd: Vector3 = frame_fwd if frame_fwd.length_squared() > 0.0001 else -global_basis.z
	_orient_bogie(front_bogie, front_bogie.rail_progress, curve, total, delta, ref_fwd)
	if rear_on_old_curve:
		_orient_bogie(rear_bogie, rear_old_progress, _rear_old_curve, _rear_old_total, delta, ref_fwd)
	else:
		_orient_bogie(rear_bogie, rear_progress, curve, total, delta, ref_fwd)

	# Sync rear bogie state for any code that reads it
	if rear_on_old_curve:
		rear_bogie.rail_curve = _rear_old_curve
		rear_bogie.rail_progress = rear_old_progress
	else:
		rear_bogie.rail_curve = curve
		rear_bogie.rail_progress = rear_progress
		rear_bogie.current_rail_path = front_bogie.current_rail_path

	# Platform velocity — use curve tangent on transition frame to avoid spike
	if front_bogie._just_transitioned:
		front_bogie._just_transitioned = false
		var total_t: float = curve.get_baked_length()
		var ahead_t: float = minf(front_bogie.rail_progress + 1.0, total_t)
		var behind_t: float = maxf(front_bogie.rail_progress - 1.0, 0.0)
		var fwd_t: Vector3 = curve.sample_baked(ahead_t) - curve.sample_baked(behind_t)
		if fwd_t.length_squared() > 0.0001:
			fwd_t = fwd_t.normalized()
		else:
			fwd_t = Vector3.FORWARD
		_set_platform_velocity(fwd_t * front_bogie.speed)
	else:
		var actual_vel: Vector3 = (global_position - old_pos) / delta
		_set_platform_velocity(actual_vel)

	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_network_snapshot_accum += delta
		if _network_snapshot_accum >= NETWORK_SNAPSHOT_INTERVAL:
			_network_snapshot_accum = 0.0
			WorldSync.broadcast_train_entity_snapshots()


func _orient_bogie(bogie: TrainChassis, progress: float, curve: Curve3D, total: float, delta: float, ref_fwd: Vector3 = Vector3.ZERO) -> void:
	var ahead: float = minf(progress + 1.0, total)
	var behind: float = maxf(progress - 1.0, 0.0)
	var fwd: Vector3 = curve.sample_baked(ahead) - curve.sample_baked(behind)
	if fwd.length_squared() > 0.0001:
		fwd = fwd.normalized()
		var desired_fwd := ref_fwd.normalized() if ref_fwd.length_squared() > 0.0001 else Vector3.ZERO
		# Keep the bogie aligned with the wagon axis across junctions.
		# Same-side transitions can reverse the curve tangent, which used to
		# trigger a visible 180° snap before the wagon settled on the next rail.
		if desired_fwd.length_squared() > 0.0001 and fwd.dot(desired_fwd) < 0.0:
			fwd = -fwd
		elif desired_fwd.length_squared() <= 0.0001:
			var prev_fwd: Vector3 = bogie.global_basis.z.normalized()
			if prev_fwd.length_squared() > 0.0001 and fwd.dot(prev_fwd) < 0.0:
				fwd = -fwd
		var rt: Vector3 = Vector3.UP.cross(fwd)
		if rt.length_squared() < 0.0001:
			rt = Vector3.RIGHT
		rt = rt.normalized()
		var up_v: Vector3 = fwd.cross(rt).normalized()
		var target_b := Basis(rt, up_v, fwd)
		bogie.global_basis = bogie.global_basis.orthonormalized().slerp(target_b, minf(delta * 8.0, 1.0)).scaled(bogie._basis_scale)


func _stabilize_frame_forward(candidate: Vector3, reference: Vector3 = Vector3.ZERO) -> Vector3:
	var fwd := candidate.normalized()
	if fwd.length_squared() < 0.0001:
		return Vector3.ZERO
	var desired := reference.normalized() if reference.length_squared() > 0.0001 else basis.z.normalized()
	if desired.length_squared() > 0.0001 and fwd.dot(desired) < 0.0:
		fwd = -fwd
	return fwd


func _set_platform_velocity(vel: Vector3) -> void:
	if front_bogie:
		front_bogie.constant_linear_velocity = vel
	if rear_bogie:
		rear_bogie.constant_linear_velocity = vel
	if _build_surface and is_instance_valid(_build_surface):
		_build_surface.constant_linear_velocity = vel
	for child in get_children():
		if child is StaticBody3D:
			child.constant_linear_velocity = vel
	for body in _floor_bodies:
		if is_instance_valid(body):
			body.constant_linear_velocity = vel


func snap_to_rails() -> void:
	if front_bogie == null:
		return
	is_on_rails = true
	# Let front bogie find the best rail path
	front_bogie.is_on_rails = true
	front_bogie.snap_to_rails()
	front_bogie.is_on_rails = false  # WagonFrame handles movement, not the bogie

	# Position everything from the bogie's found curve
	if front_bogie.rail_curve != null and front_bogie.rail_curve.get_baked_length() > 0.1:
		var curve: Curve3D = front_bogie.rail_curve
		var total: float = curve.get_baked_length()
		var spacing: float = float(wagon_length) * GRID_SIZE
		# Ensure front bogie is far enough from start for the rear bogie to fit
		front_bogie.rail_progress = maxf(front_bogie.rail_progress, spacing)
		var front_pos: Vector3 = curve.sample_baked(front_bogie.rail_progress)
		var rear_progress: float = front_bogie.rail_progress - spacing
		var rear_pos: Vector3 = curve.sample_baked(rear_progress)

		global_position = (front_pos + rear_pos) * 0.5
		front_bogie.position = to_local(front_pos)
		rear_bogie.position = to_local(rear_pos)

		# Orient frame
		var fwd: Vector3 = front_pos - rear_pos
		if fwd.length_squared() > 0.001:
			fwd = _stabilize_frame_forward(fwd)
			var rt: Vector3 = Vector3.UP.cross(fwd)
			if rt.length_squared() < 0.0001:
				rt = Vector3.RIGHT
			rt = rt.normalized()
			var up_v: Vector3 = fwd.cross(rt).normalized()
			basis = Basis(rt, up_v, fwd)

		rear_bogie.rail_curve = curve
		rear_bogie.rail_progress = rear_progress
		rear_bogie.current_rail_path = front_bogie.current_rail_path


func pump() -> void:
	if front_bogie:
		front_bogie.speed = clampf(
			front_bogie.speed + front_bogie.pump_impulse * front_bogie.travel_direction,
			-front_bogie.max_speed, front_bogie.max_speed)
		front_bogie.speed_changed.emit(front_bogie.speed)


func set_direction(dir: float) -> void:
	if front_bogie:
		front_bogie.set_direction(dir)


# --- Grid system ---

func get_grid_width() -> int:
	return 3 + extra_width * 2

func get_grid_length() -> int:
	# Tile count along z — bogies sit at z = ±wagon_length/2, so we need wagon_length+1 tiles
	# to cover both inclusive.
	return wagon_length + 1

func _grid_min_x() -> int:
	return -int(floor(float(get_grid_width()) / 2.0))

func _grid_max_x() -> int:
	return int(floor(float(get_grid_width() - 1) / 2.0))

func _grid_min_z() -> int:
	return -int(wagon_length / 2)

func _grid_max_z() -> int:
	return int(wagon_length / 2)

func is_grid_in_bounds(grid_pos: Vector2i) -> bool:
	return (
		grid_pos.x >= _grid_min_x() and grid_pos.x <= _grid_max_x()
		and grid_pos.y >= _grid_min_z() and grid_pos.y <= _grid_max_z()
	)

func get_grid_position(world_pos: Vector3) -> Vector2i:
	var local_pos := to_local(world_pos)
	var gx := _round_to_int(local_pos.x / GRID_SIZE)
	var gz := _round_to_int(local_pos.z / GRID_SIZE)
	return Vector2i(gx, gz)

func _round_to_int(v: float) -> int:
	return int(floor(v + 0.5)) if v >= 0.0 else int(ceil(v - 0.5))

func grid_to_local(grid_pos: Vector2i) -> Vector3:
	return Vector3(
		grid_pos.x * GRID_SIZE,
		0.0,
		grid_pos.y * GRID_SIZE
	)

func grid_to_world(grid_pos: Vector2i) -> Vector3:
	return to_global(grid_to_local(grid_pos))

func get_build_surface_local_y() -> float:
	return BUILD_SURFACE_LOCAL_Y

func get_build_surface_normal_world() -> Vector3:
	return global_basis.y.normalized()

func can_place_floor(grid_pos: Vector2i) -> bool:
	if not is_grid_in_bounds(grid_pos):
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
	if floor_node:
		_register_floor_body(floor_node)
	floor_placed.emit(grid_pos)

func _register_floor_body(floor_node: Node3D) -> void:
	for child in floor_node.get_children():
		if child is StaticBody3D:
			_floor_bodies.append(child)
			return

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


# --- Frame visuals ---

func _build_frame_visuals() -> void:
	# Lateral wood rails removed — kept as no-op for external callers.
	for vis in _frame_visuals:
		if is_instance_valid(vis):
			vis.queue_free()
	_frame_visuals.clear()


func _build_collision_surface() -> void:
	if _build_surface and is_instance_valid(_build_surface):
		_build_surface.queue_free()
	# Flat invisible box covering the full build grid so raycasts can hit it
	var width_m: float = float(get_grid_width()) * GRID_SIZE
	var length_m: float = float(get_grid_length()) * GRID_SIZE
	_build_surface = StaticBody3D.new()
	_build_surface.name = "BuildSurface"
	# Detection-only layer — player does NOT collide with this.
	# Walkable collision for placed tiles lives inside floor_piece.tscn.
	_build_surface.collision_layer = 128  # Layer 8 = BuildDetect
	_build_surface.collision_mask = 0
	var shape := BoxShape3D.new()
	shape.size = Vector3(width_m, 0.04, length_m)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, BUILD_SURFACE_LOCAL_Y, 0.0))
	_build_surface.add_child(col)
	add_child(_build_surface)
