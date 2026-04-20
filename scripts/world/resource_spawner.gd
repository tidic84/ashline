extends Node3D
class_name ResourceSpawner

const PICKUP_TEST_ITEM_IDS: Array[String] = ["branch", "log", "stone", "metal_scrap"]

@export var world_radius: float = 85.0
@export var min_distance_to_rails: float = 5.0
@export var world_seed: int = 1701

@export var branch_nodes: int = 80
@export var log_nodes: int = 60
@export var stone_nodes: int = 70
@export var scrap_nodes: int = 50
@export var tree_nodes: int = 18
@export var big_rock_nodes: int = 14
@export var pickup_test_cluster_nodes: int = 18

@export_group("Tree Proximity Spawning")
@export var branch_tree_radius_min: float = 0.4
@export var branch_tree_radius_max: float = 2.5
@export var log_tree_radius_min: float = 1.0
@export var log_tree_radius_max: float = 4.0

var _rng := RandomNumberGenerator.new()
var _next_resource_net_id: int = 200000
var _tree_positions: PackedVector3Array = PackedVector3Array()

func _ready() -> void:
	var seed_value: int = world_seed if world_seed != 0 else int(Time.get_unix_time_from_system())
	_rng.seed = seed_value
	await get_tree().process_frame
	await get_tree().process_frame
	await _collect_tree_positions()
	_spawn_all()

func _collect_tree_positions() -> void:
	_tree_positions = PackedVector3Array()
	var parent_node: Node = get_parent()
	if parent_node == null:
		return
	var trees: Node = parent_node.get_node_or_null("Trees")
	if trees == null or not trees.has_method("get_generated_world_positions"):
		return
	for attempt in range(120):
		var positions: PackedVector3Array = trees.call("get_generated_world_positions")
		if positions.size() > 0:
			_tree_positions = positions
			return
		await get_tree().process_frame

func _spawn_all() -> void:
	_next_resource_net_id = 200000
	_spawn_pickup_test_cluster()
	_spawn_batch(branch_nodes, "branch", 2, 4, 1, "", "Collect Branches", true, branch_tree_radius_min, branch_tree_radius_max)
	_spawn_batch(log_nodes, "log", 2, 4, 1, "", "Collect Logs", true, log_tree_radius_min, log_tree_radius_max)
	_spawn_batch(stone_nodes, "stone", 2, 4, 1, "", "Pick Stones", false, 0.0, 0.0)
	_spawn_batch(scrap_nodes, "metal_scrap", 2, 4, 1, "", "Collect Scrap", false, 0.0, 0.0)
	if not _has_existing_tree_biome():
		_spawn_batch(tree_nodes, "log", 6, 10, 4, "axe", "Chop Tree", false, 0.0, 0.0)
	_spawn_batch(big_rock_nodes, "stone", 6, 10, 4, "pickaxe", "Break Rock", false, 0.0, 0.0)

func _spawn_batch(count: int, item_id: String, amount_min: int, amount_max: int, hits: int, required_tool_id: String, label: String, near_trees: bool = false, tree_radius_min: float = 0.0, tree_radius_max: float = 0.0) -> void:
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
		var spawn_position: Vector3 = Vector3.ZERO
		if near_trees and _tree_positions.size() > 0:
			spawn_position = _pick_position_near_tree(tree_radius_min, tree_radius_max)
		else:
			spawn_position = _pick_position()
		node.global_position = spawn_position
		_match_visual(node, item_id, required_tool_id)

func _spawn_pickup_test_cluster() -> void:
	if pickup_test_cluster_nodes <= 0:
		return
	var center: Vector3 = _get_pickup_test_center()
	for i in range(pickup_test_cluster_nodes):
		var item_id: String = PICKUP_TEST_ITEM_IDS[i % PICKUP_TEST_ITEM_IDS.size()]
		var node := Harvestable.new()
		node.drop_item_id = item_id
		node.amount = _rng.randi_range(2, 4)
		node.hits_to_harvest = 1
		node.required_tool_id = ""
		node.interact_label = "Collect"
		add_child(node)
		WorldSync.register_entity(node, _next_resource_net_id)
		_next_resource_net_id += 1
		var angle := float(i) / float(pickup_test_cluster_nodes) * TAU
		var radius := 2.5 + float(i % 3) * 1.3
		var pos := center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		var terrain: TerrainGenerator = _get_terrain()
		if terrain != null:
			pos.y = terrain.get_height_at(pos.x, pos.z)
		node.global_position = pos
		_match_visual(node, item_id, "")

func _get_pickup_test_center() -> Vector3:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player != null:
		return player.global_position
	var scene := get_tree().current_scene
	if scene != null:
		var fps := scene.get_node_or_null("UP_FPSController_Prefab") as Node3D
		if fps != null:
			return fps.global_position
	return Vector3.ZERO

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

func _pick_position_near_tree(radius_min: float, radius_max: float) -> Vector3:
	if _tree_positions.size() == 0:
		return _pick_position()
	var terrain: TerrainGenerator = _get_terrain()
	var low: float = minf(radius_min, radius_max)
	var high: float = maxf(radius_min, radius_max)
	for i in range(64):
		var tree_pos: Vector3 = _tree_positions[_rng.randi() % _tree_positions.size()]
		var angle: float = _rng.randf_range(0.0, TAU)
		var dist: float = _rng.randf_range(low, high)
		var p := Vector3(tree_pos.x + cos(angle) * dist, 0.0, tree_pos.z + sin(angle) * dist)
		if absf(p.x) > world_radius or absf(p.z) > world_radius:
			continue
		if terrain != null:
			if terrain.distance_to_rails(p) < min_distance_to_rails:
				continue
			p.y = terrain.get_height_at(p.x, p.z)
		return p
	return _pick_position()

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
