extends StaticBody3D
class_name Coupler

const COUPLE_RANGE: float = 4.0

var _parent_wagon: WagonFrame = null
var _my_side: int = 1
var _coupled_other: WagonFrame = null
var _coupled_other_side: int = -1

func _ready() -> void:
	collision_layer = 32
	collision_mask = 0
	add_to_group("interactable")
	if not has_meta(WorldSync.NET_ID_META):
		WorldSync.register_entity(self, 400000 + absi(String(get_path()).hash() % 500000))
	var current: Node = get_parent()
	while current:
		if current is WagonFrame:
			_parent_wagon = current
			break
		current = current.get_parent()
	if _parent_wagon:
		_my_side = 0 if position.z > 0.0 else 1

func interact(_player: CharacterBody3D) -> void:
	if WorldSync.should_request_host():
		WorldSync.request_interact(WorldSync.get_net_id(self))
		return
	server_interact(Inventory.get_local_peer_id())

func server_interact(_peer_id: int) -> void:
	if _parent_wagon == null:
		return
	if _coupled_other != null and is_instance_valid(_coupled_other):
		var other := _coupled_other
		var other_side := _coupled_other_side
		_parent_wagon.uncouple(_my_side)
		_coupled_other = null
		_coupled_other_side = -1
		WorldSync.broadcast_coupling(
			WorldSync.get_net_id(_parent_wagon),
			WorldSync.get_net_id(other),
			_my_side, other_side, false
		)
		AudioManager.play_sfx("lever", 0.0, randf_range(0.85, 0.95))
		return
	var match_info := _find_nearest_coupleable()
	if match_info.is_empty():
		return
	var other: WagonFrame = match_info.wagon
	var other_side: int = match_info.side
	if not _parent_wagon.couple_to(other, _my_side, other_side):
		return
	_coupled_other = other
	_coupled_other_side = other_side
	WorldSync.broadcast_coupling(
		WorldSync.get_net_id(_parent_wagon),
		WorldSync.get_net_id(other),
		_my_side, other_side, true
	)
	AudioManager.play_sfx("lever", 0.0, randf_range(1.0, 1.1))

func apply_network_interact() -> void:
	pass

func get_interact_text() -> String:
	if _coupled_other != null and is_instance_valid(_coupled_other):
		return "[E] Decoupler"
	return "[E] Coupler"

func _find_nearest_coupleable() -> Dictionary:
	if _parent_wagon == null or _parent_wagon.front_bogie == null:
		return {}
	var my_pos: Vector3 = global_position
	var best: Dictionary = {}
	var best_dist: float = COUPLE_RANGE
	for w in get_tree().get_nodes_in_group("wagon_frame"):
		if w == _parent_wagon or not (w is WagonFrame):
			continue
		var wf := w as WagonFrame
		if wf.front_bogie == null or wf.rear_bogie == null:
			continue
		if wf.front_bogie.current_rail_path != _parent_wagon.front_bogie.current_rail_path:
			continue
		var end_front: Vector3 = wf.global_position + wf.global_basis.z * (float(wf.wagon_length) * WagonFrame.GRID_SIZE * 0.5)
		var end_back: Vector3 = wf.global_position - wf.global_basis.z * (float(wf.wagon_length) * WagonFrame.GRID_SIZE * 0.5)
		var d_front: float = my_pos.distance_to(end_front)
		var d_back: float = my_pos.distance_to(end_back)
		if d_front < d_back and d_front < best_dist and wf.is_end_free(0):
			best_dist = d_front
			best = {"wagon": wf, "side": 0}
		elif d_back <= d_front and d_back < best_dist and wf.is_end_free(1):
			best_dist = d_back
			best = {"wagon": wf, "side": 1}
	return best
