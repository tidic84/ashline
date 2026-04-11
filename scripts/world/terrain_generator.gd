extends Node3D
class_name TerrainGenerator

# Consumes a hand-placed Curve3D from a RailPath node in the scene.
# Sculpts a flat roadbed under the curve and renders rail meshes along it.
# If no RailPath is found, falls back to legacy procedural generation.

enum Biome { PLAINS, FOREST, DESERT, SNOW, MOUNTAIN }
enum SegmentType { GROUND, BRIDGE, TUNNEL }

@export var terrain_size: float = 500.0
@export var water_level: float = -100.0
## Legacy procedural fallback knobs (only used if no RailPath node found)
@export var rail_waypoints: int = 55
@export var detour_search_width: float = 60.0
@export var detour_search_step: float = 5.0
@export var max_slope: float = 0.04
@export var bridge_threshold: float = 2.0
@export var tunnel_threshold: float = 3.5
@export var ground_offset: float = 0.20
@export var roadbed_half_width: float = 2.5
@export var roadbed_blend_width: float = 3.5
@export var rail_gauge: float = 1.0
@export var rail_seed: int = 1337
## Optional explicit reference — if null, scans the "rail_path" group
@export var rail_path_node: NodePath

## Target can be a single TerrainPatch3D or a TerrainStreamer (both expose
## get_height_at, sculpt_terrain_for_rails, and _sample_height).
var _terrain_patch: Node = null
var _rail_curve: Curve3D = null
var _rail_points: Array[Vector3] = []
var _rail_types: Array[int] = []


func _ready() -> void:
	add_to_group("terrain")
	await get_tree().process_frame
	_find_terrain_patch()
	if _terrain_patch == null:
		push_warning("TerrainGenerator: no TerrainPatch3D or TerrainStreamer found — rails disabled")
		return
	if _load_curve_from_rail_path():
		return  # hand-placed path already sculpted + built meshes
	# Legacy procedural fallback
	_build_rail_curve()
	var dense_rail_pts: Array[Vector3] = []
	if _rail_curve and _rail_curve.get_baked_length() > 0.0:
		var total_len: float = _rail_curve.get_baked_length()
		var t: float = 0.0
		while t <= total_len:
			dense_rail_pts.append(_rail_curve.sample_baked(t))
			t += 1.0
		if dense_rail_pts.size() == 0 or dense_rail_pts[-1] != _rail_curve.sample_baked(total_len):
			dense_rail_pts.append(_rail_curve.sample_baked(total_len))
	_terrain_patch.sculpt_terrain_for_rails(
		dense_rail_pts, roadbed_half_width, roadbed_blend_width
	)
	_build_rail_meshes()
	_carve_biomes_along_rails()


func _carve_biomes_along_rails() -> void:
	# Paint an exclusion stripe along the rails into each Biomes node's mask
	# so trees / plants / flowers don't spawn on the tracks.
	if _rail_curve == null or _rail_points.is_empty():
		return
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var exclusion_radius: float = roadbed_half_width + 1.5
	for child in scene_root.get_children():
		if child == null:
			continue
		if not child.has_method("get_mask_image_copy") or not child.has_method("preview_mask_image"):
			continue
		var img: Image = child.get_mask_image_copy()
		if img == null or img.is_empty():
			continue
		# Densely sample along the curve so the painted line has no gaps
		var total_len: float = _rail_curve.get_baked_length()
		var step: float = 1.0
		var t: float = 0.0
		while t <= total_len:
			var p: Vector3 = _rail_curve.sample_baked(t, true)
			child.paint_mask_circle_on_image(img, Vector3(p.x, 0.0, p.z), exclusion_radius, 1.0, 0.8, 1.0)
			t += step
		# Apply without saving to disk
		child.preview_mask_image(img)


func _find_terrain_patch() -> void:
	var parent := get_parent()
	if parent == null:
		return
	# Prefer TerrainStreamer if present, fall back to a plain TerrainPatch3D
	for child in parent.get_children():
		if child is TerrainStreamer:
			_terrain_patch = child
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
		push_warning("RailPath found but curve is empty — falling back to procedural")
		return false
	# Bake into world space so sampling in TerrainGenerator local space (Main)
	# is consistent with the rest of the code.
	var world_curve := Curve3D.new()
	world_curve.bake_interval = 0.5
	for i in range(path.curve.point_count):
		var p: Vector3 = path.to_global(path.curve.get_point_position(i))
		var t_in: Vector3 = path.curve.get_point_in(i)
		var t_out: Vector3 = path.curve.get_point_out(i)
		# Tangents are local offsets — rotate them into world basis
		t_in = path.global_basis * t_in
		t_out = path.global_basis * t_out
		world_curve.add_point(p, t_in, t_out)
	_rail_curve = world_curve
	# Dense sampling for sculpting
	var total_len := _rail_curve.get_baked_length()
	_rail_points.clear()
	var t := 0.0
	while t <= total_len:
		_rail_points.append(_rail_curve.sample_baked(t))
		t += 1.0
	if _rail_points.size() == 0 or _rail_points[-1] != _rail_curve.sample_baked(total_len):
		_rail_points.append(_rail_curve.sample_baked(total_len))
	_terrain_patch.sculpt_terrain_for_rails(
		_rail_points, roadbed_half_width, roadbed_blend_width
	)
	_classify_segments_from_curve()
	_build_rail_meshes()
	_carve_biomes_along_rails()
	return true


func _classify_segments_from_curve() -> void:
	# Rebuild _rail_types from the current _rail_points so bridge/tunnel
	# decoration still works in both procedural and hand-placed modes.
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

func get_height_at(x: float, z: float) -> float:
	if _terrain_patch == null:
		return 0.0
	return _terrain_patch._sample_height(x, z)

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
	# Use get_closest_point for fast XZ distance (single call, O(1) vs O(N))
	var closest: Vector3 = _rail_curve.get_closest_point(world_pos)
	var dx: float = world_pos.x - closest.x
	var dz: float = world_pos.z - closest.z
	return sqrt(dx * dx + dz * dz)

func sample_rail_progress(world_pos: Vector3) -> float:
	if _rail_curve == null:
		return 0.0
	return _rail_curve.get_closest_offset(world_pos)


# --- Rail curve generation ---

func _build_rail_curve() -> void:
	var half: float = terrain_size * 0.45
	var n: int = rail_waypoints

	# Step 1: Coarse waypoints — search for low terrain in a wide band
	var pts: Array[Vector3] = []
	for i in range(n + 1):
		var t: float = float(i) / float(n)
		var z: float = lerpf(-half, half, t)
		var base_x: float = sin(t * TAU * 0.4) * 15.0  # gentle sinusoidal base
		var best_x: float = base_x
		var best_h: float = INF
		var x: float = base_x - detour_search_width
		while x <= base_x + detour_search_width:
			var h: float = get_height_at(x, z)
			if h < best_h:
				best_h = h
				best_x = x
			x += detour_search_step
		pts.append(Vector3(best_x, best_h, z))

	# Step 2: Very heavy XZ smoothing — trains need gentle curves
	for _pass in range(20):
		for i in range(1, pts.size() - 1):
			pts[i].x = (pts[i - 1].x + pts[i].x + pts[i + 1].x) / 3.0
			pts[i].z = (pts[i - 1].z + pts[i].z + pts[i + 1].z) / 3.0

	# Step 3: Resample heights at smoothed XZ, add ground offset
	for i in range(pts.size()):
		pts[i].y = get_height_at(pts[i].x, pts[i].z) + ground_offset

	# Step 4: Very heavy Y smoothing — wide window, many passes
	for _pass in range(30):
		for i in range(1, pts.size() - 1):
			var lo: int = maxi(i - 5, 0)
			var hi: int = mini(i + 5, pts.size() - 1)
			var sum: float = 0.0
			var cnt: int = 0
			for k in range(lo, hi + 1):
				sum += pts[k].y
				cnt += 1
			pts[i].y = sum / float(cnt)

	# Step 5: Enforce max slope — many passes for convergence
	for _pass in range(10):
		for i in range(1, pts.size()):
			var run: float = Vector2(
				pts[i].x - pts[i - 1].x,
				pts[i].z - pts[i - 1].z
			).length()
			var max_rise: float = run * max_slope
			var dy: float = pts[i].y - pts[i - 1].y
			if absf(dy) > max_rise:
				pts[i].y = pts[i - 1].y + (max_rise if dy > 0.0 else -max_rise)
		for i in range(pts.size() - 2, -1, -1):
			var run: float = Vector2(
				pts[i + 1].x - pts[i].x,
				pts[i + 1].z - pts[i].z
			).length()
			var max_rise: float = run * max_slope
			var dy: float = pts[i + 1].y - pts[i].y
			if absf(dy) > max_rise:
				pts[i].y = pts[i + 1].y + (-max_rise if dy > 0.0 else max_rise)

	# Step 6: Classify segments
	_rail_types.clear()
	_rail_types.resize(pts.size())
	for i in range(pts.size()):
		var terrain_h: float = get_height_at(pts[i].x, pts[i].z)
		var diff: float = pts[i].y - terrain_h
		if diff > bridge_threshold:
			_rail_types[i] = SegmentType.BRIDGE
		elif diff < -tunnel_threshold:
			_rail_types[i] = SegmentType.TUNNEL
		else:
			_rail_types[i] = SegmentType.GROUND

	_rail_points = pts

	# Build Curve3D with Catmull-Rom tangents
	_rail_curve = Curve3D.new()
	_rail_curve.bake_interval = 0.5  # dense bake for smooth train movement
	for i in range(pts.size()):
		var t_in := Vector3.ZERO
		var t_out := Vector3.ZERO
		if i > 0 and i < pts.size() - 1:
			var tang: Vector3 = (pts[i + 1] - pts[i - 1]) * 0.5
			t_in = -tang
			t_out = tang
		elif i == 0 and pts.size() > 1:
			t_out = (pts[1] - pts[0]) * 0.5
		elif i == pts.size() - 1 and pts.size() > 1:
			t_in = -(pts[i] - pts[i - 1]) * 0.5
		_rail_curve.add_point(pts[i], t_in, t_out)


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


# --- Rail mesh building (tiled Megascans rail sections via MultiMesh) ---

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

	# ── Tiled rail sections (Megascans model) ──
	# The rail_section.glb in Godot: X~2.5m (width), Y~0.22m (height), Z~2.4m (length)
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
				# The model's length runs along X; rotate 90° Y so it aligns with track Z
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
	else:
		_build_fallback_rails(rail_container, total_len)

	_build_bridges()
	_build_tunnel_portals()


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

	var gravel_mat: Material = load("res://textures/rails/M_gravel.tres")
	if gravel_mat == null:
		gravel_mat = StandardMaterial3D.new()

	var ballast_mesh := _build_ballast_strip(samples, gravel_mat)
	var ballast_mi := MeshInstance3D.new()
	ballast_mi.name = "Ballast"
	ballast_mi.mesh = ballast_mesh
	rail_container.add_child(ballast_mi)

	var tie_mat: Material = load("res://textures/rails/wood_tie/M_wood_tie.tres")
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


## Build a continuous gravel ballast strip as a flat ribbon along the track.
func _build_ballast_strip(samples: Array[Transform3D], mat: Material) -> ArrayMesh:
	var half_w: float = 1.1  # half width of ballast bed
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs_arr := PackedVector2Array()
	var indices := PackedInt32Array()
	var n: int = samples.size()

	for i in range(n):
		var t: Transform3D = samples[i]
		var right: Vector3 = t.basis.x.normalized()
		var center: Vector3 = t.origin
		center.y -= 0.02  # slightly below ties
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


## Build a continuous rail strip as an ArrayMesh (no gaps, no staircase).
## Each cross-section is an inverted-T rail profile.
func _build_rail_strip(samples: Array[Transform3D], lateral_offset: float, mat: Material) -> ArrayMesh:
	# Rail profile (cross-section): simplified inverted-T
	# Head: 0.05 wide, 0.03 tall at top
	# Web:  0.02 wide, 0.04 tall in middle
	# Base: 0.06 wide, 0.02 tall at bottom
	# We approximate as a simple rectangular cross-section for performance
	var hw: float = 0.025  # half width of rail head
	var hh: float = 0.05   # half height of rail

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var n: int = samples.size()

	# For each sample, generate 4 vertices (box cross-section corners)
	for i in range(n):
		var t: Transform3D = samples[i]
		var right: Vector3 = t.basis.x.normalized()
		var up := Vector3.UP
		var center: Vector3 = t.origin + right * lateral_offset
		center.y += hh + 0.04  # lift above tie

		var uv_v: float = float(i) * 0.5  # UV along length

		# 4 corners: top-left, top-right, bottom-right, bottom-left
		verts.append(center + up * hh - right * hw)  # TL
		verts.append(center + up * hh + right * hw)  # TR
		verts.append(center - up * hh + right * hw)  # BR
		verts.append(center - up * hh - right * hw)  # BL

		norms.append((-right + up).normalized())
		norms.append((right + up).normalized())
		norms.append((right - up).normalized())
		norms.append((-right - up).normalized())

		uvs.append(Vector2(0.0, uv_v))
		uvs.append(Vector2(1.0, uv_v))
		uvs.append(Vector2(1.0, uv_v))
		uvs.append(Vector2(0.0, uv_v))

	# Connect each pair of cross-sections with quads (2 triangles each face)
	for i in range(n - 1):
		var base: int = i * 4
		var next: int = (i + 1) * 4
		# 4 faces: top, right, bottom, left
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


func _build_bridges() -> void:
	var container := Node3D.new()
	container.name = "Bridges"
	add_child(container)

	var pier_mat := StandardMaterial3D.new()
	pier_mat.albedo_color = Color(0.52, 0.50, 0.46)
	pier_mat.roughness = 0.85
	pier_mat.metallic = 0.1
	var pier_mesh := BoxMesh.new()
	pier_mesh.size = Vector3(0.4, 1.0, 0.4)
	pier_mesh.material = pier_mat

	var deck_mat := StandardMaterial3D.new()
	deck_mat.albedo_color = Color(0.32, 0.30, 0.27)
	deck_mat.roughness = 0.6
	deck_mat.metallic = 0.7
	var deck_mesh := BoxMesh.new()
	deck_mesh.size = Vector3(2.0, 0.12, 1.0)
	deck_mesh.material = deck_mat

	var piers: Array[Transform3D] = []
	var decks: Array[Transform3D] = []

	for i in range(_rail_points.size()):
		if _rail_types[i] != SegmentType.BRIDGE:
			continue
		var p: Vector3 = _rail_points[i]
		var gh: float = get_height_at(p.x, p.z)
		var ph: float = maxf(p.y - gh, 0.5)
		if i % 3 == 0:
			for side in [-0.8, 0.8]:
				var pp := Vector3(p.x + side, gh + ph * 0.5, p.z)
				piers.append(Transform3D(Basis().scaled(Vector3(1, ph, 1)), pp))
		var off := _rail_curve.get_closest_offset(p)
		var ft := _sample_flat_transform(off)
		ft.origin.y -= 0.06
		decks.append(ft)

	_emit_multimesh(container, "Piers", pier_mesh, piers)
	_emit_multimesh(container, "Deck", deck_mesh, decks)


func _build_tunnel_portals() -> void:
	var container := Node3D.new()
	container.name = "TunnelPortals"
	add_child(container)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.28, 0.25, 0.22)
	pmat.roughness = 0.9

	for i in range(_rail_points.size()):
		var is_t: bool = _rail_types[i] == SegmentType.TUNNEL
		var prev_t: bool = i > 0 and _rail_types[i - 1] == SegmentType.TUNNEL
		if not ((is_t and not prev_t) or (not is_t and prev_t)):
			continue
		var p: Vector3 = _rail_points[i]
		var gh: float = get_height_at(p.x, p.z)
		var portal := CSGBox3D.new()
		portal.size = Vector3(3.5, 3.5, 0.6)
		portal.material = pmat
		portal.position = Vector3(p.x, maxf(p.y, gh) + 1.2, p.z)
		var hole := CSGBox3D.new()
		hole.size = Vector3(2.2, 2.6, 1.0)
		hole.operation = CSGShape3D.OPERATION_SUBTRACTION
		hole.position = Vector3(0, -0.3, 0)
		portal.add_child(hole)
		portal.basis = _sample_flat_transform(_rail_curve.get_closest_offset(p)).basis
		container.add_child(portal)


func _emit_multimesh(parent: Node3D, node_name: String, mesh: Mesh, transforms: Array[Transform3D]) -> void:
	if transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	parent.add_child(mmi)
