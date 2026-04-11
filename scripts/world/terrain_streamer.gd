@tool
class_name TerrainStreamer
extends Node3D

## Chunked terrain manager. Spawns a grid of TerrainPatch3D chunks, streams
## their mesh visibility + collision based on distance to the active camera.
## Provides the same interface that TerrainGenerator expects from a single
## TerrainPatch3D (get_height_at, sculpt_terrain_for_rails, _sample_height).

@export_group("World")
@export var world_size: Vector2 = Vector2(500.0, 500.0):
	set(value):
		world_size = Vector2(maxf(value.x, 1.0), maxf(value.y, 1.0))
		_queue_rebuild()

@export var chunk_count: Vector2i = Vector2i(5, 5):
	set(value):
		chunk_count = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		_queue_rebuild()

@export_range(4, 512, 1, "or_greater") var subdivisions_per_chunk: int = 40:
	set(value):
		subdivisions_per_chunk = maxi(value, 4)
		_queue_rebuild()

@export_group("Terrain")
@export_range(0.0, 1000.0, 0.01, "or_greater") var height_scale: float = 22.0:
	set(value):
		height_scale = maxf(value, 0.0)
		_queue_rebuild()

@export_range(0.01, 100.0, 0.01, "or_greater") var uv_scale: float = 3.0:
	set(value):
		uv_scale = maxf(value, 0.01)
		_queue_rebuild()

@export var terrain_material: Material:
	set(value):
		terrain_material = value
		_apply_terrain_material_override()

@export_group("Noise")
@export var noise: FastNoiseLite:
	set(value):
		noise = value
		_queue_rebuild()

@export_subgroup("Advanced Terrain")
@export var terrain_advanced: bool = true
@export_range(0.0, 100.0, 0.1) var erosion_strength: float = 6.0
@export_range(0.0, 50.0, 0.1) var detail_strength: float = 1.2
@export_range(0.0, 100.0, 0.1) var ridge_strength: float = 5.0
@export_range(0.0, 50.0, 0.1) var domain_warp_amount: float = 14.0
@export_range(0.0, 1.0, 0.01) var plateau_factor: float = 0.25
@export_range(0.0, 1.0, 0.01) var valley_carve: float = 0.3

@export_group("Collision")
@export var generate_collision: bool = true
@export_flags_3d_physics var collision_layer: int = 1
@export_flags_3d_physics var collision_mask: int = 1

@export_group("Grass")
@export var grass_enabled: bool = false
@export var grass_mesh: Mesh
@export var grass_material: Material
@export var grass_mask_enabled: bool = false
@export var grass_mask_texture: Texture2D
@export var grass_mask_area_size: Vector2 = Vector2.ZERO
@export_enum("Red", "Green", "Blue", "Alpha", "Luminance") var grass_mask_channel: int = 0
@export_range(0.0, 1.0, 0.01) var grass_mask_threshold: float = 0.5
@export var grass_mask_inverse: bool = false
@export_range(1.0, 200.0, 0.1, "or_greater") var grass_radius: float = 10.0
@export_range(0.1, 10.0, 0.01, "or_greater") var grass_spacing: float = 0.32
@export_range(1, 20000, 1, "or_greater") var grass_max_instances: int = 4000
@export_range(-10.0, 10.0, 0.01) var grass_height_offset: float = -0.17
@export_range(0.1, 20.0, 0.01, "or_greater") var grass_rebuild_distance: float = 3.5
@export_range(0.01, 10.0, 0.01, "or_greater") var grass_scale_min: float = 0.56
@export_range(0.01, 10.0, 0.01, "or_greater") var grass_scale_max: float = 0.88

@export_group("Streaming")
## Chunk-grid ring around player that stays rendered + collidable.
## 1 = 3x3, 2 = 5x5. Higher = bigger view but less savings.
@export_range(0, 10) var active_radius_chunks: int = 1
@export_range(0.05, 5.0, 0.01) var stream_update_interval: float = 0.15

var _chunks: Array[TerrainPatch3D] = []
var _chunk_size: Vector2 = Vector2.ZERO
var _rebuild_queued: bool = false
var _stream_accum: float = 0.0
var _last_chunk_coord: Vector2i = Vector2i(-999999, -999999)
var _camera: Camera3D = null


func _ready() -> void:
	add_to_group("terrain_streamer")
	_rebuild_now()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_stream_accum += delta
	if _stream_accum < stream_update_interval:
		return
	_stream_accum = 0.0
	_update_streaming()


# --- Public interface (matches TerrainPatch3D for TerrainGenerator) ---

func get_height_at(world_x: float, world_z: float) -> float:
	var chunk := _find_chunk_at(world_x, world_z)
	if chunk == null:
		return 0.0
	return chunk._sample_height(world_x - chunk.world_offset.x, world_z - chunk.world_offset.y)


# Alias so TerrainGenerator.get_height_at → patch._sample_height works the same
func _sample_height(world_x: float, world_z: float) -> float:
	return get_height_at(world_x, world_z)


func sculpt_terrain_for_rails(rail_points: Array[Vector3], half_width: float = 3.0, blend_width: float = 3.0) -> void:
	# Each chunk sculpts its own vertices using world-space rail points
	# (TerrainPatch3D now applies world_offset internally).
	for chunk in _chunks:
		if chunk == null:
			continue
		chunk.sculpt_terrain_for_rails(rail_points, half_width, blend_width)


# --- Chunk creation ---

func _queue_rebuild() -> void:
	if _rebuild_queued:
		return
	if not is_inside_tree():
		return
	_rebuild_queued = true
	call_deferred("_rebuild_now")


func _rebuild_now() -> void:
	_rebuild_queued = false
	_clear_chunks()
	if chunk_count.x <= 0 or chunk_count.y <= 0:
		return
	_chunk_size = Vector2(
		world_size.x / float(chunk_count.x),
		world_size.y / float(chunk_count.y)
	)
	var half := world_size * 0.5
	for cz in range(chunk_count.y):
		for cx in range(chunk_count.x):
			var patch := TerrainPatch3D.new()
			patch.name = "Chunk_%d_%d" % [cx, cz]
			var center_x := -half.x + _chunk_size.x * (float(cx) + 0.5)
			var center_z := -half.y + _chunk_size.y * (float(cz) + 0.5)
			patch.position = Vector3(center_x, 0.0, center_z)
			patch.world_offset = Vector2(center_x, center_z)
			patch.size = _chunk_size
			patch.subdivisions_x = subdivisions_per_chunk
			patch.subdivisions_z = subdivisions_per_chunk
			patch.height_scale = height_scale
			patch.uv_scale = uv_scale
			patch.terrain_material = terrain_material
			patch.noise = noise
			patch.terrain_advanced = terrain_advanced
			patch.erosion_strength = erosion_strength
			patch.detail_strength = detail_strength
			patch.ridge_strength = ridge_strength
			patch.domain_warp_amount = domain_warp_amount
			patch.plateau_factor = plateau_factor
			patch.valley_carve = valley_carve
			patch.generate_collision = generate_collision
			patch.collision_layer = collision_layer
			patch.collision_mask = collision_mask
			# Grass: forward streamer settings to each chunk
			patch.grass_enabled = grass_enabled
			patch.grass_mesh = grass_mesh
			patch.grass_material = grass_material
			patch.grass_mask_enabled = grass_mask_enabled
			patch.grass_mask_texture = grass_mask_texture
			patch.grass_mask_area_size = grass_mask_area_size if grass_mask_area_size != Vector2.ZERO else world_size
			patch.grass_mask_channel = grass_mask_channel
			patch.grass_mask_threshold = grass_mask_threshold
			patch.grass_mask_inverse = grass_mask_inverse
			patch.grass_radius = grass_radius
			patch.grass_spacing = grass_spacing
			patch.grass_max_instances = grass_max_instances
			patch.grass_height_offset = grass_height_offset
			patch.grass_rebuild_distance = grass_rebuild_distance
			patch.grass_scale_min = grass_scale_min
			patch.grass_scale_max = grass_scale_max
			add_child(patch)
			_chunks.append(patch)
	_last_chunk_coord = Vector2i(-999999, -999999)


func _clear_chunks() -> void:
	for chunk in _chunks:
		if chunk != null and is_instance_valid(chunk):
			chunk.queue_free()
	_chunks.clear()


func _apply_terrain_material_override() -> void:
	for chunk in _chunks:
		if chunk == null:
			continue
		chunk.terrain_material = terrain_material


# --- Streaming ---

func _update_streaming() -> void:
	if _chunks.is_empty():
		return
	var cam := _get_active_camera()
	if cam == null:
		return
	var cam_pos := cam.global_position
	var player_coord := _world_to_chunk_coord(cam_pos.x, cam_pos.z)
	if player_coord == _last_chunk_coord:
		return
	_last_chunk_coord = player_coord
	for chunk in _chunks:
		if chunk == null:
			continue
		var coord := _chunk_coord_of(chunk)
		var dx := absi(coord.x - player_coord.x)
		var dy := absi(coord.y - player_coord.y)
		var active := maxi(dx, dy) <= active_radius_chunks
		chunk.set_streaming_active(active)


func _world_to_chunk_coord(world_x: float, world_z: float) -> Vector2i:
	if _chunk_size.x <= 0.0 or _chunk_size.y <= 0.0:
		return Vector2i.ZERO
	var half := world_size * 0.5
	var cx := int(floor((world_x + half.x) / _chunk_size.x))
	var cz := int(floor((world_z + half.y) / _chunk_size.y))
	return Vector2i(cx, cz)


func _chunk_coord_of(chunk: TerrainPatch3D) -> Vector2i:
	return _world_to_chunk_coord(chunk.world_offset.x, chunk.world_offset.y)


func _find_chunk_at(world_x: float, world_z: float) -> TerrainPatch3D:
	if _chunks.is_empty():
		return null
	var coord := _world_to_chunk_coord(world_x, world_z)
	coord.x = clampi(coord.x, 0, chunk_count.x - 1)
	coord.y = clampi(coord.y, 0, chunk_count.y - 1)
	var idx := coord.y * chunk_count.x + coord.x
	if idx < 0 or idx >= _chunks.size():
		return null
	return _chunks[idx]


func _get_active_camera() -> Camera3D:
	if _camera != null and is_instance_valid(_camera):
		return _camera
	var vp := get_viewport()
	if vp == null:
		return null
	_camera = vp.get_camera_3d()
	return _camera
