extends StaticBody3D
class_name RailSwitch

## Place at a junction point. Links to a RailPath and an endpoint (0=start, 1=end).
## Interacting cycles through available connected routes.

@export var rail_path: NodePath
@export_enum("Start:0", "End:1") var endpoint: int = 1
@export var switch_cooldown: float = 0.4

var _path_node: Node = null
var _can_switch: bool = true

func _ready() -> void:
	collision_layer = 32  # Layer 6 = Interactable
	collision_mask = 0
	add_to_group("interactable")
	add_to_group("rail_switch")
	_path_node = get_node_or_null(rail_path)

func get_interact_text() -> String:
	return "[E] Switch"

func interact(_player: CharacterBody3D) -> void:
	if not _can_switch or _path_node == null:
		return
	_can_switch = false
	var new_idx: int = RailNetwork.cycle_switch(_path_node, endpoint)
	AudioManager.play_sfx("lever", 0.0, randf_range(0.90, 1.10))
	_update_indicator(new_idx)
	await get_tree().create_timer(switch_cooldown).timeout
	_can_switch = true

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
