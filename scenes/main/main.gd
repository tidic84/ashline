extends Node3D

@onready var players_container: Node3D = $Players
@onready var fps_controller: CharacterBody3D = $UP_FPSController_Prefab

var player_scene: PackedScene = preload("res://scenes/player/player.tscn")

func _ready() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame

	if multiplayer.has_multiplayer_peer():
		_spawn_multiplayer_players()

	Inventory.add_resource("wood", 1000)
	Inventory.add_resource("metal", 800)
	Inventory.add_resource("components", 400)
	Inventory.add_resource("fuel", 600)

	GraphicsSettings.apply_all()
	GameManager.start_game()


func _spawn_multiplayer_players() -> void:
	var spawn_offsets: Array[Vector3] = [
		Vector3(4, 0, 0),
		Vector3(-4, 0, 0),
		Vector3(4, 0, 3),
		Vector3(-4, 0, 3),
	]
	var idx: int = 0
	var base: Vector3 = fps_controller.global_position
	for peer_id in NetworkManager.players_info:
		var player: Node3D = player_scene.instantiate()
		player.name = str(peer_id)
		player.set_multiplayer_authority(peer_id)
		players_container.add_child(player)
		if idx < spawn_offsets.size():
			player.global_position = base + spawn_offsets[idx]
		idx += 1
