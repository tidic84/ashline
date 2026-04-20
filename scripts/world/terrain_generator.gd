@tool
extends Node3D
class_name TerrainGenerator

# Reads a hand-placed Curve3D from a RailPath node in the scene
# and builds rail meshes (sections, ties, gravel) along it.
# Terrain sculpting is optional — only runs if the active terrain node
# exposes a sculpt_terrain_for_rails() method.

enum Biome { PLAINS, FOREST, DESERT, SNOW, MOUNTAIN }
enum SegmentType { GROUND, BRIDGE, TUNNEL }

@export var ground_offset: float = 0.20
@export var roadbed_half_width: float = 5.0
@export var roadbed_blend_width: float = 7.0
@export var rail_gauge: float = 2.0
@export_range(0.1, 10.0, 0.01, "or_greater") var rail_width_scale: float = 2.0
## Optional trim off each endpoint that connects to another path. Kept for
## the non-deformed (tiled MultiMesh / fallback) render paths. When the
## deformed mesh is used, junction blending replaces trim — leave at 0.
@export_range(0.0, 5.0, 0.05) var junction_trim_length: float = 0.0
## Distance (m) over which the deformed mesh bends near a junction so its
## rails and ties align with the neighbor path(s). Both sides converge to
## a shared right/up basis at the shared endpoint, so the two paths' rails
## meet seamlessly instead of overlapping or leaving a gap.
@export_range(0.0, 10.0, 0.05) var junction_blend_length: float = 2.0
@export var rail_follow_pitch: bool = true
@export var rail_use_deformed_mesh: bool = true
@export var rail_auto_section_length: bool = true
@export_range(0.2, 10.0, 0.01) var rail_section_length: float = 2.4
@export var rail_adaptive_sampling: bool = true
@export_range(0.2, 5.0, 0.01) var rail_adaptive_min_step: float = 0.45
@export_range(0.5, 12.0, 0.01) var rail_adaptive_max_step: float = 2.4
@export_range(0.0, 6.0, 0.01) var rail_curve_influence: float = 2.2
@export_range(0.0, 6.0, 0.01) var rail_pitch_influence: float = 1.8
@export var bridge_threshold: float = 2.0
@export var tunnel_threshold: float = 3.5
## Optional explicit reference — if null, scans the "rail_path" group
@export var rail_path_node: NodePath
## If true, terrain and rails are generated automatically at _ready().
## If false, call generate_terrain() or use the Rail Builder plugin button.
@export var auto_generate: bool = false
## Runtime keeps automatic generation so the game always has rails,
## even if editor generation is manual.
@export var auto_generate_in_game: bool = true

var _terrain_patch: Node = null
var _rail_curve: Curve3D = null
var _rail_points: Array[Vector3] = []
var _rail_types: Array[int] = []
var _generated := false


func _ready() -> void:
	add_to_group("terrain")
	await get_tree().process_frame
	_find_terrain_patch()
	if Engine.is_editor_hint():
		if auto_generate:
			generate_terrain()
	elif auto_generate or auto_generate_in_game:
		generate_terrain()


## Public API: call this to generate terrain + rails on demand.
func generate_terrain() -> void:
	# Re-scan for terrain patch in case it was added after _ready.
	if _terrain_patch == null or not is_instance_valid(_terrain_patch):
		_find_terrain_patch()
	# Remove previously generated nodes so repeated presses don't stack meshes.
	_clear_generated_rail_nodes()
	var rail_paths := get_tree().get_nodes_in_group("rail_path")
	print("[TerrainGenerator] generate_terrain: %d RailPath nodes in group, terrain_patch=%s" % [
		rail_paths.size(), "found" if _terrain_patch != null else "missing"])
	if rail_paths.is_empty():
		push_warning("TerrainGenerator: no RailPath found in 'rail_path' group — add a RailPath to the scene")
		return
	if not _load_curve_from_rail_path(true):
		push_warning("TerrainGenerator: no valid RailPath curve found — rails disabled")
	else:
		_generated = true
		print("[TerrainGenerator] Terrain and rails generated successfully.")


## Public API: rebuild only rail meshes without re-sculpting terrain.
func rebuild_rail_meshes() -> void:
	# Remove all previously generated rail nodes (supports both old and new naming)
	_clear_generated_rail_nodes()
	if not _load_curve_from_rail_path(false, true):
		push_warning("TerrainGenerator: no valid RailPath found — unable to rebuild rails")
		return
	print("[TerrainGenerator] Rail meshes rebuilt.")


func _find_terrain_patch() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for child in parent.get_children():
		if child is TerrainPatch3D:
			_terrain_patch = child
			return


func _clear_generated_rail_nodes() -> void:
	var to_remove: Array[Node] = []
	for child in get_children():
		if child.name == "Rails" or child.name == "RailPath" \
				or child.name.begins_with("Rails_") or child.name.begins_with("RailPath_"):
			to_remove.append(child)
	for child in to_remove:
		remove_child(child)
		if Engine.is_editor_hint():
			child.free()
		else:
			child.queue_free()


func _load_curve_from_rail_path(sculpt_terrain: bool = true, rebuild_meshes: bool = true) -> bool:
	var paths_to_process: Array[Path3D] = []
	var combined_sculpt_points: Array[Vector3] = []

	if not rail_path_node.is_empty():
		var node := get_node_or_null(rail_path_node)
		if node is Path3D:
			paths_to_process.append(node as Path3D)
	else:
		for candidate in get_tree().get_nodes_in_group("rail_path"):
			if candidate is Path3D:
				paths_to_process.append(candidate as Path3D)

	if paths_to_process.is_empty():
		return false

	var any_success := false
	for i in paths_to_process.size():
		if _process_one_rail_path(paths_to_process[i], false, rebuild_meshes, i):
			if sculpt_terrain:
				combined_sculpt_points.append_array(_sample_curve_world_points(_rail_curve))
			any_success = true
	if sculpt_terrain and any_success and _terrain_patch and _terrain_patch.has_method("sculpt_terrain_for_rails"):
		_terrain_patch.sculpt_terrain_for_rails(
			combined_sculpt_points, roadbed_half_width, roadbed_blend_width, ground_offset
		)
	return any_success


func _process_one_rail_path(path: Path3D, sculpt_terrain: bool, rebuild_meshes: bool, idx: int) -> bool:
	if path.curve == null or path.curve.point_count < 2:
		push_warning("RailPath '%s' has empty curve — skipped" % path.name)
		return false
	var world_curve := Curve3D.new()
	world_curve.bake_interval = maxf(path.curve.bake_interval, 0.05)
	for i in range(path.curve.point_count):
		var p: Vector3 = path.to_global(path.curve.get_point_position(i))
		var t_in: Vector3 = path.global_basis * path.curve.get_point_in(i)
		var t_out: Vector3 = path.global_basis * path.curve.get_point_out(i)
		world_curve.add_point(p, t_in, t_out)
	_rail_curve = world_curve
	_rail_points = _sample_curve_world_points(_rail_curve)
	if sculpt_terrain and _terrain_patch and _terrain_patch.has_method("sculpt_terrain_for_rails"):
		_terrain_patch.sculpt_terrain_for_rails(
			_rail_points, roadbed_half_width, roadbed_blend_width, ground_offset
		)
	_classify_segments_from_curve()
	if rebuild_meshes:
		var trim_start: float = _compute_junction_trim(path, 0)
		var trim_end: float = _compute_junction_trim(path, 1)
		_build_rail_meshes(idx, trim_start, trim_end)
	return true


func _compute_junction_trim(path: Path3D, endpoint: int) -> float:
	if junction_trim_length <= 0.0:
		return 0.0
	if path.curve == null or path.curve.point_count < 2:
		return 0.0
	# At each junction, only the path with the highest instance_id trims
	# back — the other path extends fully to the shared point. This avoids
	# both the overlap (two full meshes at once) and the gap (both trimmed).
	var my_idx := 0 if endpoint == 0 else path.curve.point_count - 1
	var my_pos: Vector3 = path.to_global(path.curve.get_point_position(my_idx))
	var my_id: int = path.get_instance_id()
	var threshold_sq := 0.05 * 0.05
	var should_trim := false
	# First pass: explicit connections listed on the RailPath node.
	var prop_name: String = "connections_at_start" if endpoint == 0 else "connections_at_end"
	var conns_variant: Variant = path.get(prop_name)
	if conns_variant is Array:
		for np in (conns_variant as Array):
			var other := path.get_node_or_null(np)
			if other is Path3D and other.get_instance_id() < my_id:
				should_trim = true
				break
	# Fallback: proximity-based detection against every other RailPath.
	if not should_trim:
		for other in get_tree().get_nodes_in_group("rail_path"):
			if other == path or not (other is Path3D):
				continue
			var op := other as Path3D
			if op.curve == null or op.curve.point_count == 0:
				continue
			var o_start: Vector3 = op.to_global(op.curve.get_point_position(0))
			var o_end: Vector3 = op.to_global(op.curve.get_point_position(op.curve.point_count - 1))
			var touches: bool = my_pos.distance_squared_to(o_start) <= threshold_sq \
					or my_pos.distance_squared_to(o_end) <= threshold_sq
			if touches and op.get_instance_id() < my_id:
				should_trim = true
				break
	return junction_trim_length if should_trim else 0.0


func _endpoint_touches_other_path(path: Path3D, endpoint: int) -> bool:
	if path.curve == null or path.curve.point_count < 2:
		return false
	var idx := 0 if endpoint == 0 else path.curve.point_count - 1
	var my_pos: Vector3 = path.to_global(path.curve.get_point_position(idx))
	var threshold_sq := 0.05 * 0.05
	for other in get_tree().get_nodes_in_group("rail_path"):
		if other == path or not (other is Path3D):
			continue
		var op := other as Path3D
		if op.curve == null or op.curve.point_count == 0:
			continue
		var o_start: Vector3 = op.to_global(op.curve.get_point_position(0))
		var o_end: Vector3 = op.to_global(op.curve.get_point_position(op.curve.point_count - 1))
		if my_pos.distance_squared_to(o_start) <= threshold_sq:
			return true
		if my_pos.distance_squared_to(o_end) <= threshold_sq:
			return true
	return false


func _sample_curve_world_points(sample_curve: Curve3D) -> Array[Vector3]:
	var sampled_points: Array[Vector3] = []
	if sample_curve == null:
		return sampled_points
	var total_len := sample_curve.get_baked_length()
	var t := 0.0
	while t <= total_len:
		sampled_points.append(sample_curve.sample_baked(t))
		t += 1.0
	var last_point := sample_curve.sample_baked(total_len)
	if sampled_points.is_empty() or sampled_points[-1] != last_point:
		sampled_points.append(last_point)
	return sampled_points


func _classify_segments_from_curve() -> void:
	if _rail_points.is_empty():
		return
	_rail_types.clear()
	_rail_types.resize(_rail_points.size())
	for i in range(_rail_points.size()):
		var terrain_h: float = get_height_at(_rail_points[i].x, _rail_points[i].z)
		var diff: float = _rail_points[i].y - terrain_h
		if diff > bridge_threshold:
			_rail_types[i] = SegmentType.BRIDGE
		elif diff < -tunnel_threshold:
			_rail_types[i] = SegmentType.TUNNEL
		else:
			_rail_types[i] = SegmentType.GROUND


# --- Public API ---

func get_height_at(world_x: float, world_z: float) -> float:
	if _terrain_patch == null:
		return 0.0
	# Forest TerrainPatch3D uses local coords
	var local: Vector3 = (_terrain_patch as Node3D).to_local(Vector3(world_x, 0.0, world_z))
	return _terrain_patch._sample_height(local.x, local.z)

func get_biome_at(_x: float, _z: float) -> int:
	return Biome.FOREST

func get_rail_curve() -> Curve3D:
	return _rail_curve

func distance_to_rails(world_pos: Vector3) -> float:
	if _rail_curve == null:
		return 1000.0
	var total: float = _rail_curve.get_baked_length()
	if total <= 0.0:
		return 1000.0
	var closest: Vector3 = _rail_curve.get_closest_point(world_pos)
	var dx: float = world_pos.x - closest.x
	var dz: float = world_pos.z - closest.z
	return sqrt(dx * dx + dz * dz)

func sample_rail_progress(world_pos: Vector3) -> float:
	if _rail_curve == null:
		return 0.0
	return _rail_curve.get_closest_offset(world_pos)


# --- Track transform ---

func _sample_track_transform(offset: float) -> Transform3D:
	var total: float = _rail_curve.get_baked_length()
	var pos: Vector3 = _rail_curve.sample_baked(offset)
	var ahead: float = minf(offset + 1.0, total)
	var behind: float = maxf(offset - 1.0, 0.0)
	var fwd: Vector3 = _rail_curve.sample_baked(ahead) - _rail_curve.sample_baked(behind)
	if not rail_follow_pitch:
		fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var right := Vector3.UP.cross(fwd)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	right = right.normalized()
	var up := Vector3.UP if not rail_follow_pitch else fwd.cross(right).normalized()
	return Transform3D(Basis(right, up, fwd), pos)


func _adaptive_step_at_offset(offset: float, base_step: float, total_len: float) -> float:
	if not rail_adaptive_sampling:
		return maxf(base_step, 0.05)
	var complexity := _track_complexity_at_offset(offset, total_len)
	var min_step := minf(rail_adaptive_min_step, rail_adaptive_max_step)
	var max_step := maxf(rail_adaptive_min_step, rail_adaptive_max_step)
	var target := base_step / (1.0 + complexity)
	return clampf(target, min_step, max_step)


func _track_complexity_at_offset(offset: float, total_len: float) -> float:
	var d := 1.0
	var p0 := maxf(offset - d, 0.0)
	var p1 := offset
	var p2 := minf(offset + d, total_len)
	var f0 := _rail_curve.sample_baked(p1) - _rail_curve.sample_baked(p0)
	var f1 := _rail_curve.sample_baked(p2) - _rail_curve.sample_baked(p1)
	if f0.length_squared() < 0.00001 or f1.length_squared() < 0.00001:
		return 0.0
	var h0 := Vector3(f0.x, 0.0, f0.z)
	var h1 := Vector3(f1.x, 0.0, f1.z)
	var yaw_delta := 0.0
	if h0.length_squared() > 0.00001 and h1.length_squared() > 0.00001:
		yaw_delta = rad_to_deg(h0.normalized().angle_to(h1.normalized()))
	var pitch0 := _pitch_of_vector(f0)
	var pitch1 := _pitch_of_vector(f1)
	var pitch_delta := absf(pitch1 - pitch0)
	return (yaw_delta / 45.0) * rail_curve_influence + (pitch_delta / 20.0) * rail_pitch_influence


func _pitch_of_vector(v: Vector3) -> float:
	var h := Vector2(v.x, v.z).length()
	if h < 0.0001:
		return 0.0 if absf(v.y) < 0.0001 else (90.0 if v.y > 0.0 else -90.0)
	return rad_to_deg(atan2(v.y, h))


# --- Rail mesh building ---

var _rail_section_scene: PackedScene = null

func _build_rail_meshes(idx: int = 0, trim_start: float = 0.0, trim_end: float = 0.0) -> void:
	if _rail_curve == null or _rail_curve.point_count < 2:
		return

	var path := Path3D.new()
	path.name = "RailPath_%d" % idx
	path.curve = _rail_curve
	add_child(path)

	var total_len: float = _rail_curve.get_baked_length()
	# Clamp trims so the rendered range stays positive.
	var max_trim: float = maxf(total_len * 0.45, 0.0)
	trim_start = clampf(trim_start, 0.0, max_trim)
	trim_end = clampf(trim_end, 0.0, max_trim)

	var rail_container := Node3D.new()
	rail_container.name = "Rails_%d" % idx
	add_child(rail_container)

	# Try tiled rail sections from glb asset, fall back to procedural strips
	if ResourceLoader.exists("res://assets/models/rails/rail_section.glb"):
		_rail_section_scene = load("res://assets/models/rails/rail_section.glb")

	if rail_use_deformed_mesh and _rail_section_scene != null:
		var deformed_mesh := _build_deformed_rail_section_mesh(total_len, _rail_section_scene, trim_start, trim_end)
		if deformed_mesh != null:
			var mi_def := MeshInstance3D.new()
			mi_def.name = "RailsDeformed"
			mi_def.mesh = deformed_mesh
			mi_def.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			rail_container.add_child(mi_def)
			mi_def.global_transform = Transform3D.IDENTITY
			return

	if _rail_section_scene != null:
		var width_scale: float = maxf(rail_width_scale, 0.1)
		var section_length: float = maxf(rail_section_length, 0.2)
		if total_len > 0.0:
			var temp_instance: Node = _rail_section_scene.instantiate()
			var rail_mesh: Mesh = _find_first_mesh_recursive(temp_instance)
			if rail_auto_section_length:
				section_length = _compute_section_length_from_instance(temp_instance, section_length)
			temp_instance.queue_free()
			if rail_mesh != null:
				var range_start: float = trim_start
				var range_end: float = total_len - trim_end
				var offsets := PackedFloat32Array()
				var o := range_start + section_length * 0.5
				while o <= range_end + 0.0001:
					offsets.push_back(clampf(o, range_start, range_end))
					o += _adaptive_step_at_offset(o, section_length, total_len)
				if offsets.size() == 0 and range_end > range_start:
					offsets.push_back((range_start + range_end) * 0.5)
				var section_count: int = offsets.size()
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = rail_mesh
				mm.instance_count = section_count
				var rot90 := Basis(Vector3.UP, -PI / 2.0)
				for i in range(section_count):
					var t_offset: float = offsets[i]
					var t := _sample_track_transform(t_offset)
					t.basis = (t.basis * rot90).scaled(Vector3(width_scale, 1.0, 1.0))
					mm.set_instance_transform(i, t)
				var mmi := MultiMeshInstance3D.new()
				mmi.name = "RailSections"
				mmi.multimesh = mm
				rail_container.add_child(mmi)
				return

	_build_fallback_rails(rail_container, total_len, trim_start, trim_end)


func _build_fallback_rails(rail_container: Node3D, total_len: float, trim_start: float = 0.0, trim_end: float = 0.0) -> void:
	var width_scale: float = maxf(rail_width_scale, 0.1)
	var range_start: float = clampf(trim_start, 0.0, total_len)
	var range_end: float = clampf(total_len - trim_end, range_start, total_len)
	if range_end - range_start <= 0.05:
		return
	var step: float = maxf(rail_section_length * 0.25, 0.2)
	var samples: Array[Transform3D] = []
	var offset: float = range_start
	while offset <= range_end:
		samples.append(_sample_track_transform(offset))
		offset += _adaptive_step_at_offset(offset, step, total_len)
	if samples.size() == 0 or samples[-1].origin.distance_to(_rail_curve.sample_baked(range_end)) > 0.01:
		samples.append(_sample_track_transform(range_end))
	if samples.size() < 2:
		return

	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.28, 0.26, 0.24)
	rail_mat.metallic = 0.88
	rail_mat.roughness = 0.28

	var tie_mat: Material = null
	if ResourceLoader.exists("res://textures/rails/wood_tie/M_wood_tie.tres"):
		tie_mat = load("res://textures/rails/wood_tie/M_wood_tie.tres")
	if tie_mat == null:
		tie_mat = StandardMaterial3D.new()
	var tie_spacing: float = 0.55
	var rendered_len: float = range_end - range_start
	var tie_count: int = int(rendered_len / tie_spacing)
	if tie_count > 0:
		var tm := BoxMesh.new()
		tm.size = Vector3(1.6 * width_scale, 0.08, 0.12)
		tm.surface_set_material(0, tie_mat)
		var tmm := MultiMesh.new()
		tmm.transform_format = MultiMesh.TRANSFORM_3D
		tmm.mesh = tm
		tmm.instance_count = tie_count
		for i in range(tie_count):
			var t := _sample_track_transform(range_start + float(i) * tie_spacing)
			tmm.set_instance_transform(i, t)
		var tmmi := MultiMeshInstance3D.new()
		tmmi.name = "Ties"
		tmmi.multimesh = tmm
		rail_container.add_child(tmmi)

	var half_gauge: float = rail_gauge * 0.5
	for side in [-1.0, 1.0]:
		var mesh := _build_rail_strip(samples, half_gauge * side, rail_mat)
		var mi := MeshInstance3D.new()
		mi.name = "Rail_L" if side < 0.0 else "Rail_R"
		mi.mesh = mesh
		rail_container.add_child(mi)


func _find_first_mesh_recursive(node: Node) -> Mesh:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			return mi.mesh
	for child in node.get_children():
		var found := _find_first_mesh_recursive(child)
		if found != null:
			return found
	return null


func _compute_section_length_from_instance(instance: Node, fallback_length: float) -> float:
	var bounds: Variant = _compute_scene_local_bounds(instance, Transform3D.IDENTITY)
	if bounds == null:
		return maxf(fallback_length, 0.2)
	var aabb: AABB = bounds
	var inferred := maxf(aabb.size.x, aabb.size.z)
	if inferred <= 0.05:
		return maxf(fallback_length, 0.2)
	return maxf(inferred, 0.2)


func _find_first_mesh_and_xf(node: Node, parent_xf: Transform3D) -> Array:
	var cur := parent_xf
	if node is Node3D:
		cur = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return [(node as MeshInstance3D).mesh, cur]
	for c in node.get_children():
		var r := _find_first_mesh_and_xf(c, cur)
		if r.size() > 0:
			return r
	return []


func _build_deformed_rail_section_mesh(total_len: float, section_scene: PackedScene, trim_start: float = 0.0, trim_end: float = 0.0) -> ArrayMesh:
	if _rail_curve == null or total_len <= 0.001:
		return null
	var width_scale: float = maxf(rail_width_scale, 0.1)
	var range_start: float = clampf(trim_start, 0.0, total_len)
	var range_end: float = clampf(total_len - trim_end, range_start, total_len)
	var effective_len: float = range_end - range_start
	if effective_len <= 0.001:
		return null
	var temp: Node = section_scene.instantiate()
	var found := _find_first_mesh_and_xf(temp, Transform3D.IDENTITY)
	if found.size() == 0:
		temp.queue_free()
		return null
	var src_mesh: Mesh = found[0]
	var src_xf: Transform3D = found[1]
	temp.queue_free()

	var src_aabb: AABB = _transform_aabb(src_mesh.get_aabb(), src_xf)
	var tile_len: float = maxf(src_aabb.size.x, 0.05)
	var x_min: float = src_aabb.position.x
	var tile_count: int = int(ceil(effective_len / tile_len))
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
			# the effective rendered length. Without this, clamping end-side
			# vertices collapses them to a single point and pinches the mesh.
			var this_tile_len: float = minf(tile_len, effective_len - base_arc)
			if this_tile_len < 0.001:
				continue
			var x_scale: float = this_tile_len / tile_len
			var base_idx: int = out_verts.size()
			for i in range(vc):
				var v_local: Vector3 = src_xf * src_verts[i]
				var along_local: float = base_arc + (v_local.x - x_min) * x_scale
				along_local = clampf(along_local, 0.0, effective_len)
				var along: float = range_start + along_local
				var lateral: float = -v_local.z * width_scale
				var vertical: float = v_local.y
				var t := _sample_track_transform(along)
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




func _build_rail_strip(samples: Array[Transform3D], lateral_offset: float, mat: Material) -> ArrayMesh:
	var width_scale: float = maxf(rail_width_scale, 0.1)
	var hw: float = 0.025 * width_scale
	var hh: float = 0.05
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var n: int = samples.size()
	for i in range(n):
		var t: Transform3D = samples[i]
		var right: Vector3 = t.basis.x.normalized()
		var up := Vector3.UP
		var center: Vector3 = t.origin + right * lateral_offset
		center.y += hh + 0.04
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
	var m := mat.duplicate() as StandardMaterial3D
	mesh.surface_set_material(0, m)
	return mesh
