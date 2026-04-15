extends Control

@onready var name_input: LineEdit = get_node_or_null("VBoxContainer/NameInput") as LineEdit
@onready var address_input: LineEdit = get_node_or_null("VBoxContainer/AddressInput") as LineEdit
@onready var port_input: LineEdit = get_node_or_null("VBoxContainer/PortInput") as LineEdit
@onready var host_button: Button = get_node_or_null("VBoxContainer/HBoxContainer/HostButton") as Button
@onready var join_button: Button = get_node_or_null("VBoxContainer/HBoxContainer/JoinButton") as Button
@onready var start_button: Button = get_node_or_null("VBoxContainer/StartButton") as Button
@onready var player_list: ItemList = get_node_or_null("VBoxContainer/PlayerList") as ItemList
@onready var status_label: Label = get_node_or_null("VBoxContainer/StatusLabel") as Label

@onready var solo_button: Button = get_node_or_null("VBoxContainer/SoloButton") as Button

func _ready() -> void:
	if host_button:
		host_button.pressed.connect(_on_host_pressed)
	if join_button:
		join_button.pressed.connect(_on_join_pressed)
	if start_button:
		start_button.pressed.connect(_on_start_pressed)
		start_button.visible = false
	if solo_button:
		solo_button.pressed.connect(_on_solo_pressed)

	_connect_network_signal(NetworkManager.player_connected, _on_player_connected)
	_connect_network_signal(NetworkManager.player_disconnected, _on_player_disconnected)
	_connect_network_signal(NetworkManager.server_started, _on_server_started)
	_connect_network_signal(NetworkManager.connection_succeeded, _on_connection_succeeded)
	_connect_network_signal(NetworkManager.connection_failed, _on_connection_failed)
	_connect_network_signal(NetworkManager.lobby_updated, _refresh_player_list)

	if address_input:
		address_input.text = "localhost"
	if port_input:
		port_input.text = str(NetworkManager.DEFAULT_PORT)
	if name_input:
		name_input.text = "Player"

func _connect_network_signal(sig: Signal, callback: Callable) -> void:
	if not sig.is_connected(callback):
		sig.connect(callback)

func _on_solo_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main/main.tscn")

func _on_host_pressed() -> void:
	NetworkManager.local_player_name = name_input.text if name_input else "Player"
	var port := int(port_input.text) if port_input else NetworkManager.DEFAULT_PORT
	var error := NetworkManager.host_game(port)
	if error != OK:
		_set_status("Failed to host: %s" % error_string(error))
		return
	_set_status("Hosting on port %d..." % port)
	if host_button:
		host_button.disabled = true
	if join_button:
		join_button.disabled = true
	if start_button:
		start_button.visible = true
	_refresh_player_list()

func _on_join_pressed() -> void:
	NetworkManager.local_player_name = name_input.text if name_input else "Player"
	var address := address_input.text if address_input else "localhost"
	var port := int(port_input.text) if port_input else NetworkManager.DEFAULT_PORT
	var error := NetworkManager.join_game(address, port)
	if error != OK:
		_set_status("Failed to join: %s" % error_string(error))
		return
	_set_status("Connecting to %s:%d..." % [address, port])
	if host_button:
		host_button.disabled = true
	if join_button:
		join_button.disabled = true

func _on_start_pressed() -> void:
	if not NetworkManager.is_host():
		return
	NetworkManager.start_game.rpc()

func _on_server_started() -> void:
	_set_status("Server running. Waiting for players...")
	_refresh_player_list()

func _on_connection_succeeded() -> void:
	_set_status("Connected!")
	if start_button:
		start_button.visible = false
	_refresh_player_list()

func _on_connection_failed() -> void:
	_set_status("Connection failed.")
	if host_button:
		host_button.disabled = false
	if join_button:
		join_button.disabled = false

func _on_player_connected(_id: int) -> void:
	_refresh_player_list()

func _on_player_disconnected(_id: int) -> void:
	_refresh_player_list()

func _refresh_player_list() -> void:
	if player_list == null:
		return
	player_list.clear()
	for id in NetworkManager.players_info:
		var info: Dictionary = NetworkManager.players_info[id]
		var host_tag: String = " (Host)" if id == 1 else ""
		player_list.add_item("%s%s" % [info.name, host_tag])

func _set_status(text: String) -> void:
	if status_label:
		status_label.text = text
