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
@export var rail_follow_pitch: bool = true
@export var rail_use_deformed_mesh: bool = true
@export var rail_auto_section_length: bool = true
@export_range(0.2, 10.0, 0.01) var rail_section_length: float = 2.4
@export var rail_adaptive_sampling: bool = true
@export_range(0.2, 5.0, 0.01) var rail_adaptive_min_step: float = 0.45
@export_range(0.5, 12.0, 0.01) var rail_adaptive_max_step: float = 2.4
@export_range(0.0, 6.0, 0.01) var rail_curve_influence: float = 2.2
@export_range(0.0, 6.0, 0.01) var rail_pitch_influence: float = 1.8
## Distance (meters) over which the mesh bends through a shared cubic Bezier
## at a connected endpoint so two adjacent rail paths meet with matching
## angle and curvature instead of snapping between straight segments.
@export_range(0.0, 8.0, 0.05) var rail_junction_blend_length: float = 3.0
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
var _current_rail_path_source: Path3D = null


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
	_current_rail_path_source = path
	_rail_points = _sample_curve_world_points(_rail_curve)
	if sculpt_terrain and _terrain_patch and _terrain_patch.has_method("sculpt_terrain_for_rails"):
		_terrain_patch.sculpt_terrain_for_rails(
			_rail_points, roadbed_half_width, roadbed_blend_width, ground_offset
		)
	_classify_segments_from_curve()
	if rebuild_meshes:
		_build_rail_meshes(idx)
	_current_rail_path_source = null
	return true


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
	var fwd: Vector3 = _sample_curve_fwd(_rail_curve, offset, total)
	return Transform3D(_basis_from_fwd(fwd), pos)


func _sample_curve_fwd(sample_curve: Curve3D, offset: float, total: float) -> Vector3:
	var ahead: float = minf(offset + 1.0, total)
	var behind: float = maxf(offset - 1.0, 0.0)
	var fwd: Vector3 = sample_curve.sample_baked(ahead) - sample_curve.sample_baked(behind)
	if not rail_follow_pitch:
		fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return Vector3.FORWARD
	return fwd.normalized()


func _basis_from_fwd(fwd: Vector3) -> Basis:
	var f: Vector3 = fwd
	if not rail_follow_pitch:
		f.y = 0.0
	if f.length_squared() < 0.0001:
		f = Vector3.FORWARD
	f = f.normalized()
	var right: Vector3 = Vector3.UP.cross(f)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	right = right.normalized()
	var up: Vector3 = Vector3.UP if not rail_follow_pitch else f.cross(right).normalized()
	return Basis(right, up, f)


func _bezier_point(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var u: float = 1.0 - t
	return u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3


func _bezier_tangent(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var u: float = 1.0 - t
	return 3.0 * (u * u * (p1 - p0) + 2.0 * u * t * (p2 - p1) + t * t * (p3 - p2))


func _compute_junction_basis(source_path: Path3D, offset: float) -> Dictionary:
	# Shared cross-section orientation at a junction between connected rail paths.
	# Both paths meeting at the same world point compute the same averaged fwd,
	# so blending each mesh toward this basis makes their end caps line up.
	if source_path == null or _rail_curve == null:
		return {}
	var total_len: float = _rail_curve.get_baked_length()
	var endpoint: int
	if offset <= 0.001:
		endpoint = 0
	elif offset >= total_len - 0.001:
		endpoint = 1
	else:
		return {}
	var connections_variant: Variant = (
		source_path.get("connections_at_start") if endpoint == 0
		else source_path.get("connections_at_end")
	)
	if not (connections_variant is Array):
		return {}
	var connections: Array = connections_variant
	if connections.is_empty():
		return {}
	var self_pos: Vector3 = _rail_curve.sample_baked(offset)
	var self_fwd: Vector3 = _sample_curve_fwd(_rail_curve, offset, total_len)
	if self_fwd.length_squared() < 0.0001:
		return {}
	var sum_fwd: Vector3 = self_fwd
	var count: int = 1
	for np in connections:
		var other := source_path.get_node_or_null(np)
		if not (other is Path3D):
			continue
		var other_path := other as Path3D
		if other_path.curve == null or other_path.curve.point_count < 2:
			continue
		var other_total: float = other_path.curve.get_baked_length()
		if other_total <= 0.001:
			continue
		var other_start_world: Vector3 = other_path.to_global(other_path.curve.get_point_position(0))
		var other_end_world: Vector3 = other_path.to_global(
			other_path.curve.get_point_position(other_path.curve.point_count - 1)
		)
		var other_offset: float = 0.0
		if self_pos.distance_squared_to(other_start_world) > self_pos.distance_squared_to(other_end_world):
			other_offset = other_total
		var other_fwd_local: Vector3 = _sample_curve_fwd(other_path.curve, other_offset, other_total)
		if other_fwd_local.length_squared() < 0.0001:
			continue
		var other_fwd: Vector3 = (other_path.global_basis * other_fwd_local).normalized()
		if other_fwd.dot(self_fwd) < 0.0:
			other_fwd = -other_fwd
		sum_fwd += other_fwd
		count += 1
	if count <= 1 or sum_fwd.length_squared() < 0.0001:
		return {}
	var junction_fwd: Vector3 = sum_fwd.normalized()
	var basis := _basis_from_fwd(junction_fwd)
	return {
		"pos": self_pos,
		"fwd": junction_fwd,
		"right": basis.x,
		"up": basis.y,
	}


func _endpoint_blend_weight(distance: float, max_distance: float) -> float:
	if max_distance <= 0.001:
		return 0.0
	if distance <= 0.0:
		return 1.0
	if distance >= max_distance:
		return 0.0
	var t: float = 1.0 - distance / max_distance
	return t * t * (3.0 - 2.0 * t)


func _build_junction_bezier(junction: Dictionary, blend_dist: float, total_len: float, is_start: bool) -> Dictionary:
	# Cubic Bezier that bridges the own rail's interior anchor to the shared
	# junction point. u=0 sits at the anchor side (natural rail), u=1 at the
	# junction (shared by both connected paths). Matches derivatives at both
	# ends so the deformation blends seamlessly into the rest of the mesh.
	if junction.is_empty() or blend_dist <= 0.001 or _rail_curve == null:
		return {}
	var anchor_offset: float = blend_dist if is_start else total_len - blend_dist
	anchor_offset = clampf(anchor_offset, 0.0, total_len)
	var anchor_pos: Vector3 = _rail_curve.sample_baked(anchor_offset)
	var anchor_fwd: Vector3 = _sample_curve_fwd(_rail_curve, anchor_offset, total_len)
	var junction_pos: Vector3 = junction.pos
	var junction_fwd: Vector3 = junction.fwd
	if junction_fwd.dot(anchor_fwd) < 0.0:
		junction_fwd = -junction_fwd
	var tangent_len: float = blend_dist / 3.0
	var p0: Vector3
	var p1: Vector3
	var p2: Vector3
	var p3: Vector3
	if is_start:
		# u=0 at anchor (along = blend_dist), u=1 at junction (along = 0)
		p0 = anchor_pos
		p1 = anchor_pos - anchor_fwd * tangent_len
		p2 = junction_pos + junction_fwd * tangent_len
		p3 = junction_pos
	else:
		# u=0 at anchor (along = total_len - blend_dist), u=1 at junction (along = total_len)
		p0 = anchor_pos
		p1 = anchor_pos + anchor_fwd * tangent_len
		p2 = junction_pos - junction_fwd * tangent_len
		p3 = junction_pos
	return {
		"p0": p0,
		"p1": p1,
		"p2": p2,
		"p3": p3,
		"is_start": is_start,
	}


func _sample_bezier_transform(bez: Dictionary, u: float) -> Transform3D:
	# u here follows the Bezier (0=anchor, 1=junction). For the start blend the
	# along axis travels from junction (along=0) toward anchor (along=blend_dist),
	# so we flip u before evaluating to keep u=0=anchor / u=1=junction.
	var bez_u: float = u
	if bool(bez.get("is_start", false)):
		bez_u = 1.0 - u
	var pos: Vector3 = _bezier_point(bez.p0, bez.p1, bez.p2, bez.p3, bez_u)
	var tangent: Vector3 = _bezier_tangent(bez.p0, bez.p1, bez.p2, bez.p3, bez_u)
	if bool(bez.get("is_start", false)):
		tangent = -tangent
	if tangent.length_squared() < 0.0001:
		tangent = Vector3.FORWARD
	return Transform3D(_basis_from_fwd(tangent.normalized()), pos)


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

func _build_rail_meshes(idx: int = 0) -> void:
	if _rail_curve == null or _rail_curve.point_count < 2:
		return

	var path := Path3D.new()
	path.name = "RailPath_%d" % idx
	path.curve = _rail_curve
	add_child(path)

	var total_len: float = _rail_curve.get_baked_length()

	var rail_container := Node3D.new()
	rail_container.name = "Rails_%d" % idx
	add_child(rail_container)

	# Try tiled rail sections from glb asset, fall back to procedural strips
	if ResourceLoader.exists("res://assets/models/rails/rail_section.glb"):
		_rail_section_scene = load("res://assets/models/rails/rail_section.glb")

	if rail_use_deformed_mesh and _rail_section_scene != null:
		var deformed_mesh := _build_deformed_rail_section_mesh(total_len, _rail_section_scene)
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
				var offsets := PackedFloat32Array()
				var o := section_length * 0.5
				while o <= total_len + 0.0001:
					offsets.push_back(minf(o, total_len))
					o += _adaptive_step_at_offset(o, section_length, total_len)
				if offsets.size() == 0:
					offsets.push_back(total_len * 0.5)
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

	_build_fallback_rails(rail_container, total_len)


func _build_fallback_rails(rail_container: Node3D, total_len: float) -> void:
	var width_scale: float = maxf(rail_width_scale, 0.1)
	var step: float = maxf(rail_section_length * 0.25, 0.2)
	var samples: Array[Transform3D] = []
	var offset: float = 0.0
	while offset <= total_len:
		samples.append(_sample_track_transform(offset))
		offset += _adaptive_step_at_offset(offset, step, total_len)
	if samples.size() == 0 or samples[-1].origin.distance_to(_rail_curve.sample_baked(total_len)) > 0.01:
		samples.append(_sample_track_transform(total_len))
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
	var tie_count: int = int(total_len / tie_spacing)
	if tie_count > 0:
		var tm := BoxMesh.new()
		tm.size = Vector3(1.6 * width_scale, 0.08, 0.12)
		tm.surface_set_material(0, tie_mat)
		var tmm := MultiMesh.new()
		tmm.transform_format = MultiMesh.TRANSFORM_3D
		tmm.mesh = tm
		tmm.instance_count = tie_count
		for i in range(tie_count):
			var t := _sample_track_transform(float(i) * tie_spacing)
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


func _build_deformed_rail_section_mesh(total_len: float, section_scene: PackedScene) -> ArrayMesh:
	if _rail_curve == null or total_len <= 0.001:
		return null
	var width_scale: float = maxf(rail_width_scale, 0.1)
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
	var tile_count: int = int(ceil(total_len / tile_len))
	if tile_count <= 0:
		tile_count = 1

	var junction_start: Dictionary = _compute_junction_basis(_current_rail_path_source, 0.0)
	var junction_end: Dictionary = _compute_junction_basis(_current_rail_path_source, total_len)
	var blend_dist: float = clampf(rail_junction_blend_length, 0.0, total_len * 0.45)
	var start_bezier: Dictionary = _build_junction_bezier(junction_start, blend_dist, total_len, true)
	var end_bezier: Dictionary = _build_junction_bezier(junction_end, blend_dist, total_len, false)

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
				var lateral: float = -v_local.z * width_scale
				var vertical: float = v_local.y
				var t := _sample_track_transform(along)
				if not start_bezier.is_empty() and along < blend_dist:
					var u: float = clampf(along / blend_dist, 0.0, 1.0)
					t = _sample_bezier_transform(start_bezier, u)
				elif not end_bezier.is_empty() and along > total_len - blend_dist:
					var u: float = clampf((along - (total_len - blend_dist)) / blend_dist, 0.0, 1.0)
					t = _sample_bezier_transform(end_bezier, u)
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
		out_mesh.surface_set_material(out_mesh.get_surface_count() - 1, _make_visible_rail_section_material())
	return out_mesh


func _make_visible_rail_section_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.18, 1.08, 0.96, 1.0)
	if ResourceLoader.exists("res://assets/models/rails/rail_section_rail_basecolor.jpg"):
		mat.albedo_texture = load("res://assets/models/rails/rail_section_rail_basecolor.jpg")
	mat.metallic = 0.0
	mat.roughness = 0.8
	mat.normal_enabled = false
	return mat




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
