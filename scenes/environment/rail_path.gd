@tool
extends Path3D
class_name RailPath

## Hand-placed rail path. Edit the Path3D curve in the editor — the
## TerrainGenerator reads this curve to sculpt the roadbed and build meshes.
##
## Usage:
##   1. Add a RailPath node to your scene (or instance rail_path.tscn).
##   2. Select it, use the Path3D handles in the 3D viewport to draw the track.
##   3. Toggle "Snap To Ground" to pin each control point to terrain height.
##   4. At runtime, TerrainGenerator picks it up via the "rail_path" group.

@export var snap_to_ground: bool = true:
	set(value):
		snap_to_ground = value
		if Engine.is_editor_hint():
			_snap_points_to_ground()

@export_range(-10.0, 10.0, 0.01) var ground_offset: float = 0.20

## Re-snap now (editor button via tool reload)
@export var action_snap_now: bool = false:
	set(value):
		if value:
			_snap_points_to_ground()
		action_snap_now = false

## Reset to a default S-curve spanning the world
@export var action_reset_curve: bool = false:
	set(value):
		if value:
			_reset_default_curve()
		action_reset_curve = false


func _ready() -> void:
	add_to_group("rail_path")
	if curve == null:
		curve = Curve3D.new()
	curve.bake_interval = 0.5
	if Engine.is_editor_hint():
		return
	if curve.point_count == 0:
		_reset_default_curve()
	elif snap_to_ground:
		# Wait one frame so terrain is ready, then snap Y to ground height
		await get_tree().process_frame
		_snap_points_to_ground()


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		set_process(false)
		return
	# Keep bake interval dense so sampling is smooth.
	if curve and not is_equal_approx(curve.bake_interval, 0.5):
		curve.bake_interval = 0.5


func get_rail_curve() -> Curve3D:
	return curve


func _snap_points_to_ground() -> void:
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


func _reset_default_curve() -> void:
	if curve == null:
		curve = Curve3D.new()
	curve.clear_points()
	var n := 6
	var span := 400.0
	for i in range(n):
		var t := float(i) / float(n - 1)
		var z := lerpf(-span * 0.5, span * 0.5, t)
		var x := sin(t * TAU * 0.5) * 20.0
		var p := Vector3(x, 0.0, z)
		# Catmull-Rom tangents
		var t_in := Vector3.ZERO
		var t_out := Vector3.ZERO
		if i > 0 and i < n - 1:
			var tang := Vector3(
				sin((float(i + 1) / float(n - 1)) * TAU * 0.5) * 20.0
				- sin((float(i - 1) / float(n - 1)) * TAU * 0.5) * 20.0,
				0.0,
				lerpf(-span * 0.5, span * 0.5, float(i + 1) / float(n - 1))
				- lerpf(-span * 0.5, span * 0.5, float(i - 1) / float(n - 1))
			) * 0.5
			t_in = -tang
			t_out = tang
		curve.add_point(p, t_in, t_out)
	if snap_to_ground:
		_snap_points_to_ground()


func _find_terrain_node() -> Node:
	# Walk the scene for a node exposing _sample_height (TerrainStreamer or TerrainPatch3D).
	var root: Node = get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
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
