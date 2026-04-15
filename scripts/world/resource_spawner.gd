extends Node3D
class_name ResourceSpawner

@export var world_radius: float = 85.0
@export var min_distance_to_rails: float = 5.0
@export var world_seed: int = 1701

@export var branch_nodes: int = 28
@export var log_nodes: int = 22
@export var stone_nodes: int = 24
@export var scrap_nodes: int = 16
@export var tree_nodes: int = 18
@export var big_rock_nodes: int = 14

var _rng := RandomNumberGenerator.new()
var _next_resource_net_id: int = 200000

func _ready() -> void:
	var seed_value: int = world_seed if world_seed != 0 else int(Time.get_unix_time_from_system())
	_rng.seed = seed_value
	await get_tree().process_frame
	await get_tree().process_frame
	_spawn_all()

func _spawn_all() -> void:
	_next_resource_net_id = 200000
	_spawn_batch(branch_nodes, "branch", 2, 4, 1, "", "Collect Branches")
	_spawn_batch(log_nodes, "log", 2, 4, 1, "", "Collect Logs")
	_spawn_batch(stone_nodes, "stone", 2, 4, 1, "", "Pick Stones")
	_spawn_batch(scrap_nodes, "metal_scrap", 2, 4, 1, "", "Collect Scrap")
	if not _has_existing_tree_biome():
		_spawn_batch(tree_nodes, "log", 6, 10, 4, "axe", "Chop Tree")
	_spawn_batch(big_rock_nodes, "stone", 6, 10, 4, "pickaxe", "Break Rock")

func _spawn_batch(count: int, item_id: String, amount_min: int, amount_max: int, hits: int, required_tool_id: String, label: String) -> void:
	for i in range(count):
		var node := Harvestable.new()
		node.drop_item_id = item_id
		node.amount = _rng.randi_range(amount_min, amount_max)
		node.hits_to_harvest = hits
		node.required_tool_id = required_tool_id
		node.interact_label = label
		add_child(node)
		WorldSync.register_entity(node, _next_resource_net_id)
		_next_resource_net_id += 1
		node.position = _pick_position()
		_match_visual(node, item_id, required_tool_id)

func _pick_position() -> Vector3:
	var terrain: TerrainGenerator = _get_terrain()
	for i in range(64):
		var p := Vector3(
			_rng.randf_range(-world_radius, world_radius),
			0.0,
			_rng.randf_range(-world_radius, world_radius)
		)
		if terrain != null:
			if terrain.distance_to_rails(p) < min_distance_to_rails:
				continue
			p.y = terrain.get_height_at(p.x, p.z)
		return p
	return Vector3.ZERO

func _match_visual(node: Harvestable, item_id: String, required_tool_id: String) -> void:
	if required_tool_id == "axe":
		HarvestableBuilder.build_tree(node, _rng)
		return
	if required_tool_id == "pickaxe":
		HarvestableBuilder.build_rock_large(node, _rng)
		return
	match item_id:
		"branch": HarvestableBuilder.build_branch_pile(node, _rng)
		"log": HarvestableBuilder.build_log(node, _rng)
		"stone": HarvestableBuilder.build_stone_small(node, _rng)
		"metal_scrap": HarvestableBuilder.build_scrap(node, _rng)
		_: HarvestableBuilder.build_components(node, _rng)

func _get_terrain() -> TerrainGenerator:
	var nodes := get_tree().get_nodes_in_group("terrain")
	if nodes.is_empty():
		return null
	return nodes[0] as TerrainGenerator


func _has_existing_tree_biome() -> bool:
	var parent_node: Node = get_parent()
	if parent_node == null:
		return false
	return parent_node.get_node_or_null("Trees") != null
