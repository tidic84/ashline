@tool
extends Path3D
class_name RailPath

const PREVIEW_ROOT_NAME := "RailPreview"
const PREVIEW_RAILS_NAME := "Rails"
const PREVIEW_TIES_NAME := "Ties"
const PREVIEW_SECTIONS_NAME := "RailSections"
const RAIL_SECTION_SCENE_PATH := "res://assets/models/rails/rail_section.glb"

## Hand-placed rail path used by `TerrainGenerator` to build the tracks.
##
## Rails are meant to be realistic: piecewise-straight segments between
## control points, optionally rising from the ground but constrained by
## maximum horizontal (yaw) and vertical (pitch / grade) deltas between
## consecutive segments.
##
## Editor workflow:
##   1. Drop the `rail_path.tscn` node in your scene and edit the Path3D
##      curve in the viewport.
##   2. Set `smoothing_mode` to None (straight), Corner (tight), or
##      Distributed (natural railroad curves across adjacent segments).
##   3. Toggle `snap_to_ground` to pin points to terrain Y.
##   4. Use the action buttons to validate and enforce constraints.

@export_group("Constraints")
## Max yaw delta (degrees) between two consecutive segments. Turns larger
## than this are rejected by `action_validate` / clamped by `action_enforce`.
@export_range(1.0, 90.0, 0.5) var max_yaw_deg: float = 12.0
## Max pitch delta (degrees) between two consecutive segments. Controls
## how fast grade can change along the track.
@export_range(0.1, 45.0, 0.1) var max_pitch_delta_deg: float = 5.0
## Max absolute pitch (degrees) — caps how steep any single segment can be.
@export_range(0.1, 45.0, 0.1) var max_abs_pitch_deg: float = 15.0
## Minimum length (meters) for any segment between two points. Segments
## below this are flagged during validation.
@export_range(0.5, 50.0, 0.5) var min_segment_length: float = 4.0

@export_group("Shape")
@export_range(0.05, 1.0, 0.01) var curve_bake_interval: float = 0.2

@export_group("Smoothing")
## None: tangents left as-is (manual or zero).
## Corner: smooth curve only at the junction point (tight easement).
## Distributed: curve spreads across both adjacent segments (natural railroad feel).
@export_enum("None", "Corner", "Distributed") var smoothing_mode: int = 0:
	set(value):
		smoothing_mode = value
		_apply_smoothing()
		_preview_signature = ""

## How far (meters) the transition curve extends from each control point.
## Longer = gentler curve but eats more of the straight segment.
@export_range(1.0, 100.0, 0.5) var smooth_length: float = 10.0:
	set(value):
		smooth_length = maxf(value, 1.0)
		_apply_smoothing()
		_preview_signature = ""

## Maximum curvature rate (degrees per meter) for horizontal turns.
## Limits how tight the auto-generated curves can be.
@export_range(0.1, 10.0, 0.1) var max_curvature_deg_per_m: float = 2.0:
	set(value):
		max_curvature_deg_per_m = maxf(value, 0.1)
		_apply_smoothing()
		_preview_signature = ""

## Maximum vertical curvature rate (degrees per meter).
@export_range(0.1, 10.0, 0.1) var max_pitch_curvature_deg_per_m: float = 1.0:
	set(value):
		max_pitch_curvature_deg_per_m = maxf(value, 0.1)
		_apply_smoothing()
		_preview_signature = ""

@export_group("Ground")
## If true, point Y is pinned to terrain height on load. Leave off if
## you want segments to rise above the ground — you can still hit
## `action_snap_now` to snap the current selection manually.
@export var snap_to_ground: bool = false:
	set(value):
		snap_to_ground = value
		if Engine.is_editor_hint() and is_inside_tree():
			_snap_points_to_ground()

@export_range(-10.0, 10.0, 0.01) var ground_offset: float = 0.20

@export_group("Connections")
## Paths connected at the START of this rail (point 0).
@export var connections_at_start: Array[NodePath] = []
## Paths connected at the END of this rail (last point).
@export var connections_at_end: Array[NodePath] = []
## Max distance (meters) to auto-detect and snap nearby endpoints.
@export_range(0.5, 20.0, 0.5) var auto_connect_radius: float = 5.0
## Scan all RailPaths and connect this path's endpoints within radius.
## Snaps endpoints to match the neighbor exactly so meshes join visually.
@export var action_auto_connect: bool = false:
	set(value):
		if value:
			_auto_connect_endpoints()
		action_auto_connect = false
## Run auto-connect on ALL RailPaths in the scene (batch operation).
@export var action_auto_connect_all: bool = false:
	set(value):
		if value:
			_auto_connect_all_paths()
		action_auto_connect_all = false

@export_group("Preview")
@export var preview_enabled: bool = true
@export var preview_match_runtime_deformed: bool = false
@export var preview_follow_pitch: bool = true
@export var preview_adaptive_sampling: bool = true
@export_range(0.2, 5.0, 0.01) var preview_adaptive_min_step: float = 0.45
@export_range(0.5, 12.0, 0.01) var preview_adaptive_max_step: float = 2.4
@export_range(0.0, 6.0, 0.01) var preview_curve_influence: float = 2.2
@export_range(0.0, 6.0, 0.01) var preview_pitch_influence: float = 1.8
@export var preview_real_rails_enabled: bool = true
@export var preview_real_auto_section_length: bool = true
@export_range(0.5, 10.0, 0.01) var preview_real_section_length: float = 2.4
@export_range(-180.0, 180.0, 0.1) var preview_real_yaw_offset_deg: float = -90.0
@export_range(0.2, 2.5, 0.01) var preview_rail_gauge: float = 1.0
@export_range(0.1, 2.0, 0.01) var preview_sample_step: float = 0.5
@export_range(0.2, 2.5, 0.01) var preview_tie_spacing: float = 0.55
@export var preview_show_ties: bool = true

@export_group("Actions")
## Re-apply smoothing to tangents (useful after manually moving points).
@export var action_apply_smoothing: bool = false:
	set(value):
		if value:
			_apply_smoothing()
		action_apply_smoothing = false

## Log warnings for every point that violates yaw/pitch/length constraints.
@export var action_validate: bool = false:
	set(value):
		if value:
			_validate_constraints()
		action_validate = false

## Clamp each point's Y (grade) and lateral offset so yaw/pitch stay
## within the configured limits. Walks the path forward from point 0.
@export var action_enforce: bool = false:
	set(value):
		if value:
			_enforce_constraints()
		action_enforce = false

## Re-snap now (editor button via tool reload).
@export var action_snap_now: bool = false:
	set(value):
		if value:
			_snap_points_to_ground()
		action_snap_now = false

## Reset to a clean long-straight curve with a gentle climb.
@export var action_reset_curve: bool = false:
	set(value):
		if value:
			_reset_default_curve()
		action_reset_curve = false

var _preview_signature := ""
var _preview_rails_material: StandardMaterial3D
var _preview_ties_material: StandardMaterial3D
var _preview_section_scene: PackedScene = null
var _preview_section_length_cache: float = -1.0
var _editor_point_positions_hash := ""


func _ready() -> void:
	add_to_group("rail_path")
	if curve == null:
		curve = Curve3D.new()
	curve.bake_interval = curve_bake_interval
	if Engine.is_editor_hint():
		_ensure_preview_materials()
		_update_preview_mesh(true)
		return
	# Register with RailNetwork and set up connections
	if not Engine.is_editor_hint():
		RailNetwork.register_path(self)
		call_deferred("_register_connections")
	if curve.point_count == 0:
		_reset_default_curve()
	_apply_smoothing()
	if snap_to_ground:
		await get_tree().process_frame
		_snap_points_to_ground()


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		set_process(false)
		return
	if curve and not is_equal_approx(curve.bake_interval, curve_bake_interval):
		curve.bake_interval = curve_bake_interval
	if smoothing_mode > 0:
		var pos_hash := _build_point_positions_hash()
		if pos_hash != _editor_point_positions_hash:
			_editor_point_positions_hash = pos_hash
			_apply_smoothing()
	_update_preview_mesh()


func get_rail_curve() -> Curve3D:
	return curve


func _register_connections() -> void:
	for np in connections_at_start:
		var node := get_node_or_null(np)
		if node is RailPath:
			if node == self:
				# Self-loop: start connects to own end
				RailNetwork.add_connection(self, 0, self, 1)
			else:
				var target_end := _closest_end_of(node as RailPath, _get_start_world())
				RailNetwork.add_connection(self, 0, node, target_end)
	for np in connections_at_end:
		var node := get_node_or_null(np)
		if node is RailPath:
			if node == self:
				# Self-loop: end connects to own start
				RailNetwork.add_connection(self, 1, self, 0)
			else:
				var target_end := _closest_end_of(node as RailPath, _get_end_world())
				RailNetwork.add_connection(self, 1, node, target_end)


func _get_start_world() -> Vector3:
	if curve == null or curve.point_count == 0:
		return global_position
	return to_global(curve.get_point_position(0))


func _get_end_world() -> Vector3:
	if curve == null or curve.point_count < 2:
		return global_position
	return to_global(curve.get_point_position(curve.point_count - 1))


func _closest_end_of(other: RailPath, world_pos: Vector3) -> int:
	var start_dist := world_pos.distance_squared_to(other._get_start_world())
	var end_dist := world_pos.distance_squared_to(other._get_end_world())
	return 0 if start_dist < end_dist else 1


func _auto_connect_endpoints() -> void:
	if curve == null or curve.point_count < 2:
		push_warning("[RailPath] Need at least 2 points to auto-connect")
		return
	var tree := get_tree()
	if tree == null:
		return
	var others: Array[RailPath] = []
	for node in tree.get_nodes_in_group("rail_path"):
		if node is RailPath and node != self:
			others.append(node as RailPath)
	if others.is_empty():
		push_warning("[RailPath] No other RailPaths found to connect to")
		return

	var radius_sq := auto_connect_radius * auto_connect_radius
	var my_start := _get_start_world()
	var my_end := _get_end_world()
	var found_start := 0
	var found_end := 0

	connections_at_start.clear()
	connections_at_end.clear()

	for other in others:
		if other.curve == null or other.curve.point_count < 2:
			continue
		var other_start := other._get_start_world()
		var other_end := other._get_end_world()

		# Check MY START against other's endpoints
		var dist_to_other_start := my_start.distance_squared_to(other_start)
		var dist_to_other_end := my_start.distance_squared_to(other_end)
		if dist_to_other_start < radius_sq or dist_to_other_end < radius_sq:
			var closer_end: int
			var snap_target: Vector3
			if dist_to_other_start < dist_to_other_end:
				closer_end = 0
				snap_target = other_start
			else:
				closer_end = 1
				snap_target = other_end
			# Snap my start point to match neighbor exactly
			curve.set_point_position(0, to_local(snap_target))
			my_start = snap_target
			var np := get_path_to(other)
			if np not in connections_at_start:
				connections_at_start.append(np)
			found_start += 1
			# Align tangent at my start toward neighbor's direction
			_align_tangent_at_junction(0, other, closer_end)

		# Check MY END against other's endpoints
		var last_idx := curve.point_count - 1
		var dist_end_to_other_start := my_end.distance_squared_to(other_start)
		var dist_end_to_other_end := my_end.distance_squared_to(other_end)
		if dist_end_to_other_start < radius_sq or dist_end_to_other_end < radius_sq:
			var closer_end: int
			var snap_target: Vector3
			if dist_end_to_other_start < dist_end_to_other_end:
				closer_end = 0
				snap_target = other_start
			else:
				closer_end = 1
				snap_target = other_end
			# Snap my end point to match neighbor exactly
			curve.set_point_position(last_idx, to_local(snap_target))
			my_end = snap_target
			var np := get_path_to(other)
			if np not in connections_at_end:
				connections_at_end.append(np)
			found_end += 1
			_align_tangent_at_junction(last_idx, other, closer_end)

	_preview_signature = ""
	notify_property_list_changed()
	print("[RailPath] Auto-connect: %d at start, %d at end (radius=%.1fm)" % [found_start, found_end, auto_connect_radius])


func _auto_connect_all_paths() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var all_paths: Array[RailPath] = []
	for node in tree.get_nodes_in_group("rail_path"):
		if node is RailPath:
			all_paths.append(node as RailPath)
	print("[RailPath] Auto-connect ALL: processing %d paths..." % all_paths.size())
	for path in all_paths:
		path._auto_connect_endpoints()
	print("[RailPath] Auto-connect ALL: done.")


func _align_tangent_at_junction(my_point_idx: int, other: RailPath, other_end: int) -> void:
	## Make tangent at junction smooth so rail meshes join visually.
	## Points the tangent toward the other path's interior direction.
	if other.curve == null or other.curve.point_count < 2:
		return
	var other_curve := other.curve
	var other_idx: int
	var other_interior_idx: int
	if other_end == 0:
		other_idx = 0
		other_interior_idx = 1
	else:
		other_idx = other_curve.point_count - 1
		other_interior_idx = other_curve.point_count - 2
	# Direction from junction toward other path's interior (in world space)
	var junction_world := other.to_global(other_curve.get_point_position(other_idx))
	var interior_world := other.to_global(other_curve.get_point_position(other_interior_idx))
	var other_dir := (interior_world - junction_world).normalized()

	# My interior direction
	var my_pos := curve.get_point_position(my_point_idx)
	var my_interior_idx: int
	if my_point_idx == 0:
		my_interior_idx = 1
	else:
		my_interior_idx = curve.point_count - 2
	var my_interior_world := to_global(curve.get_point_position(my_interior_idx))
	var my_junction_world := to_global(my_pos)
	var my_dir := (my_interior_world - my_junction_world).normalized()

	# Tangent length = fraction of distance to interior point
	var tangent_len := my_junction_world.distance_to(my_interior_world) * 0.3
	tangent_len = clampf(tangent_len, 1.0, smooth_length)

	# Set tangent pointing toward my interior (in local space)
	var tangent_local := to_local(my_junction_world + my_dir * tangent_len) - my_pos
	if my_point_idx == 0:
		curve.set_point_out(0, tangent_local)
		# in-tangent points toward the connected path
		var in_local := to_local(my_junction_world + other_dir * tangent_len) - my_pos
		curve.set_point_in(0, in_local)
	else:
		# in-tangent must point toward the interior so the Bézier control
		# point stays on the approach side of the junction (same convention
		# as _apply_smoothing: in = -dir_before * len, i.e. toward prev point).
		curve.set_point_in(my_point_idx, tangent_local)
		var out_local := to_local(my_junction_world + other_dir * tangent_len) - my_pos
		curve.set_point_out(my_point_idx, out_local)


func _build_point_positions_hash() -> String:
	if curve == null:
		return ""
	var parts := PackedStringArray()
	parts.append(str(curve.point_count))
	for i in range(curve.point_count):
		var p := curve.get_point_position(i)
		parts.append("%.3f,%.3f,%.3f" % [p.x, p.y, p.z])
	return "|".join(parts)


# --- Smoothing ---

func _apply_smoothing() -> void:
	_apply_smoothing_internal({})


func _apply_smoothing_internal(visited: Dictionary) -> void:
	var visit_key := get_instance_id()
	if visited.has(visit_key):
		return
	visited[visit_key] = true

	if curve == null or curve.point_count < 2:
		return
	if not is_inside_tree():
		return

	# Mode 0 = None: zero all tangents (straight segments)
	if smoothing_mode == 0:
		for i in range(curve.point_count):
			curve.set_point_in(i, Vector3.ZERO)
			curve.set_point_out(i, Vector3.ZERO)
		_preview_signature = ""
		return

	var n := curve.point_count
	var start_connections := _get_connected_paths_for_endpoint(0)
	var end_connections := _get_connected_paths_for_endpoint(1)

	# Compute segment directions and lengths
	var seg_dirs: Array[Vector3] = []
	var seg_lens: Array[float] = []
	for i in range(n - 1):
		var seg: Vector3 = curve.get_point_position(i + 1) - curve.get_point_position(i)
		seg_lens.append(seg.length())
		seg_dirs.append(seg.normalized() if seg.length() > 0.001 else Vector3.FORWARD)

	# First and last points: zero tangents unless connected to another path
	# (connections set tangents for visual continuity at junctions)
	var start_connected := not start_connections.is_empty()
	var end_connected := not end_connections.is_empty()
	if not start_connected:
		curve.set_point_in(0, Vector3.ZERO)
		curve.set_point_out(0, Vector3.ZERO)
	if not end_connected:
		curve.set_point_in(n - 1, Vector3.ZERO)
		curve.set_point_out(n - 1, Vector3.ZERO)

	# For interior points, compute smooth tangents
	for i in range(1, n - 1):
		var dir_before: Vector3 = seg_dirs[i - 1]
		var dir_after: Vector3 = seg_dirs[i]
		var len_before: float = seg_lens[i - 1]
		var len_after: float = seg_lens[i]

		# Yaw angle between segments
		var h_before := Vector3(dir_before.x, 0.0, dir_before.z)
		var h_after := Vector3(dir_after.x, 0.0, dir_after.z)
		var yaw_deg := 0.0
		if h_before.length_squared() > 0.0001 and h_after.length_squared() > 0.0001:
			yaw_deg = rad_to_deg(h_before.normalized().angle_to(h_after.normalized()))

		# Pitch change
		var pitch_before := _pitch_of(dir_before)
		var pitch_after := _pitch_of(dir_after)
		var pitch_delta := absf(pitch_after - pitch_before)

		# Compute tangent length clamped by curvature limits
		var tangent_len: float = smooth_length

		# Clamp by yaw curvature: angle / tangent_len <= max_curvature_deg_per_m
		if yaw_deg > 0.001:
			var max_len_for_yaw := yaw_deg / max_curvature_deg_per_m
			tangent_len = minf(tangent_len, max_len_for_yaw)

		# Clamp by pitch curvature
		if pitch_delta > 0.001:
			var max_len_for_pitch := pitch_delta / max_pitch_curvature_deg_per_m
			tangent_len = minf(tangent_len, max_len_for_pitch)

		# Don't exceed half the adjacent segment length
		tangent_len = minf(tangent_len, len_before * 0.45)
		tangent_len = minf(tangent_len, len_after * 0.45)
		tangent_len = maxf(tangent_len, 0.5)

		if smoothing_mode == 1:
			# Corner mode: tangent along the bisector direction, short
			# Uses incoming/outgoing directions directly
			var tangent_out: Vector3 = dir_after * tangent_len
			var tangent_in: Vector3 = -dir_before * tangent_len
			curve.set_point_in(i, tangent_in)
			curve.set_point_out(i, tangent_out)

		elif smoothing_mode == 2:
			# Distributed mode: blend curve across both segments
			# Tangent direction = average of incoming and outgoing
			var blend_dir: Vector3 = (dir_before + dir_after).normalized()
			if blend_dir.length_squared() < 0.0001:
				blend_dir = dir_after
			var tangent_out: Vector3 = blend_dir * tangent_len
			var tangent_in: Vector3 = -blend_dir * tangent_len
			curve.set_point_in(i, tangent_in)
			curve.set_point_out(i, tangent_out)

	if start_connected:
		_apply_endpoint_smoothing(0, start_connections)
	if end_connected:
		_apply_endpoint_smoothing(n - 1, end_connections)

	_preview_signature = ""

	for other in _get_all_connected_paths():
		if is_instance_valid(other):
			other._apply_smoothing_internal(visited)


func _get_connected_paths_for_endpoint(endpoint: int) -> Array[RailPath]:
	var result: Array[RailPath] = []
	var node_paths: Array[NodePath] = connections_at_start if endpoint == 0 else connections_at_end
	for np in node_paths:
		var node := get_node_or_null(np)
		if node is RailPath and node not in result:
			result.append(node as RailPath)
	return result


func _get_all_connected_paths() -> Array[RailPath]:
	var result: Array[RailPath] = []
	for path in _get_connected_paths_for_endpoint(0):
		if path not in result:
			result.append(path)
	for path in _get_connected_paths_for_endpoint(1):
		if path not in result:
			result.append(path)
	return result


func _apply_endpoint_smoothing(point_idx: int, connected_paths: Array[RailPath]) -> void:
	var endpoint := 0 if point_idx == 0 else 1
	var self_state := _get_endpoint_state_world(endpoint)
	if self_state.is_empty():
		curve.set_point_in(point_idx, Vector3.ZERO)
		curve.set_point_out(point_idx, Vector3.ZERO)
		return

	var junction_world: Vector3 = self_state.junction
	var axis_dir: Vector3 = self_state.dir
	var tangent_len: float = smooth_length
	var segment_lengths: Array[float] = [self_state.length]

	for other in connected_paths:
		if not is_instance_valid(other):
			continue
		var other_endpoint := 1 - endpoint if other == self else _closest_end_of(other, junction_world)
		var other_state := other._get_endpoint_state_world(other_endpoint)
		if other_state.is_empty():
			continue
		var other_dir: Vector3 = other_state.dir
		if axis_dir.length_squared() > 0.0001 and other_dir.dot(axis_dir) < 0.0:
			other_dir = -other_dir
		axis_dir += other_dir
		segment_lengths.append(other_state.length)

	axis_dir = axis_dir.normalized()
	if axis_dir.length_squared() < 0.0001:
		axis_dir = self_state.dir
	if axis_dir.length_squared() < 0.0001:
		curve.set_point_in(point_idx, Vector3.ZERO)
		curve.set_point_out(point_idx, Vector3.ZERO)
		return

	var yaw_deg := _yaw_delta_deg(self_state.dir, axis_dir)
	if yaw_deg > 0.001:
		tangent_len = minf(tangent_len, yaw_deg / max_curvature_deg_per_m)

	var pitch_delta := absf(_pitch_of(axis_dir) - _pitch_of(self_state.dir))
	if pitch_delta > 0.001:
		tangent_len = minf(tangent_len, pitch_delta / max_pitch_curvature_deg_per_m)

	for seg_len in segment_lengths:
		tangent_len = minf(tangent_len, seg_len * 0.45)
	tangent_len = clampf(tangent_len, 0.5, smooth_length)

	var local_anchor := curve.get_point_position(point_idx)
	var toward_interior := to_local(junction_world + axis_dir * tangent_len) - local_anchor
	var toward_connection := to_local(junction_world - axis_dir * tangent_len) - local_anchor
	if endpoint == 0:
		curve.set_point_in(point_idx, toward_connection)
		curve.set_point_out(point_idx, toward_interior)
	else:
		curve.set_point_in(point_idx, toward_interior)
		curve.set_point_out(point_idx, toward_connection)


func _get_endpoint_state_world(endpoint: int) -> Dictionary:
	if curve == null or curve.point_count < 2:
		return {}
	var point_idx := 0 if endpoint == 0 else curve.point_count - 1
	var junction_world := to_global(curve.get_point_position(point_idx))
	var step := 1 if endpoint == 0 else -1
	var stop := curve.point_count if step > 0 else -1
	for idx in range(point_idx + step, stop, step):
		var candidate_world := to_global(curve.get_point_position(idx))
		var delta := candidate_world - junction_world
		var seg_len := delta.length()
		if seg_len > 0.001:
			return {
				"junction": junction_world,
				"dir": delta / seg_len,
				"length": seg_len,
			}
	return {}


# --- Validation ---

func _validate_constraints() -> void:
	if curve == null or curve.point_count < 2:
		print("[RailPath] curve empty — nothing to validate")
		return
	var issues: int = 0
	var prev_fwd: Vector3 = Vector3.ZERO
	for i in range(curve.point_count - 1):
		var a: Vector3 = curve.get_point_position(i)
		var b: Vector3 = curve.get_point_position(i + 1)
		var seg: Vector3 = b - a
		var seg_len: float = seg.length()
		if seg_len < min_segment_length:
			print("[RailPath] segment %d: length %.2fm < min %.2fm" % [i, seg_len, min_segment_length])
			issues += 1
		var pitch_deg: float = _pitch_of(seg)
		if absf(pitch_deg) > max_abs_pitch_deg:
			print("[RailPath] segment %d: pitch %.2f° exceeds max %.2f°" % [i, pitch_deg, max_abs_pitch_deg])
			issues += 1
		if prev_fwd.length_squared() > 0.0001:
			var yaw_delta: float = _yaw_delta_deg(prev_fwd, seg)
			if yaw_delta > max_yaw_deg:
				print("[RailPath] segment %d: yaw delta %.2f° exceeds max %.2f°" % [i, yaw_delta, max_yaw_deg])
				issues += 1
			var prev_pitch: float = _pitch_of(prev_fwd)
			var pitch_delta: float = absf(pitch_deg - prev_pitch)
			if pitch_delta > max_pitch_delta_deg:
				print("[RailPath] segment %d: pitch delta %.2f° exceeds max %.2f°" % [i, pitch_delta, max_pitch_delta_deg])
				issues += 1
		prev_fwd = seg
	if issues == 0:
		print("[RailPath] validation OK — %d segments within constraints" % (curve.point_count - 1))
	else:
		push_warning("[RailPath] %d constraint violations found" % issues)


# --- Enforce (clamp) ---

func _enforce_constraints() -> void:
	if curve == null or curve.point_count < 2:
		return
	var prev_fwd: Vector3 = Vector3.ZERO
	for i in range(curve.point_count - 1):
		var a: Vector3 = curve.get_point_position(i)
		var b: Vector3 = curve.get_point_position(i + 1)
		var seg: Vector3 = b - a
		var h: Vector3 = Vector3(seg.x, 0.0, seg.z)
		var h_len: float = h.length()
		if h_len < 0.001:
			continue
		# Clamp yaw to previous segment
		if prev_fwd.length_squared() > 0.0001:
			var prev_h: Vector3 = Vector3(prev_fwd.x, 0.0, prev_fwd.z)
			if prev_h.length_squared() > 0.0001:
				prev_h = prev_h.normalized()
				var cur_h: Vector3 = h.normalized()
				var yaw_delta: float = rad_to_deg(cur_h.angle_to(prev_h))
				if yaw_delta > max_yaw_deg:
					var axis: Vector3 = prev_h.cross(cur_h)
					var sign: float = signf(axis.y) if absf(axis.y) > 0.0001 else 1.0
					var clamped := prev_h.rotated(Vector3.UP, deg_to_rad(max_yaw_deg) * sign)
					h = clamped * h_len
		# Clamp absolute pitch
		var pitch: float = _pitch_of(Vector3(h.x, seg.y, h.z))
		var max_pitch: float = max_abs_pitch_deg
		# Also clamp pitch delta vs previous segment
		if prev_fwd.length_squared() > 0.0001:
			var prev_pitch: float = _pitch_of(prev_fwd)
			var lo: float = prev_pitch - max_pitch_delta_deg
			var hi: float = prev_pitch + max_pitch_delta_deg
			max_pitch = minf(max_pitch, hi)
			pitch = maxf(pitch, lo)
		pitch = clampf(pitch, -max_abs_pitch_deg, max_pitch)
		var new_y: float = h.length() * tan(deg_to_rad(pitch))
		var new_seg := Vector3(h.x, new_y, h.z)
		var new_b: Vector3 = a + new_seg
		curve.set_point_position(i + 1, new_b)
		prev_fwd = new_seg
	print("[RailPath] constraints enforced")
	_preview_signature = ""


func _pitch_of(v: Vector3) -> float:
	var h: float = Vector2(v.x, v.z).length()
	if h < 0.0001:
		return 0.0 if absf(v.y) < 0.0001 else (90.0 if v.y > 0.0 else -90.0)
	return rad_to_deg(atan2(v.y, h))


func _yaw_delta_deg(a: Vector3, b: Vector3) -> float:
	var ha := Vector3(a.x, 0.0, a.z)
	var hb := Vector3(b.x, 0.0, b.z)
	if ha.length_squared() < 0.0001 or hb.length_squared() < 0.0001:
		return 0.0
	return rad_to_deg(ha.normalized().angle_to(hb.normalized()))


# --- Ground snap ---

func _snap_points_to_ground() -> void:
	if not is_inside_tree():
		return
	if curve == null or curve.point_count == 0:
		return
	var terrain := _find_terrain_node()
	if terrain == null:
		push_warning("RailPath: no terrain found to snap against")
		return
	for i in range(curve.point_count):
		var p: Vector3 = curve.get_point_position(i)
		var world_p: Vector3 = to_global(p)
		var local_t: Vector3 = terrain.to_local(Vector3(world_p.x, 0.0, world_p.z))
		var h: float = terrain._sample_height(local_t.x, local_t.z) + ground_offset
		world_p.y = h
		curve.set_point_position(i, to_local(world_p))
	_preview_signature = ""


# --- Default curve ---

func _reset_default_curve() -> void:
	if curve == null:
		curve = Curve3D.new()
	curve.clear_points()
	# Long straight with a single gentle bend and a small climb at the end.
	# Tangents are left at zero so segments stay straight.
	var points: Array[Vector3] = [
		Vector3(0.0, 0.0, -60.0),
		Vector3(0.0, 0.0, -20.0),
		Vector3(0.0, 0.0, 20.0),
		Vector3(6.0, 0.0, 60.0),
		Vector3(12.0, 1.5, 100.0),
		Vector3(12.0, 3.0, 140.0),
	]
	for p in points:
		curve.add_point(p, Vector3.ZERO, Vector3.ZERO)
	if snap_to_ground:
		_snap_points_to_ground()
	_preview_signature = ""


func _find_terrain_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var root: Node = tree.edited_scene_root if Engine.is_editor_hint() else tree.current_scene
	if root == null:
		return null
	return _search_terrain(root)


func _search_terrain(node: Node) -> Node:
	if node == null:
		return null
	if node != self and node.has_method("_sample_height"):
		return node
	for c in node.get_children():
		var found := _search_terrain(c)
		if found:
			return found
	return null


# --- Editor preview ---

func _ensure_preview_materials() -> void:
	if _preview_rails_material == null:
		_preview_rails_material = StandardMaterial3D.new()
		_preview_rails_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		_preview_rails_material.albedo_color = Color(0.60, 0.62, 0.66, 1.0)
		_preview_rails_material.metallic = 0.65
		_preview_rails_material.roughness = 0.45
		_preview_rails_material.vertex_color_use_as_albedo = false
		_preview_rails_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	if _preview_ties_material == null:
		_preview_ties_material = StandardMaterial3D.new()
		_preview_ties_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		_preview_ties_material.albedo_color = Color(0.33, 0.22, 0.14, 1.0)
		_preview_ties_material.roughness = 0.9
		_preview_ties_material.vertex_color_use_as_albedo = false
		_preview_ties_material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED


func _update_preview_mesh(force: bool = false) -> void:
	if not Engine.is_editor_hint():
		return
	var signature := _build_preview_signature()
	if not force and signature == _preview_signature:
		return
	_preview_signature = signature

	if not preview_enabled or curve == null or curve.point_count < 2:
		_clear_preview_mesh()
		return

	_ensure_preview_materials()
	var root := _ensure_preview_root()
	if root == null:
		return

	if preview_match_runtime_deformed and _build_preview_deformed_rails(root):
		var sections_old_match := root.get_node_or_null(PREVIEW_SECTIONS_NAME)
		if sections_old_match != null:
			_free_preview_node(sections_old_match)
		return

	if preview_real_rails_enabled and _build_preview_real_sections(root):
		var rails_old := root.get_node_or_null(PREVIEW_RAILS_NAME)
		if rails_old != null:
			_free_preview_node(rails_old)
		var ties_old := root.get_node_or_null(PREVIEW_TIES_NAME)
		if ties_old != null:
			_free_preview_node(ties_old)
		return

	var sections_old := root.get_node_or_null(PREVIEW_SECTIONS_NAME)
	if sections_old != null:
		_free_preview_node(sections_old)

	var rails_mesh := _build_preview_rails_mesh()
	var rails := root.get_node_or_null(PREVIEW_RAILS_NAME) as MeshInstance3D
	if rails == null:
		rails = MeshInstance3D.new()
		rails.name = PREVIEW_RAILS_NAME
		rails.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(rails)
	rails.mesh = rails_mesh
	rails.material_override = _preview_rails_material

	if preview_show_ties:
		var ties_mesh := _build_preview_ties_mesh()
		var ties := root.get_node_or_null(PREVIEW_TIES_NAME) as MeshInstance3D
		if ties == null:
			ties = MeshInstance3D.new()
			ties.name = PREVIEW_TIES_NAME
			ties.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(ties)
		ties.mesh = ties_mesh
		ties.material_override = _preview_ties_material
	else:
		var ties_old := root.get_node_or_null(PREVIEW_TIES_NAME)
		if ties_old != null:
			_free_preview_node(ties_old)


func _build_preview_signature() -> String:
	if curve == null:
		return "no_curve"
	var parts := PackedStringArray()
	parts.append(str(preview_enabled))
	parts.append(str(preview_match_runtime_deformed))
	parts.append(str(preview_follow_pitch))
	parts.append(str(preview_adaptive_sampling))
	parts.append("%.3f" % preview_adaptive_min_step)
	parts.append("%.3f" % preview_adaptive_max_step)
	parts.append("%.3f" % preview_curve_influence)
	parts.append("%.3f" % preview_pitch_influence)
	parts.append(str(preview_real_rails_enabled))
	parts.append(str(preview_real_auto_section_length))
	parts.append("%.3f" % preview_real_section_length)
	parts.append("%.3f" % preview_real_yaw_offset_deg)
	parts.append(str(preview_show_ties))
	parts.append("%.3f" % preview_rail_gauge)
	parts.append("%.3f" % preview_sample_step)
	parts.append("%.3f" % preview_tie_spacing)
	parts.append(str(smoothing_mode))
	parts.append("%.2f" % smooth_length)
	parts.append("%.2f" % max_curvature_deg_per_m)
	parts.append("%.2f" % max_pitch_curvature_deg_per_m)
	parts.append(str(curve.point_count))
	for i in range(curve.point_count):
		var p := curve.get_point_position(i)
		var ti := curve.get_point_in(i)
		var to := curve.get_point_out(i)
		parts.append("%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f" % [p.x, p.y, p.z, ti.x, ti.y, ti.z, to.x, to.y, to.z])
	return "::".join(parts)


func _adaptive_preview_step(offset: float, base_step: float, total_len: float) -> float:
	if not preview_adaptive_sampling:
		return maxf(base_step, 0.05)
	var complexity := _preview_complexity_at_offset(offset, total_len)
	var min_step := minf(preview_adaptive_min_step, preview_adaptive_max_step)
	var max_step := maxf(preview_adaptive_min_step, preview_adaptive_max_step)
	var target := base_step / (1.0 + complexity)
	return clampf(target, min_step, max_step)


func _preview_complexity_at_offset(offset: float, total_len: float) -> float:
	var d := 1.0
	var p0 := maxf(offset - d, 0.0)
	var p1 := offset
	var p2 := minf(offset + d, total_len)
	var f0 := curve.sample_baked(p1) - curve.sample_baked(p0)
	var f1 := curve.sample_baked(p2) - curve.sample_baked(p1)
	if f0.length_squared() < 0.00001 or f1.length_squared() < 0.00001:
		return 0.0
	var h0 := Vector3(f0.x, 0.0, f0.z)
	var h1 := Vector3(f1.x, 0.0, f1.z)
	var yaw_delta := 0.0
	if h0.length_squared() > 0.00001 and h1.length_squared() > 0.00001:
		yaw_delta = rad_to_deg(h0.normalized().angle_to(h1.normalized()))
	var pitch0 := _pitch_of(f0)
	var pitch1 := _pitch_of(f1)
	var pitch_delta := absf(pitch1 - pitch0)
	return (yaw_delta / 45.0) * preview_curve_influence + (pitch_delta / 20.0) * preview_pitch_influence


func _ensure_preview_root() -> Node3D:
	var root := get_node_or_null(PREVIEW_ROOT_NAME) as Node3D
	if root != null:
		root.visible = true
		return root
	root = Node3D.new()
	root.name = PREVIEW_ROOT_NAME
	root.set_meta("editor_only", true)
	add_child(root)
	return root


func _clear_preview_mesh() -> void:
	var root := get_node_or_null(PREVIEW_ROOT_NAME)
	if root != null:
		_free_preview_node(root)


func _free_preview_node(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var parent := node.get_parent()
	if parent != null:
		parent.remove_child(node)
	node.free()


func _sample_preview_frame(offset: float, total_len: float) -> Dictionary:
	var pos := curve.sample_baked(offset)
	var ahead := minf(offset + 0.5, total_len)
	var behind := maxf(offset - 0.5, 0.0)
	var fwd := curve.sample_baked(ahead) - curve.sample_baked(behind)
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var right := Vector3.UP.cross(fwd)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	right = right.normalized()
	var up := fwd.cross(right)
	if up.length_squared() < 0.0001:
		up = Vector3.UP
	else:
		up = up.normalized()
	return {
		"pos": pos,
		"right": right,
		"up": up,
		"fwd": fwd,
	}


func _build_preview_deformed_rails(root: Node3D) -> bool:
	if curve == null or curve.point_count < 2:
		return false
	var total_len := curve.get_baked_length()
	if total_len <= 0.001:
		return false

	var step := maxf(preview_sample_step, 0.05)
	var samples: Array[Transform3D] = []
	var offset := 0.0
	while offset <= total_len:
		samples.append(_sample_track_transform_from_curve(curve, offset, preview_follow_pitch))
		offset += step
	samples.append(_sample_track_transform_from_curve(curve, total_len, preview_follow_pitch))
	if samples.size() < 2:
		return false

	var sections_old := root.get_node_or_null(PREVIEW_SECTIONS_NAME)
	if sections_old != null:
		_free_preview_node(sections_old)

	var rails_node := root.get_node_or_null(PREVIEW_RAILS_NAME) as Node3D
	if rails_node == null:
		rails_node = Node3D.new()
		rails_node.name = PREVIEW_RAILS_NAME
		rails_node.set_meta("editor_only", true)
		root.add_child(rails_node)
	var rails_children := rails_node.get_children()
	for child in rails_children:
		rails_node.remove_child(child)
		child.free()

	var half_gauge := maxf(preview_rail_gauge * 0.5, 0.05)
	for side in [-1.0, 1.0]:
		var mesh := _build_preview_rail_strip_mesh(samples, half_gauge * side)
		var mi := MeshInstance3D.new()
		mi.name = "Rail_L" if side < 0.0 else "Rail_R"
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.material_override = _preview_rails_material
		rails_node.add_child(mi)

	var ties_old := root.get_node_or_null(PREVIEW_TIES_NAME)
	if ties_old != null:
		_free_preview_node(ties_old)
	if preview_show_ties:
		var tie_spacing := maxf(preview_tie_spacing, 0.1)
		var tie_count := int(total_len / tie_spacing)
		if tie_count > 0:
			var tie_mesh := BoxMesh.new()
			tie_mesh.size = Vector3(maxf(preview_rail_gauge + 0.6, 1.2), 0.08, 0.12)
			var tmm := MultiMesh.new()
			tmm.transform_format = MultiMesh.TRANSFORM_3D
			tmm.mesh = tie_mesh
			tmm.instance_count = tie_count
			for i in range(tie_count):
				var tr := _sample_track_transform_from_curve(curve, float(i) * tie_spacing, preview_follow_pitch)
				tmm.set_instance_transform(i, tr)
			var tmmi := MultiMeshInstance3D.new()
			tmmi.name = PREVIEW_TIES_NAME
			tmmi.multimesh = tmm
			tmmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			tmmi.material_override = _preview_ties_material
			root.add_child(tmmi)

	return true


func _sample_track_transform_from_curve(sample_curve: Curve3D, offset: float, follow_pitch: bool) -> Transform3D:
	var total: float = sample_curve.get_baked_length()
	var pos: Vector3 = sample_curve.sample_baked(offset)
	var ahead: float = minf(offset + 1.0, total)
	var behind: float = maxf(offset - 1.0, 0.0)
	var fwd: Vector3 = sample_curve.sample_baked(ahead) - sample_curve.sample_baked(behind)
	if not follow_pitch:
		fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var right := Vector3.UP.cross(fwd)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	right = right.normalized()
	var up := Vector3.UP if not follow_pitch else fwd.cross(right).normalized()
	return Transform3D(Basis(right, up, fwd), pos)


func _build_preview_rail_strip_mesh(samples: Array[Transform3D], lateral_offset: float) -> ArrayMesh:
	var hw: float = 0.025
	var hh: float = 0.05
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var n: int = samples.size()
	for i in range(n):
		var t: Transform3D = samples[i]
		var right: Vector3 = t.basis.x.normalized()
		var up: Vector3 = t.basis.y.normalized()
		var center: Vector3 = t.origin + right * lateral_offset + up * (hh + 0.04)
		var uv_v: float = float(i) * 0.5
		verts.append(center + up * hh - right * hw)
		verts.append(center + up * hh + right * hw)
		verts.append(center - up * hh + right * hw)
		verts.append(center - up * hh - right * hw)
		norms.append((-right + up).normalized())
		norms.append((right + up).normalized())
		norms.append((right - up).normalized())
		norms.append((-right - up).normalized())
		uvs.append(Vector2(0.0, uv_v))
		uvs.append(Vector2(1.0, uv_v))
		uvs.append(Vector2(1.0, uv_v))
		uvs.append(Vector2(0.0, uv_v))
	for i in range(n - 1):
		var base: int = i * 4
		var next: int = (i + 1) * 4
		for f in range(4):
			var a: int = base + f
			var b: int = base + (f + 1) % 4
			var c: int = next + (f + 1) % 4
			var d: int = next + f
			indices.append(a)
			indices.append(b)
			indices.append(c)
			indices.append(a)
			indices.append(c)
			indices.append(d)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_preview_real_sections(root: Node3D) -> bool:
	var section_scene := _get_preview_section_scene()
	if section_scene == null:
		return false
	var world_curve := _build_world_preview_curve()
	if world_curve == null or world_curve.point_count < 2:
		return false
	var total_len := world_curve.get_baked_length()
	if total_len <= 0.001:
		return false

	var deformed := _build_preview_deformed_section_mesh(world_curve, total_len, section_scene)
	if deformed != null:
		var sections_def := root.get_node_or_null(PREVIEW_SECTIONS_NAME) as Node3D
		if sections_def == null:
			sections_def = Node3D.new()
			sections_def.name = PREVIEW_SECTIONS_NAME
			sections_def.set_meta("editor_only", true)
			root.add_child(sections_def)
		for child in sections_def.get_children():
			sections_def.remove_child(child)
			child.free()
		var mi := MeshInstance3D.new()
		mi.name = "RailsDeformed"
		mi.mesh = deformed
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("editor_only", true)
		mi.transform = global_transform.affine_inverse()
		sections_def.add_child(mi)
		return true

	var section_length := _get_preview_section_length()
	var offsets := PackedFloat32Array()
	var o := section_length * 0.5
	while o <= total_len + 0.0001:
		offsets.push_back(minf(o, total_len))
		o += _adaptive_preview_step(o, section_length, total_len)
	if offsets.size() == 0:
		offsets.push_back(total_len * 0.5)
	var section_count := offsets.size()
	if section_count <= 0:
		return false

	var sections := root.get_node_or_null(PREVIEW_SECTIONS_NAME) as Node3D
	if sections == null:
		sections = Node3D.new()
		sections.name = PREVIEW_SECTIONS_NAME
		sections.set_meta("editor_only", true)
		root.add_child(sections)
	var old_children := sections.get_children()
	for child in old_children:
		sections.remove_child(child)
		child.free()

	var yaw_offset := Basis(Vector3.UP, deg_to_rad(preview_real_yaw_offset_deg))
	for i in range(section_count):
		var t_offset: float = offsets[i]
		var world_tr := _sample_track_transform_from_curve(world_curve, t_offset, preview_follow_pitch)
		world_tr.basis = world_tr.basis * yaw_offset
		var tr := global_transform.affine_inverse() * world_tr
		var instance := section_scene.instantiate()
		if instance is Node3D:
			var section_node := instance as Node3D
			section_node.transform = tr
			section_node.set_meta("editor_only", true)
			sections.add_child(section_node)
		else:
			instance.queue_free()
	return true


func _build_world_preview_curve() -> Curve3D:
	if curve == null or curve.point_count < 2:
		return null
	var world_curve := Curve3D.new()
	world_curve.bake_interval = curve_bake_interval
	for i in range(curve.point_count):
		var p: Vector3 = to_global(curve.get_point_position(i))
		var t_in: Vector3 = global_basis * curve.get_point_in(i)
		var t_out: Vector3 = global_basis * curve.get_point_out(i)
		world_curve.add_point(p, t_in, t_out)
	return world_curve


func _sample_flat_transform_from_curve(sample_curve: Curve3D, offset: float) -> Transform3D:
	var total: float = sample_curve.get_baked_length()
	var pos: Vector3 = sample_curve.sample_baked(offset)
	var ahead: float = minf(offset + 1.0, total)
	var behind: float = maxf(offset - 1.0, 0.0)
	var fwd: Vector3 = sample_curve.sample_baked(ahead) - sample_curve.sample_baked(behind)
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var right := Vector3.UP.cross(fwd).normalized()
	return Transform3D(Basis(right, Vector3.UP, fwd), pos)


func _find_first_mesh_and_xf_preview(node: Node, parent_xf: Transform3D) -> Array:
	var cur := parent_xf
	if node is Node3D:
		cur = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return [(node as MeshInstance3D).mesh, cur]
	for c in node.get_children():
		var r := _find_first_mesh_and_xf_preview(c, cur)
		if r.size() > 0:
			return r
	return []


func _build_preview_deformed_section_mesh(world_curve: Curve3D, total_len: float, section_scene: PackedScene) -> ArrayMesh:
	var temp: Node = section_scene.instantiate()
	var found := _find_first_mesh_and_xf_preview(temp, Transform3D.IDENTITY)
	if found.size() == 0:
		temp.queue_free()
		return null
	var src_mesh: Mesh = found[0]
	var src_xf: Transform3D = found[1]
	temp.queue_free()

	var src_aabb: AABB = _transform_aabb(src_mesh.get_aabb(), src_xf)
	var tile_len: float = maxf(src_aabb.size.x, 0.05)
	var x_min: float = src_aabb.position.x
	var tile_count: int = int(ceil(total_len / tile_len))
	if tile_count <= 0:
		tile_count = 1

	var out_mesh := ArrayMesh.new()
	var surf_count: int = src_mesh.get_surface_count()
	for surf in range(surf_count):
		var arrays: Array = src_mesh.surface_get_arrays(surf)
		if arrays.is_empty():
			continue
		var src_verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var vc: int = src_verts.size()
		if vc == 0:
			continue
		var has_norms: bool = arrays[Mesh.ARRAY_NORMAL] != null
		var src_norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if has_norms else PackedVector3Array()
		var has_uvs: bool = arrays[Mesh.ARRAY_TEX_UV] != null
		var src_uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if has_uvs else PackedVector2Array()
		var has_idx: bool = arrays[Mesh.ARRAY_INDEX] != null
		var src_idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if has_idx else PackedInt32Array()

		var out_verts := PackedVector3Array()
		var out_norms := PackedVector3Array()
		var out_uvs := PackedVector2Array()
		var out_idx := PackedInt32Array()

		for tile in range(tile_count):
			var base_arc: float = float(tile) * tile_len
			# Scale the last (partial) tile along X so its end exactly meets
			# total_len. Without this, clamping end-side vertices to total_len
			# collapses them to a single point and pinches the mesh.
			var this_tile_len: float = minf(tile_len, total_len - base_arc)
			if this_tile_len < 0.001:
				continue
			var x_scale: float = this_tile_len / tile_len
			var base_idx: int = out_verts.size()
			for i in range(vc):
				var v_local: Vector3 = src_xf * src_verts[i]
				var along: float = base_arc + (v_local.x - x_min) * x_scale
				along = clampf(along, 0.0, total_len)
				var lateral: float = -v_local.z
				var vertical: float = v_local.y
				var t := _sample_track_transform_from_curve(world_curve, along, preview_follow_pitch)
				var right: Vector3 = t.basis.x
				var up: Vector3 = t.basis.y
				var world_p: Vector3 = t.origin + right * lateral + up * vertical
				out_verts.push_back(world_p)
				if has_norms:
					var n_local: Vector3 = (src_xf.basis * src_norms[i]).normalized()
					var n_track := Vector3(-n_local.z, n_local.y, n_local.x)
					var world_n: Vector3 = (t.basis * n_track).normalized()
					out_norms.push_back(world_n)
				if has_uvs:
					out_uvs.push_back(src_uvs[i])
			if has_idx:
				for i in range(src_idx.size()):
					out_idx.push_back(base_idx + src_idx[i])
			else:
				for i in range(vc):
					out_idx.push_back(base_idx + i)

		var out_arrays: Array = []
		out_arrays.resize(Mesh.ARRAY_MAX)
		out_arrays[Mesh.ARRAY_VERTEX] = out_verts
		if out_norms.size() > 0:
			out_arrays[Mesh.ARRAY_NORMAL] = out_norms
		if out_uvs.size() > 0:
			out_arrays[Mesh.ARRAY_TEX_UV] = out_uvs
		out_arrays[Mesh.ARRAY_INDEX] = out_idx
		out_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arrays)
		var src_mat: Material = src_mesh.surface_get_material(surf)
		if src_mat != null:
			out_mesh.surface_set_material(surf, src_mat)
	return out_mesh


func _get_preview_section_scene() -> PackedScene:
	if _preview_section_scene != null:
		return _preview_section_scene
	if not ResourceLoader.exists(RAIL_SECTION_SCENE_PATH):
		return null
	var packed := load(RAIL_SECTION_SCENE_PATH) as PackedScene
	if packed == null:
		return null
	_preview_section_scene = packed
	_preview_section_length_cache = -1.0
	return _preview_section_scene


func _get_preview_section_length() -> float:
	if not preview_real_auto_section_length:
		return maxf(preview_real_section_length, 0.2)
	if _preview_section_length_cache > 0.0:
		return _preview_section_length_cache
	var section_scene := _get_preview_section_scene()
	if section_scene == null:
		return maxf(preview_real_section_length, 0.2)
	var instance: Node = section_scene.instantiate()
	if instance == null:
		return maxf(preview_real_section_length, 0.2)
	var bounds: Variant = _compute_scene_local_bounds(instance, Transform3D.IDENTITY)
	instance.queue_free()
	if bounds == null:
		return maxf(preview_real_section_length, 0.2)
	var aabb: AABB = bounds
	var inferred := maxf(aabb.size.x, aabb.size.z)
	if inferred <= 0.05:
		inferred = maxf(preview_real_section_length, 0.2)
	_preview_section_length_cache = maxf(inferred, 0.2)
	return _preview_section_length_cache


func _compute_scene_local_bounds(node: Node, parent_xf: Transform3D) -> Variant:
	var current_xf := parent_xf
	if node is Node3D:
		current_xf = parent_xf * (node as Node3D).transform

	var merged: Variant = null
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			merged = _transform_aabb(mi.mesh.get_aabb(), current_xf)

	for child in node.get_children():
		var child_bounds: Variant = _compute_scene_local_bounds(child, current_xf)
		if child_bounds == null:
			continue
		if merged == null:
			merged = child_bounds
		else:
			merged = (merged as AABB).merge(child_bounds as AABB)
	return merged


func _transform_aabb(aabb: AABB, xf: Transform3D) -> AABB:
	var p := aabb.position
	var s := aabb.size
	var corners := [
		xf * Vector3(p.x, p.y, p.z),
		xf * Vector3(p.x + s.x, p.y, p.z),
		xf * Vector3(p.x, p.y + s.y, p.z),
		xf * Vector3(p.x, p.y, p.z + s.z),
		xf * Vector3(p.x + s.x, p.y + s.y, p.z),
		xf * Vector3(p.x + s.x, p.y, p.z + s.z),
		xf * Vector3(p.x, p.y + s.y, p.z + s.z),
		xf * Vector3(p.x + s.x, p.y + s.y, p.z + s.z),
	]
	var out := AABB(corners[0], Vector3.ZERO)
	for i in range(1, corners.size()):
		out = out.expand(corners[i])
	return out


func _build_preview_rails_mesh() -> ArrayMesh:
	var total_len := curve.get_baked_length()
	var step := maxf(preview_sample_step, 0.1)
	var half_gauge := maxf(preview_rail_gauge * 0.5, 0.05)

	var left_points: Array[Vector3] = []
	var right_points: Array[Vector3] = []
	var offset := 0.0
	while offset <= total_len:
		var frame := _sample_preview_frame(offset, total_len)
		var pos: Vector3 = frame["pos"]
		var right: Vector3 = frame["right"]
		left_points.append(pos - right * half_gauge)
		right_points.append(pos + right * half_gauge)
		offset += _adaptive_preview_step(offset, step, total_len)
	if left_points.size() == 0:
		return ArrayMesh.new()
	if left_points[-1].distance_to(curve.sample_baked(total_len) - _sample_preview_frame(total_len, total_len)["right"] * half_gauge) > 0.001:
		var frame_end := _sample_preview_frame(total_len, total_len)
		left_points.append(frame_end["pos"] - frame_end["right"] * half_gauge)
		right_points.append(frame_end["pos"] + frame_end["right"] * half_gauge)

	var vertices := PackedVector3Array()
	for i in range(left_points.size() - 1):
		vertices.push_back(left_points[i])
		vertices.push_back(left_points[i + 1])
		vertices.push_back(right_points[i])
		vertices.push_back(right_points[i + 1])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	if vertices.size() > 1:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


func _build_preview_ties_mesh() -> ArrayMesh:
	var total_len := curve.get_baked_length()
	var spacing := maxf(preview_tie_spacing, 0.1)
	var half_gauge := maxf(preview_rail_gauge * 0.5, 0.05)

	var vertices := PackedVector3Array()
	var offset := 0.0
	while offset <= total_len:
		var frame := _sample_preview_frame(offset, total_len)
		var pos: Vector3 = frame["pos"]
		var right: Vector3 = frame["right"]
		vertices.push_back(pos - right * (half_gauge + 0.35))
		vertices.push_back(pos + right * (half_gauge + 0.35))
		offset += spacing

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	if vertices.size() > 1:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh
