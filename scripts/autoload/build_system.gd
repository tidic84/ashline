extends Node

signal build_mode_entered
signal build_mode_exited
signal item_placed(item: Node3D)
signal item_removed(item: Node3D)
signal buildable_selected(data: BuildableData)

enum BuildMode { OFF, CHASSIS, FLOOR, CEILING, ITEM, DEMOLISH }
const DEMOLISH_FLOOR_EDGE: int = -3

var mode: BuildMode = BuildMode.OFF
var is_building: bool = false
var current_buildable_data: BuildableData = null
var current_buildable: PackedScene = null
var preview_instance: Node3D = null
var batch_preview_instances: Array[Node3D] = []
var _batch_preview_scene: PackedScene = null
var preview_material_valid: StandardMaterial3D
var preview_material_invalid: StandardMaterial3D
var can_place: bool = false
var _preview_material_state: int = -1 # -1 unknown, 0 invalid, 1 valid
var preview_rotation: float = 0.0

var buildable_catalog: Dictionary = {}
var chassis_scene: PackedScene = null
var wagon_frame_scene: PackedScene = null
var floor_scene: PackedScene = null
var ceiling_scene: PackedScene = null

# Two-step chassis/wagon placement
var _first_bogie: TrainChassis = null
var _first_bogie_progress: float = 0.0
var _first_bogie_curve: Curve3D = null
var _first_bogie_rail_path: Node = null
var _second_bogie_preview: Node3D = null
var demolish_target: Node3D = null  # Node highlighted for demolition
var batch_demolish_targets: Array[Node3D] = []
var _wall_sfx_index: int = 0
var preview_material_demolish: StandardMaterial3D

# Edge snapping for walls
enum EdgeSide { NONE, NORTH, SOUTH, EAST, WEST }
var _last_edge: EdgeSide = EdgeSide.NONE
var _last_edge_grid: Vector3i = Vector3i.ZERO
var _last_item_preview_target: Node = null
var _last_item_preview_grid: Vector3i = Vector3i.ZERO
var _last_item_preview_buildable_id: String = ""
var _last_item_preview_rotation: float = 0.0
# Costs
const CHASSIS_COST: Dictionary = { "wood": 10, "metal": 15 }
const FLOOR_COST: Dictionary = { "wood": 3 }
const CEILING_COST: Dictionary = { "wood": 3 }

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
	ceiling_scene = floor_scene
	_load_buildables()
	item_placed.connect(_play_blueprint_anim)

func _play_blueprint_anim(node: Node3D) -> void:
	if node == null or not is_instance_valid(node):
		return
	BlueprintAnimator.animate(node)

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
			mode = BuildMode.CEILING
		BuildMode.CEILING:
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
		BuildMode.CEILING:
			_update_ceiling_preview(hit_point, hit_normal, target)
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
	var grid_pos: Vector3i = chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		hide_preview()
		return
	var world_pos: Vector3 = chassis.grid_to_world(grid_pos)
	preview_instance.visible = true
	preview_instance.global_position = world_pos
	preview_instance.global_basis = chassis.global_basis
	_set_preview_validity(chassis.can_place_floor(grid_pos) and Inventory.has_resources(FLOOR_COST) and _has_build_tool())

func _update_ceiling_preview(hit_point: Vector3, _hit_normal: Vector3, chassis: Node) -> void:
	if chassis == null or not chassis.has_method("get_ceiling_surface_local_y"):
		hide_preview()
		return
	if preview_instance == null and ceiling_scene:
		preview_instance = ceiling_scene.instantiate()
		preview_instance.set_meta("is_preview", true)
		_apply_material(preview_instance, preview_material_valid)
	if preview_instance == null:
		return
	if not preview_instance.is_inside_tree():
		get_tree().current_scene.add_child(preview_instance)
		_disable_preview_collision(preview_instance)
	# Caller projects onto the ceiling plane, so hit_point's level is the ceiling level.
	var ceiling_grid: Vector3i = chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(ceiling_grid) or ceiling_grid.z <= 0:
		hide_preview()
		return
	var world_pos: Vector3 = chassis.grid_to_world(ceiling_grid)
	preview_instance.visible = true
	preview_instance.global_position = world_pos
	preview_instance.global_basis = chassis.global_basis
	_set_preview_validity(chassis.can_place_floor(ceiling_grid) and Inventory.has_resources(CEILING_COST) and _has_build_tool())

func _update_item_preview(hit_point: Vector3, _hit_normal: Vector3, chassis: Node) -> void:
	if preview_instance == null:
		return
	if not preview_instance.is_inside_tree():
		get_tree().current_scene.add_child(preview_instance)
		_disable_preview_collision(preview_instance)
	var grid_pos: Vector3i = chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		_last_edge = EdgeSide.NONE
		hide_preview()
		return
	var is_edge_item: bool = _is_edge_category()
	var world_pos: Vector3
	var rot_y: float = preview_rotation

	if is_edge_item:
		_clear_item_preview_anchor()
		var edge: EdgeSide = _detect_edge_from_hit(chassis, hit_point, grid_pos)
		_last_edge = edge
		_last_edge_grid = grid_pos
		var edge_offset: Vector3 = _edge_offset(edge)
		var local_center: Vector3 = chassis.grid_to_local(grid_pos)
		local_center += edge_offset
		local_center.y = chassis.get_surface_local_y(grid_pos.z) + 0.05
		world_pos = chassis.to_global(local_center)
		# Auto-rotate wall to face the edge
		rot_y = _edge_rotation(edge) + preview_rotation
	else:
		_last_edge = EdgeSide.NONE
		grid_pos = _resolve_buildable_anchor(chassis, grid_pos, current_buildable_data, preview_rotation)
		_store_item_preview_anchor(chassis, grid_pos)
		world_pos = _get_item_world_position(chassis, grid_pos, _get_buildable_footprint(current_buildable_data, preview_rotation))

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
		_set_preview_validity(_can_place_buildable_item(chassis, grid_pos, current_buildable_data, preview_rotation) and has_cost and has_tool)


func show_batch_floor_preview(target: Node, grid_positions: Array[Vector3i]) -> void:
	if target == null or floor_scene == null or grid_positions.is_empty():
		clear_batch_preview()
		can_place = false
		return
	if preview_instance and is_instance_valid(preview_instance) and preview_instance.is_inside_tree():
		preview_instance.visible = false

	_prepare_batch_preview(floor_scene, grid_positions.size())
	var has_tool: bool = _has_build_tool()
	var has_batch_cost: bool = _has_batch_resources(FLOOR_COST, grid_positions.size())
	var floor_order: Array[Vector3i] = get_batch_floor_order(target, grid_positions)
	var valid_floor_set: Dictionary = _positions_to_set(floor_order)
	var all_valid: bool = has_tool and has_batch_cost and floor_order.size() == grid_positions.size()
	for index in range(grid_positions.size()):
		var preview: Node3D = batch_preview_instances[index]
		var grid_pos: Vector3i = grid_positions[index]
		var cell_valid: bool = valid_floor_set.has(grid_pos)
		preview.visible = true
		preview.global_position = target.grid_to_world(grid_pos)
		preview.global_basis = target.global_basis
		_apply_material(preview, preview_material_valid if cell_valid and has_tool and has_batch_cost else preview_material_invalid)
	can_place = all_valid


func get_batch_floor_order(target: Node, grid_positions: Array[Vector3i]) -> Array[Vector3i]:
	var ordered: Array[Vector3i] = []
	if target == null or grid_positions.is_empty():
		return ordered

	var remaining: Array[Vector3i] = []
	var seen: Dictionary = {}
	for grid_pos in grid_positions:
		if seen.has(grid_pos):
			continue
		seen[grid_pos] = true
		if not _is_batch_floor_empty_cell(target, grid_pos):
			return ordered
		remaining.append(grid_pos)

	var virtual_floors: Dictionary = {}
	while not remaining.is_empty():
		var placed_this_pass: bool = false
		for index in range(remaining.size() - 1, -1, -1):
			var grid_pos: Vector3i = remaining[index]
			if _can_place_floor_with_virtual_batch(target, grid_pos, virtual_floors):
				ordered.append(grid_pos)
				virtual_floors[grid_pos] = true
				remaining.remove_at(index)
				placed_this_pass = true
		if not placed_this_pass:
			ordered.clear()
			return ordered
	return ordered


func _is_batch_floor_empty_cell(target: Node, grid_pos: Vector3i) -> bool:
	if target == null or not target.has_method("is_grid_in_bounds"):
		return false
	if not target.is_grid_in_bounds(grid_pos):
		return false
	if target.has_method("has_floor_at") and target.has_floor_at(grid_pos):
		return false
	return true


func _can_place_floor_with_virtual_batch(target: Node, grid_pos: Vector3i, virtual_floors: Dictionary) -> bool:
	if target == null or not target.has_method("can_place_floor"):
		return false
	if target.can_place_floor(grid_pos):
		return true
	var neighbors: Array[Vector3i] = [
		Vector3i(grid_pos.x + 1, grid_pos.y, grid_pos.z),
		Vector3i(grid_pos.x - 1, grid_pos.y, grid_pos.z),
		Vector3i(grid_pos.x, grid_pos.y + 1, grid_pos.z),
		Vector3i(grid_pos.x, grid_pos.y - 1, grid_pos.z),
	]
	for neighbor in neighbors:
		if virtual_floors.has(neighbor):
			return true
	# Upper-level first tile needs support directly below (real or virtual).
	if grid_pos.z > 0:
		var below := Vector3i(grid_pos.x, grid_pos.y, grid_pos.z - 1)
		if virtual_floors.has(below):
			return true
	return false


func show_batch_ceiling_preview(target: Node, grid_positions: Array[Vector3i]) -> void:
	if target == null or ceiling_scene == null or grid_positions.is_empty():
		clear_batch_preview()
		can_place = false
		return
	if preview_instance and is_instance_valid(preview_instance) and preview_instance.is_inside_tree():
		preview_instance.visible = false

	# Caller supplies ceiling-level positions (z >= 1) already.
	_prepare_batch_preview(ceiling_scene, grid_positions.size())
	var has_tool: bool = _has_build_tool()
	var has_batch_cost: bool = _has_batch_resources(CEILING_COST, grid_positions.size())
	var ceiling_order: Array[Vector3i] = get_batch_floor_order(target, grid_positions)
	var valid_ceiling_set: Dictionary = _positions_to_set(ceiling_order)
	var all_valid: bool = has_tool and has_batch_cost and ceiling_order.size() == grid_positions.size()
	for index in range(grid_positions.size()):
		var preview: Node3D = batch_preview_instances[index]
		var grid_pos: Vector3i = grid_positions[index]
		var cell_valid: bool = valid_ceiling_set.has(grid_pos)
		preview.visible = true
		preview.global_position = target.grid_to_world(grid_pos)
		preview.global_basis = target.global_basis
		_apply_material(preview, preview_material_valid if cell_valid and has_tool and has_batch_cost else preview_material_invalid)
	can_place = all_valid


func get_batch_ceiling_order(target: Node, grid_positions: Array[Vector3i]) -> Array[Vector3i]:
	# Ceiling-level positions use the same ordering rules as floors.
	return get_batch_floor_order(target, grid_positions)


func _positions_to_set(positions: Array[Vector3i]) -> Dictionary:
	var position_set: Dictionary = {}
	for grid_pos in positions:
		position_set[grid_pos] = true
	return position_set


func show_batch_wall_preview(target: Node, grid_positions: Array[Vector3i], edge: int) -> void:
	if target == null or current_buildable == null or grid_positions.is_empty() or edge == EdgeSide.NONE:
		clear_batch_preview()
		can_place = false
		return
	if preview_instance and is_instance_valid(preview_instance) and preview_instance.is_inside_tree():
		preview_instance.visible = false

	_prepare_batch_preview(current_buildable, grid_positions.size())
	var cost: Dictionary = current_buildable_data.cost if current_buildable_data else {}
	var has_tool: bool = _has_build_tool()
	var has_batch_cost: bool = cost.is_empty() or _has_batch_resources(cost, grid_positions.size())
	var all_valid: bool = has_tool and has_batch_cost
	var rot_y: float = _edge_rotation(edge) + preview_rotation
	for index in range(grid_positions.size()):
		var preview: Node3D = batch_preview_instances[index]
		var grid_pos: Vector3i = grid_positions[index]
		var cell_valid: bool = target.is_grid_in_bounds(grid_pos) and target.can_place_edge(grid_pos, edge)
		all_valid = all_valid and cell_valid
		var local_pos: Vector3 = target.grid_to_local(grid_pos)
		local_pos.y = target.get_surface_local_y(grid_pos.z) + 0.05
		local_pos += _edge_offset(edge)
		var original_scale: Vector3 = preview.get_meta("original_scale", preview.scale)
		preview.visible = true
		preview.global_position = target.to_global(local_pos)
		preview.global_basis = target.global_basis.orthonormalized() * Basis(Vector3.UP, rot_y)
		preview.scale = original_scale
		_apply_material(preview, preview_material_valid if cell_valid and has_tool and has_batch_cost else preview_material_invalid)
	can_place = all_valid


func clear_batch_preview() -> void:
	for preview in batch_preview_instances:
		if preview and is_instance_valid(preview) and preview.is_inside_tree():
			preview.queue_free()
	batch_preview_instances.clear()
	_batch_preview_scene = null
	_clear_batch_demolish_highlight()


func _prepare_batch_preview(scene: PackedScene, count: int) -> void:
	if scene == null:
		clear_batch_preview()
		return
	if _batch_preview_scene != scene:
		clear_batch_preview()
		_batch_preview_scene = scene
	while batch_preview_instances.size() > count:
		var extra: Node3D = batch_preview_instances.pop_back()
		if extra and is_instance_valid(extra) and extra.is_inside_tree():
			extra.queue_free()
	while batch_preview_instances.size() < count:
		var preview: Node3D = scene.instantiate() as Node3D
		if preview == null:
			break
		preview.set_meta("is_preview", true)
		preview.set_meta("original_scale", preview.scale)
		_apply_material(preview, preview_material_valid)
		if get_tree().current_scene != null:
			get_tree().current_scene.add_child(preview)
			_disable_preview_collision(preview)
		batch_preview_instances.append(preview)


func _has_batch_resources(cost: Dictionary, count: int) -> bool:
	if cost.is_empty():
		return true
	if count <= 0:
		return false
	var total_cost: Dictionary = {}
	for item_id in cost:
		total_cost[item_id] = int(cost[item_id]) * count
	return Inventory.has_resources(total_cost)


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
	instance.set_meta("owner_peer_id", peer_id)
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
	item_placed.emit(instance)
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
	frame.set_meta("owner_peer_id", peer_id)

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
	front.set_meta("owner_peer_id", peer_id)
	rear.set_meta("owner_peer_id", peer_id)
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
			rear_progress,
			peer_id
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
	# A first bogie is already paid and placed in the world. Changing modes
	# should only stop the two-step coupling flow, not delete the chassis.
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
	var grid_pos: Vector3i = chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		return null
	if not chassis.can_place_floor(grid_pos):
		return null
	if not _spend_resources_for_peer(peer_id, FLOOR_COST):
		return null
	var instance := floor_scene.instantiate() as Node3D
	chassis.add_child(instance)
	WorldSync.register_entity(instance)
	instance.position = chassis.grid_to_local(grid_pos)
	instance.set_meta("grid_pos_x", grid_pos.x)
	instance.set_meta("grid_pos_y", grid_pos.y)
	instance.set_meta("grid_pos_z", grid_pos.z)
	chassis.place_floor(grid_pos, instance)
	item_placed.emit(instance)
	if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_place_floor(WorldSync.get_net_id(chassis), WorldSync.get_net_id(instance), grid_pos)
	return instance

func try_place_ceiling(hit_point: Vector3, chassis: Node, actor_peer_id: int = -1, replicate: bool = true) -> Node3D:
	# Caller projects onto the ceiling plane, so hit_point already resolves to the ceiling cell (z >= 1).
	var grid_pos: Vector3i = chassis.get_grid_position(hit_point)
	if WorldSync.should_request_host():
		WorldSync.request_place_ceiling(WorldSync.get_net_id(chassis), grid_pos)
		return null
	var peer_id := _resolve_actor_peer_id(actor_peer_id)
	if not _has_build_tool_for_peer(peer_id):
		return null
	if grid_pos.z <= 0:
		return null
	if not chassis.is_grid_in_bounds(grid_pos):
		return null
	if not chassis.can_place_floor(grid_pos):
		return null
	if not _spend_resources_for_peer(peer_id, CEILING_COST):
		return null
	var instance := ceiling_scene.instantiate() as Node3D
	instance.set_meta("is_ceiling", true)
	chassis.add_child(instance)
	WorldSync.register_entity(instance)
	instance.position = chassis.grid_to_local(grid_pos)
	instance.set_meta("grid_pos_x", grid_pos.x)
	instance.set_meta("grid_pos_y", grid_pos.y)
	instance.set_meta("grid_pos_z", grid_pos.z)
	chassis.place_floor(grid_pos, instance)
	item_placed.emit(instance)
	if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_place_ceiling(WorldSync.get_net_id(chassis), WorldSync.get_net_id(instance), grid_pos)
	return instance

func try_place_item(hit_point: Vector3, chassis: Node, actor_peer_id: int = -1, replicate: bool = true) -> Node3D:
	var grid_pos: Vector3i = chassis.get_grid_position(hit_point)
	var requested_edge: EdgeSide = EdgeSide.NONE
	if current_buildable_data != null and _is_edge_category():
		requested_edge = _detect_edge_from_hit(chassis, hit_point, grid_pos)
	elif current_buildable_data != null:
		grid_pos = _get_cached_or_resolved_buildable_anchor(chassis, grid_pos, current_buildable_data, preview_rotation)
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
		if not _can_place_buildable_item(chassis, grid_pos, current_buildable_data, preview_rotation):
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
	local_pos.y = chassis.get_surface_local_y(grid_pos.z) + 0.05

	if is_edge_item and edge != EdgeSide.NONE:
		local_pos += _edge_offset(edge)
		instance.rotation.y = _edge_rotation(edge) + preview_rotation
		instance.set_meta("edge_side", edge)
		instance.set_meta("grid_pos_x", grid_pos.x)
		instance.set_meta("grid_pos_y", grid_pos.y)
		instance.set_meta("grid_pos_z", grid_pos.z)
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

func server_try_place_floor(peer_id: int, target_net_id: int, grid_pos: Vector3i) -> Node3D:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("grid_to_world") or not target.has_method("can_place_floor"):
		return null
	var hit_point: Vector3 = target.grid_to_world(grid_pos)
	return try_place_floor(hit_point, target, peer_id, true)

func server_try_place_ceiling(peer_id: int, target_net_id: int, grid_pos: Vector3i) -> Node3D:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("grid_to_world") or not target.has_method("can_place_floor"):
		return null
	# Client already resolved to the ceiling cell (z >= 1).
	var hit_point: Vector3 = target.grid_to_world(grid_pos)
	return try_place_ceiling(hit_point, target, peer_id, true)

func server_try_place_item(peer_id: int, target_net_id: int, buildable_id: String, grid_pos: Vector3i, rotation_y: float, edge: int) -> Node3D:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("is_grid_in_bounds"):
		return null
	if not target.has_method("can_place_item") or not target.has_method("can_place_edge"):
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
		if not _can_place_buildable_item(target, grid_pos, data, rotation_y):
			return null
	if not _spend_resources_for_peer(peer_id, data.cost):
		return null
	var placed := _instantiate_buildable_on_target(target, data, grid_pos, rotation_y, edge)
	if placed != null:
		WorldSync.replicate_place_item(target_net_id, WorldSync.get_net_id(placed), buildable_id, grid_pos, rotation_y, edge)
	return placed

func apply_network_floor(target_net_id: int, floor_net_id: int, grid_pos: Vector3i) -> Node3D:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("can_place_floor"):
		return null
	if not target.can_place_floor(grid_pos):
		return null
	var instance := floor_scene.instantiate() as Node3D
	target.add_child(instance)
	WorldSync.register_entity(instance, floor_net_id)
	instance.position = target.grid_to_local(grid_pos)
	instance.set_meta("grid_pos_x", grid_pos.x)
	instance.set_meta("grid_pos_y", grid_pos.y)
	instance.set_meta("grid_pos_z", grid_pos.z)
	target.place_floor(grid_pos, instance)
	item_placed.emit(instance)
	return instance

func apply_network_ceiling(target_net_id: int, ceiling_net_id: int, grid_pos: Vector3i) -> Node3D:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("can_place_floor"):
		return null
	# Ceiling on the wire is the final floor cell (level >= 1). Apply it as a floor.
	if not target.can_place_floor(grid_pos):
		return null
	var instance := ceiling_scene.instantiate() as Node3D
	instance.set_meta("is_ceiling", true)
	target.add_child(instance)
	WorldSync.register_entity(instance, ceiling_net_id)
	instance.position = target.grid_to_local(grid_pos)
	instance.set_meta("grid_pos_x", grid_pos.x)
	instance.set_meta("grid_pos_y", grid_pos.y)
	instance.set_meta("grid_pos_z", grid_pos.z)
	target.place_floor(grid_pos, instance)
	item_placed.emit(instance)
	return instance

func apply_network_item(target_net_id: int, item_net_id: int, buildable_id: String, grid_pos: Vector3i, rotation_y: float, edge: int) -> Node3D:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not buildable_catalog.has(buildable_id):
		return null
	if not target.has_method("can_place_item") or not target.has_method("can_place_edge"):
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
		if not _can_place_buildable_item(target, grid_pos, data, rotation_y):
			return null
	return _instantiate_buildable_on_target(target, data, grid_pos, rotation_y, edge, item_net_id)

func _instantiate_buildable_on_target(target: Node, data: BuildableData, grid_pos: Vector3i, rotation_y: float, edge: int, net_id: int = 0) -> Node3D:
	if data == null or data.scene == null:
		return null
	if not target.has_method("grid_to_local") or not target.has_method("get_surface_local_y"):
		return null
	var instance := data.scene.instantiate() as Node3D
	instance.set_meta("buildable_id", data.id)
	target.add_child(instance)
	WorldSync.register_entity(instance, net_id)
	var is_edge_item: bool = data.category in [
		BuildableData.Category.WALL,
		BuildableData.Category.BARRICADE,
	]
	if is_edge_item and edge != EdgeSide.NONE:
		var local_pos: Vector3 = target.grid_to_local(grid_pos)
		local_pos.y = target.get_surface_local_y(grid_pos.z) + 0.05
		local_pos += _edge_offset(edge)
		instance.rotation.y = _edge_rotation(edge) + rotation_y
		instance.set_meta("edge_side", edge)
		instance.set_meta("grid_pos_x", grid_pos.x)
		instance.set_meta("grid_pos_y", grid_pos.y)
		instance.set_meta("grid_pos_z", grid_pos.z)
		instance.position = local_pos
		target.place_edge_item(grid_pos, edge, instance)
	else:
		var footprint_size: Vector2i = _get_buildable_footprint(data, rotation_y)
		instance.rotation.y = rotation_y
		instance.position = _get_item_local_position(target, grid_pos, footprint_size)
		instance.set_meta("grid_pos_x", grid_pos.x)
		instance.set_meta("grid_pos_y", grid_pos.y)
		instance.set_meta("grid_pos_z", grid_pos.z)
		instance.set_meta("footprint_w", footprint_size.x)
		instance.set_meta("footprint_h", footprint_size.y)
		if target.has_method("place_item_footprint"):
			target.place_item_footprint(grid_pos, footprint_size, instance)
		else:
			target.place_item(grid_pos, instance)
	item_placed.emit(instance)
	return instance

# --- Edge snapping (walls/barricades snap to cell edges) ---

func _get_buildable_footprint(data: BuildableData, rotation_y: float) -> Vector2i:
	if data == null:
		return Vector2i(1, 1)
	var footprint_size: Vector2i = data.footprint_size
	footprint_size.x = maxi(1, footprint_size.x)
	footprint_size.y = maxi(1, footprint_size.y)
	if data.can_rotate and _is_quarter_turn_sideways(rotation_y):
		return Vector2i(footprint_size.y, footprint_size.x)
	return footprint_size


func _is_quarter_turn_sideways(rotation_y: float) -> bool:
	var turns: int = int(round(rotation_y / (PI / 2.0)))
	return absi(turns) % 2 == 1


func _get_footprint_cells(grid_pos: Vector3i, footprint_size: Vector2i) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var width: int = maxi(1, footprint_size.x)
	var length: int = maxi(1, footprint_size.y)
	for z in range(length):
		for x in range(width):
			cells.append(Vector3i(grid_pos.x + x, grid_pos.y + z, grid_pos.z))
	return cells


func _resolve_buildable_anchor(target: Node, grid_pos: Vector3i, data: BuildableData, rotation_y: float) -> Vector3i:
	var footprint_size: Vector2i = _get_buildable_footprint(data, rotation_y)
	if footprint_size == Vector2i(1, 1) or _can_place_buildable_item(target, grid_pos, data, rotation_y):
		return grid_pos
	for z in range(footprint_size.y):
		for x in range(footprint_size.x):
			var candidate: Vector3i = Vector3i(grid_pos.x - x, grid_pos.y - z, grid_pos.z)
			if _can_place_buildable_item(target, candidate, data, rotation_y):
				return candidate
	return grid_pos


func _get_cached_or_resolved_buildable_anchor(target: Node, grid_pos: Vector3i, data: BuildableData, rotation_y: float) -> Vector3i:
	if _has_matching_item_preview_anchor(target, data, rotation_y):
		if _can_place_buildable_item(target, _last_item_preview_grid, data, rotation_y):
			return _last_item_preview_grid
	return _resolve_buildable_anchor(target, grid_pos, data, rotation_y)


func _store_item_preview_anchor(target: Node, grid_pos: Vector3i) -> void:
	_last_item_preview_target = target
	_last_item_preview_grid = grid_pos
	_last_item_preview_buildable_id = current_buildable_data.id if current_buildable_data else ""
	_last_item_preview_rotation = preview_rotation


func _clear_item_preview_anchor() -> void:
	_last_item_preview_target = null
	_last_item_preview_grid = Vector3i.ZERO
	_last_item_preview_buildable_id = ""
	_last_item_preview_rotation = 0.0


func _has_matching_item_preview_anchor(target: Node, data: BuildableData, rotation_y: float) -> bool:
	if _last_item_preview_target == null or not is_instance_valid(_last_item_preview_target):
		return false
	if _last_item_preview_target != target:
		return false
	if data == null or _last_item_preview_buildable_id != data.id:
		return false
	return is_equal_approx(_last_item_preview_rotation, rotation_y)


func _get_item_local_position(target: Node, grid_pos: Vector3i, footprint_size: Vector2i) -> Vector3:
	var cells: Array[Vector3i] = _get_footprint_cells(grid_pos, footprint_size)
	var local_pos: Vector3 = Vector3.ZERO
	for cell_pos in cells:
		local_pos += target.grid_to_local(cell_pos)
	local_pos /= float(cells.size())
	local_pos.y = target.get_surface_local_y(grid_pos.z) + 0.05
	return local_pos


func _get_item_world_position(target: Node, grid_pos: Vector3i, footprint_size: Vector2i) -> Vector3:
	return target.to_global(_get_item_local_position(target, grid_pos, footprint_size))


func _can_place_buildable_item(target: Node, grid_pos: Vector3i, data: BuildableData, rotation_y: float) -> bool:
	if target == null or data == null:
		return false
	var footprint_size: Vector2i = _get_buildable_footprint(data, rotation_y)
	if target.has_method("can_place_item_footprint"):
		return target.can_place_item_footprint(grid_pos, footprint_size)
	if footprint_size != Vector2i(1, 1):
		return false
	return target.can_place_item(grid_pos)

func _is_edge_category() -> bool:
	if current_buildable_data == null:
		return false
	return current_buildable_data.category in [
		BuildableData.Category.WALL,
		BuildableData.Category.BARRICADE,
	]

func _detect_edge_from_hit(chassis: Node, hit_point: Vector3, grid_pos: Vector3i) -> EdgeSide:
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
	var grid_pos: Vector3i = chassis.get_grid_position(hit_point)
	if not chassis.is_grid_in_bounds(grid_pos):
		_clear_demolish_highlight()
		can_place = false
		return
	if not chassis.grid_cells.has(grid_pos):
		_clear_demolish_highlight()
		can_place = false
		return
	var cell: Dictionary = chassis.grid_cells[grid_pos]
	# Edge item closest > center item > floor (level is baked into grid_pos.z).
	var target: Node3D = null
	if cell.has("edges"):
		var best_dist: float = INF
		for edge_key in cell.edges:
			var edge_item: Node3D = cell.edges[edge_key]
			if edge_item != null and is_instance_valid(edge_item):
				var d: float = edge_item.global_position.distance_to(hit_point)
				if d < best_dist:
					best_dist = d
					target = edge_item
	if target == null and cell.get("item") != null and is_instance_valid(cell.item):
		target = cell.item
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

func get_demolish_context_at(chassis: Node, hit_point: Vector3) -> Dictionary:
	if chassis == null or not chassis.has_method("get_grid_position"):
		return {}
	var grid_pos: Vector2i = chassis.get_grid_position(hit_point)
	if not _is_grid_cell_available(chassis, grid_pos):
		return {}
	var edge: int = _get_closest_demolishable_edge(chassis, grid_pos, hit_point)
	if edge != EdgeSide.NONE:
		return {
			"target": chassis,
			"grid_pos": grid_pos,
			"edge": edge,
			"kind": "wall",
		}
	if _is_demolishable_floor_at(chassis, grid_pos):
		return {
			"target": chassis,
			"grid_pos": grid_pos,
			"edge": DEMOLISH_FLOOR_EDGE,
			"kind": "floor",
		}
	return {}


func show_batch_demolish_preview(chassis: Node, entries: Array[Dictionary]) -> void:
	_clear_preview()
	_clear_demolish_highlight()
	_clear_batch_demolish_highlight()
	if chassis == null or entries.is_empty():
		can_place = false
		return

	var seen_nodes: Dictionary = {}
	for entry in entries:
		var grid_pos: Vector2i = entry.get("grid_pos", Vector2i.ZERO)
		var edge: int = int(entry.get("edge", DEMOLISH_FLOOR_EDGE))
		var target: Node3D = _get_demolish_node_for_entry(chassis, grid_pos, edge)
		if target == null or not is_instance_valid(target):
			continue
		var target_id: int = target.get_instance_id()
		if seen_nodes.has(target_id):
			continue
		seen_nodes[target_id] = true
		batch_demolish_targets.append(target)
		_apply_temp_material(target, preview_material_demolish)
	can_place = not batch_demolish_targets.is_empty()


func try_demolish_entry(chassis: Node, grid_pos: Vector2i, edge: int, actor_peer_id: int = -1, replicate: bool = true, refund: bool = true) -> bool:
	if edge == DEMOLISH_FLOOR_EDGE:
		return try_demolish_floor_at(chassis, grid_pos, actor_peer_id, replicate, refund)
	return try_demolish_edge_at(chassis, grid_pos, edge, actor_peer_id, replicate, refund)


func try_demolish_floor_at(chassis: Node, grid_pos: Vector2i, actor_peer_id: int = -1, replicate: bool = true, refund: bool = true) -> bool:
	if WorldSync.should_request_host():
		WorldSync.request_demolish(WorldSync.get_net_id(chassis), grid_pos, DEMOLISH_FLOOR_EDGE)
		return false
	if not _is_demolishable_floor_at(chassis, grid_pos):
		return false
	var peer_id: int = _resolve_actor_peer_id(actor_peer_id)
	var cell: Dictionary = chassis.grid_cells[grid_pos]
	var floor_node: Node3D = _find_floor_mesh(chassis, grid_pos)
	cell.floor = false
	cell.floor_node = null
	chassis.floor_count -= 1
	if floor_node != null and is_instance_valid(floor_node):
		floor_node.queue_free()
	if refund:
		for res_name in FLOOR_COST:
			_refund_resource_for_peer(peer_id, res_name, int(ceil(FLOOR_COST[res_name] * 0.5)))
	item_removed.emit(floor_node)
	_clear_demolish_highlight()
	_clear_batch_demolish_highlight()
	if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_demolish(WorldSync.get_net_id(chassis), grid_pos, DEMOLISH_FLOOR_EDGE)
	return true


func try_demolish_edge_at(chassis: Node, grid_pos: Vector2i, edge: int, actor_peer_id: int = -1, replicate: bool = true, refund: bool = true) -> bool:
	if WorldSync.should_request_host():
		WorldSync.request_demolish(WorldSync.get_net_id(chassis), grid_pos, edge)
		return false
	if edge == EdgeSide.NONE or not _is_grid_cell_available(chassis, grid_pos):
		return false
	var edge_item: Node3D = _get_edge_item_at(chassis, grid_pos, edge)
	if edge_item == null or not is_instance_valid(edge_item):
		return false
	var peer_id: int = _resolve_actor_peer_id(actor_peer_id)
	chassis.remove_edge_item(grid_pos, edge)
	if refund:
		_refund_item(edge_item, peer_id)
	edge_item.queue_free()
	item_removed.emit(edge_item)
	_clear_demolish_highlight()
	_clear_batch_demolish_highlight()
	if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_demolish(WorldSync.get_net_id(chassis), grid_pos, edge)
	return true


func update_train_demolish_preview(part: Node) -> void:
	_clear_preview()
	var target := _get_train_demolish_root(part)
	if target == null or not is_instance_valid(target) or not (target is Node3D):
		_clear_demolish_highlight()
		can_place = false
		return
	var target_3d := target as Node3D
	if demolish_target == target_3d:
		can_place = true
		return
	_clear_demolish_highlight()
	demolish_target = target_3d
	_apply_temp_material(demolish_target, preview_material_demolish)
	can_place = true

func _clear_demolish_highlight() -> void:
	if demolish_target and is_instance_valid(demolish_target):
		_restore_temp_material(demolish_target)
	demolish_target = null

func _clear_batch_demolish_highlight() -> void:
	for target in batch_demolish_targets:
		if target != null and is_instance_valid(target):
			_restore_temp_material(target)
	batch_demolish_targets.clear()

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

func _find_floor_mesh(chassis: Node, grid_pos: Vector3i) -> Node3D:
	return chassis.get_floor_node(grid_pos)

func _is_grid_cell_available(chassis: Node, grid_pos: Vector2i) -> bool:
	if chassis == null or not chassis.has_method("is_grid_in_bounds"):
		return false
	if not (chassis is TrainChassis or chassis is WagonFrame):
		return false
	if not chassis.is_grid_in_bounds(grid_pos):
		return false
	return chassis.grid_cells.has(grid_pos)


func _get_closest_demolishable_edge(chassis: Node, grid_pos: Vector2i, hit_point: Vector3) -> int:
	if not _is_grid_cell_available(chassis, grid_pos):
		return EdgeSide.NONE
	var cell: Dictionary = chassis.grid_cells[grid_pos]
	if not cell.has("edges"):
		return EdgeSide.NONE
	var best_dist: float = INF
	var best_edge: int = EdgeSide.NONE
	for edge_key in cell.edges:
		var edge_item: Node3D = cell.edges[edge_key]
		if edge_item == null or not is_instance_valid(edge_item):
			continue
		var distance: float = edge_item.global_position.distance_to(hit_point)
		if distance < best_dist:
			best_dist = distance
			best_edge = int(edge_key)
	if best_dist < 1.5:
		return best_edge
	return EdgeSide.NONE


func _get_edge_item_at(chassis: Node, grid_pos: Vector2i, edge: int) -> Node3D:
	if not _is_grid_cell_available(chassis, grid_pos):
		return null
	var cell: Dictionary = chassis.grid_cells[grid_pos]
	if not cell.has("edges") or not cell.edges.has(edge):
		return null
	var edge_item: Node3D = cell.edges[edge]
	if edge_item != null and is_instance_valid(edge_item):
		return edge_item
	return null


func _cell_has_valid_edge_item(cell: Dictionary) -> bool:
	if not cell.has("edges"):
		return false
	for edge_key in cell.edges:
		var edge_item: Node3D = cell.edges[edge_key]
		if edge_item != null and is_instance_valid(edge_item):
			return true
	return false


func _is_demolishable_floor_at(chassis: Node, grid_pos: Vector2i) -> bool:
	if not _is_grid_cell_available(chassis, grid_pos):
		return false
	var cell: Dictionary = chassis.grid_cells[grid_pos]
	if not bool(cell.get("floor", false)):
		return false
	if cell.get("item") != null and is_instance_valid(cell.item):
		return false
	return not _cell_has_valid_edge_item(cell)


func _get_demolish_node_for_entry(chassis: Node, grid_pos: Vector2i, edge: int) -> Node3D:
	if edge == DEMOLISH_FLOOR_EDGE:
		if not _is_demolishable_floor_at(chassis, grid_pos):
			return null
		return _find_floor_mesh(chassis, grid_pos)
	return _get_edge_item_at(chassis, grid_pos, edge)


func try_demolish(hit_point: Vector3, chassis: Node, actor_peer_id: int = -1, replicate: bool = true, refund: bool = true) -> bool:
	if WorldSync.should_request_host():
		WorldSync.request_demolish(WorldSync.get_net_id(chassis), chassis.get_grid_position(hit_point), -1)
		return false
	var peer_id := _resolve_actor_peer_id(actor_peer_id)
	var grid_pos: Vector3i = chassis.get_grid_position(hit_point)
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

	# Remove floor (ground or upper level — same op)
	if cell.get("floor", false):
		var floor_node := _find_floor_mesh(chassis, grid_pos)
		chassis.remove_floor(grid_pos)
		if floor_node:
			floor_node.queue_free()
		if refund:
			# Upper-level floors were built as ceilings at the detected-lower level.
			var cost_ref: Dictionary = CEILING_COST if grid_pos.z > 0 else FLOOR_COST
			for res_name in cost_ref:
				_refund_resource_for_peer(peer_id, res_name, int(ceil(cost_ref[res_name] * 0.5)))
		item_removed.emit(floor_node)
		_clear_demolish_highlight()
		if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
			WorldSync.replicate_demolish(WorldSync.get_net_id(chassis), grid_pos, -1)
		return true

	return false

func try_demolish_train_part(part: Node, actor_peer_id: int = -1, replicate: bool = true, refund: bool = true) -> bool:
	if part == null or not is_instance_valid(part):
		return false
	if WorldSync.should_request_host():
		WorldSync.request_demolish(WorldSync.get_net_id(part), Vector3i.ZERO, -2)
		return false
	var target := _get_train_demolish_root(part)
	if target == null:
		return false
	var peer_id := _resolve_actor_peer_id(actor_peer_id)
	if refund:
		_refund_train_chassis_parts(target, peer_id)
	var main_net_id := WorldSync.get_net_id(target)
	_unregister_train_tree(target)
	if target == _first_bogie or (target is WagonFrame and _first_bogie != null and _first_bogie.get_parent() == target):
		_first_bogie = null
		_first_bogie_progress = 0.0
		_first_bogie_curve = null
		_first_bogie_rail_path = null
	if target is WagonFrame:
		(target as WagonFrame)._stop_train_move_sound()
	target.queue_free()
	item_removed.emit(target)
	_clear_demolish_highlight()
	if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server() and main_net_id > 0:
		WorldSync.replicate_despawn(main_net_id)
	return true

func _get_train_demolish_root(part: Node) -> Node:
	if part is WagonFrame:
		return part
	if part is TrainChassis:
		var parent := part.get_parent()
		if parent is WagonFrame:
			return parent
		return part
	var current := part
	while current != null:
		if current is WagonFrame:
			return current
		if current is TrainChassis:
			var chassis_parent := current.get_parent()
			if chassis_parent is WagonFrame:
				return chassis_parent
			return current
		current = current.get_parent()
	return null

func _refund_train_chassis_parts(target: Node, peer_id: int) -> void:
	var chassis_count := 0
	if target is TrainChassis:
		chassis_count = 1
	else:
		for child in target.get_children():
			if child is TrainChassis:
				chassis_count += 1
	for i in range(chassis_count):
		for res_name in CHASSIS_COST:
			_refund_resource_for_peer(peer_id, res_name, int(ceil(CHASSIS_COST[res_name] * 0.5)))

func _unregister_train_tree(root: Node) -> void:
	if root.has_meta(WorldSync.NET_ID_META):
		WorldSync.unregister_entity(int(root.get_meta(WorldSync.NET_ID_META)))
	for child in root.get_children():
		_unregister_train_tree(child)

func server_try_demolish(peer_id: int, target_net_id: int, grid_pos: Vector3i, _edge: int) -> bool:
	var target := WorldSync.get_entity(target_net_id)
	if _edge == -2:
		if target == null:
			return false
		return try_demolish_train_part(target, peer_id, true, true)
	if target == null or not target.has_method("grid_to_world"):
		return false
	if _edge == DEMOLISH_FLOOR_EDGE:
		return try_demolish_floor_at(target, grid_pos, peer_id, true, true)
	if _edge != -1:
		return try_demolish_edge_at(target, grid_pos, _edge, peer_id, true, true)
	return try_demolish(target.grid_to_world(grid_pos), target, peer_id, true, true)

func apply_network_demolish(target_net_id: int, grid_pos: Vector3i, edge: int) -> bool:
	var target := WorldSync.get_entity(target_net_id)
	if target == null or not target.has_method("grid_to_world"):
		return false
	if edge == DEMOLISH_FLOOR_EDGE:
		return try_demolish_floor_at(target, Vector2i(grid_pos.x, grid_pos.y), -1, false, false)
	if edge != -1:
		return try_demolish_edge_at(target, Vector2i(grid_pos.x, grid_pos.y), edge, -1, false, false)
	var hit_point: Vector3 = target.grid_to_world(grid_pos)
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
	clear_batch_preview()
	_clear_item_preview_anchor()
	if _second_bogie_preview and is_instance_valid(_second_bogie_preview) and _second_bogie_preview.is_inside_tree():
		_second_bogie_preview.visible = false
	_clear_demolish_highlight()
	can_place = false
	_preview_material_state = -1

func _clear_preview() -> void:
	clear_batch_preview()
	_clear_item_preview_anchor()
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
		BuildMode.CEILING: return "Ceiling"
		BuildMode.ITEM:
			if current_buildable_data:
				return current_buildable_data.display_name
			return "Item"
		BuildMode.DEMOLISH: return "Demolish"
	return ""
