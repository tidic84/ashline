@tool
extends Node3D
class_name LakeWater3D

const SURFACE_NODE_NAME := "__lake_surface"

var _rebuild_queued := false
var _terrain_refresh_queued := false
var _suppress_refresh := false

@export var terrain_path: NodePath:
	set(value):
		terrain_path = value
		_queue_rebuild()
		_queue_terrain_refresh()

@export_range(2.0, 80.0, 0.1, "or_greater") var radius: float = 14.0:
	set(value):
		radius = maxf(value, 2.0)
		_queue_rebuild()
		_queue_terrain_refresh()

@export_range(0.5, 40.0, 0.1, "or_greater") var shore_width: float = 4.0:
	set(value):
		shore_width = maxf(value, 0.5)
		_queue_rebuild()
		_queue_terrain_refresh()

@export_range(0.0, 40.0, 0.1, "or_greater") var blend_width: float = 4.0:
	set(value):
		blend_width = maxf(value, 0.0)
		_queue_rebuild()
		_queue_terrain_refresh()

@export_range(0.5, 40.0, 0.1, "or_greater") var depth: float = 4.5:
	set(value):
		depth = maxf(value, 0.5)
		_queue_rebuild()
		_queue_terrain_refresh()

@export_range(0.0, 5.0, 0.01, "or_greater") var surface_inset: float = 0.35:
	set(value):
		surface_inset = maxf(value, 0.0)
		_queue_rebuild()

@export_range(12, 128, 1, "or_greater") var surface_segments: int = 56:
	set(value):
		surface_segments = maxi(value, 12)
		_queue_rebuild()

@export var auto_fit_height := true:
	set(value):
		auto_fit_height = value
		_queue_rebuild()
		_queue_terrain_refresh()

@export_range(-10.0, 10.0, 0.01) var water_level_offset: float = -1.1:
	set(value):
		water_level_offset = value
		_queue_rebuild()
		_queue_terrain_refresh()

@export var surface_material: Material:
	set(value):
		surface_material = value
		_apply_surface_material()


func _enter_tree() -> void:
	add_to_group("terrain_lake")
	set_notify_transform(true)


func _ready() -> void:
	_queue_rebuild()
	_queue_terrain_refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and not _suppress_refresh:
		_queue_rebuild()
		_queue_terrain_refresh()


func get_lake_sculpt_data() -> Dictionary:
	return {
		"center": global_position,
		"radius": radius,
		"shore_width": shore_width,
		"blend_width": blend_width,
		"depth": depth
	}


func _queue_rebuild() -> void:
	if _rebuild_queued or not is_inside_tree():
		return
	_rebuild_queued = true
	call_deferred("_rebuild")


func _queue_terrain_refresh() -> void:
	if _terrain_refresh_queued or not is_inside_tree():
		return
	_terrain_refresh_queued = true
	call_deferred("_refresh_terrain")


func _rebuild() -> void:
	_rebuild_queued = false
	if not is_inside_tree():
		return
	_fit_height_to_terrain()
	var surface := _ensure_surface_instance()
	surface.mesh = _build_surface_mesh()
	_apply_surface_material()


func _refresh_terrain() -> void:
	_terrain_refresh_queued = false
	var terrain := _find_terrain_patch()
	if terrain != null and terrain.has_method("regenerate"):
		terrain.call_deferred("regenerate")


func _fit_height_to_terrain() -> void:
	if not auto_fit_height:
		return
	var terrain := _find_terrain_patch()
	if terrain == null:
		return
	var local_center := terrain.to_local(global_position)
	var base_height: float = terrain.sample_base_height(local_center.x, local_center.z)
	var world_height := terrain.to_global(Vector3(local_center.x, base_height + water_level_offset, local_center.z)).y
	if is_equal_approx(global_position.y, world_height):
		return
	_suppress_refresh = true
	global_position.y = world_height
	_suppress_refresh = false


func _ensure_surface_instance() -> MeshInstance3D:
	var surface := get_node_or_null(SURFACE_NODE_NAME) as MeshInstance3D
	if surface != null:
		return surface
	surface = MeshInstance3D.new()
	surface.name = SURFACE_NODE_NAME
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(surface)
	return surface


func _apply_surface_material() -> void:
	var surface := get_node_or_null(SURFACE_NODE_NAME) as MeshInstance3D
	if surface == null:
		return
	surface.material_override = surface_material if surface_material != null else _build_default_material()


func _build_surface_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var ring_radius := maxf(radius - surface_inset, 0.5)
	var segment_count := maxi(surface_segments, 12)

	verts.push_back(Vector3.ZERO)
	normals.push_back(Vector3.UP)
	uvs.push_back(Vector2(0.5, 0.5))

	for i in range(segment_count):
		var angle := TAU * float(i) / float(segment_count)
		var x := cos(angle) * ring_radius
		var z := sin(angle) * ring_radius
		verts.push_back(Vector3(x, 0.0, z))
		normals.push_back(Vector3.UP)
		uvs.push_back(Vector2((x / (ring_radius * 2.0)) + 0.5, (z / (ring_radius * 2.0)) + 0.5))

	for i in range(segment_count):
		var current := i + 1
		var next := ((i + 1) % segment_count) + 1
		indices.push_back(0)
		indices.push_back(next)
		indices.push_back(current)

	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_default_material() -> Material:
	var shader_mat: Material = load("res://materials/M_lake_water.tres")
	if shader_mat != null:
		return shader_mat
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.12, 0.33, 0.40, 0.72)
	mat.metallic = 0.04
	mat.roughness = 0.08
	mat.emission_enabled = true
	mat.emission = Color(0.03, 0.10, 0.12)
	return mat


func _find_terrain_patch() -> TerrainPatch3D:
	if not terrain_path.is_empty():
		var explicit := get_node_or_null(terrain_path) as TerrainPatch3D
		if explicit != null:
			return explicit
	var parent := get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child is TerrainPatch3D:
			return child as TerrainPatch3D
	return null
