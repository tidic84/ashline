extends StaticBody3D
class_name BiomeHarvestProxy

const INTERACTABLE_LAYER: int = 32

var drop_item_id: String = ""
var amount_min: int = 1
var amount_max: int = 1
var hits_to_harvest: int = 1
var required_tool_id: String = ""
var interact_label: String = "Harvest"
var target_name: String = "Resource"

const PICKUP_SFX: String = "pickup_item"

var _rng := RandomNumberGenerator.new()
var _instances: Array[Dictionary] = []
var _render_nodes: Array[MultiMeshInstance3D] = []


func _ready() -> void:
	collision_layer |= INTERACTABLE_LAYER
	_rng.randomize()
	add_to_group("harvestable")


func setup_chunk(config: Dictionary) -> void:
	drop_item_id = String(config.get("drop_item_id", ""))
	amount_min = maxi(1, int(config.get("amount_min", 1)))
	amount_max = maxi(amount_min, int(config.get("amount_max", amount_min)))
	hits_to_harvest = maxi(1, int(config.get("hits_to_harvest", 1)))
	required_tool_id = String(config.get("required_tool_id", ""))
	interact_label = String(config.get("interact_label", "Harvest"))
	target_name = String(config.get("target_name", "Resource"))

	_render_nodes.clear()
	for render_node in config.get("render_nodes", []):
		if render_node is MultiMeshInstance3D:
			_render_nodes.append(render_node as MultiMeshInstance3D)

	_instances.clear()
	for raw_instance in config.get("instances", []):
		var collision_shapes: Array[CollisionShape3D] = []
		for shape_node in raw_instance.get("collision_shapes", []):
			if shape_node is CollisionShape3D:
				collision_shapes.append(shape_node as CollisionShape3D)

		_instances.append({
			"local_center": raw_instance.get("local_center", Vector3.ZERO),
			"collision_shapes": collision_shapes,
			"hits_remaining": hits_to_harvest,
			"depleted": false,
		})


func interact(player: CharacterBody3D) -> void:
	var hit := _build_hit_from_player(player)
	if hit.is_empty():
		return
	interact_at(player, hit)


func interact_at(_player: CharacterBody3D, hit: Dictionary) -> void:
	var instance_index: int = _find_best_instance_index(hit)
	if instance_index < 0:
		return

	var instance_data: Dictionary = _instances[instance_index]
	if bool(instance_data.get("depleted", false)):
		return

	if not required_tool_id.is_empty() and Inventory.get_selected_item() != required_tool_id:
		AudioManager.play_sfx("metal_hit", 0.0, 0.85)
		return

	instance_data["hits_remaining"] = int(instance_data.get("hits_remaining", hits_to_harvest)) - 1
	_instances[instance_index] = instance_data
	if _is_pickup_collectible():
		_play_pickup_sfx()
	else:
		_play_hit_sfx()

	if int(instance_data["hits_remaining"]) <= 0:
		_harvest_instance(instance_index)


func get_interact_text() -> String:
	return _format_interact_text()


func get_interact_text_at(_hit: Dictionary) -> String:
	return _format_interact_text()


func get_target_name_at(_hit: Dictionary) -> String:
	return target_name


func _format_interact_text() -> String:
	if required_tool_id.is_empty():
		return "[E] %s" % interact_label
	var tool_name: String = Inventory.get_item_name(required_tool_id)
	return "[E] %s (%s required)" % [interact_label, tool_name]


func _play_hit_sfx() -> void:
	match drop_item_id:
		"wood", "branch", "log":
			var idx: int = randi_range(1, 9)
			AudioManager.play_sfx("cutting_wood0%d" % idx, 0.0, randf_range(0.95, 1.05))
		"stone":
			var idx: int = randi_range(1, 4)
			AudioManager.play_sfx("mining_stone0%d" % idx, 0.0, randf_range(0.9, 1.1))
		"metal", "metal_scrap":
			AudioManager.play_sfx("metal_hit", 0.0, randf_range(0.9, 1.1))
		_:
			AudioManager.play_sfx("harvest", 0.0, randf_range(0.9, 1.1))

func _is_pickup_collectible() -> bool:
	return required_tool_id.is_empty() and hits_to_harvest <= 1

func _play_pickup_sfx() -> void:
	AudioManager.play_sfx(PICKUP_SFX, 0.0, randf_range(0.96, 1.04))


func _harvest_instance(instance_index: int) -> void:
	var instance_data: Dictionary = _instances[instance_index]
	instance_data["depleted"] = true
	instance_data["hits_remaining"] = 0
	_instances[instance_index] = instance_data

	Inventory.add_item(drop_item_id, _rng.randi_range(amount_min, amount_max))

	for shape_node in instance_data.get("collision_shapes", []):
		if is_instance_valid(shape_node):
			shape_node.disabled = true

	for render_node in _render_nodes:
		if not is_instance_valid(render_node) or render_node.multimesh == null:
			continue
		if instance_index < 0 or instance_index >= render_node.multimesh.instance_count:
			continue
		var hidden_transform: Transform3D = render_node.multimesh.get_instance_transform(instance_index)
		hidden_transform.origin.y = -1000.0 - float(instance_index)
		render_node.multimesh.set_instance_transform(instance_index, hidden_transform)


func _find_best_instance_index(hit: Dictionary) -> int:
	if _instances.is_empty():
		return -1

	var hit_position_global: Vector3 = hit.get("position", global_position)
	var hit_position_local: Vector3 = to_local(hit_position_global)
	var best_index: int = -1
	var best_distance_sq: float = INF

	for index in range(_instances.size()):
		var instance_data: Dictionary = _instances[index]
		if bool(instance_data.get("depleted", false)):
			continue
		var local_center: Vector3 = instance_data.get("local_center", Vector3.ZERO)
		var distance_sq: float = hit_position_local.distance_squared_to(local_center)
		if distance_sq < best_distance_sq:
			best_distance_sq = distance_sq
			best_index = index

	return best_index


func _build_hit_from_player(player: CharacterBody3D) -> Dictionary:
	if player == null:
		return {}

	var camera: Camera3D = player.get_node_or_null("RotationHelper/Camera") as Camera3D
	if camera == null:
		camera = player.get_node_or_null("Head/Camera3D") as Camera3D
	if camera == null:
		return {}

	var from: Vector3 = camera.global_position
	var to: Vector3 = from + -camera.global_transform.basis.z * 4.0
	var params := PhysicsRayQueryParameters3D.create(from, to, collision_layer)
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(params)
	if hit.is_empty():
		return {}
	if hit.get("collider") != self:
		return {}
	return hit
