extends Control

@onready var name_input: LineEdit = $VBoxContainer/NameInput
@onready var address_input: LineEdit = $VBoxContainer/AddressInput
@onready var port_input: LineEdit = $VBoxContainer/PortInput
@onready var host_button: Button = $VBoxContainer/HBoxContainer/HostButton
@onready var join_button: Button = $VBoxContainer/HBoxContainer/JoinButton
@onready var start_button: Button = $VBoxContainer/StartButton
@onready var player_list: ItemList = $VBoxContainer/PlayerList
@onready var status_label: Label = $VBoxContainer/StatusLabel

@onready var solo_button: Button = $VBoxContainer/SoloButton

func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	start_button.pressed.connect(_on_start_pressed)
	solo_button.pressed.connect(_on_solo_pressed)
	start_button.visible = false

	NetworkManager.player_connected.connect(_on_player_connected)
	NetworkManager.player_disconnected.connect(_on_player_disconnected)
	NetworkManager.server_started.connect(_on_server_started)
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)

	address_input.text = "localhost"
	port_input.text = str(NetworkManager.DEFAULT_PORT)
	name_input.text = "Player"

func _on_solo_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main/main.tscn")

func _on_host_pressed() -> void:
	NetworkManager.local_player_name = name_input.text
	var port := int(port_input.text)
	var error := NetworkManager.host_game(port)
	if error != OK:
		status_label.text = "Failed to host: %s" % error_string(error)
		return
	status_label.text = "Hosting on port %d..." % port
	host_button.disabled = true
	join_button.disabled = true
	start_button.visible = true
	_refresh_player_list()

func _on_join_pressed() -> void:
	NetworkManager.local_player_name = name_input.text
	var address := address_input.text
	var port := int(port_input.text)
	var error := NetworkManager.join_game(address, port)
	if error != OK:
		status_label.text = "Failed to join: %s" % error_string(error)
		return
	status_label.text = "Connecting to %s:%d..." % [address, port]
	host_button.disabled = true
	join_button.disabled = true

func _on_start_pressed() -> void:
	if not NetworkManager.is_host():
		return
	NetworkManager.start_game.rpc()

func _on_server_started() -> void:
	status_label.text = "Server running. Waiting for players..."
	_refresh_player_list()

func _on_connection_succeeded() -> void:
	status_label.text = "Connected!"
	_refresh_player_list()

func _on_connection_failed() -> void:
	status_label.text = "Connection failed."
	host_button.disabled = false
	join_button.disabled = false

func _on_player_connected(_id: int) -> void:
	_refresh_player_list()

func _on_player_disconnected(_id: int) -> void:
	_refresh_player_list()

func _refresh_player_list() -> void:
	player_list.clear()
	for id in NetworkManager.players_info:
		var info: Dictionary = NetworkManager.players_info[id]
		var host_tag: String = " (Host)" if id == 1 else ""
		player_list.add_item("%s%s" % [info.name, host_tag])
