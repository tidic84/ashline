extends Node3D

@onready var players_container: Node3D = $Players
@onready var fps_controller: CharacterBody3D = $UP_FPSController_Prefab
@onready var build_controller: Node = $BuildController

var player_scene: PackedScene = preload("res://scenes/player/player.tscn")
var _spawn_origin: Vector3 = Vector3.ZERO
var _spawn_offsets: Array[Vector3] = [
	Vector3(4, 0, 0),
	Vector3(-4, 0, 0),
	Vector3(4, 0, 3),
	Vector3(-4, 0, 3),
]
var _loading_overlay: CanvasLayer = null

func _ready() -> void:
	_spawn_origin = fps_controller.global_position
	if multiplayer.has_multiplayer_peer():
		_disable_solo_controller()

	await get_tree().physics_frame
	await get_tree().physics_frame

	if multiplayer.has_multiplayer_peer():
		_spawn_multiplayer_players(_spawn_origin)
		if multiplayer.is_server():
			Inventory.setup_server_inventories(NetworkManager.players_info.keys())
		else:
			_show_loading_overlay("Synchronisation du monde...")
			WorldSync.request_world_snapshot_from_host()
	else:
		Inventory.grant_starter_inventory()

	GraphicsSettings.apply_all()
	AudioManager.force_play_ambient("train_ambience")
	GameManager.start_game()
	await get_tree().process_frame
	Inventory.force_refresh()


func _disable_solo_controller() -> void:
	if build_controller and is_instance_valid(build_controller):
		build_controller.queue_free()
	if fps_controller and is_instance_valid(fps_controller):
		fps_controller.queue_free()


func _spawn_multiplayer_players(base: Vector3) -> void:
	var idx: int = 0
	for peer_id in NetworkManager.players_info:
		_spawn_player_for_peer(int(peer_id), base, idx)
		idx += 1


func _spawn_player_for_peer(peer_id: int, base: Vector3, slot_index: int) -> Node3D:
	var existing := players_container.get_node_or_null("Player_%d" % peer_id)
	if existing != null:
		return existing as Node3D
	var player: Node3D = player_scene.instantiate()
	player.name = "Player_%d" % peer_id
	var info: Dictionary = NetworkManager.players_info.get(peer_id, {})
	if player.has_method("set_display_name"):
		player.set_display_name(String(info.get("name", "Player %d" % peer_id)))
	player.set_multiplayer_authority(peer_id)
	players_container.add_child(player)
	WorldSync.register_entity(player, peer_id)
	var offset_idx: int = clampi(slot_index, 0, _spawn_offsets.size() - 1)
	player.global_position = base + _spawn_offsets[offset_idx]
	return player


func spawn_player_for_late_join(peer_id: int) -> void:
	var slot_index: int = players_container.get_child_count()
	_spawn_player_for_peer(peer_id, _spawn_origin, slot_index)


func get_spawn_position_for_peer(peer_id: int) -> Vector3:
	var slot_index: int = 0
	for peer_id_value in NetworkManager.players_info.keys():
		if int(peer_id_value) == peer_id:
			break
		slot_index += 1
	var offset_idx: int = clampi(slot_index, 0, _spawn_offsets.size() - 1)
	return _spawn_origin + _spawn_offsets[offset_idx]


func hide_loading_overlay() -> void:
	if _loading_overlay and is_instance_valid(_loading_overlay):
		_loading_overlay.queue_free()
	_loading_overlay = null


func _show_loading_overlay(message: String) -> void:
	if _loading_overlay and is_instance_valid(_loading_overlay):
		return
	var layer := CanvasLayer.new()
	layer.layer = 128
	var rect := ColorRect.new()
	rect.color = Color(0.06, 0.08, 0.08, 0.92)
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	layer.add_child(rect)
	var label := Label.new()
	label.text = message
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	label.add_theme_font_size_override("font_size", 28)
	layer.add_child(label)
	add_child(layer)
	_loading_overlay = layer
