extends StaticBody3D
class_name BiomeHarvestProxy

const INTERACTABLE_LAYER: int = 32
const FIBER_ITEM_ID: String = "fiber"
const FIBER_PICK_SFX_NAMES: Array[String] = [
	"FougerePick1",
	"FougerePick2",
	"FougerePick3",
]

var drop_item_id: String = ""
var amount_min: int = 1
var amount_max: int = 1
var hits_to_harvest: int = 1
var required_tool_id: String = ""
var interact_label: String = "Harvest"
var target_name: String = "Resource"
var hit_cooldown: float = 0.5

const PICKUP_SFX: String = "pickup_item"

var _rng := RandomNumberGenerator.new()
var _instances: Array[Dictionary] = []
var _render_nodes: Array[MultiMeshInstance3D] = []
var _last_fiber_pick_sfx: String = ""

var hits_remaining: int:
	get:
		for inst in _instances:
			if not bool(inst.get("depleted", false)):
				return int(inst.get("hits_remaining", hits_to_harvest))
		return 0


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
			"next_hit_time": 0.0,
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
		_play_spatial_sfx("metal_hit", hit.get("position", global_position), 0.0, 0.85)
		return

	var now := float(Time.get_ticks_msec()) / 1000.0
	if hit_cooldown > 0.0 and now < float(instance_data.get("next_hit_time", 0.0)):
		return
	instance_data["next_hit_time"] = now + hit_cooldown
	instance_data["hits_remaining"] = int(instance_data.get("hits_remaining", hits_to_harvest)) - 1
	_instances[instance_index] = instance_data
	if _is_pickup_collectible():
		_play_pickup_sfx()
	else:
		_play_hit_sfx(hit.get("position", global_position))

	if int(instance_data["hits_remaining"]) <= 0:
		_harvest_instance(instance_index)


func get_interact_text() -> String:
	return _format_interact_text()


func get_interact_text_at(_hit: Dictionary) -> String:
	return _format_interact_text()


func get_target_name_at(_hit: Dictionary) -> String:
	return target_name


func _format_interact_text() -> String:
	if drop_item_id == FIBER_ITEM_ID:
		return interact_label
	if required_tool_id.is_empty():
		return "[E] %s" % interact_label
	var tool_name: String = Inventory.get_item_name(required_tool_id)
	return "[E] %s (%s required)" % [interact_label, tool_name]


func _play_hit_sfx(hit_position: Vector3) -> void:
	match drop_item_id:
		"wood", "branch", "log":
			var idx: int = randi_range(1, 9)
			_play_spatial_sfx("cutting_wood0%d" % idx, hit_position, 0.0, randf_range(0.95, 1.05))
		"stone":
			var idx: int = randi_range(1, 4)
			_play_spatial_sfx("mining_stone0%d" % idx, hit_position, 0.0, randf_range(0.9, 1.1))
		"metal", "metal_scrap":
			_play_spatial_sfx("metal_hit", hit_position, 0.0, randf_range(0.9, 1.1))
		FIBER_ITEM_ID:
			_play_fiber_pick_sfx(hit_position)
		_:
			_play_spatial_sfx("harvest", hit_position, 0.0, randf_range(0.9, 1.1))

func _play_spatial_sfx(name: String, hit_position: Vector3, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if AudioManager != null and AudioManager.has_method("play_sfx_3d"):
		AudioManager.play_sfx_3d(name, hit_position, volume_db, pitch)

func _play_fiber_pick_sfx(hit_position: Vector3) -> void:
	var sfx_name: String = _pick_fiber_sfx_name()
	if sfx_name.is_empty():
		return
	_play_spatial_sfx(sfx_name, hit_position, 0.0, randf_range(0.96, 1.04))

func _pick_fiber_sfx_name() -> String:
	if FIBER_PICK_SFX_NAMES.is_empty():
		return ""
	var candidates: Array[String] = []
	for index in range(FIBER_PICK_SFX_NAMES.size()):
		var candidate: String = FIBER_PICK_SFX_NAMES[index]
		if FIBER_PICK_SFX_NAMES.size() <= 1 or candidate != _last_fiber_pick_sfx:
			candidates.append(candidate)
	if candidates.is_empty():
		candidates.append(FIBER_PICK_SFX_NAMES[0])
	var selected_index: int = _rng.randi_range(0, candidates.size() - 1)
	var sfx_name: String = candidates[selected_index]
	_last_fiber_pick_sfx = sfx_name
	return sfx_name

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
		hidden_transform.basis = Basis(Vector3(0.0001, 0.0, 0.0), Vector3(0.0, 0.0001, 0.0), Vector3(0.0, 0.0, 0.0001))
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
