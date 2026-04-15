extends Node3D

@onready var players_container: Node3D = $Players
@onready var fps_controller: CharacterBody3D = $UP_FPSController_Prefab
@onready var build_controller: Node = $BuildController

var player_scene: PackedScene = preload("res://scenes/player/player.tscn")

func _ready() -> void:
	var spawn_origin: Vector3 = fps_controller.global_position
	if multiplayer.has_multiplayer_peer():
		_disable_solo_controller()

	await get_tree().physics_frame
	await get_tree().physics_frame

	if multiplayer.has_multiplayer_peer():
		if multiplayer.is_server():
			Inventory.setup_server_inventories(NetworkManager.players_info.keys())
		_spawn_multiplayer_players(spawn_origin)
	else:
		Inventory.grant_starter_inventory()

	GraphicsSettings.apply_all()
	AudioManager.play_ambient("train_ambience")
	GameManager.start_game()


func _disable_solo_controller() -> void:
	if build_controller and is_instance_valid(build_controller):
		build_controller.queue_free()
	if fps_controller and is_instance_valid(fps_controller):
		fps_controller.queue_free()


func _spawn_multiplayer_players(base: Vector3) -> void:
	var spawn_offsets: Array[Vector3] = [
		Vector3(4, 0, 0),
		Vector3(-4, 0, 0),
		Vector3(4, 0, 3),
		Vector3(-4, 0, 3),
	]
	var idx: int = 0
	for peer_id in NetworkManager.players_info:
		var player: Node3D = player_scene.instantiate()
		player.name = "Player_%d" % int(peer_id)
		var info: Dictionary = NetworkManager.players_info[peer_id]
		if player.has_method("set_display_name"):
			player.set_display_name(String(info.get("name", "Player %d" % int(peer_id))))
		player.set_multiplayer_authority(peer_id)
		players_container.add_child(player)
		WorldSync.register_entity(player, int(peer_id))
		if idx < spawn_offsets.size():
			player.global_position = base + spawn_offsets[idx]
		idx += 1
