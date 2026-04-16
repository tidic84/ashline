extends Node

signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)
signal server_started
signal connection_failed
signal connection_succeeded
signal lobby_updated
signal chat_message_received(peer_id: int, player_name: String, message: String, is_system: bool)

const DEFAULT_PORT: int = 27015
const MAX_PLAYERS: int = 4

var peer: ENetMultiplayerPeer = null
var players_info: Dictionary = {} # peer_id -> { name, character, ready }
var local_player_name: String = "Player"

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func host_game(port: int = DEFAULT_PORT) -> Error:
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_server(port, MAX_PLAYERS)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	players_info.clear()
	players_info[1] = { "name": local_player_name, "ready": false }
	server_started.emit()
	lobby_updated.emit()
	_emit_system_chat("%s hosts the game." % local_player_name)
	return OK

func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_client(address, port)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	return OK

func disconnect_game() -> void:
	if peer:
		peer.close()
		peer = null
	multiplayer.multiplayer_peer = null
	players_info.clear()
	lobby_updated.emit()

func is_host() -> bool:
	return multiplayer.is_server()

func get_player_count() -> int:
	return players_info.size()

@rpc("any_peer", "reliable")
func request_register_player(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = 1
	players_info[sender_id] = { "name": player_name, "ready": false }
	player_connected.emit(sender_id)
	lobby_updated.emit()
	_sync_lobby_state.rpc(players_info)
	_broadcast_system_chat("%s joined." % player_name)

@rpc("authority", "reliable")
func _sync_lobby_state(snapshot: Dictionary) -> void:
	players_info = snapshot.duplicate(true)
	lobby_updated.emit()

@rpc("any_peer", "reliable")
func set_player_ready(ready: bool) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = 1
	if players_info.has(sender_id):
		players_info[sender_id].ready = ready
	if multiplayer.is_server():
		lobby_updated.emit()
		_sync_lobby_state.rpc(players_info)
		_check_all_ready()

func _check_all_ready() -> void:
	if players_info.size() < 1:
		return
	for id in players_info:
		if not players_info[id].ready:
			return
	# All ready - start game
	host_start_game()

func host_start_game() -> void:
	if not multiplayer.is_server():
		return
	for id in players_info:
		var peer_id := int(id)
		if peer_id == 1:
			continue
		start_game.rpc_id(peer_id)
	start_game()

@rpc("authority", "call_local", "reliable")
func start_game() -> void:
	get_tree().change_scene_to_file("res://scenes/main/main.tscn")

func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		_sync_lobby_state.rpc_id(id, players_info)

func _on_peer_disconnected(id: int) -> void:
	var player_name := _get_player_name(id)
	players_info.erase(id)
	player_disconnected.emit(id)
	lobby_updated.emit()
	if multiplayer.is_server():
		_sync_lobby_state.rpc(players_info)
		_broadcast_system_chat("%s left." % player_name)
	# Remove their player node
	var player_node: Node = get_tree().current_scene.get_node_or_null("Players/Player_%d" % id)
	if player_node == null:
		player_node = get_tree().current_scene.get_node_or_null(str(id))
	if player_node:
		player_node.queue_free()

func _on_connected_to_server() -> void:
	var my_id := multiplayer.get_unique_id()
	players_info[my_id] = { "name": local_player_name, "ready": false }
	request_register_player.rpc_id(1, local_player_name)
	connection_succeeded.emit()

func _on_connection_failed() -> void:
	connection_failed.emit()
	disconnect_game()

func _on_server_disconnected() -> void:
	disconnect_game()
	get_tree().change_scene_to_file("res://scenes/ui/lobby.tscn")

func send_chat_message(message: String) -> void:
	var clean := message.strip_edges()
	if clean.is_empty():
		return
	if clean.length() > 160:
		clean = clean.substr(0, 160)
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		request_chat_message.rpc_id(1, clean)
		return
	var peer_id := multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1
	_broadcast_chat_message(peer_id, _get_player_name(peer_id), clean, false)

@rpc("any_peer", "reliable")
func request_chat_message(message: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = 1
	var clean := message.strip_edges()
	if clean.is_empty():
		return
	if clean.length() > 160:
		clean = clean.substr(0, 160)
	_broadcast_chat_message(sender_id, _get_player_name(sender_id), clean, false)

func _broadcast_system_chat(message: String) -> void:
	_broadcast_chat_message(0, "System", message, true)

func _emit_system_chat(message: String) -> void:
	chat_message_received.emit(0, "System", message, true)

func _broadcast_chat_message(peer_id: int, player_name: String, message: String, is_system: bool) -> void:
	chat_message_received.emit(peer_id, player_name, message, is_system)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		receive_chat_message.rpc(peer_id, player_name, message, is_system)

@rpc("authority", "reliable")
func receive_chat_message(peer_id: int, player_name: String, message: String, is_system: bool) -> void:
	chat_message_received.emit(peer_id, player_name, message, is_system)

func _get_player_name(peer_id: int) -> String:
	if peer_id == 0:
		return "System"
	if players_info.has(peer_id):
		return String(players_info[peer_id].get("name", "Player %d" % peer_id))
	if peer_id == 1:
		return local_player_name
	return "Player %d" % peer_id
