@tool
class_name TerrainPatch3D
extends Node3D

enum MaskChannel {
    RED,
    GREEN,
    BLUE,
    ALPHA,
    LUMINANCE
}

const MESH_NODE_NAME := "__terrain_mesh"
const BODY_NODE_NAME := "__terrain_body"
const SHAPE_NODE_NAME := "__terrain_shape"
const GRASS_NODE_NAME := "__terrain_grass"
const GENERATED_META_KEY := "_terrain_patch_generated"
const EDITOR_REGENERATE_DEBOUNCE_SEC := 0.5

var _regenerate_queued := false
var _editor_debounce_deadline_msec := 0
var _connected_noise: FastNoiseLite
var _noise_changed_callable := Callable(self, "_on_noise_changed")

# Multi-layer terrain noise for realistic hills
var _erosion_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _ridge_noise: FastNoiseLite
var _warp_noise: FastNoiseLite
var _rail_sculpt_points: Array[Vector3] = []  # stored by sculpt_terrain_for_rails
var _rail_sculpt_half_w: float = 0.0
var _rail_sculpt_blend_w: float = 0.0
var _grass_dirty := true
var _grass_last_camera_local := Vector3.INF
var _grass_build_thread := Thread.new()
var _grass_build_in_flight := false
var _grass_build_request_id := 0
var _grass_pending_camera_local := Vector3.INF
var _grass_mask_image_cache: Image
var _grass_mask_cache_key := ""

@export_group("Terrain")
@export var size: Vector2 = Vector2(200.0, 200.0):
    set(value):
        size = Vector2(maxf(value.x, 0.1), maxf(value.y, 0.1))
        _queue_regenerate()

@export_range(2, 512, 1, "or_greater") var subdivisions_x: int = 128:
    set(value):
        subdivisions_x = maxi(value, 2)
        _queue_regenerate()

@export_range(2, 512, 1, "or_greater") var subdivisions_z: int = 128:
    set(value):
        subdivisions_z = maxi(value, 2)
        _queue_regenerate()

@export_range(0.0, 1000.0, 0.01, "or_greater") var height_scale: float = 4.0:
    set(value):
        height_scale = maxf(value, 0.0)
        _queue_regenerate()

@export_range(0.01, 100.0, 0.01, "or_greater") var uv_scale: float = 8.0:
    set(value):
        uv_scale = maxf(value, 0.01)
        _queue_regenerate()

## World-space offset so adjacent streamed chunks sample noise continuously.
## Set by TerrainStreamer on each chunk. Patch-local vertex x + world_offset.x
## gives the world-space x used when sampling noise and rail sculpting.
@export var world_offset: Vector2 = Vector2.ZERO:
    set(value):
        world_offset = value
        _queue_regenerate()

@export var terrain_material: Material:
    set(value):
        terrain_material = value
        _apply_terrain_material_override()

@export_group("Noise")
@export var noise: FastNoiseLite:
    set(value):
        if noise == value:
            return
        _disconnect_noise()
        noise = value
        _connect_noise()
        _queue_regenerate()

@export_subgroup("Advanced Terrain")
@export var terrain_advanced := true
@export_range(0.0, 100.0, 0.1) var erosion_strength: float = 8.0
@export_range(0.0, 50.0, 0.1) var detail_strength: float = 1.5
@export_range(0.0, 100.0, 0.1) var ridge_strength: float = 6.0
@export_range(0.0, 50.0, 0.1) var domain_warp_amount: float = 15.0
@export_range(0.0, 1.0, 0.01) var plateau_factor: float = 0.3
@export_range(0.0, 1.0, 0.01) var valley_carve: float = 0.4

@export_group("Collision")
@export var generate_collision := true:
    set(value):
        generate_collision = value
        _queue_regenerate()

@export_flags_3d_physics var collision_layer: int = 1:
    set(value):
        collision_layer = value
        _queue_regenerate()

@export_flags_3d_physics var collision_mask: int = 1:
    set(value):
        collision_mask = value
        _queue_regenerate()

@export_group("Grass")
@export var grass_enabled := false:
    set(value):
        grass_enabled = value
        _grass_dirty = true
        _refresh_process_state()
        if not grass_enabled:
            _remove_grass_instance()

@export var grass_mesh: Mesh:
    set(value):
        grass_mesh = value
        _grass_dirty = true

@export var grass_material: Material:
    set(value):
        grass_material = value
        _apply_grass_material_override()

@export var grass_mask_enabled := false:
    set(value):
        grass_mask_enabled = value
        _grass_dirty = true

@export var grass_mask_texture: Texture2D:
    set(value):
        grass_mask_texture = value
        _invalidate_grass_mask_cache()
        _grass_dirty = true

@export var grass_mask_area_size: Vector2 = Vector2.ZERO:
    set(value):
        grass_mask_area_size = value
        _grass_dirty = true

@export_enum("Red", "Green", "Blue", "Alpha", "Luminance") var grass_mask_channel: int = MaskChannel.RED:
    set(value):
        grass_mask_channel = clampi(value, MaskChannel.RED, MaskChannel.LUMINANCE)
        _grass_dirty = true

@export_range(0.0, 1.0, 0.01) var grass_mask_threshold: float = 0.5:
    set(value):
        grass_mask_threshold = clampf(value, 0.0, 1.0)
        _grass_dirty = true

@export var grass_mask_inverse := false:
    set(value):
        grass_mask_inverse = value
        _grass_dirty = true

@export var grass_mask_affects_density := false:
    set(value):
        grass_mask_affects_density = value
        _grass_dirty = true

@export var grass_mask_affects_scale := true:
    set(value):
        grass_mask_affects_scale = value
        _grass_dirty = true

@export_range(0.0, 1.0, 0.01) var grass_mask_min_scale_factor: float = 0.2:
    set(value):
        grass_mask_min_scale_factor = clampf(value, 0.0, 1.0)
        _grass_dirty = true

@export_range(1.0, 200.0, 0.1, "or_greater") var grass_radius: float = 18.0:
    set(value):
        grass_radius = maxf(value, 1.0)
        _grass_dirty = true

@export_range(0.1, 10.0, 0.01, "or_greater") var grass_spacing: float = 0.8:
    set(value):
        grass_spacing = maxf(value, 0.1)
        _grass_dirty = true

@export_range(1, 20000, 1, "or_greater") var grass_max_instances: int = 3000:
    set(value):
        grass_max_instances = maxi(value, 1)
        _grass_dirty = true

@export_range(-10.0, 10.0, 0.01, "or_greater") var grass_height_offset: float = 0.0:
    set(value):
        grass_height_offset = value
        _grass_dirty = true

@export_range(0.1, 20.0, 0.01, "or_greater") var grass_rebuild_distance: float = 2.0:
    set(value):
        grass_rebuild_distance = maxf(value, 0.1)
        _grass_dirty = true

@export_range(0.01, 10.0, 0.01, "or_greater") var grass_scale_min: float = 0.9:
    set(value):
        grass_scale_min = maxf(value, 0.01)
        _grass_dirty = true

@export_range(0.01, 10.0, 0.01, "or_greater") var grass_scale_max: float = 1.2:
    set(value):
        grass_scale_max = maxf(value, 0.01)
        _grass_dirty = true

## Called by TerrainGenerator after rail path is built.
## Flattens the terrain mesh + collision under the rail, creating a realistic roadbed.
## rail_points is an Array[Vector3] of world-space positions along the rail centre.
## half_width controls how wide the flattened strip is (meters each side of centre).
func sculpt_terrain_for_rails(rail_points: Array[Vector3], half_width: float = 3.0, blend_width: float = 3.0) -> void:
    # Store sculpt data so _sample_height can use it (for grass rebuild)
    _rail_sculpt_points = rail_points
    _rail_sculpt_half_w = half_width
    _rail_sculpt_blend_w = blend_width

    var mesh_instance := get_node_or_null(MESH_NODE_NAME) as MeshInstance3D
    if mesh_instance == null or mesh_instance.mesh == null:
        return
    var arr_mesh := mesh_instance.mesh as ArrayMesh
    if arr_mesh == null or arr_mesh.get_surface_count() == 0:
        return

    var arrays := arr_mesh.surface_get_arrays(0)
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]

    # Build spatial grid for O(1) rail point lookup instead of O(N) brute force
    var max_radius: float = half_width + blend_width
    var cell_size: float = maxf(max_radius, 2.0)
    var grid: Dictionary = {}  # Vector2i -> Array[Vector3]
    for rp in rail_points:
        var gx: int = int(floor(rp.x / cell_size))
        var gz: int = int(floor(rp.z / cell_size))
        var key := Vector2i(gx, gz)
        if not grid.has(key):
            grid[key] = []
        grid[key].append(rp)

    # Rail points are WORLD space. Vertices are patch-local — offset them.
    var off_x: float = world_offset.x
    var off_z: float = world_offset.y
    for vi in range(vertices.size()):
        var v := vertices[vi]
        var vwx: float = v.x + off_x
        var vwz: float = v.z + off_z
        var gx: int = int(floor(vwx / cell_size))
        var gz: int = int(floor(vwz / cell_size))
        var best_dist_sq: float = INF
        var best_rail_y: float = v.y
        # Search 3x3 neighborhood
        for dxx in range(-1, 2):
            for dzz in range(-1, 2):
                var key := Vector2i(gx + dxx, gz + dzz)
                if not grid.has(key):
                    continue
                for rp in grid[key]:
                    var dx: float = vwx - rp.x
                    var dz: float = vwz - rp.z
                    var d2: float = dx * dx + dz * dz
                    if d2 < best_dist_sq:
                        best_dist_sq = d2
                        best_rail_y = rp.y
        var dist := sqrt(best_dist_sq)
        if dist < half_width:
            vertices[vi].y = best_rail_y - 0.15
        elif dist < half_width + blend_width:
            var t: float = (dist - half_width) / blend_width
            t = t * t * (3.0 - 2.0 * t)
            vertices[vi].y = lerpf(best_rail_y - 0.15, v.y, t)

    # Rebuild mesh with modified vertices
    arrays[Mesh.ARRAY_VERTEX] = vertices

    # Recalculate normals
    var normals := PackedVector3Array()
    normals.resize(vertices.size())
    for ni in range(normals.size()):
        normals[ni] = Vector3.ZERO
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    for ti in range(0, indices.size(), 3):
        var a := indices[ti]
        var b := indices[ti + 1]
        var c := indices[ti + 2]
        var fn := (vertices[c] - vertices[a]).cross(vertices[b] - vertices[a])
        normals[a] += fn
        normals[b] += fn
        normals[c] += fn
    for ni in range(normals.size()):
        normals[ni] = normals[ni].normalized()
    arrays[Mesh.ARRAY_NORMAL] = normals

    var new_mesh := ArrayMesh.new()
    new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    new_mesh.regen_normal_maps()
    mesh_instance.mesh = new_mesh
    _apply_terrain_material_override()

    # Rebuild collision
    if generate_collision:
        var collision_faces := PackedVector3Array()
        collision_faces.resize(indices.size())
        for fi in range(indices.size()):
            collision_faces[fi] = vertices[indices[fi]]
        var body := _ensure_static_body()
        body.collision_layer = collision_layer
        body.collision_mask = collision_mask
        var cs := _ensure_collision_shape(body)
        var shape := ConcavePolygonShape3D.new()
        shape.data = collision_faces
        cs.shape = shape

    # Force grass to rebuild so it follows the sculpted terrain
    _grass_dirty = true


@export_group("Editor")
@export var editor_regenerate_biomes := true

@export var editor_auto_regenerate := true:
    set(value):
        editor_auto_regenerate = value
        if value:
            _queue_regenerate()

@export_tool_button("Regenerate")
var regenerate_button := regenerate


func _init() -> void:
    if noise == null:
        noise = FastNoiseLite.new()
        noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
        noise.frequency = 0.03
        _connect_noise()
    _init_terrain_noises()


func _enter_tree() -> void:
    _connect_noise()
    _refresh_process_state()
    if Engine.is_editor_hint():
        call_deferred("_deferred_regenerate")


func _ready() -> void:
    _connect_noise()
    _refresh_process_state()
    if not Engine.is_editor_hint():
        _queue_regenerate()
        call_deferred("_bootstrap_grass_after_start")


func _exit_tree() -> void:
    set_process(false)
    _disconnect_noise()
    if _grass_build_thread.is_started():
        _grass_build_thread.wait_to_finish()


func _process(_delta: float) -> void:
    if Engine.is_editor_hint():
        if _editor_debounce_deadline_msec > 0 and Time.get_ticks_msec() >= _editor_debounce_deadline_msec:
            _editor_debounce_deadline_msec = 0
            if not _regenerate_queued:
                _regenerate_queued = true
                call_deferred("_deferred_regenerate")
    _flush_grass_build_if_ready()
    _update_grass_if_needed()


func regenerate() -> void:
    _regenerate_queued = false
    _editor_debounce_deadline_msec = 0
    _generate()


func _queue_regenerate() -> void:
    if not is_inside_tree():
        return
    if Engine.is_editor_hint() and not editor_auto_regenerate:
        return
    if _regenerate_queued:
        return
    if Engine.is_editor_hint():
        _editor_debounce_deadline_msec = Time.get_ticks_msec() + int(EDITOR_REGENERATE_DEBOUNCE_SEC * 1000.0)
        return
    _regenerate_queued = true
    call_deferred("_deferred_regenerate")


func _deferred_regenerate() -> void:
    _regenerate_queued = false
    if not is_inside_tree():
        return
    _generate()


func _generate() -> void:
    var vertex_count_x := subdivisions_x + 1
    var vertex_count_z := subdivisions_z + 1
    var half_size := size * 0.5
    var step_x := size.x / float(subdivisions_x)
    var step_z := size.y / float(subdivisions_z)

    var vertices := PackedVector3Array()
    var uvs := PackedVector2Array()
    var indices := PackedInt32Array()
    var normals_accum: Array[Vector3] = []
    vertices.resize(vertex_count_x * vertex_count_z)
    uvs.resize(vertex_count_x * vertex_count_z)
    normals_accum.resize(vertex_count_x * vertex_count_z)

    for z in range(vertex_count_z):
        for x in range(vertex_count_x):
            var vertex_index := z * vertex_count_x + x
            var local_x := -half_size.x + (float(x) * step_x)
            var local_z := -half_size.y + (float(z) * step_z)
            var local_y := _sample_height(local_x, local_z)
            vertices[vertex_index] = Vector3(local_x, local_y, local_z)
            uvs[vertex_index] = Vector2(
                (float(x) / float(subdivisions_x)) * uv_scale,
                (float(z) / float(subdivisions_z)) * uv_scale
            )
            normals_accum[vertex_index] = Vector3.ZERO

    var collision_faces := PackedVector3Array()
    collision_faces.resize(subdivisions_x * subdivisions_z * 6)
    var collision_face_index := 0

    for z in range(subdivisions_z):
        for x in range(subdivisions_x):
            var a := z * vertex_count_x + x
            var b := a + 1
            var c := a + vertex_count_x
            var d := c + 1

            _append_triangle(indices, normals_accum, vertices, a, b, c)
            _append_triangle(indices, normals_accum, vertices, b, d, c)

            collision_faces[collision_face_index + 0] = vertices[a]
            collision_faces[collision_face_index + 1] = vertices[b]
            collision_faces[collision_face_index + 2] = vertices[c]
            collision_faces[collision_face_index + 3] = vertices[b]
            collision_faces[collision_face_index + 4] = vertices[d]
            collision_faces[collision_face_index + 5] = vertices[c]
            collision_face_index += 6

    var normals := PackedVector3Array()
    normals.resize(normals_accum.size())
    for index in range(normals_accum.size()):
        normals[index] = normals_accum[index].normalized()

    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_INDEX] = indices

    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.regen_normal_maps()

    var mesh_instance := _ensure_mesh_instance()
    mesh_instance.mesh = mesh
    _apply_terrain_material_override()
    _grass_dirty = true

    if generate_collision:
        var body := _ensure_static_body()
        body.collision_layer = collision_layer
        body.collision_mask = collision_mask
        var collision_shape := _ensure_collision_shape(body)
        var shape := ConcavePolygonShape3D.new()
        shape.data = collision_faces
        collision_shape.shape = shape
    else:
        _remove_collision_body()

    if Engine.is_editor_hint() and editor_regenerate_biomes:
        call_deferred("_regenerate_biomes_in_scene")


func _append_triangle(indices: PackedInt32Array, normals_accum: Array[Vector3], vertices: PackedVector3Array, a: int, b: int, c: int) -> void:
    indices.push_back(a)
    indices.push_back(b)
    indices.push_back(c)

    var face_normal := (vertices[c] - vertices[a]).cross(vertices[b] - vertices[a])
    normals_accum[a] += face_normal
    normals_accum[b] += face_normal
    normals_accum[c] += face_normal


func _init_terrain_noises() -> void:
    # Erosion: medium frequency ridges and gullies
    _erosion_noise = FastNoiseLite.new()
    _erosion_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    _erosion_noise.seed = 1337
    _erosion_noise.frequency = 0.008
    _erosion_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    _erosion_noise.fractal_octaves = 4
    _erosion_noise.fractal_lacunarity = 2.2
    _erosion_noise.fractal_gain = 0.45

    # Detail: high frequency micro-bumps (stones, small mounds)
    _detail_noise = FastNoiseLite.new()
    _detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    _detail_noise.seed = 7331
    _detail_noise.frequency = 0.05
    _detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    _detail_noise.fractal_octaves = 3
    _detail_noise.fractal_lacunarity = 2.0
    _detail_noise.fractal_gain = 0.5

    # Ridge noise: creates sharp ridgelines like eroded hills
    _ridge_noise = FastNoiseLite.new()
    _ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    _ridge_noise.seed = 42
    _ridge_noise.frequency = 0.004
    _ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
    _ridge_noise.fractal_octaves = 5
    _ridge_noise.fractal_lacunarity = 2.0
    _ridge_noise.fractal_gain = 0.5

    # Domain warp noise: deforms sampling coordinates for organic shapes
    _warp_noise = FastNoiseLite.new()
    _warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    _warp_noise.seed = 9999
    _warp_noise.frequency = 0.003
    _warp_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    _warp_noise.fractal_octaves = 3


func _sample_height(local_x: float, local_z: float) -> float:
    if noise == null or height_scale == 0.0:
        return 0.0
    # Convert to world-space coords so adjacent chunks line up
    var world_x := local_x + world_offset.x
    var world_z := local_z + world_offset.y
    if not terrain_advanced:
        return noise.get_noise_2d(world_x, world_z) * height_scale

    # Domain warping: shift coordinates organically to break up grid patterns
    var warp_x := 0.0
    var warp_z := 0.0
    if _warp_noise != null and domain_warp_amount > 0.0:
        warp_x = _warp_noise.get_noise_2d(world_x, world_z) * domain_warp_amount
        warp_z = _warp_noise.get_noise_2d(world_x + 500.0, world_z + 500.0) * domain_warp_amount
    var wx := world_x + warp_x
    var wz := world_z + warp_z

    # Layer 1: Continental / base shape (large rolling hills)
    var base := noise.get_noise_2d(wx, wz) * height_scale

    # Layer 2: Ridged erosion (sharp crests and valleys)
    var ridge := 0.0
    if _ridge_noise != null and ridge_strength > 0.0:
        ridge = _ridge_noise.get_noise_2d(wx, wz) * ridge_strength

    # Layer 3: Erosion detail (medium bumps, gullies)
    var erosion := 0.0
    if _erosion_noise != null and erosion_strength > 0.0:
        erosion = _erosion_noise.get_noise_2d(wx, wz) * erosion_strength

    # Layer 4: Micro detail (small stones, ground roughness)
    var detail := 0.0
    if _detail_noise != null and detail_strength > 0.0:
        # Scale detail by slope — more roughness on steep areas
        detail = _detail_noise.get_noise_2d(world_x, world_z) * detail_strength

    var combined := base + ridge + erosion + detail

    # Plateau effect: flatten peaks into realistic mesa/plateau shapes
    if plateau_factor > 0.0:
        var plateau_threshold := height_scale * 0.6
        if combined > plateau_threshold:
            var excess := combined - plateau_threshold
            combined = plateau_threshold + excess * (1.0 - plateau_factor)

    # Valley carving: deepen low areas to create riverbed-like valleys
    if valley_carve > 0.0:
        var valley_threshold := -height_scale * 0.2
        if combined < valley_threshold:
            var depth := valley_threshold - combined
            combined = valley_threshold - depth * (1.0 + valley_carve)

    # Rail sculpt blending: flatten terrain toward rail bed near stored rail points.
    # Rail points stored in WORLD space; compare against vertex world position.
    if _rail_sculpt_points.size() > 0 and _rail_sculpt_half_w > 0.0:
        var best_d2: float = INF
        var best_ry: float = combined
        for rp in _rail_sculpt_points:
            var dx: float = world_x - rp.x
            var dz: float = world_z - rp.z
            var d2: float = dx * dx + dz * dz
            if d2 < best_d2:
                best_d2 = d2
                best_ry = rp.y
        var dist := sqrt(best_d2)
        var target_y := best_ry - 0.15
        if dist < _rail_sculpt_half_w:
            combined = target_y
        elif dist < _rail_sculpt_half_w + _rail_sculpt_blend_w:
            var t: float = (dist - _rail_sculpt_half_w) / _rail_sculpt_blend_w
            t = t * t * (3.0 - 2.0 * t)
            combined = lerpf(target_y, combined, t)

    return combined


static func _sample_height_static(payload: Dictionary, local_x: float, local_z: float) -> float:
    var noise_res = payload.get("noise") as FastNoiseLite
    var hs: float = float(payload.get("height_scale", 0.0))
    if noise_res == null or hs == 0.0:
        return 0.0
    var world_offset_v: Vector2 = payload.get("world_offset", Vector2.ZERO)
    var world_x := local_x + world_offset_v.x
    var world_z := local_z + world_offset_v.y
    if not bool(payload.get("terrain_advanced", false)):
        return noise_res.get_noise_2d(world_x, world_z) * hs

    var warp_amt: float = float(payload.get("domain_warp_amount", 0.0))
    var warp_n = payload.get("warp_noise") as FastNoiseLite
    var warp_x := 0.0
    var warp_z := 0.0
    if warp_n != null and warp_amt > 0.0:
        warp_x = warp_n.get_noise_2d(world_x, world_z) * warp_amt
        warp_z = warp_n.get_noise_2d(world_x + 500.0, world_z + 500.0) * warp_amt
    var wx := world_x + warp_x
    var wz := world_z + warp_z

    var base := noise_res.get_noise_2d(wx, wz) * hs

    var ridge_n = payload.get("ridge_noise") as FastNoiseLite
    var ridge_s: float = float(payload.get("ridge_strength", 0.0))
    var ridge := 0.0
    if ridge_n != null and ridge_s > 0.0:
        ridge = ridge_n.get_noise_2d(wx, wz) * ridge_s

    var erosion_n = payload.get("erosion_noise") as FastNoiseLite
    var erosion_s: float = float(payload.get("erosion_strength", 0.0))
    var erosion := 0.0
    if erosion_n != null and erosion_s > 0.0:
        erosion = erosion_n.get_noise_2d(wx, wz) * erosion_s

    var detail_n = payload.get("detail_noise") as FastNoiseLite
    var detail_s: float = float(payload.get("detail_strength", 0.0))
    var detail := 0.0
    if detail_n != null and detail_s > 0.0:
        detail = detail_n.get_noise_2d(world_x, world_z) * detail_s

    var combined := base + ridge + erosion + detail

    var pf: float = float(payload.get("plateau_factor", 0.0))
    if pf > 0.0:
        var pt := hs * 0.6
        if combined > pt:
            combined = pt + (combined - pt) * (1.0 - pf)

    var vc: float = float(payload.get("valley_carve", 0.0))
    if vc > 0.0:
        var vt := -hs * 0.2
        if combined < vt:
            combined = vt - (vt - combined) * (1.0 + vc)

    # Rail sculpt blending (mirror of instance version) — rail points in WORLD space
    var rail_pts = payload.get("rail_sculpt_points")
    var rail_hw: float = float(payload.get("rail_sculpt_half_w", 0.0))
    var rail_bw: float = float(payload.get("rail_sculpt_blend_w", 0.0))
    if rail_pts != null and rail_hw > 0.0 and (rail_pts as Array).size() > 0:
        var best_d2: float = INF
        var best_ry: float = combined
        for rp in rail_pts:
            var dx: float = world_x - (rp as Vector3).x
            var dz: float = world_z - (rp as Vector3).z
            var d2: float = dx * dx + dz * dz
            if d2 < best_d2:
                best_d2 = d2
                best_ry = (rp as Vector3).y
        var dist := sqrt(best_d2)
        var target_y := best_ry - 0.15
        if dist < rail_hw:
            combined = target_y
        elif dist < rail_hw + rail_bw:
            var t: float = (dist - rail_hw) / rail_bw
            t = t * t * (3.0 - 2.0 * t)
            combined = lerpf(target_y, combined, t)

    return combined


func _ensure_mesh_instance() -> MeshInstance3D:
    var mesh_instance := get_node_or_null(MESH_NODE_NAME) as MeshInstance3D
    if mesh_instance != null:
        return mesh_instance

    mesh_instance = MeshInstance3D.new()
    mesh_instance.name = MESH_NODE_NAME
    mesh_instance.set_meta(GENERATED_META_KEY, true)
    add_child(mesh_instance)
    return mesh_instance


func _apply_terrain_material_override() -> void:
    var mesh_instance := get_node_or_null(MESH_NODE_NAME) as MeshInstance3D
    if mesh_instance == null:
        return
    mesh_instance.material_override = terrain_material
    mesh_instance.material_overlay = null


func _ensure_grass_instance() -> MultiMeshInstance3D:
    var grass_instance := get_node_or_null(GRASS_NODE_NAME) as MultiMeshInstance3D
    if grass_instance != null:
        return grass_instance

    grass_instance = MultiMeshInstance3D.new()
    grass_instance.name = GRASS_NODE_NAME
    grass_instance.set_meta(GENERATED_META_KEY, true)
    add_child(grass_instance)
    return grass_instance


func _apply_grass_material_override() -> void:
    var grass_instance := get_node_or_null(GRASS_NODE_NAME) as MultiMeshInstance3D
    if grass_instance == null:
        return
    grass_instance.material_override = grass_material


func _remove_grass_instance() -> void:
    var grass_instance := get_node_or_null(GRASS_NODE_NAME)
    if grass_instance != null:
        remove_child(grass_instance)
        grass_instance.queue_free()
    _grass_last_camera_local = Vector3.INF
    _grass_pending_camera_local = Vector3.INF


func _refresh_process_state() -> void:
    set_process(Engine.is_editor_hint() or grass_enabled)


func _bootstrap_grass_after_start() -> void:
    await get_tree().process_frame
    await get_tree().process_frame
    _grass_last_camera_local = Vector3.INF
    _grass_dirty = true
    _update_grass_if_needed()


func _update_grass_if_needed() -> void:
    if not grass_enabled or grass_mesh == null:
        _remove_grass_instance()
        return
    if not is_inside_tree():
        return

    var camera := _get_active_camera()
    if camera == null:
        return
    var camera_local := to_local(camera.global_position)
    var rebuild_threshold := maxf(grass_rebuild_distance, grass_spacing)
    if not _grass_dirty and _grass_last_camera_local != Vector3.INF and _grass_last_camera_local.distance_to(camera_local) < rebuild_threshold:
        return
    _request_grass_rebuild(camera_local)


func _request_grass_rebuild(camera_local: Vector3) -> void:
    _grass_pending_camera_local = camera_local
    if _grass_build_in_flight:
        return
    _start_grass_build(camera_local)


func _start_grass_build(camera_local: Vector3) -> void:
    _grass_build_in_flight = true
    _grass_build_request_id += 1
    var request_id := _grass_build_request_id
    var noise_copy := noise.duplicate() if noise != null else null
    var grass_mask_image := _get_grass_mask_image()
    var grass_mask_copy := grass_mask_image.duplicate() if grass_mask_image != null else null
    var erosion_copy := _erosion_noise.duplicate() if _erosion_noise != null else null
    var detail_copy := _detail_noise.duplicate() if _detail_noise != null else null
    var ridge_copy := _ridge_noise.duplicate() if _ridge_noise != null else null
    var warp_copy := _warp_noise.duplicate() if _warp_noise != null else null
    var payload := {
        "request_id": request_id,
        "camera_local": camera_local,
        "world_offset": world_offset,
        "size": size,
        "spacing": maxf(grass_spacing, 0.1),
        "radius": grass_radius,
        "max_instances": grass_max_instances,
        "height_offset": grass_height_offset,
        "scale_min": minf(grass_scale_min, grass_scale_max),
        "scale_max": maxf(grass_scale_min, grass_scale_max),
        "height_scale": height_scale,
        "noise": noise_copy,
        "terrain_advanced": terrain_advanced,
        "erosion_noise": erosion_copy,
        "detail_noise": detail_copy,
        "ridge_noise": ridge_copy,
        "warp_noise": warp_copy,
        "erosion_strength": erosion_strength,
        "detail_strength": detail_strength,
        "ridge_strength": ridge_strength,
        "domain_warp_amount": domain_warp_amount,
        "plateau_factor": plateau_factor,
        "valley_carve": valley_carve,
        "grass_mask_enabled": grass_mask_enabled,
        "grass_mask_image": grass_mask_copy,
        "grass_mask_area_size": grass_mask_area_size if grass_mask_area_size != Vector2.ZERO else size,
        "grass_mask_channel": grass_mask_channel,
        "grass_mask_threshold": grass_mask_threshold,
        "grass_mask_inverse": grass_mask_inverse,
        "grass_mask_affects_density": grass_mask_affects_density,
        "grass_mask_affects_scale": grass_mask_affects_scale,
        "grass_mask_min_scale_factor": grass_mask_min_scale_factor,
        "rail_sculpt_points": _rail_sculpt_points.duplicate(),
        "rail_sculpt_half_w": _rail_sculpt_half_w,
        "rail_sculpt_blend_w": _rail_sculpt_blend_w
    }
    _grass_build_thread.start(_build_grass_transforms.bind(payload))


func _flush_grass_build_if_ready() -> void:
    if not _grass_build_in_flight or not _grass_build_thread.is_started():
        return
    if _grass_build_thread.is_alive():
        return
    var result = _grass_build_thread.wait_to_finish()
    _grass_build_in_flight = false
    if typeof(result) != TYPE_DICTIONARY:
        return
    var result_dict := result as Dictionary
    if int(result_dict.get("request_id", -1)) != _grass_build_request_id:
        return
    _apply_grass_build_result(result_dict)
    if _grass_pending_camera_local != Vector3.INF and _grass_pending_camera_local.distance_to(_grass_last_camera_local) >= maxf(grass_rebuild_distance, grass_spacing):
        _start_grass_build(_grass_pending_camera_local)


func _apply_grass_build_result(result_dict: Dictionary) -> void:
    var grass_instance := _ensure_grass_instance()
    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.mesh = grass_mesh
    var transforms: Array = result_dict.get("transforms", [])
    multimesh.instance_count = transforms.size()
    multimesh.visible_instance_count = transforms.size()
    for index in range(transforms.size()):
        multimesh.set_instance_transform(index, transforms[index])
    grass_instance.multimesh = multimesh
    grass_instance.material_override = grass_material
    grass_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _grass_last_camera_local = result_dict.get("camera_local", Vector3.ZERO)
    _grass_dirty = false


func _build_grass_transforms(payload: Dictionary) -> Dictionary:
    if Engine.get_version_info()["hex"] >= 0x040100:
        Callable(Thread, "set_thread_safety_checks_enabled").call(false)
    var camera_local: Vector3 = payload["camera_local"]
    var terrain_size: Vector2 = payload["size"]
    var spacing: float = payload["spacing"]
    var radius: float = payload["radius"]
    var radius_sq := radius * radius
    var estimated_candidate_count := maxi(int(ceil((PI * radius_sq) / (spacing * spacing))), 1)
    var keep_probability := minf(1.0, float(payload["max_instances"]) / float(estimated_candidate_count))
    var min_x := int(floor((camera_local.x - radius) / spacing))
    var max_x := int(ceil((camera_local.x + radius) / spacing))
    var min_z := int(floor((camera_local.z - radius) / spacing))
    var max_z := int(ceil((camera_local.z + radius) / spacing))
    var half_size := terrain_size * 0.5
    var transforms: Array[Transform3D] = []
    var noise_resource = payload["noise"] as FastNoiseLite
    var mask_enabled: bool = payload["grass_mask_enabled"]
    var mask_image = payload["grass_mask_image"] as Image
    var mask_area_size: Vector2 = payload["grass_mask_area_size"]

    for cell_z in range(min_z, max_z + 1):
        for cell_x in range(min_x, max_x + 1):
            var base_x := float(cell_x) * spacing
            var base_z := float(cell_z) * spacing
            var hash := _hash_cell(cell_x, cell_z)
            var jitter_x := (_hash_to_unit(hash) - 0.5) * spacing
            var jitter_z := (_hash_to_unit(_hash_u32(hash ^ 0x68bc21eb)) - 0.5) * spacing
            var local_x := base_x + jitter_x
            var local_z := base_z + jitter_z
            if local_x < -half_size.x or local_x > half_size.x or local_z < -half_size.y or local_z > half_size.y:
                continue
            var offset_xz := Vector2(local_x - camera_local.x, local_z - camera_local.z)
            if offset_xz.length_squared() > radius_sq:
                continue
            var mask_density := 1.0
            var mask_scale := 1.0
            if mask_enabled:
                var mask_sample := _grass_mask_adjusted_sample(
                    mask_image,
                    mask_area_size,
                    local_x,
                    local_z,
                    int(payload["grass_mask_channel"]),
                    bool(payload["grass_mask_inverse"])
                )
                mask_density = _grass_mask_density_from_sample(
                    mask_sample,
                    float(payload["grass_mask_threshold"]),
                    bool(payload["grass_mask_affects_density"])
                )
                if mask_density <= 0.0:
                    continue
                mask_scale = _grass_mask_scale_from_sample(
                    mask_sample,
                    float(payload["grass_mask_threshold"]),
                    bool(payload["grass_mask_affects_scale"]),
                    float(payload["grass_mask_min_scale_factor"])
                )
            if _hash_to_unit(_hash_u32(hash ^ 0x4f1bbcdc)) > (keep_probability * mask_density):
                continue

            var local_y := _sample_height_static(payload, local_x, local_z)
            local_y += float(payload["height_offset"])
            var yaw := _hash_to_unit(_hash_u32(hash ^ 0xa53c9d71)) * TAU
            var scale_t := _hash_to_unit(_hash_u32(hash ^ 0x9e3779b9))
            var scale_value := lerpf(float(payload["scale_min"]), float(payload["scale_max"]), scale_t)
            scale_value *= mask_scale
            var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_value)
            transforms.append(Transform3D(basis, Vector3(local_x, local_y, local_z)))

    return {
        "request_id": payload["request_id"],
        "camera_local": camera_local,
        "transforms": transforms
    }


func _grass_mask_adjusted_sample(image: Image, mask_area_size: Vector2, local_x: float, local_z: float, channel: int, inverse: bool) -> float:
    if image == null or image.is_empty():
        return 1.0
    var uv := _grass_local_to_mask_uv(local_x, local_z, mask_area_size)
    if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
        return 0.0
    var width := image.get_width()
    var height := image.get_height()
    if width <= 0 or height <= 0:
        return 1.0
    var pixel_x := clampi(int(floor(uv.x * float(width))), 0, width - 1)
    var pixel_y := clampi(int(floor(uv.y * float(height))), 0, height - 1)
    var sample := _sample_mask_channel(image.get_pixel(pixel_x, pixel_y), channel)
    var adjusted := 1.0 - sample if inverse else sample
    return clampf(adjusted, 0.0, 1.0)


func _grass_mask_density_from_sample(adjusted: float, threshold: float, affects_density: bool) -> float:
    if not affects_density:
        return 1.0 if adjusted > 0.0 else 0.0
    if adjusted <= threshold:
        return 0.0
    return inverse_lerp(threshold, 1.0, adjusted)


func _grass_mask_scale_from_sample(adjusted: float, threshold: float, affects_scale: bool, min_scale_factor: float) -> float:
    if not affects_scale:
        return 1.0
    if adjusted <= 0.0:
        return 0.0
    return lerpf(clampf(min_scale_factor, 0.0, 1.0), 1.0, clampf(adjusted, 0.0, 1.0))


func _grass_local_to_mask_uv(local_x: float, local_z: float, mask_area_size: Vector2) -> Vector2:
    if mask_area_size.x <= 0.0 or mask_area_size.y <= 0.0:
        return Vector2(-1.0, -1.0)
    return Vector2(
        (local_x / mask_area_size.x) + 0.5,
        (local_z / mask_area_size.y) + 0.5
    )


func _sample_mask_channel(color: Color, channel: int) -> float:
    match channel:
        MaskChannel.RED:
            return color.r
        MaskChannel.GREEN:
            return color.g
        MaskChannel.BLUE:
            return color.b
        MaskChannel.ALPHA:
            return color.a
        MaskChannel.LUMINANCE:
            return color.get_luminance()
        _:
            return color.r


func get_mask_texture_path() -> String:
    if grass_mask_texture == null:
        return ""
    return grass_mask_texture.resource_path


func get_mask_image_copy() -> Image:
    var image := _get_grass_mask_image()
    if image == null or image.is_empty():
        return Image.create(1, 1, false, Image.FORMAT_RGBA8)
    return image.duplicate()


func local_to_mask_uv(local_position: Vector3) -> Vector2:
    var area_size := grass_mask_area_size if grass_mask_area_size != Vector2.ZERO else size
    return _grass_local_to_mask_uv(local_position.x, local_position.z, area_size)


func preview_mask_image(image: Image) -> void:
    _set_grass_mask_cache_from_image(image)
    _grass_dirty = true


func set_mask_image(image: Image, save_to_disk := true) -> void:
    _set_grass_mask_cache_from_image(image)
    if save_to_disk:
        _save_grass_mask_image_to_disk(image)
        _grass_mask_cache_key = _build_grass_mask_cache_key()
    _grass_dirty = true


func create_mask_texture_file(path: String, resolution: int) -> bool:
    if path.is_empty() or resolution <= 0:
        return false
    var image := Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
    image.fill(Color(0.0, 0.0, 0.0, 1.0))
    if image.save_png(path) != OK:
        return false
    _set_grass_mask_cache_from_image(image)
    _grass_mask_cache_key = _build_grass_mask_cache_key()
    grass_mask_enabled = true
    return true


func assign_mask_texture(texture: Texture2D, enable_mask := true) -> void:
    grass_mask_texture = texture
    grass_mask_enabled = enable_mask
    notify_property_list_changed()
    _grass_dirty = true


func paint_mask_circle_on_image(image: Image, local_position: Vector3, radius_world: float, value: float, hardness: float = 0.35, opacity: float = 1.0) -> bool:
    if image == null or image.is_empty():
        return false

    var uv := local_to_mask_uv(local_position)
    if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
        return false

    var width := image.get_width()
    var height := image.get_height()
    if width <= 0 or height <= 0:
        return false

    var center_x := int(round(uv.x * float(width - 1)))
    var center_y := int(round(uv.y * float(height - 1)))
    var radius_px := _world_radius_to_mask_pixel_radius(radius_world, width, height)
    var radius_sq := radius_px * radius_px
    var clamped_hardness := clampf(hardness, 0.0, 1.0)
    var clamped_opacity := clampf(opacity, 0.0, 1.0)
    var inner_radius := float(radius_px) * clamped_hardness
    var changed := false

    for y in range(maxi(0, center_y - radius_px), mini(height, center_y + radius_px + 1)):
        for x in range(maxi(0, center_x - radius_px), mini(width, center_x + radius_px + 1)):
            var dx := x - center_x
            var dy := y - center_y
            var distance_sq := (dx * dx) + (dy * dy)
            if distance_sq > radius_sq:
                continue
            var distance := sqrt(float(distance_sq))
            var influence := 1.0
            if radius_px > 0 and distance > inner_radius:
                var outer_range := maxf(float(radius_px) - inner_radius, 0.0001)
                var falloff_t := clampf((distance - inner_radius) / outer_range, 0.0, 1.0)
                influence = 1.0 - _smoothstep(0.0, 1.0, falloff_t)
            influence *= clamped_opacity
            if influence <= 0.0:
                continue
            var color := image.get_pixel(x, y)
            var next_color := _apply_mask_paint(color, value, influence)
            if next_color != color:
                image.set_pixel(x, y, next_color)
                changed = true
    return changed


func _get_grass_mask_image() -> Image:
    if grass_mask_texture == null:
        return null
    var cache_key := _build_grass_mask_cache_key()
    if _grass_mask_image_cache != null and _grass_mask_cache_key == cache_key and not _grass_mask_image_cache.is_empty():
        return _grass_mask_image_cache
    var image := grass_mask_texture.get_image()
    if image == null or image.is_empty():
        return null
    if image.is_compressed():
        image.decompress()
    if image.get_format() != Image.FORMAT_RGBA8:
        image.convert(Image.FORMAT_RGBA8)
    _grass_mask_image_cache = image
    _grass_mask_cache_key = cache_key
    return _grass_mask_image_cache


func _set_grass_mask_cache_from_image(image: Image) -> void:
    if image == null or image.is_empty():
        _grass_mask_image_cache = null
        _grass_mask_cache_key = ""
        return
    _grass_mask_image_cache = image.duplicate()
    if _grass_mask_image_cache.is_compressed():
        _grass_mask_image_cache.decompress()
    if _grass_mask_image_cache.get_format() != Image.FORMAT_RGBA8:
        _grass_mask_image_cache.convert(Image.FORMAT_RGBA8)
    _grass_mask_cache_key = _build_grass_mask_cache_key()


func _invalidate_grass_mask_cache() -> void:
    _grass_mask_image_cache = null
    _grass_mask_cache_key = ""


func _build_grass_mask_cache_key() -> String:
    if grass_mask_texture == null:
        return ""
    var path := grass_mask_texture.resource_path
    var modified := ""
    if path != "" and FileAccess.file_exists(path):
        modified = str(FileAccess.get_modified_time(path))
    return "%s|%s" % [_resource_id(grass_mask_texture), modified]


func _save_grass_mask_image_to_disk(image: Image) -> void:
    var path := get_mask_texture_path()
    if path.is_empty():
        return
    image.save_png(path)


func _world_radius_to_mask_pixel_radius(radius_world: float, width: int, height: int) -> int:
    var area_size := grass_mask_area_size if grass_mask_area_size != Vector2.ZERO else size
    var world_per_pixel_x := area_size.x / maxf(float(width), 1.0)
    var world_per_pixel_y := area_size.y / maxf(float(height), 1.0)
    var world_per_pixel := maxf(minf(world_per_pixel_x, world_per_pixel_y), 0.0001)
    return maxi(1, int(ceil(radius_world / world_per_pixel)))


func _apply_mask_paint(color: Color, value: float, influence: float) -> Color:
    var clamped_value := clampf(value, 0.0, 1.0)
    var clamped_influence := clampf(influence, 0.0, 1.0)
    match grass_mask_channel:
        MaskChannel.RED:
            color.r = lerpf(color.r, clamped_value, clamped_influence)
        MaskChannel.GREEN:
            color.g = lerpf(color.g, clamped_value, clamped_influence)
        MaskChannel.BLUE:
            color.b = lerpf(color.b, clamped_value, clamped_influence)
        MaskChannel.ALPHA:
            color.a = lerpf(color.a, clamped_value, clamped_influence)
        MaskChannel.LUMINANCE:
            color.r = lerpf(color.r, clamped_value, clamped_influence)
            color.g = lerpf(color.g, clamped_value, clamped_influence)
            color.b = lerpf(color.b, clamped_value, clamped_influence)
    return color


func _smoothstep(edge0: float, edge1: float, x: float) -> float:
    var t := clampf(inverse_lerp(edge0, edge1, x), 0.0, 1.0)
    return t * t * (3.0 - (2.0 * t))


func _resource_id(resource: Resource) -> String:
    if resource == null:
        return ""
    if resource.resource_path != "":
        return resource.resource_path
    return str(resource.get_instance_id())


func _get_active_camera() -> Camera3D:
    if Engine.is_editor_hint():
        var editor_viewport := EditorInterface.get_editor_viewport_3d(0)
        if editor_viewport != null and editor_viewport.get_camera_3d() != null:
            return editor_viewport.get_camera_3d()
    var viewport := get_viewport()
    if viewport == null:
        return null
    return viewport.get_camera_3d()


func _hash_cell(x: int, z: int) -> int:
    var hash := _hash_u32(int(x) * 73856093)
    hash = _hash_u32(hash ^ (int(z) * 19349663))
    return hash


func _hash_u32(value: int) -> int:
    var hash := value & 0x7fffffff
    hash = int((hash ^ 61) ^ (hash >> 16))
    hash = int(hash + (hash << 3))
    hash = int(hash ^ (hash >> 4))
    hash = int(hash * 668265261)
    hash = int(hash ^ (hash >> 15))
    return hash & 0x7fffffff


func _hash_to_unit(value: int) -> float:
    return float(value & 0x7fffffff) / 2147483647.0


func _ensure_static_body() -> StaticBody3D:
    var body := get_node_or_null(BODY_NODE_NAME) as StaticBody3D
    if body != null:
        return body

    body = StaticBody3D.new()
    body.name = BODY_NODE_NAME
    body.set_meta(GENERATED_META_KEY, true)
    body.add_to_group("ground")
    add_child(body)
    return body


func _ensure_collision_shape(body: StaticBody3D) -> CollisionShape3D:
    var collision_shape := body.get_node_or_null(SHAPE_NODE_NAME) as CollisionShape3D
    if collision_shape != null:
        return collision_shape

    collision_shape = CollisionShape3D.new()
    collision_shape.name = SHAPE_NODE_NAME
    collision_shape.set_meta(GENERATED_META_KEY, true)
    body.add_child(collision_shape)
    return collision_shape


func _remove_collision_body() -> void:
    var body := get_node_or_null(BODY_NODE_NAME)
    if body != null:
        remove_child(body)
        body.queue_free()


## Streaming toggle used by TerrainStreamer. Controls mesh visibility and
## collision shape disable without destroying the chunk data.
func set_streaming_active(active: bool) -> void:
    var mesh_instance := get_node_or_null(MESH_NODE_NAME) as MeshInstance3D
    if mesh_instance != null:
        mesh_instance.visible = active
    var body := get_node_or_null(BODY_NODE_NAME) as StaticBody3D
    if body != null:
        var cs := body.get_node_or_null(SHAPE_NODE_NAME) as CollisionShape3D
        if cs != null:
            cs.disabled = not active
    var grass_instance := get_node_or_null(GRASS_NODE_NAME) as MultiMeshInstance3D
    if grass_instance != null:
        grass_instance.visible = active


func _connect_noise() -> void:
    if noise == null or noise == _connected_noise:
        return
    if not noise.changed.is_connected(_noise_changed_callable):
        noise.changed.connect(_noise_changed_callable)
    _connected_noise = noise


func _disconnect_noise() -> void:
    if _connected_noise == null:
        return
    if _connected_noise.changed.is_connected(_noise_changed_callable):
        _connected_noise.changed.disconnect(_noise_changed_callable)
    _connected_noise = null


func _on_noise_changed() -> void:
    _queue_regenerate()


func _regenerate_biomes_in_scene() -> void:
    var scene_root := get_tree().edited_scene_root
    if scene_root == null:
        return
    _regenerate_biomes_recursive(scene_root)


func _regenerate_biomes_recursive(node: Node) -> void:
    if node is Biomes:
        (node as Biomes).regenerate()
        return
    for child in node.get_children():
        var child_node := child as Node
        if child_node == null:
            continue
        _regenerate_biomes_recursive(child_node)
