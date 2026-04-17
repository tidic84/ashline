extends StaticBody3D
class_name RailSwitch

## Place at a junction point. Links to a RailPath and an endpoint (0=start, 1=end).
## Interacting cycles through available connected routes.

@export var rail_path: NodePath
@export_enum("Start:0", "End:1") var endpoint: int = 1
@export var switch_cooldown: float = 0.4

const LEVER_TILT_DEG: float = 12.0
const LEVER_TWEEN_TIME: float = 0.12

var _path_node: Node = null
var _can_switch: bool = true
var _lever_tween: Tween = null

func _get_lever_node() -> Node3D:
	return (
		get_node_or_null("Visuals/Lever") as Node3D
		if has_node("Visuals/Lever")
		else get_node_or_null("Lever") as Node3D
	)

func _ready() -> void:
	collision_layer = 32  # Layer 6 = Interactable
	collision_mask = 0
	add_to_group("interactable")
	add_to_group("rail_switch")
	if not has_meta(WorldSync.NET_ID_META):
		WorldSync.register_entity(self, 300000 + absi(String(get_path()).hash() % 500000))
	_path_node = get_node_or_null(rail_path)
	call_deferred("_refresh_visual_state")

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
	var active_index := RailNetwork.get_active_index(_path_node, endpoint)
	_update_indicator(active_index)
	_update_lever_visual(active_index, false)

func _update_indicator(active_index: int) -> void:
	var arrow := get_node_or_null("Arrow") as Node3D
	if arrow == null:
		return
	var conns: Array = RailNetwork.get_connections_at(_path_node, endpoint)
	if conns.size() == 0:
		return
	var route: Dictionary = conns[clampi(active_index, 0, conns.size() - 1)]
	var target: Node = route.path
	if not is_instance_valid(target):
		return
	# Point arrow toward the connected path's endpoint
	var target_pos: Vector3
	var target_curve: Curve3D = target.get_rail_curve() if target.has_method("get_rail_curve") else null
	if target_curve and target_curve.point_count > 0:
		if route.end == 0:
			target_pos = target.to_global(target_curve.get_point_position(0))
		else:
			target_pos = target.to_global(target_curve.get_point_position(target_curve.point_count - 1))
	else:
		target_pos = target.global_position
	var dir: Vector3 = (target_pos - global_position)
	dir.y = 0.0
	if dir.length_squared() > 0.01:
		arrow.look_at(global_position + dir.normalized(), Vector3.UP)


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
	var conns: Array = RailNetwork.get_connections_at(_path_node, endpoint)
	if conns.size() <= 1:
		return 0.0
	if conns.size() == 2:
		return -LEVER_TILT_DEG if active_index == 0 else LEVER_TILT_DEG
	var denom := maxf(float(conns.size() - 1), 1.0)
	var t := clampf(float(active_index) / denom, 0.0, 1.0)
	return lerpf(-LEVER_TILT_DEG, LEVER_TILT_DEG, t)
