extends StaticBody3D
class_name Coupler

const COUPLE_RANGE: float = 1.5

var my_side: int = -1  # 0=front, 1=back; set deferred after placement


func _ready() -> void:
	collision_layer = 32
	collision_mask = 0
	add_to_group("interactable")
	add_to_group("coupler")
	if my_side == -1:
		call_deferred("_determine_side")


func setup(side: int) -> void:
	my_side = side


func _get_my_wagon() -> WagonFrame:
	return get_parent() as WagonFrame


func _determine_side() -> void:
	my_side = 0 if position.z > 0.0 else 1


func _is_coupled() -> bool:
	if my_side == -1:
		_determine_side()
	var wagon := _get_my_wagon()
	if wagon == null:
		return false
	return not wagon.is_end_free(my_side)


func _find_nearby_coupler() -> Coupler:
	var my_wagon := _get_my_wagon()
	for node in get_tree().get_nodes_in_group("coupler"):
		var other := node as Coupler
		if other == null or other == self:
			continue
		if other._get_my_wagon() == my_wagon:
			continue
		if other._is_coupled():
			continue
		if global_position.distance_to(other.global_position) <= COUPLE_RANGE:
			return other
	return null


func get_interact_text() -> String:
	if _is_coupled():
		return "[E] Decouple"
	if _find_nearby_coupler() != null:
		return "[E] Couple"
	return ""


func interact(_player: CharacterBody3D) -> void:
	if WorldSync.should_request_host():
		var wagon := _get_my_wagon()
		if wagon != null:
			WorldSync.request_coupler_interact(WorldSync.get_net_id(wagon), my_side)
		return
	server_interact(Inventory.get_local_peer_id())


func server_interact(_peer_id: int) -> void:
	if _is_coupled():
		_do_uncouple()
	else:
		var nearby := _find_nearby_coupler()
		if nearby != null:
			_do_couple(nearby)


func apply_network_interact() -> void:
	pass


func _do_couple(other: Coupler) -> void:
	if my_side == -1:
		_determine_side()
	if other.my_side == -1:
		other._determine_side()
	var my_wagon := _get_my_wagon()
	var other_wagon := other._get_my_wagon()
	if my_wagon == null or other_wagon == null:
		return
	if not my_wagon.couple_to(other_wagon, my_side, other.my_side):
		return
	AudioManager.play_sfx("lever", 0.0, randf_range(0.9, 1.0))
	var a_net_id := WorldSync.get_net_id(my_wagon)
	var b_net_id := WorldSync.get_net_id(other_wagon)
	if a_net_id > 0 and b_net_id > 0:
		WorldSync.broadcast_coupling(a_net_id, b_net_id, my_side, other.my_side, true)


func _do_uncouple() -> void:
	if my_side == -1:
		_determine_side()
	var my_wagon := _get_my_wagon()
	if my_wagon == null:
		return
	var other_wagon: WagonFrame = my_wagon.coupled_front if my_side == 0 else my_wagon.coupled_back
	var other_side: int = 1 if (other_wagon != null and other_wagon.coupled_front == my_wagon) else 0
	my_wagon.uncouple(my_side)
	AudioManager.play_sfx("lever", 0.0, randf_range(0.85, 0.95))
	var a_net_id := WorldSync.get_net_id(my_wagon)
	var b_net_id := WorldSync.get_net_id(other_wagon) if other_wagon != null else 0
	if a_net_id > 0 and b_net_id > 0:
		WorldSync.broadcast_coupling(a_net_id, b_net_id, my_side, other_side, false)
