extends Node3D
class_name TerrainGenerator

# Reads a hand-placed Curve3D from a RailPath node in the scene
# and builds rail meshes (sections, ties, gravel) along it.
# Terrain sculpting is optional — only runs if the active terrain node
# exposes a sculpt_terrain_for_rails() method.

enum Biome { PLAINS, FOREST, DESERT, SNOW, MOUNTAIN }
enum SegmentType { GROUND, BRIDGE, TUNNEL }

@export var ground_offset: float = 0.20
@export var roadbed_half_width: float = 2.5
@export var roadbed_blend_width: float = 3.5
@export var rail_gauge: float = 1.0
@export var bridge_threshold: float = 2.0
@export var tunnel_threshold: float = 3.5
## Optional explicit reference — if null, scans the "rail_path" group
@export var rail_path_node: NodePath

var _terrain_patch: Node = null
var _rail_curve: Curve3D = null
var _rail_points: Array[Vector3] = []
var _rail_types: Array[int] = []


func _ready() -> void:
	add_to_group("terrain")
	await get_tree().process_frame
	_find_terrain_patch()
	if not _load_curve_from_rail_path():
		push_warning("TerrainGenerator: no valid RailPath found — rails disabled")


func _find_terrain_patch() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for child in parent.get_children():
		if child is TerrainPatch3D:
			_terrain_patch = child
			return


func _load_curve_from_rail_path() -> bool:
	var node: Node = null
	if not rail_path_node.is_empty():
		node = get_node_or_null(rail_path_node)
	if node == null:
		var candidates := get_tree().get_nodes_in_group("rail_path")
		if candidates.size() > 0:
			node = candidates[0]
	if node == null or not (node is Path3D):
		return false
	var path: Path3D = node
	if path.curve == null or path.curve.point_count < 2:
		push_warning("RailPath found but curve is empty")
		return false
	var world_curve := Curve3D.new()
	world_curve.bake_interval = 0.5
	for i in range(path.curve.point_count):
		var p: Vector3 = path.to_global(path.curve.get_point_position(i))
		var t_in: Vector3 = path.global_basis * path.curve.get_point_in(i)
		var t_out: Vector3 = path.global_basis * path.curve.get_point_out(i)
		world_curve.add_point(p, t_in, t_out)
	_rail_curve = world_curve
	var total_len := _rail_curve.get_baked_length()
	_rail_points.clear()
	var t := 0.0
	while t <= total_len:
		_rail_points.append(_rail_curve.sample_baked(t))
		t += 1.0
	if _rail_points.size() == 0 or _rail_points[-1] != _rail_curve.sample_baked(total_len):
		_rail_points.append(_rail_curve.sample_baked(total_len))
	if _terrain_patch and _terrain_patch.has_method("sculpt_terrain_for_rails"):
		_terrain_patch.sculpt_terrain_for_rails(
			_rail_points, roadbed_half_width, roadbed_blend_width
		)
	_classify_segments_from_curve()
	_build_rail_meshes()
	return true


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


# --- Flat transform (Y = world up) ---

func _sample_flat_transform(offset: float) -> Transform3D:
	var total: float = _rail_curve.get_baked_length()
	var pos: Vector3 = _rail_curve.sample_baked(offset)
	var ahead: float = minf(offset + 1.0, total)
	var behind: float = maxf(offset - 1.0, 0.0)
	var fwd: Vector3 = _rail_curve.sample_baked(ahead) - _rail_curve.sample_baked(behind)
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var right := Vector3.UP.cross(fwd).normalized()
	return Transform3D(Basis(right, Vector3.UP, fwd), pos)


# --- Rail mesh building ---

var _rail_section_scene: PackedScene = null

func _build_rail_meshes() -> void:
	if _rail_curve == null or _rail_curve.point_count < 2:
		return

	var path := Path3D.new()
	path.name = "RailPath"
	path.curve = _rail_curve
	add_child(path)

	var total_len: float = _rail_curve.get_baked_length()

	var rail_container := Node3D.new()
	rail_container.name = "Rails"
	add_child(rail_container)

	# Try tiled rail sections from glb asset, fall back to procedural strips
	if ResourceLoader.exists("res://assets/models/rails/rail_section.glb"):
		_rail_section_scene = load("res://assets/models/rails/rail_section.glb")
	if _rail_section_scene != null:
		var section_length: float = 2.4
		var section_count: int = int(ceil(total_len / section_length))
		if section_count > 0:
			var temp_instance := _rail_section_scene.instantiate()
			var rail_mesh: Mesh = null
			for child in temp_instance.get_children():
				if child is MeshInstance3D:
					rail_mesh = child.mesh
					break
			temp_instance.queue_free()
			if rail_mesh != null:
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = rail_mesh
				mm.instance_count = section_count
				var rot90 := Basis(Vector3.UP, -PI / 2.0)
				for i in range(section_count):
					var t_offset: float = float(i) * section_length + section_length * 0.5
					t_offset = minf(t_offset, total_len)
					var t := _sample_flat_transform(t_offset)
					t.basis = t.basis * rot90
					mm.set_instance_transform(i, t)
				var mmi := MultiMeshInstance3D.new()
				mmi.name = "RailSections"
				mmi.multimesh = mm
				rail_container.add_child(mmi)
				return

	_build_fallback_rails(rail_container, total_len)


func _build_fallback_rails(rail_container: Node3D, total_len: float) -> void:
	var step: float = 0.5
	var samples: Array[Transform3D] = []
	var offset: float = 0.0
	while offset <= total_len:
		samples.append(_sample_flat_transform(offset))
		offset += step
	if samples.size() < 2:
		return

	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.28, 0.26, 0.24)
	rail_mat.metallic = 0.88
	rail_mat.roughness = 0.28

	var gravel_mat: Material = null
	if ResourceLoader.exists("res://textures/rails/M_gravel.tres"):
		gravel_mat = load("res://textures/rails/M_gravel.tres")
	if gravel_mat == null:
		gravel_mat = StandardMaterial3D.new()

	var ballast_mesh := _build_ballast_strip(samples, gravel_mat)
	var ballast_mi := MeshInstance3D.new()
	ballast_mi.name = "Ballast"
	ballast_mi.mesh = ballast_mesh
	rail_container.add_child(ballast_mi)

	var tie_mat: Material = null
	if ResourceLoader.exists("res://textures/rails/wood_tie/M_wood_tie.tres"):
		tie_mat = load("res://textures/rails/wood_tie/M_wood_tie.tres")
	if tie_mat == null:
		tie_mat = StandardMaterial3D.new()
	var tie_spacing: float = 0.55
	var tie_count: int = int(total_len / tie_spacing)
	if tie_count > 0:
		var tm := BoxMesh.new()
		tm.size = Vector3(1.6, 0.08, 0.12)
		tm.surface_set_material(0, tie_mat)
		var tmm := MultiMesh.new()
		tmm.transform_format = MultiMesh.TRANSFORM_3D
		tmm.mesh = tm
		tmm.instance_count = tie_count
		for i in range(tie_count):
			var t := _sample_flat_transform(float(i) * tie_spacing)
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


func _build_ballast_strip(samples: Array[Transform3D], mat: Material) -> ArrayMesh:
	var half_w: float = 1.1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs_arr := PackedVector2Array()
	var indices := PackedInt32Array()
	var n: int = samples.size()
	for i in range(n):
		var t: Transform3D = samples[i]
		var right: Vector3 = t.basis.x.normalized()
		var center: Vector3 = t.origin
		center.y -= 0.02
		var uv_v: float = float(i) * 0.5
		verts.append(center - right * half_w)
		verts.append(center + right * half_w)
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		uvs_arr.append(Vector2(0.0, uv_v))
		uvs_arr.append(Vector2(1.0, uv_v))
	for i in range(n - 1):
		var b: int = i * 2
		indices.append(b)
		indices.append(b + 1)
		indices.append(b + 3)
		indices.append(b)
		indices.append(b + 3)
		indices.append(b + 2)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs_arr
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	return mesh


func _build_rail_strip(samples: Array[Transform3D], lateral_offset: float, mat: Material) -> ArrayMesh:
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
