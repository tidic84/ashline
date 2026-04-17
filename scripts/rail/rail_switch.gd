extends StaticBody3D
class_name RailSwitch

## Place at a junction point. Links to a RailPath and an endpoint (0=start, 1=end).
## Interacting cycles through available connected routes.

@export var rail_path: NodePath
@export_enum("Start:0", "End:1") var endpoint: int = 1
@export var switch_cooldown: float = 0.4
@export var auto_place_next_to_junction: bool = true
@export_range(0.1, 10.0, 0.1) var junction_side_offset: float = 2.5
@export var snap_to_ground: bool = true
@export_range(-5.0, 5.0, 0.05) var junction_vertical_offset: float = 0.0
@export_range(0.0, 6.0, 0.05) var hologram_height: float = 1.2
@export_range(0.5, 6.0, 0.05) var hologram_min_length: float = 0.95
@export_range(0.5, 8.0, 0.05) var hologram_max_length: float = 1.8
@export var hologram_requires_hover: bool = true

const LEVER_TILT_DEG: float = 12.0
const LEVER_TWEEN_TIME: float = 0.12
const GROUND_RAY_HEIGHT: float = 40.0
const GROUND_RAY_DEPTH: float = 120.0
const INDICATOR_REFRESH_INTERVAL: float = 0.15
const HOVER_RELEASE_GRACE: float = 0.2
const SWITCH_INDICATOR_HOLD: float = 0.7
const INDICATOR_LEFT_ICON: Texture2D = preload("res://assets/ui/icons/rail_switch_arrow_left.png")
const INDICATOR_RIGHT_ICON: Texture2D = preload("res://assets/ui/icons/rail_switch_arrow_right.png")

var _path_node: Node = null
var _can_switch: bool = true
var _lever_tween: Tween = null
var _hovered: bool = false
var _visual_bottom_local_y: float = 0.0
var _indicator_refresh_accum: float = 0.0
var _indicator_visibility_hold: float = 0.0

func _get_lever_node() -> Node3D:
	return (
		get_node_or_null("Visuals/Lever") as Node3D
		if has_node("Visuals/Lever")
		else get_node_or_null("Lever") as Node3D
	)

func _ready() -> void:
	if endpoint != 0 and endpoint != 1:
		endpoint = 1
	collision_layer = 32  # Layer 6 = Interactable
	collision_mask = 0
	add_to_group("interactable")
	add_to_group("rail_switch")
	if not has_meta(WorldSync.NET_ID_META):
		WorldSync.register_entity(self, 300000 + absi(String(get_path()).hash() % 500000))
	_path_node = get_node_or_null(rail_path)
	_visual_bottom_local_y = _compute_visual_bottom_local_y()
	_ensure_indicator()
	_set_indicator_visible(false)
	set_process(true)
	call_deferred("_refresh_visual_state")


func _process(delta: float) -> void:
	_indicator_visibility_hold = maxf(_indicator_visibility_hold - delta, 0.0)
	_indicator_refresh_accum += delta
	if _indicator_refresh_accum < INDICATOR_REFRESH_INTERVAL:
		return
	_indicator_refresh_accum = 0.0
	if _path_node == null:
		_path_node = get_node_or_null(rail_path)
	if _path_node == null:
		_set_indicator_visible(false)
		return
	_update_position_from_junction()
	_update_indicator(_get_active_route_index())

func get_interact_text() -> String:
	return "[E] Switch"

func interact(_player: CharacterBody3D) -> void:
	if WorldSync.should_request_host():
		WorldSync.request_interact(WorldSync.get_net_id(self))
		return
	server_interact(Inventory.get_local_peer_id())

func server_interact(_peer_id: int) -> void:
	_perform_switch(true)

func apply_network_interact() -> void:
	_perform_switch(false)

func _perform_switch(replicate: bool) -> void:
	if not _can_switch or _path_node == null:
		return
	_can_switch = false
	_indicator_visibility_hold = maxf(_indicator_visibility_hold, SWITCH_INDICATOR_HOLD)
	var new_idx: int = RailNetwork.cycle_switch(_path_node, endpoint)
	AudioManager.play_sfx("lever", 0.0, randf_range(0.90, 1.10))
	_update_indicator(new_idx)
	_update_lever_visual(new_idx, true)
	if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_interact(WorldSync.get_net_id(self))
	await get_tree().create_timer(switch_cooldown).timeout
	_can_switch = true


func _refresh_visual_state() -> void:
	await get_tree().process_frame
	if _path_node == null:
		_path_node = get_node_or_null(rail_path)
	if _path_node == null:
		return
	_update_position_from_junction()
	var active_index := RailNetwork.get_active_index(_path_node, endpoint)
	_update_indicator(active_index)
	_update_lever_visual(active_index, false)

func _update_indicator(active_index: int) -> void:
	var arrow := _ensure_indicator()
	if arrow == null:
		return
	var state := _get_junction_state()
	var direction_origin: Vector3 = global_position
	if not state.is_empty():
		direction_origin = state["junction"] as Vector3
	var dir: Vector3 = Vector3.ZERO
	var conns: Array = _get_switch_connections()
	if conns.size() > 0:
		var route: Dictionary = conns[clampi(active_index, 0, conns.size() - 1)]
		var target: Node = route.get("path", null) as Node
		if is_instance_valid(target):
			dir = _resolve_route_direction(target, int(route.get("end", 0)), direction_origin)
	if conns.size() == 0 or dir.length_squared() <= 0.01:
		_set_indicator_visible(false)
		return
	arrow.position = Vector3.ZERO
	var icon := arrow.get_node_or_null("IndicatorIcon") as Sprite3D
	if icon == null:
		_set_indicator_visible(false)
		return
	icon.position = Vector3(0.0, hologram_height, 0.0)
	icon.texture = _get_indicator_texture(dir, state, active_index, conns.size())
	_set_indicator_visible(_should_show_indicator())


func _update_lever_visual(active_index: int, animate: bool) -> void:
	var lever := _get_lever_node()
	if lever == null:
		return
	var target_rot := lever.rotation_degrees
	target_rot.z = _compute_lever_tilt(active_index)
	if _lever_tween != null and _lever_tween.is_running():
		_lever_tween.kill()
	if animate:
		_lever_tween = create_tween()
		_lever_tween.set_trans(Tween.TRANS_SINE)
		_lever_tween.set_ease(Tween.EASE_OUT)
		_lever_tween.tween_property(lever, "rotation_degrees", target_rot, LEVER_TWEEN_TIME)
	else:
		lever.rotation_degrees = target_rot


func _compute_lever_tilt(active_index: int) -> float:
	if _path_node == null:
		return 0.0
	var conns: Array = _get_switch_connections()
	if conns.size() <= 1:
		return 0.0
	if conns.size() == 2:
		return -LEVER_TILT_DEG if active_index == 0 else LEVER_TILT_DEG
	var denom := maxf(float(conns.size() - 1), 1.0)
	var t := clampf(float(active_index) / denom, 0.0, 1.0)
	return lerpf(-LEVER_TILT_DEG, LEVER_TILT_DEG, t)


func _update_position_from_junction() -> void:
	if not auto_place_next_to_junction:
		return
	var state := _get_junction_state()
	if state.is_empty():
		return
	var junction: Vector3 = state.junction
	var forward: Vector3 = state.dir
	forward.y = 0.0
	if forward.length_squared() <= 0.0001:
		return
	forward = forward.normalized()
	var right := Vector3.UP.cross(forward).normalized()
	if right.length_squared() <= 0.0001:
		return

	var current_delta := global_position - junction
	var side_sign := 1.0
	var side_projection := current_delta.dot(right)
	if absf(side_projection) > 0.05:
		side_sign = -1.0 if side_projection < 0.0 else 1.0
	var target_position := junction + right * (junction_side_offset * side_sign)
	target_position.y = junction.y
	if snap_to_ground:
		target_position.y = _get_ground_height(target_position) - _visual_bottom_local_y + junction_vertical_offset
	else:
		var vertical_offset := junction_vertical_offset
		if absf(current_delta.y) > 0.05:
			vertical_offset = current_delta.y
		target_position.y += vertical_offset
	global_position = target_position


func _get_junction_state() -> Dictionary:
	if _path_node == null or not _path_node.has_method("get_rail_curve"):
		return {}
	var path_node := _path_node as Node3D
	if path_node == null:
		return {}
	var rail_curve: Curve3D = _path_node.get_rail_curve()
	if rail_curve == null or rail_curve.point_count < 2:
		return {}

	var point_idx := 0 if endpoint == 0 else rail_curve.point_count - 1
	var step := 1 if endpoint == 0 else -1
	var stop := rail_curve.point_count if step > 0 else -1
	var junction: Vector3 = path_node.to_global(rail_curve.get_point_position(point_idx))

	for idx in range(point_idx + step, stop, step):
		var candidate: Vector3 = path_node.to_global(rail_curve.get_point_position(idx))
		var delta: Vector3 = candidate - junction
		if delta.length_squared() > 0.001:
			return {
				"junction": junction,
				"dir": delta.normalized(),
			}
	return {}


func set_hovered(is_hovered: bool) -> void:
	_hovered = is_hovered
	_indicator_visibility_hold = maxf(_indicator_visibility_hold, HOVER_RELEASE_GRACE)
	_set_indicator_visible(_should_show_indicator())
	if is_hovered and _path_node != null:
		_update_indicator(_get_active_route_index())


func _ensure_indicator() -> Node3D:
	var arrow := get_node_or_null("Arrow") as Node3D
	if arrow == null:
		arrow = Node3D.new()
		arrow.name = "Arrow"
		add_child(arrow)
	arrow.top_level = false

	var legacy_direction := arrow.get_node_or_null("Direction")
	if legacy_direction != null:
		legacy_direction.queue_free()
	var legacy_ring := arrow.get_node_or_null("Ring")
	if legacy_ring != null:
		legacy_ring.queue_free()
	var legacy_pillar := arrow.get_node_or_null("Pillar")
	if legacy_pillar != null:
		legacy_pillar.queue_free()

	var legacy_label := arrow.get_node_or_null("IndicatorLabel")
	if legacy_label != null:
		legacy_label.queue_free()

	var icon := arrow.get_node_or_null("IndicatorIcon") as Sprite3D
	if icon == null:
		icon = Sprite3D.new()
		icon.name = "IndicatorIcon"
		icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		icon.fixed_size = true
		icon.pixel_size = 0.0022
		icon.modulate = Color(0.72, 0.72, 0.72, 0.9)
		icon.no_depth_test = false
		arrow.add_child(icon)
	icon.position = Vector3(0.0, hologram_height, 0.0)

	return arrow


func _resolve_route_direction(target: Node, target_endpoint: int, direction_origin: Vector3) -> Vector3:
	var target_pos: Vector3 = _get_route_preview_position(target, target_endpoint)
	var dir: Vector3 = target_pos - direction_origin
	dir.y = 0.0
	if dir.length_squared() > 0.01:
		return dir
	return _get_route_preview_tangent(target, target_endpoint)


func _get_route_preview_position(target: Node, target_endpoint: int) -> Vector3:
	if target == null:
		return global_position
	if not target.has_method("get_rail_curve"):
		return target.global_position
	var target_curve: Curve3D = target.get_rail_curve()
	if target_curve == null or target_curve.point_count == 0:
		return target.global_position
	if target_curve.point_count == 1:
		return target.to_global(target_curve.get_point_position(0))

	var point_idx: int
	if target_endpoint == 0:
		point_idx = 1
	else:
		point_idx = target_curve.point_count - 2
	point_idx = clampi(point_idx, 0, target_curve.point_count - 1)
	return target.to_global(target_curve.get_point_position(point_idx))


func _get_route_preview_tangent(target: Node, target_endpoint: int) -> Vector3:
	if target == null or not target.has_method("get_rail_curve"):
		return Vector3.ZERO
	var target_curve: Curve3D = target.get_rail_curve()
	if target_curve == null or target_curve.point_count < 2:
		return Vector3.ZERO
	var from_idx := 0 if target_endpoint == 0 else target_curve.point_count - 1
	var to_idx := 1 if target_endpoint == 0 else target_curve.point_count - 2
	var from_pos: Vector3 = target.to_global(target_curve.get_point_position(from_idx))
	var to_pos: Vector3 = target.to_global(target_curve.get_point_position(to_idx))
	var tangent: Vector3 = to_pos - from_pos
	tangent.y = 0.0
	return tangent


func _get_indicator_texture(route_dir: Vector3, junction_state: Dictionary, active_index: int, connection_count: int) -> Texture2D:
	var side := _get_indicator_side(route_dir, junction_state, active_index, connection_count)
	return INDICATOR_LEFT_ICON if side < 0 else INDICATOR_RIGHT_ICON


func _get_indicator_side(route_dir: Vector3, junction_state: Dictionary, active_index: int, connection_count: int) -> int:
	if connection_count > 1:
		var lever_tilt := _compute_lever_tilt(active_index)
		if absf(lever_tilt) > 0.01:
			var lever_side := -1 if lever_tilt < 0.0 else 1
			return -lever_side if endpoint == 0 else lever_side
	if not junction_state.is_empty():
		var forward: Vector3 = junction_state["dir"] as Vector3
		forward.y = 0.0
		var flat_route: Vector3 = route_dir
		flat_route.y = 0.0
		if forward.length_squared() > 0.0001 and flat_route.length_squared() > 0.0001:
			var side_axis := forward.cross(Vector3.UP)
			if side_axis.length_squared() > 0.0001:
				var side_score := flat_route.normalized().dot(side_axis.normalized())
				if absf(side_score) > 0.15:
					var route_side := -1 if side_score < 0.0 else 1
					return -route_side if endpoint == 0 else route_side
	if connection_count == 2:
		var active_side := -1 if active_index == 0 else 1
		return -active_side if endpoint == 0 else active_side
	if connection_count > 1:
		var indexed_side := -1 if active_index < int(connection_count / 2) else 1
		return -indexed_side if endpoint == 0 else indexed_side
	return 1


func _set_indicator_visible(is_visible: bool) -> void:
	var arrow := get_node_or_null("Arrow") as Node3D
	if arrow != null:
		arrow.visible = is_visible


func _should_show_indicator() -> bool:
	return _hovered or _indicator_visibility_hold > 0.0 or not hologram_requires_hover


func _get_active_route_index() -> int:
	if _path_node == null:
		return 0
	return RailNetwork.get_active_index(_path_node, endpoint)


func _get_switch_connections() -> Array:
	if _path_node == null:
		return []
	var conns: Array = RailNetwork.get_connections_at(_path_node, endpoint)
	if conns.size() > 0:
		return conns
	if not (_path_node is Node):
		return []
	var path_node := _path_node as Node
	var node_paths: Array = []
	var node_paths_variant: Variant = null
	if endpoint == 0:
		node_paths_variant = path_node.get("connections_at_start")
	else:
		node_paths_variant = path_node.get("connections_at_end")
	if node_paths_variant is Array:
		node_paths = node_paths_variant as Array
	var fallback: Array = []
	for np in node_paths:
		var other := path_node.get_node_or_null(np)
		if other == null:
			continue
		var other_end := 0
		if other.has_method("get_rail_curve") and path_node.has_method("get_rail_curve"):
			other_end = _closest_endpoint_for(path_node, other, endpoint)
		fallback.append({
			"path": other,
			"end": other_end,
		})
	return fallback


func _closest_endpoint_for(source_path: Node, other_path: Node, source_endpoint: int) -> int:
	if not source_path.has_method("get_rail_curve") or not other_path.has_method("get_rail_curve"):
		return 0
	var source_curve: Curve3D = source_path.get_rail_curve()
	var other_curve: Curve3D = other_path.get_rail_curve()
	if source_curve == null or other_curve == null:
		return 0
	if source_curve.point_count == 0 or other_curve.point_count == 0:
		return 0
	var source_idx := 0 if source_endpoint == 0 else source_curve.point_count - 1
	var source_pos: Vector3 = source_path.to_global(source_curve.get_point_position(source_idx))
	var other_start: Vector3 = other_path.to_global(other_curve.get_point_position(0))
	var other_end: Vector3 = other_path.to_global(other_curve.get_point_position(other_curve.point_count - 1))
	return 0 if source_pos.distance_squared_to(other_start) <= source_pos.distance_squared_to(other_end) else 1


func _get_ground_height(world_pos: Vector3) -> float:
	var tree := get_tree()
	if tree != null:
		for node in tree.get_nodes_in_group("terrain"):
			if node != null and is_instance_valid(node) and node.has_method("get_height_at"):
				return node.get_height_at(world_pos.x, world_pos.z)
	var world := get_world_3d()
	if world == null:
		return world_pos.y
	var from := world_pos + Vector3.UP * GROUND_RAY_HEIGHT
	var to := world_pos + Vector3.DOWN * GROUND_RAY_DEPTH
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return world_pos.y
	var hit_position: Vector3 = hit["position"]
	return hit_position.y


func _compute_visual_bottom_local_y() -> float:
	var visuals := get_node_or_null("Visuals")
	if visuals == null:
		return 0.0
	var bounds: Variant = _compute_visual_bounds(visuals, Transform3D.IDENTITY)
	if bounds == null:
		return 0.0
	return (bounds as AABB).position.y


func _compute_visual_bounds(node: Node, parent_xf: Transform3D) -> Variant:
	var current_xf := parent_xf
	if node is Node3D:
		current_xf = parent_xf * (node as Node3D).transform

	var merged: Variant = null
	if node is VisualInstance3D:
		var vis := node as VisualInstance3D
		merged = _transform_aabb(vis.get_aabb(), current_xf)

	for child in node.get_children():
		var child_node := child as Node
		if child_node == null:
			continue
		var child_bounds: Variant = _compute_visual_bounds(child_node, current_xf)
		if child_bounds == null:
			continue
		if merged == null:
			merged = child_bounds
		else:
			merged = (merged as AABB).merge(child_bounds as AABB)
	return merged


func _transform_aabb(aabb: AABB, xf: Transform3D) -> AABB:
	var p: Vector3 = aabb.position
	var s: Vector3 = aabb.size
	var corners: Array[Vector3] = [
		xf * p,
		xf * (p + Vector3(s.x, 0.0, 0.0)),
		xf * (p + Vector3(0.0, s.y, 0.0)),
		xf * (p + Vector3(0.0, 0.0, s.z)),
		xf * (p + Vector3(s.x, s.y, 0.0)),
		xf * (p + Vector3(s.x, 0.0, s.z)),
		xf * (p + Vector3(0.0, s.y, s.z)),
		xf * (p + s),
	]
	var out := AABB(corners[0], Vector3.ZERO)
	for i in range(1, corners.size()):
		out = out.expand(corners[i])
	return out
