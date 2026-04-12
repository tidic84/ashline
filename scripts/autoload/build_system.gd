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
var floor_scene: PackedScene = null
var demolish_target: Node3D = null  # Node highlighted for demolition
var preview_material_demolish: StandardMaterial3D

# Edge snapping for walls
enum EdgeSide { NONE, NORTH, SOUTH, EAST, WEST }
var _last_edge: EdgeSide = EdgeSide.NONE
var _last_edge_grid: Vector2i = Vector2i.ZERO
var _cached_player: Node3D = null

# Costs
const CHASSIS_COST: Dictionary = { "wood": 10, "metal": 15 }
const FLOOR_COST: Dictionary = { "wood": 3 }

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
	build_mode_entered.emit()

func exit_build_mode() -> void:
	is_building = false
	mode = BuildMode.OFF
	_clear_preview()
	build_mode_exited.emit()

func set_mode(new_mode: BuildMode) -> void:
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

func update_preview_on_ground(hit_point: Vector3, hit_normal: Vector3) -> void:
	if mode != BuildMode.CHASSIS:
		hide_preview()
		return
	if preview_instance == null and chassis_scene:
		preview_instance = chassis_scene.instantiate()
		preview_instance.set_meta("is_preview", true)
		_apply_material(preview_instance, preview_material_valid)
	if preview_instance == null:
		return
	if not preview_instance.is_inside_tree():
		get_tree().current_scene.add_child(preview_instance)
		_disable_preview_collision(preview_instance)

	# Always snap the preview to the rail curve when possible so the user
	# clearly sees where the chassis would be placed. Validity is gated by
	# how far the hit point was from the tracks.
	var terrain: TerrainGenerator = _find_terrain()
	var near_rails: bool = false
	var final_pos: Vector3 = hit_point
	var fwd: Vector3 = Vector3.FORWARD
	if terrain:
		var curve: Curve3D = terrain.get_rail_curve()
		if curve and curve.get_baked_length() > 0.0:
			var offset: float = curve.get_closest_offset(hit_point)
			final_pos = curve.sample_baked(offset)
			var total: float = curve.get_baked_length()
			var ahead: float = minf(offset + 1.0, total)
			var behind: float = maxf(offset - 1.0, 0.0)
			fwd = curve.sample_baked(ahead) - curve.sample_baked(behind)
			if fwd.length_squared() < 0.0001:
				fwd = Vector3.FORWARD
			fwd = fwd.normalized()
			var dist: float = terrain.distance_to_rails(hit_point)
			near_rails = dist < 6.0

	preview_instance.visible = true
	preview_instance.global_position = final_pos
	if fwd.length_squared() > 0.0001:
		var right: Vector3 = Vector3.UP.cross(fwd)
		if right.length_squared() < 0.0001:
			right = Vector3.RIGHT
		right = right.normalized()
		var up: Vector3 = fwd.cross(right).normalized()
		preview_instance.basis = Basis(right, up, fwd)
	_set_preview_validity(near_rails and Inventory.has_resources(CHASSIS_COST))

func _find_terrain() -> TerrainGenerator:
	var nodes := get_tree().get_nodes_in_group("terrain")
	if nodes.size() > 0:
		return nodes[0] as TerrainGenerator
	return null

func update_preview_on_chassis(hit_point: Vector3, hit_normal: Vector3, chassis: TrainChassis) -> void:
	match mode:
		BuildMode.FLOOR:
			_update_floor_preview(hit_point, hit_normal, chassis)
		BuildMode.ITEM:
			_update_item_preview(hit_point, hit_normal, chassis)
		BuildMode.DEMOLISH:
			_update_demolish_preview(hit_point, chassis)
		_:
			hide_preview()

func _update_floor_preview(hit_point: Vector3, hit_normal: Vector3, chassis: TrainChassis) -> void:
	if preview_instance == null and floor_scene:
		preview_instance = floor_scene.instantiate()
		preview_instance.set_meta("is_preview", true)
		_apply_material(preview_instance, preview_material_valid)
	if preview_instance == null:
		return
	if not preview_instance.is_inside_tree():
		get_tree().current_scene.add_child(preview_instance)
		_disable_preview_collision(preview_instance)
	var grid_pos := chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		hide_preview()
		return
	var world_pos := chassis.grid_to_world(grid_pos)
	world_pos.y = chassis.global_position.y + chassis.get_build_surface_local_y()
	preview_instance.visible = true
	preview_instance.global_position = world_pos
	_set_preview_validity(chassis.can_place_floor(grid_pos) and Inventory.has_resources(FLOOR_COST))

func _update_item_preview(hit_point: Vector3, hit_normal: Vector3, chassis: TrainChassis) -> void:
	if preview_instance == null:
		return
	if not preview_instance.is_inside_tree():
		get_tree().current_scene.add_child(preview_instance)
		_disable_preview_collision(preview_instance)
	var grid_pos := chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		_last_edge = EdgeSide.NONE
		hide_preview()
		return
	var is_edge_item: bool = _is_edge_category()
	var world_pos: Vector3
	var rot_y: float = preview_rotation

	if is_edge_item:
		var edge: EdgeSide = _detect_edge_from_player_view(chassis, grid_pos)
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
		world_pos = chassis.grid_to_world(grid_pos)
		world_pos.y = chassis.global_position.y + chassis.get_build_surface_local_y() + 0.05

	preview_instance.visible = true
	preview_instance.global_position = world_pos
	preview_instance.rotation.y = rot_y
	var cost: Dictionary = current_buildable_data.cost if current_buildable_data else {}
	var has_cost: bool = cost.is_empty() or Inventory.has_resources(cost)
	if is_edge_item and _last_edge != EdgeSide.NONE:
		_set_preview_validity(chassis.can_place_edge(grid_pos, _last_edge) and has_cost)
	else:
		_set_preview_validity(chassis.can_place_item(grid_pos) and has_cost)

# --- Placement ---

func try_place_chassis(hit_point: Vector3) -> Node3D:
	var terrain: TerrainGenerator = _find_terrain()
	if terrain == null:
		return null
	var curve: Curve3D = terrain.get_rail_curve()
	if curve == null:
		return null
	var dist: float = terrain.distance_to_rails(hit_point)
	if dist >= 6.0:
		return null  # Not close enough to rails
	if not Inventory.spend_resources(CHASSIS_COST):
		return null
	var instance := chassis_scene.instantiate() as Node3D
	get_tree().current_scene.add_child(instance)
	var offset: float = curve.get_closest_offset(hit_point)
	instance.global_position = curve.sample_baked(offset)
	var total: float = curve.get_baked_length()
	var ahead: float = minf(offset + 1.0, total)
	var behind: float = maxf(offset - 1.0, 0.0)
	var fwd: Vector3 = curve.sample_baked(ahead) - curve.sample_baked(behind)
	fwd.y = 0.0
	if fwd.length_squared() > 0.0001:
		instance.basis = Basis.looking_at(fwd.normalized(), Vector3.UP)
	if instance is TrainChassis:
		instance.snap_to_rails()
	item_placed.emit(instance)
	return instance

func try_place_floor(hit_point: Vector3, chassis: TrainChassis) -> Node3D:
	var grid_pos := chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		return null
	if not chassis.can_place_floor(grid_pos):
		return null
	if not Inventory.spend_resources(FLOOR_COST):
		return null
	var instance := floor_scene.instantiate() as Node3D
	chassis.add_child(instance)
	var local_pos := chassis.grid_to_local(grid_pos)
	local_pos.y = chassis.get_build_surface_local_y()
	instance.position = local_pos
	chassis.place_floor(grid_pos, instance)
	item_placed.emit(instance)
	return instance

func try_place_item(hit_point: Vector3, chassis: TrainChassis) -> Node3D:
	if current_buildable == null:
		return null
	var grid_pos := chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		return null
	var is_edge_item: bool = _is_edge_category()

	# Validate placement
	if is_edge_item:
		if _last_edge == EdgeSide.NONE:
			return null
		if not chassis.can_place_edge(grid_pos, _last_edge):
			return null
	else:
		if not chassis.can_place_item(grid_pos):
			return null

	var cost: Dictionary = current_buildable_data.cost if current_buildable_data else {}
	if not cost.is_empty() and not Inventory.spend_resources(cost):
		return null
	var instance := current_buildable.instantiate() as Node3D
	if current_buildable_data:
		instance.set_meta("buildable_id", current_buildable_data.id)
	chassis.add_child(instance)

	var local_pos := chassis.grid_to_local(grid_pos)
	local_pos.y = chassis.get_build_surface_local_y() + 0.05

	if is_edge_item and _last_edge != EdgeSide.NONE:
		local_pos += _edge_offset(_last_edge)
		instance.rotation.y = _edge_rotation(_last_edge) + preview_rotation
		instance.set_meta("edge_side", _last_edge)
		instance.set_meta("grid_pos_x", grid_pos.x)
		instance.set_meta("grid_pos_y", grid_pos.y)
		instance.position = local_pos
		chassis.place_edge_item(grid_pos, _last_edge, instance)
	else:
		instance.rotation.y = preview_rotation
		instance.position = local_pos
		chassis.place_item(grid_pos, instance)

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

func _detect_edge_from_player_view(chassis: TrainChassis, grid_pos: Vector2i) -> EdgeSide:
	var player: Node3D = _get_primary_player()
	if player == null:
		return EdgeSide.NORTH
	var player_local: Vector3 = chassis.to_local(player.global_position)
	var cell_center: Vector3 = chassis.grid_to_local(grid_pos)
	var from_player: Vector3 = cell_center - player_local
	from_player.y = 0.0
	if from_player.length_squared() < 0.0001:
		return EdgeSide.NORTH
	if absf(from_player.x) > absf(from_player.z):
		return EdgeSide.EAST if from_player.x > 0.0 else EdgeSide.WEST
	return EdgeSide.SOUTH if from_player.z > 0.0 else EdgeSide.NORTH

func _get_primary_player() -> Node3D:
	if _cached_player != null and is_instance_valid(_cached_player):
		return _cached_player
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		_cached_player = null
		return null
	_cached_player = players[0] as Node3D
	return _cached_player

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

func _update_demolish_preview(hit_point: Vector3, chassis: TrainChassis) -> void:
	_clear_preview()
	var grid_pos := chassis.get_grid_position(hit_point)
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
	_apply_material(demolish_target, preview_material_demolish)
	can_place = true

func _clear_demolish_highlight() -> void:
	if demolish_target and is_instance_valid(demolish_target):
		_clear_material_overrides(demolish_target)
	demolish_target = null

func _clear_material_overrides(node: Node3D) -> void:
	if node is MeshInstance3D:
		for i in node.get_surface_override_material_count():
			node.set_surface_override_material(i, null)
	if node is CSGPrimitive3D:
		node.material = null
	for child in node.get_children():
		if child is Node3D:
			_clear_material_overrides(child)

func _find_floor_mesh(chassis: TrainChassis, grid_pos: Vector2i) -> Node3D:
	return chassis.get_floor_node(grid_pos)

func try_demolish(hit_point: Vector3, chassis: TrainChassis) -> bool:
	var grid_pos := chassis.get_grid_position(hit_point)
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
			_refund_item(best_item)
			best_item.queue_free()
			item_removed.emit(best_item)
			_clear_demolish_highlight()
			return true

	# Remove center item
	if cell.get("item") != null and is_instance_valid(cell.item):
		var item: Node3D = cell.item
		chassis.remove_item(grid_pos)
		_refund_item(item)
		item.queue_free()
		item_removed.emit(item)
		_clear_demolish_highlight()
		return true

	# Remove floor if no items
	if cell.get("floor", false):
		var floor_node := _find_floor_mesh(chassis, grid_pos)
		cell.floor = false
		cell.floor_node = null
		chassis.floor_count -= 1
		if floor_node:
			floor_node.queue_free()
		for res_name in FLOOR_COST:
			Inventory.add_resource(res_name, int(ceil(FLOOR_COST[res_name] * 0.5)))
		item_removed.emit(floor_node)
		_clear_demolish_highlight()
		return true
	return false

func _refund_item(item: Node3D) -> void:
	if item.has_meta("buildable_id"):
		var bid: String = item.get_meta("buildable_id")
		if buildable_catalog.has(bid):
			var data: BuildableData = buildable_catalog[bid]
			for res_name in data.cost:
				Inventory.add_resource(res_name, int(ceil(data.cost[res_name] * 0.5)))

func hide_preview() -> void:
	if preview_instance and is_instance_valid(preview_instance) and preview_instance.is_inside_tree():
		preview_instance.visible = false
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
