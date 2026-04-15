extends Node

signal build_mode_entered
signal build_mode_exited
signal item_placed(item: Node3D)
signal item_removed(item: Node3D)
signal buildable_selected(data: BuildableData)

enum BuildMode { OFF, CHASSIS, FLOOR, ITEM, DEMOLISH }

var mode: BuildMode = BuildMode.OFF
var is_building: bool = false
var current_buildable_data: BuildableData = null
var current_buildable: PackedScene = null
var preview_instance: Node3D = null
var preview_material_valid: StandardMaterial3D
var preview_material_invalid: StandardMaterial3D
var can_place: bool = false
var _preview_material_state: int = -1 # -1 unknown, 0 invalid, 1 valid
var preview_rotation: float = 0.0

var buildable_catalog: Dictionary = {}
var chassis_scene: PackedScene = null
var wagon_frame_scene: PackedScene = null
var floor_scene: PackedScene = null

# Two-step chassis/wagon placement
var _first_bogie: TrainChassis = null
var _first_bogie_progress: float = 0.0
var _first_bogie_curve: Curve3D = null
var _first_bogie_rail_path: Node = null
var _second_bogie_preview: Node3D = null
var demolish_target: Node3D = null  # Node highlighted for demolition
var _wall_sfx_index: int = 0
var preview_material_demolish: StandardMaterial3D

# Edge snapping for walls
enum EdgeSide { NONE, NORTH, SOUTH, EAST, WEST }
var _last_edge: EdgeSide = EdgeSide.NONE
var _last_edge_grid: Vector2i = Vector2i.ZERO
# Costs
const CHASSIS_COST: Dictionary = { "wood": 10, "metal": 15 }
const FLOOR_COST: Dictionary = { "wood": 3 }

func _has_build_tool() -> bool:
	return Inventory.get_selected_item() == "hammer"

func _resolve_actor_peer_id(actor_peer_id: int) -> int:
	if actor_peer_id > 0:
		return actor_peer_id
	if multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return 1

func _has_build_tool_for_peer(peer_id: int) -> bool:
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		return Inventory.server_get_selected_item(peer_id) == "hammer"
	return _has_build_tool()

func _spend_resources_for_peer(peer_id: int, cost: Dictionary) -> bool:
	if cost.is_empty():
		return true
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		return Inventory.server_spend_items(peer_id, cost)
	return Inventory.spend_resources(cost)

func _refund_resource_for_peer(peer_id: int, item_id: String, amount: int) -> void:
	if amount <= 0:
		return
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		Inventory.server_add_item(peer_id, item_id, amount)
	else:
		Inventory.add_resource(item_id, amount)

func _ready() -> void:
	preview_material_valid = StandardMaterial3D.new()
	preview_material_valid.albedo_color = Color(0.0, 1.0, 0.0, 0.4)
	preview_material_valid.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_material_valid.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	preview_material_invalid = StandardMaterial3D.new()
	preview_material_invalid.albedo_color = Color(1.0, 0.0, 0.0, 0.4)
	preview_material_invalid.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_material_invalid.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	preview_material_demolish = StandardMaterial3D.new()
	preview_material_demolish.albedo_color = Color(1.0, 0.3, 0.0, 0.5)
	preview_material_demolish.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_material_demolish.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	chassis_scene = preload("res://scenes/train/chassis.tscn")
	wagon_frame_scene = preload("res://scenes/train/wagon_frame.tscn")
	floor_scene = preload("res://scenes/building/floor_piece.tscn")
	_load_buildables()

func _load_buildables() -> void:
	var dir := DirAccess.open("res://resources/buildables/")
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres"):
			var data := load("res://resources/buildables/" + file_name) as BuildableData
			if data:
				buildable_catalog[data.id] = data
		file_name = dir.get_next()

func _unhandled_input(event: InputEvent) -> void:
	if not is_building:
		return
	if event.is_action_pressed("rotate_build"):
		preview_rotation += PI / 2.0
		if preview_rotation >= TAU:
			preview_rotation = 0.0

func enter_build_mode() -> void:
	is_building = true
	mode = BuildMode.OFF
	preview_rotation = 0.0
	# If the player already owns a hammer, equip it when entering build mode.
	if Inventory.has_item("hammer"):
		Inventory.select_hotbar_item("hammer")
	build_mode_entered.emit()

func exit_build_mode() -> void:
	is_building = false
	mode = BuildMode.OFF
	_clear_preview()
	_cancel_chassis_placement()
	build_mode_exited.emit()

func set_mode(new_mode: BuildMode) -> void:
	if mode == BuildMode.CHASSIS and new_mode != BuildMode.CHASSIS:
		_cancel_chassis_placement()
	mode = new_mode
	_clear_preview()
	current_buildable_data = null
	current_buildable = null

func select_buildable(buildable_id: String) -> void:
	if not buildable_catalog.has(buildable_id):
		return
	mode = BuildMode.ITEM
	current_buildable_data = buildable_catalog[buildable_id]
	current_buildable = current_buildable_data.scene
	_clear_preview()
	if current_buildable:
		preview_instance = current_buildable.instantiate()
		preview_instance.set_meta("is_preview", true)
		preview_instance.set_meta("original_scale", preview_instance.scale)
		_apply_material(preview_instance, preview_material_valid)
	buildable_selected.emit(current_buildable_data)

func _cycle_mode() -> void:
	match mode:
		BuildMode.CHASSIS:
			mode = BuildMode.FLOOR
		BuildMode.FLOOR:
			mode = BuildMode.ITEM
			# Select first buildable
			if buildable_catalog.size() > 0:
				select_buildable(buildable_catalog.keys()[0])
				return
		BuildMode.ITEM:
			# Cycle through buildables or go back to chassis
			if current_buildable_data:
				var keys: Array = buildable_catalog.keys()
				var idx: int = keys.find(current_buildable_data.id)
				idx += 1
				if idx >= keys.size():
					mode = BuildMode.CHASSIS
					_clear_preview()
					current_buildable_data = null
					current_buildable = null
					return
				select_buildable(keys[idx])
				return
			mode = BuildMode.CHASSIS
	_clear_preview()
	current_buildable_data = null
	current_buildable = null

# --- Preview updates called by player ---

func update_preview_on_ground(hit_point: Vector3, _hit_normal: Vector3) -> void:
	if mode != BuildMode.CHASSIS:
		hide_preview()
		return

	# Step 2: first bogie placed, show second bogie preview along rail
	if _first_bogie != null and _first_bogie_curve != null:
		_update_second_bogie_preview(hit_point)
		return

	# Step 1: show single bogie preview snapped to rail
	if preview_instance == null and chassis_scene:
		preview_instance = chassis_scene.instantiate()
		preview_instance.set_meta("is_preview", true)
		_apply_material(preview_instance, preview_material_valid)
	if preview_instance == null:
		return
	if not preview_instance.is_inside_tree():
		get_tree().current_scene.add_child(preview_instance)
		_disable_preview_collision(preview_instance)

	var near_rails: bool = false
	var final_pos: Vector3 = hit_point
	var fwd: Vector3 = Vector3.FORWARD
	var best_dist: float = INF
	# Scan all RailPaths for closest rail
	var rail_paths := get_tree().get_nodes_in_group("rail_path")
	for rp in rail_paths:
		if not rp.has_method("get_rail_curve"):
			continue
		var rp_curve: Curve3D = rp.get_rail_curve()
		if rp_curve == null or rp_curve.get_baked_length() < 0.1:
			continue
		var local_hit: Vector3 = rp.to_local(hit_point)
		var rp_offset: float = rp_curve.get_closest_offset(local_hit)
		var rp_pos: Vector3 = rp.to_global(rp_curve.sample_baked(rp_offset))
		var d: float = hit_point.distance_to(rp_pos)
		if d < best_dist:
			best_dist = d
			final_pos = rp_pos
			var total: float = rp_curve.get_baked_length()
			var ahead: float = minf(rp_offset + 1.0, total)
			var behind: float = maxf(rp_offset - 1.0, 0.0)
			fwd = rp.to_global(rp_curve.sample_baked(ahead)) - rp.to_global(rp_curve.sample_baked(behind))
			if fwd.length_squared() < 0.0001:
				fwd = Vector3.FORWARD
			fwd = fwd.normalized()
	# Fallback: terrain's single curve
	if best_dist == INF:
		var terrain: TerrainGenerator = _find_terrain()
		if terrain:
			var curve: Curve3D = terrain.get_rail_curve()
			if curve and curve.get_baked_length() > 0.0:
				var offset: float = curve.get_closest_offset(hit_point)
				final_pos = curve.sample_baked(offset)
				best_dist = hit_point.distance_to(final_pos)
				var total: float = curve.get_baked_length()
				var ahead: float = minf(offset + 1.0, total)
				var behind: float = maxf(offset - 1.0, 0.0)
				fwd = curve.sample_baked(ahead) - curve.sample_baked(behind)
				if fwd.length_squared() < 0.0001:
					fwd = Vector3.FORWARD
				fwd = fwd.normalized()
	near_rails = best_dist < 6.0

	preview_instance.visible = true
	preview_instance.global_position = final_pos
	if fwd.length_squared() > 0.0001:
		var right: Vector3 = Vector3.UP.cross(fwd)
		if right.length_squared() < 0.0001:
			right = Vector3.RIGHT
		right = right.normalized()
		var up: Vector3 = fwd.cross(right).normalized()
		var sc: Vector3 = preview_instance.basis.get_scale()
		preview_instance.basis = Basis(right, up, fwd).scaled(sc)
	_set_preview_validity(near_rails and Inventory.has_resources(CHASSIS_COST) and _has_build_tool())


func _update_second_bogie_preview(hit_point: Vector3) -> void:
	if _second_bogie_preview == null and chassis_scene:
		_second_bogie_preview = chassis_scene.instantiate()
		_second_bogie_preview.set_meta("is_preview", true)
		_apply_material(_second_bogie_preview, preview_material_valid)
	if _second_bogie_preview == null:
		return
	if not _second_bogie_preview.is_inside_tree():
		get_tree().current_scene.add_child(_second_bogie_preview)
		_disable_preview_collision(_second_bogie_preview)

	var curve: Curve3D = _first_bogie_curve
	var total: float = curve.get_baked_length()
	var offset: float = curve.get_closest_offset(hit_point)
	var distance: float = absf(offset - _first_bogie_progress)
	# Clamp distance: min 2 tiles, max 8 tiles
	var min_dist: float = 2.0
	var max_dist: float = 8.0
	distance = clampf(distance, min_dist, max_dist)
	# Place second bogie on the other side of first
	var second_progress: float
	if offset > _first_bogie_progress:
		second_progress = clampf(_first_bogie_progress + distance, 0.0, total)
	else:
		second_progress = clampf(_first_bogie_progress - distance, 0.0, total)

	var pos: Vector3 = curve.sample_baked(second_progress)
	var ahead: float = minf(second_progress + 1.0, total)
	var behind: float = maxf(second_progress - 1.0, 0.0)
	var fwd: Vector3 = curve.sample_baked(ahead) - curve.sample_baked(behind)
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()

	_second_bogie_preview.visible = true
	_second_bogie_preview.global_position = pos
	var right: Vector3 = Vector3.UP.cross(fwd)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	right = right.normalized()
	var up: Vector3 = fwd.cross(right).normalized()
	var sc2: Vector3 = _second_bogie_preview.basis.get_scale()
	_second_bogie_preview.basis = Basis(right, up, fwd).scaled(sc2)
	var valid: bool = distance >= min_dist and Inventory.has_resources(CHASSIS_COST) and _has_build_tool()
	_apply_material(_second_bogie_preview, preview_material_valid if valid else preview_material_invalid)
	can_place = valid

func _find_terrain() -> TerrainGenerator:
	var nodes := get_tree().get_nodes_in_group("terrain")
	if nodes.size() > 0:
		return nodes[0] as TerrainGenerator
	return null

func update_preview_on_chassis(hit_point: Vector3, hit_normal: Vector3, chassis: TrainChassis) -> void:
	update_preview_on_target(hit_point, hit_normal, chassis)

func update_preview_on_target(hit_point: Vector3, hit_normal: Vector3, target: Node) -> void:
	match mode:
		BuildMode.FLOOR:
			_update_floor_preview(hit_point, hit_normal, target)
		BuildMode.ITEM:
			_update_item_preview(hit_point, hit_normal, target)
		BuildMode.DEMOLISH:
			_update_demolish_preview(hit_point, target)
		_:
			hide_preview()

func _update_floor_preview(hit_point: Vector3, _hit_normal: Vector3, chassis: Node) -> void:
	if preview_instance == null and floor_scene:
		preview_instance = floor_scene.instantiate()
		preview_instance.set_meta("is_preview", true)
		_apply_material(preview_instance, preview_material_valid)
	if preview_instance == null:
		return
	if not preview_instance.is_inside_tree():
		get_tree().current_scene.add_child(preview_instance)
		_disable_preview_collision(preview_instance)
	var grid_pos: Vector2i = chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		hide_preview()
		return
	var local_pos: Vector3 = chassis.grid_to_local(grid_pos)
	local_pos.y = chassis.get_build_surface_local_y()
	var world_pos: Vector3 = chassis.to_global(local_pos)
	preview_instance.visible = true
	preview_instance.global_position = world_pos
	preview_instance.global_basis = chassis.global_basis
	_set_preview_validity(chassis.can_place_floor(grid_pos) and Inventory.has_resources(FLOOR_COST) and _has_build_tool())

func _update_item_preview(hit_point: Vector3, _hit_normal: Vector3, chassis: Node) -> void:
	if preview_instance == null:
		return
	if not preview_instance.is_inside_tree():
		get_tree().current_scene.add_child(preview_instance)
		_disable_preview_collision(preview_instance)
	var grid_pos: Vector2i = chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		_last_edge = EdgeSide.NONE
		hide_preview()
		return
	var is_edge_item: bool = _is_edge_category()
	var world_pos: Vector3
	var rot_y: float = preview_rotation

	if is_edge_item:
		var edge: EdgeSide = _detect_edge_from_hit(chassis, hit_point, grid_pos)
		_last_edge = edge
		_last_edge_grid = grid_pos
		var edge_offset: Vector3 = _edge_offset(edge)
		var local_center: Vector3 = chassis.grid_to_local(grid_pos)
		local_center += edge_offset
		local_center.y = chassis.get_build_surface_local_y() + 0.05
		world_pos = chassis.to_global(local_center)
		# Auto-rotate wall to face the edge
		rot_y = _edge_rotation(edge) + preview_rotation
	else:
		_last_edge = EdgeSide.NONE
		var local_center: Vector3 = chassis.grid_to_local(grid_pos)
		local_center.y = chassis.get_build_surface_local_y() + 0.05
		world_pos = chassis.to_global(local_center)

	var _sc: Vector3 = preview_instance.get_meta("original_scale", preview_instance.scale)
	preview_instance.visible = true
	preview_instance.global_position = world_pos
	preview_instance.global_basis = chassis.global_basis.orthonormalized() * Basis(Vector3.UP, rot_y)
	preview_instance.scale = _sc
	var cost: Dictionary = current_buildable_data.cost if current_buildable_data else {}
	var has_cost: bool = cost.is_empty() or Inventory.has_resources(cost)
	var has_tool: bool = _has_build_tool()
	if is_edge_item and _last_edge != EdgeSide.NONE:
		_set_preview_validity(chassis.can_place_edge(grid_pos, _last_edge) and has_cost and has_tool)
	else:
		_set_preview_validity(chassis.can_place_item(grid_pos) and has_cost and has_tool)

# --- Placement ---

func try_place_chassis(hit_point: Vector3, actor_peer_id: int = -1, replicate: bool = true) -> Node3D:
	if WorldSync.should_request_host():
		WorldSync.request_place_chassis(hit_point)
		return null
	var peer_id := _resolve_actor_peer_id(actor_peer_id)
	if not _has_build_tool_for_peer(peer_id):
		return null

	# Step 2: place second bogie + create WagonFrame
	if _first_bogie != null and _first_bogie_curve != null:
		return _place_second_bogie(hit_point, peer_id, replicate)

	# Step 1: place first bogie — find closest rail
	var best_curve: Curve3D = null
	var best_offset: float = 0.0
	var best_pos: Vector3 = hit_point
	var best_dist: float = INF
	var best_rp: Node = null
	var all_rps := get_tree().get_nodes_in_group("rail_path")
	for rp in all_rps:
		if not rp.has_method("get_rail_curve"):
			continue
		var rp_curve: Curve3D = rp.get_rail_curve()
		if rp_curve == null or rp_curve.get_baked_length() < 0.1:
			continue
		var local_hit: Vector3 = rp.to_local(hit_point)
		var rp_off: float = rp_curve.get_closest_offset(local_hit)
		var rp_pos: Vector3 = rp.to_global(rp_curve.sample_baked(rp_off))
		var d: float = hit_point.distance_to(rp_pos)
		if d < best_dist:
			best_dist = d
			best_curve = rp_curve
			best_offset = rp_off
			best_pos = rp_pos
			best_rp = rp
	# Fallback to terrain's single curve
	if best_curve == null:
		var terrain: TerrainGenerator = _find_terrain()
		if terrain:
			best_curve = terrain.get_rail_curve()
			if best_curve and best_curve.get_baked_length() > 0.0:
				best_offset = best_curve.get_closest_offset(hit_point)
				best_pos = best_curve.sample_baked(best_offset)
				best_dist = hit_point.distance_to(best_pos)
	if best_curve == null or best_dist >= 6.0:
		return null
	if not _spend_resources_for_peer(peer_id, CHASSIS_COST):
		return null
	# Build world-space curve for movement (same as chassis.snap_to_rails does)
	var world_curve: Curve3D
	if best_rp != null:
		world_curve = _build_world_curve(best_rp)
		if world_curve == null:
			world_curve = best_curve
		else:
			best_offset = world_curve.get_closest_offset(best_pos)
	else:
		world_curve = best_curve
	var instance := chassis_scene.instantiate() as TrainChassis
	get_tree().current_scene.add_child(instance)
	var chassis_net_id := WorldSync.register_entity(instance)
	instance.global_position = world_curve.sample_baked(best_offset)
	_orient_node_on_curve(instance, world_curve, best_offset)
	if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		var rail_path_ref: NodePath = best_rp.get_path() if best_rp != null else NodePath()
		WorldSync.replicate_spawn_chassis(chassis_net_id, instance.global_transform, rail_path_ref, best_offset)

	# Store for step 2
	_first_bogie = instance
	_first_bogie_progress = best_offset
	_first_bogie_curve = world_curve
	_first_bogie_rail_path = best_rp
	# Hide step 1 preview
	_clear_preview()
	return instance


func _place_second_bogie(hit_point: Vector3, actor_peer_id: int = -1, _replicate: bool = true) -> Node3D:
	var peer_id := _resolve_actor_peer_id(actor_peer_id)
	var curve: Curve3D = _first_bogie_curve
	var total: float = curve.get_baked_length()
	var offset: float = curve.get_closest_offset(hit_point)
	var distance: float = absf(offset - _first_bogie_progress)
	distance = clampf(distance, 2.0, 8.0)
	if not _spend_resources_for_peer(peer_id, CHASSIS_COST):
		return null

	# Determine direction
	var second_progress: float
	if offset > _first_bogie_progress:
		second_progress = clampf(_first_bogie_progress + distance, 0.0, total)
	else:
		second_progress = clampf(_first_bogie_progress - distance, 0.0, total)

	# Ensure front bogie has higher progress (closer to end of track)
	var raw_front: float = maxf(_first_bogie_progress, second_progress)
	var raw_rear: float = minf(_first_bogie_progress, second_progress)
	var wagon_tiles: int = clampi(int(round(absf(raw_front - raw_rear))), 2, 8)
	# Snap bogie spacing to exact tile count so placement matches physics loop
	var spacing: float = float(wagon_tiles) * WagonFrame.GRID_SIZE
	var front_progress: float = raw_front
	var rear_progress: float = front_progress - spacing

	# Create second bogie
	var second_bogie := chassis_scene.instantiate() as TrainChassis
	get_tree().current_scene.add_child(second_bogie)
	WorldSync.register_entity(second_bogie)
	second_bogie.global_position = curve.sample_baked(second_progress)
	_orient_node_on_curve(second_bogie, curve, second_progress)

	# Determine which is front, which is rear
	var front: TrainChassis
	var rear: TrainChassis
	if _first_bogie_progress >= second_progress:
		front = _first_bogie
		rear = second_bogie
	else:
		front = second_bogie
		rear = _first_bogie

	# Create WagonFrame and reparent bogies
	var frame := WagonFrame.new()
	frame.wagon_length = wagon_tiles
	get_tree().current_scene.add_child(frame)
	var frame_net_id := WorldSync.register_entity(frame)

	# Position frame at midpoint — use snapped progress values
	var front_pos: Vector3 = curve.sample_baked(front_progress)
	var rear_pos: Vector3 = curve.sample_baked(rear_progress)
	frame.global_position = (front_pos + rear_pos) * 0.5
	var fwd: Vector3 = front_pos - rear_pos
	if fwd.length_squared() > 0.001:
		fwd = fwd.normalized()
		var rt: Vector3 = Vector3.UP.cross(fwd)
		if rt.length_squared() < 0.0001:
			rt = Vector3.RIGHT
		rt = rt.normalized()
		var up_v: Vector3 = fwd.cross(rt).normalized()
		frame.basis = Basis(rt, up_v, fwd)

	# Move bogies to snapped positions before reparenting
	front.global_position = front_pos
	_orient_node_on_curve(front, curve, front_progress)
	rear.global_position = rear_pos
	_orient_node_on_curve(rear, curve, rear_progress)

	# Reparent bogies under frame — save global basis before reparenting
	var front_global_basis: Basis = front.global_basis
	var rear_global_basis: Basis = rear.global_basis

	front.get_parent().remove_child(front)
	frame.add_child(front)
	front.position = frame.to_local(front_pos)
	front.global_basis = front_global_basis

	rear.get_parent().remove_child(rear)
	frame.add_child(rear)
	rear.position = frame.to_local(rear_pos)
	rear.global_basis = rear_global_basis

	# Initialize frame
	frame.front_bogie = front
	frame.rear_bogie = rear
	frame._setup_bogies()
	frame._build_frame_visuals()
	frame._build_collision_surface()

	# Set rail data on front bogie so WagonFrame can use it
	front.rail_curve = curve
	front.rail_progress = front_progress
	front.current_rail_path = _first_bogie_rail_path
	rear.rail_curve = curve
	rear.rail_progress = rear_progress
	rear.current_rail_path = _first_bogie_rail_path

	# Activate the frame on rails
	frame.is_on_rails = true
	if _replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		var previous_first_net_id := WorldSync.get_net_id(_first_bogie)
		var front_net_id := WorldSync.get_net_id(front)
		var rear_net_id := WorldSync.get_net_id(rear)
		var rail_path_ref: NodePath = _first_bogie_rail_path.get_path() if _first_bogie_rail_path != null else NodePath()
		WorldSync.replicate_spawn_wagon_frame(
			frame_net_id,
			front_net_id,
			rear_net_id,
			previous_first_net_id,
			frame.global_transform,
			front.global_transform,
			rear.global_transform,
			wagon_tiles,
			rail_path_ref,
			front_progress,
			rear_progress
		)

	# Clean up second preview
	_clear_second_bogie_preview()
	_first_bogie = null
	_first_bogie_progress = 0.0
	_first_bogie_curve = null
	_first_bogie_rail_path = null

	item_placed.emit(frame)
	return frame


func _orient_node_on_curve(node: Node3D, curve: Curve3D, offset: float) -> void:
	var total: float = curve.get_baked_length()
	var ahead: float = minf(offset + 1.0, total)
	var behind: float = maxf(offset - 1.0, 0.0)
	var fwd: Vector3 = curve.sample_baked(ahead) - curve.sample_baked(behind)
	if fwd.length_squared() > 0.0001:
		fwd = fwd.normalized()
		var rt: Vector3 = Vector3.UP.cross(fwd)
		if rt.length_squared() < 0.0001:
			rt = Vector3.RIGHT
		rt = rt.normalized()
		var up_v: Vector3 = fwd.cross(rt).normalized()
		var sc: Vector3 = node.basis.get_scale()
		node.basis = Basis(rt, up_v, fwd).scaled(sc)


func _build_world_curve(path_node: Node) -> Curve3D:
	var src_curve: Curve3D = path_node.get_rail_curve()
	if src_curve == null or src_curve.point_count < 2:
		return null
	var wc := Curve3D.new()
	wc.bake_interval = src_curve.bake_interval
	for i in range(src_curve.point_count):
		var p: Vector3 = path_node.to_global(src_curve.get_point_position(i))
		var t_in: Vector3 = path_node.global_basis * src_curve.get_point_in(i)
		var t_out: Vector3 = path_node.global_basis * src_curve.get_point_out(i)
		wc.add_point(p, t_in, t_out)
	return wc


func _cancel_chassis_placement() -> void:
	# If first bogie was placed but not yet coupled, remove it and refund
	if _first_bogie and is_instance_valid(_first_bogie):
		_first_bogie.queue_free()
		Inventory.add_resource("wood", CHASSIS_COST.get("wood", 0))
		Inventory.add_resource("metal", CHASSIS_COST.get("metal", 0))
	_first_bogie = null
	_first_bogie_progress = 0.0
	_first_bogie_curve = null
	_first_bogie_rail_path = null
	_clear_second_bogie_preview()


func _clear_second_bogie_preview() -> void:
	if _second_bogie_preview and is_instance_valid(_second_bogie_preview):
		if _second_bogie_preview.is_inside_tree():
			_second_bogie_preview.queue_free()
	_second_bogie_preview = null

func try_place_floor(hit_point: Vector3, chassis: Node, actor_peer_id: int = -1, replicate: bool = true) -> Node3D:
	if WorldSync.should_request_host():
		WorldSync.request_place_floor(WorldSync.get_net_id(chassis), chassis.get_grid_position(hit_point))
		return null
	var peer_id := _resolve_actor_peer_id(actor_peer_id)
	if not _has_build_tool_for_peer(peer_id):
		return null
	var grid_pos: Vector2i = chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		return null
	if not chassis.can_place_floor(grid_pos):
		return null
	if not _spend_resources_for_peer(peer_id, FLOOR_COST):
		return null
	var instance := floor_scene.instantiate() as Node3D
	chassis.add_child(instance)
	WorldSync.register_entity(instance)
	var local_pos: Vector3 = chassis.grid_to_local(grid_pos)
	local_pos.y = chassis.get_build_surface_local_y()
	instance.position = local_pos
	chassis.place_floor(grid_pos, instance)
	item_placed.emit(instance)
	if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_place_floor(WorldSync.get_net_id(chassis), grid_pos)
	return instance

func try_place_item(hit_point: Vector3, chassis: Node, actor_peer_id: int = -1, replicate: bool = true) -> Node3D:
	var grid_pos: Vector2i = chassis.get_grid_position(hit_point)
	var requested_edge: EdgeSide = EdgeSide.NONE
	if current_buildable_data != null and _is_edge_category():
		requested_edge = _detect_edge_from_hit(chassis, hit_point, grid_pos)
	if WorldSync.should_request_host():
		var buildable_id := current_buildable_data.id if current_buildable_data else ""
		WorldSync.request_place_item(WorldSync.get_net_id(chassis), buildable_id, grid_pos, preview_rotation, requested_edge)
		return null
	var peer_id := _resolve_actor_peer_id(actor_peer_id)
	if not _has_build_tool_for_peer(peer_id):
		return null
	if current_buildable == null:
		return null
	if not chassis.is_grid_in_bounds(grid_pos):
		return null
	var is_edge_item: bool = _is_edge_category()
	var edge: EdgeSide = requested_edge

	# Validate placement
	if is_edge_item:
		edge = _detect_edge_from_hit(chassis, hit_point, grid_pos)
		if edge == EdgeSide.NONE:
			return null
		if not chassis.can_place_edge(grid_pos, edge):
			return null
	else:
		if not chassis.can_place_item(grid_pos):
			return null

	var cost: Dictionary = current_buildable_data.cost if current_buildable_data else {}
	if not cost.is_empty() and not _spend_resources_for_peer(peer_id, cost):
		return null
	var instance := current_buildable.instantiate() as Node3D
	if current_buildable_data:
		instance.set_meta("buildable_id", current_buildable_data.id)
	chassis.add_child(instance)
	var item_net_id := WorldSync.register_entity(instance)

	var local_pos: Vector3 = chassis.grid_to_local(grid_pos)
	local_pos.y = chassis.get_build_surface_local_y() + 0.05

	if is_edge_item and edge != EdgeSide.NONE:
		local_pos += _edge_offset(edge)
		instance.rotation.y = _edge_rotation(edge) + preview_rotation
		instance.set_meta("edge_side", edge)
		instance.set_meta("grid_pos_x", grid_pos.x)
		instance.set_meta("grid_pos_y", grid_pos.y)
		instance.position = local_pos
		chassis.place_edge_item(grid_pos, edge, instance)
	else:
		instance.rotation.y = preview_rotation
		instance.position = local_pos
		chassis.place_item(grid_pos, instance)

	if current_buildable_data:
		if current_buildable_data.id == "placeable_wall_blue" or current_buildable_data.id == "placeable_wall_yellow":
			_wall_sfx_index = (_wall_sfx_index + 1) % 3
			AudioManager.play_sfx("wall_place_" + str(_wall_sfx_index + 1), linear_to_db(0.8))
		elif current_buildable_data.id == "direction_lever":
			AudioManager.play_sfx("levier_place")
	item_placed.emit(instance)
	if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_place_item(WorldSync.get_net_id(chassis), item_net_id, current_buildable_data.id, grid_pos, preview_rotation, edge)
	return instance

func server_try_place_chassis(peer_id: int, hit_point: Vector3) -> Node3D:
	return try_place_chassis(hit_point, peer_id, true)

func server_try_place_floor(peer_id: int, target_net_id: int, grid_pos: Vector2i) -> Node3D:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("grid_to_world"):
		return null
	var hit_point: Vector3 = target.grid_to_world(grid_pos)
	return try_place_floor(hit_point, target, peer_id, true)

func server_try_place_item(peer_id: int, target_net_id: int, buildable_id: String, grid_pos: Vector2i, rotation_y: float, edge: int) -> Node3D:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("is_grid_in_bounds"):
		return null
	if not _has_build_tool_for_peer(peer_id):
		return null
	if not buildable_catalog.has(buildable_id):
		return null
	var data: BuildableData = buildable_catalog[buildable_id]
	if not target.is_grid_in_bounds(grid_pos):
		return null
	var is_edge_item: bool = data.category in [
		BuildableData.Category.WALL,
		BuildableData.Category.BARRICADE,
	]
	if is_edge_item:
		if edge == EdgeSide.NONE or not target.can_place_edge(grid_pos, edge):
			return null
	else:
		if not target.can_place_item(grid_pos):
			return null
	if not _spend_resources_for_peer(peer_id, data.cost):
		return null
	var placed := _instantiate_buildable_on_target(target, data, grid_pos, rotation_y, edge)
	if placed != null:
		WorldSync.replicate_place_item(target_net_id, WorldSync.get_net_id(placed), buildable_id, grid_pos, rotation_y, edge)
	return placed

func apply_network_floor(target_net_id: int, grid_pos: Vector2i) -> Node3D:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("can_place_floor"):
		return null
	if not target.can_place_floor(grid_pos):
		return null
	var instance := floor_scene.instantiate() as Node3D
	target.add_child(instance)
	WorldSync.register_entity(instance)
	var local_pos: Vector3 = target.grid_to_local(grid_pos)
	local_pos.y = target.get_build_surface_local_y()
	instance.position = local_pos
	target.place_floor(grid_pos, instance)
	item_placed.emit(instance)
	return instance

func apply_network_item(target_net_id: int, item_net_id: int, buildable_id: String, grid_pos: Vector2i, rotation_y: float, edge: int) -> Node3D:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not buildable_catalog.has(buildable_id):
		return null
	var data: BuildableData = buildable_catalog[buildable_id]
	var is_edge_item: bool = data.category in [
		BuildableData.Category.WALL,
		BuildableData.Category.BARRICADE,
	]
	if is_edge_item:
		if edge == EdgeSide.NONE or not target.can_place_edge(grid_pos, edge):
			return null
	else:
		if not target.can_place_item(grid_pos):
			return null
	return _instantiate_buildable_on_target(target, data, grid_pos, rotation_y, edge, item_net_id)

func _instantiate_buildable_on_target(target: Node, data: BuildableData, grid_pos: Vector2i, rotation_y: float, edge: int, net_id: int = 0) -> Node3D:
	if data == null or data.scene == null:
		return null
	var instance := data.scene.instantiate() as Node3D
	instance.set_meta("buildable_id", data.id)
	target.add_child(instance)
	WorldSync.register_entity(instance, net_id)
	var local_pos: Vector3 = target.grid_to_local(grid_pos)
	local_pos.y = target.get_build_surface_local_y() + 0.05
	var is_edge_item: bool = data.category in [
		BuildableData.Category.WALL,
		BuildableData.Category.BARRICADE,
	]
	if is_edge_item and edge != EdgeSide.NONE:
		local_pos += _edge_offset(edge)
		instance.rotation.y = _edge_rotation(edge) + rotation_y
		instance.set_meta("edge_side", edge)
		instance.set_meta("grid_pos_x", grid_pos.x)
		instance.set_meta("grid_pos_y", grid_pos.y)
		instance.position = local_pos
		target.place_edge_item(grid_pos, edge, instance)
	else:
		instance.rotation.y = rotation_y
		instance.position = local_pos
		target.place_item(grid_pos, instance)
	item_placed.emit(instance)
	return instance

# --- Edge snapping (walls/barricades snap to cell edges) ---

func _is_edge_category() -> bool:
	if current_buildable_data == null:
		return false
	return current_buildable_data.category in [
		BuildableData.Category.WALL,
		BuildableData.Category.BARRICADE,
	]

func _detect_edge_from_hit(chassis: Node, hit_point: Vector3, grid_pos: Vector2i) -> EdgeSide:
	var hit_local: Vector3 = chassis.to_local(hit_point)
	var cell_center: Vector3 = chassis.grid_to_local(grid_pos)
	var local_offset: Vector3 = hit_local - cell_center
	local_offset.y = 0.0
	if local_offset.length_squared() < 0.0001:
		return EdgeSide.NORTH
	if absf(local_offset.x) > absf(local_offset.z):
		return EdgeSide.EAST if local_offset.x > 0.0 else EdgeSide.WEST
	return EdgeSide.SOUTH if local_offset.z > 0.0 else EdgeSide.NORTH

func _edge_offset(edge: EdgeSide) -> Vector3:
	match edge:
		EdgeSide.NORTH: return Vector3(0, 0, -0.5)
		EdgeSide.SOUTH: return Vector3(0, 0, 0.5)
		EdgeSide.EAST:  return Vector3(0.5, 0, 0)
		EdgeSide.WEST:  return Vector3(-0.5, 0, 0)
	return Vector3.ZERO

func _edge_rotation(edge: EdgeSide) -> float:
	match edge:
		EdgeSide.NORTH, EdgeSide.SOUTH: return 0.0
		EdgeSide.EAST, EdgeSide.WEST:   return PI / 2.0
	return 0.0

# --- Demolish ---

func _update_demolish_preview(hit_point: Vector3, chassis: Node) -> void:
	_clear_preview()
	var grid_pos: Vector2i = chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		_clear_demolish_highlight()
		can_place = false
		return
	if not chassis.grid_cells.has(grid_pos):
		_clear_demolish_highlight()
		can_place = false
		return
	var cell: Dictionary = chassis.grid_cells[grid_pos]
	# Prefer: edge item closest to cursor > center item > floor
	var target: Node3D = null
	# Check edge items first (find closest to hit point)
	if cell.has("edges"):
		var best_dist: float = INF
		for edge_key in cell.edges:
			var edge_item: Node3D = cell.edges[edge_key]
			if edge_item != null and is_instance_valid(edge_item):
				var d: float = edge_item.global_position.distance_to(hit_point)
				if d < best_dist:
					best_dist = d
					target = edge_item
	# Fallback to center item
	if target == null and cell.get("item") != null and is_instance_valid(cell.item):
		target = cell.item
	# Fallback to floor
	if target == null and cell.get("floor", false):
		target = _find_floor_mesh(chassis, grid_pos)
	if target == null or target == demolish_target:
		if target == null:
			_clear_demolish_highlight()
		can_place = target != null
		return
	_clear_demolish_highlight()
	demolish_target = target
	_apply_temp_material(demolish_target, preview_material_demolish)
	can_place = true

func _clear_demolish_highlight() -> void:
	if demolish_target and is_instance_valid(demolish_target):
		_restore_temp_material(demolish_target)
	demolish_target = null

func _apply_temp_material(node: Node3D, mat: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		var mesh_node := node as MeshInstance3D
		if not mesh_node.has_meta("_demolish_prev_overrides"):
			var previous: Array = []
			var count: int = 0
			if mesh_node.mesh:
				count = mesh_node.mesh.get_surface_count()
			else:
				count = mesh_node.get_surface_override_material_count()
			for i in range(count):
				previous.append(mesh_node.get_surface_override_material(i))
			mesh_node.set_meta("_demolish_prev_overrides", previous)
		var set_count: int = 0
		if mesh_node.mesh:
			set_count = mesh_node.mesh.get_surface_count()
		else:
			set_count = mesh_node.get_surface_override_material_count()
		for i in range(set_count):
			mesh_node.set_surface_override_material(i, mat)
	if node is CSGPrimitive3D:
		var csg_node := node as CSGPrimitive3D
		if not csg_node.has_meta("_demolish_prev_material"):
			csg_node.set_meta("_demolish_prev_material", csg_node.material)
		csg_node.material = mat
	for child in node.get_children():
		if child is Node3D:
			_apply_temp_material(child, mat)

func _restore_temp_material(node: Node3D) -> void:
	if node is MeshInstance3D:
		var mesh_node := node as MeshInstance3D
		if mesh_node.has_meta("_demolish_prev_overrides"):
			var previous: Array = mesh_node.get_meta("_demolish_prev_overrides")
			for i in range(previous.size()):
				mesh_node.set_surface_override_material(i, previous[i])
			mesh_node.remove_meta("_demolish_prev_overrides")
	if node is CSGPrimitive3D:
		var csg_node := node as CSGPrimitive3D
		if csg_node.has_meta("_demolish_prev_material"):
			csg_node.material = csg_node.get_meta("_demolish_prev_material")
			csg_node.remove_meta("_demolish_prev_material")
	for child in node.get_children():
		if child is Node3D:
			_restore_temp_material(child)

func _find_floor_mesh(chassis: Node, grid_pos: Vector2i) -> Node3D:
	return chassis.get_floor_node(grid_pos)

func try_demolish(hit_point: Vector3, chassis: Node, actor_peer_id: int = -1, replicate: bool = true, refund: bool = true) -> bool:
	if WorldSync.should_request_host():
		WorldSync.request_demolish(WorldSync.get_net_id(chassis), chassis.get_grid_position(hit_point), -1)
		return false
	var peer_id := _resolve_actor_peer_id(actor_peer_id)
	var grid_pos: Vector2i = chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		return false
	if not chassis.grid_cells.has(grid_pos):
		return false
	var cell: Dictionary = chassis.grid_cells[grid_pos]

	# Try removing edge item closest to cursor first
	if cell.has("edges"):
		var best_dist: float = INF
		var best_edge: int = -1
		var best_item: Node3D = null
		for edge_key in cell.edges:
			var edge_item: Node3D = cell.edges[edge_key]
			if edge_item != null and is_instance_valid(edge_item):
				var d: float = edge_item.global_position.distance_to(hit_point)
				if d < best_dist:
					best_dist = d
					best_edge = edge_key
					best_item = edge_item
		if best_item != null and best_dist < 1.5:
			chassis.remove_edge_item(grid_pos, best_edge)
			if refund:
				_refund_item(best_item, peer_id)
			best_item.queue_free()
			item_removed.emit(best_item)
			_clear_demolish_highlight()
			if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
				WorldSync.replicate_demolish(WorldSync.get_net_id(chassis), grid_pos, best_edge)
			return true

	# Remove center item
	if cell.get("item") != null and is_instance_valid(cell.item):
		var item: Node3D = cell.item
		chassis.remove_item(grid_pos)
		if refund:
			_refund_item(item, peer_id)
		item.queue_free()
		item_removed.emit(item)
		_clear_demolish_highlight()
		if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
			WorldSync.replicate_demolish(WorldSync.get_net_id(chassis), grid_pos, -1)
		return true

	# Remove floor if no items
	if cell.get("floor", false):
		var floor_node := _find_floor_mesh(chassis, grid_pos)
		cell.floor = false
		cell.floor_node = null
		chassis.floor_count -= 1
		if floor_node:
			floor_node.queue_free()
		if refund:
			for res_name in FLOOR_COST:
				_refund_resource_for_peer(peer_id, res_name, int(ceil(FLOOR_COST[res_name] * 0.5)))
		item_removed.emit(floor_node)
		_clear_demolish_highlight()
		if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
			WorldSync.replicate_demolish(WorldSync.get_net_id(chassis), grid_pos, -1)
		return true
	return false

func server_try_demolish(peer_id: int, target_net_id: int, grid_pos: Vector2i, _edge: int) -> bool:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("grid_to_world"):
		return false
	return try_demolish(target.grid_to_world(grid_pos), target, peer_id, true, true)

func apply_network_demolish(target_net_id: int, grid_pos: Vector2i, edge: int) -> bool:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("grid_to_world"):
		return false
	var hit_point: Vector3 = target.grid_to_world(grid_pos)
	if edge != -1:
		hit_point += target.global_basis * _edge_offset(edge)
	return try_demolish(hit_point, target, -1, false, false)

func _refund_item(item: Node3D, peer_id: int) -> void:
	if item.has_meta("buildable_id"):
		var bid: String = item.get_meta("buildable_id")
		if buildable_catalog.has(bid):
			var data: BuildableData = buildable_catalog[bid]
			for res_name in data.cost:
				_refund_resource_for_peer(peer_id, res_name, int(ceil(data.cost[res_name] * 0.5)))

func hide_preview() -> void:
	if preview_instance and is_instance_valid(preview_instance) and preview_instance.is_inside_tree():
		preview_instance.visible = false
	if _second_bogie_preview and is_instance_valid(_second_bogie_preview) and _second_bogie_preview.is_inside_tree():
		_second_bogie_preview.visible = false
	_clear_demolish_highlight()
	can_place = false
	_preview_material_state = -1

func _clear_preview() -> void:
	if preview_instance and is_instance_valid(preview_instance):
		if preview_instance.is_inside_tree():
			preview_instance.queue_free()
	preview_instance = null
	_preview_material_state = -1

func _set_preview_validity(new_can_place: bool) -> void:
	can_place = new_can_place
	if preview_instance == null:
		return
	var new_state: int = 1 if new_can_place else 0
	if _preview_material_state == new_state:
		return
	_preview_material_state = new_state
	_apply_material(preview_instance, preview_material_valid if new_can_place else preview_material_invalid)

func _disable_preview_collision(node: Node) -> void:
	if node is CollisionObject3D:
		node.collision_layer = 0
		node.collision_mask = 0
	for child in node.get_children():
		_disable_preview_collision(child)

func _apply_material(node: Node3D, mat: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		for i in node.get_surface_override_material_count():
			node.set_surface_override_material(i, mat)
	if node is CSGPrimitive3D:
		node.material = mat
	for child in node.get_children():
		if child is Node3D:
			_apply_material(child, mat)

func get_mode_name() -> String:
	match mode:
		BuildMode.CHASSIS: return "Chassis"
		BuildMode.FLOOR: return "Floor"
		BuildMode.ITEM:
			if current_buildable_data:
				return current_buildable_data.display_name
			return "Item"
		BuildMode.DEMOLISH: return "Demolish"
	return ""
