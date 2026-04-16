extends Control

@onready var name_input: LineEdit = get_node_or_null("VBoxContainer/NameInput") as LineEdit
@onready var address_input: LineEdit = get_node_or_null("VBoxContainer/AddressInput") as LineEdit
@onready var port_input: LineEdit = get_node_or_null("VBoxContainer/PortInput") as LineEdit
@onready var host_button: Button = get_node_or_null("VBoxContainer/HBoxContainer/HostButton") as Button
@onready var join_button: Button = get_node_or_null("VBoxContainer/HBoxContainer/JoinButton") as Button
@onready var start_button: Button = get_node_or_null("VBoxContainer/StartButton") as Button
@onready var player_list: ItemList = get_node_or_null("VBoxContainer/PlayerList") as ItemList
@onready var status_label: Label = get_node_or_null("VBoxContainer/StatusLabel") as Label
@onready var chat_log: RichTextLabel = get_node_or_null("VBoxContainer/ChatLog") as RichTextLabel
@onready var chat_input: LineEdit = get_node_or_null("VBoxContainer/ChatRow/ChatInput") as LineEdit
@onready var chat_send_button: Button = get_node_or_null("VBoxContainer/ChatRow/ChatSendButton") as Button

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
	if chat_input:
		chat_input.text_submitted.connect(_on_chat_submitted)
	if chat_send_button:
		chat_send_button.pressed.connect(_on_chat_send_pressed)

	_connect_network_signal(NetworkManager.player_connected, _on_player_connected)
	_connect_network_signal(NetworkManager.player_disconnected, _on_player_disconnected)
	_connect_network_signal(NetworkManager.server_started, _on_server_started)
	_connect_network_signal(NetworkManager.connection_succeeded, _on_connection_succeeded)
	_connect_network_signal(NetworkManager.connection_failed, _on_connection_failed)
	_connect_network_signal(NetworkManager.lobby_updated, _refresh_player_list)
	_connect_network_signal(NetworkManager.chat_message_received, _on_chat_message_received)

	if address_input:
		address_input.text = "localhost"
	if port_input:
		port_input.text = str(NetworkManager.DEFAULT_PORT)
	if name_input:
		name_input.text = "Player"
	_refresh_lobby_controls()

func _connect_network_signal(sig: Signal, callback: Callable) -> void:
	if not sig.is_connected(callback):
		sig.connect(callback)

func _on_solo_pressed() -> void:
	NetworkManager.local_player_name = name_input.text if name_input else "Player"
	var port := int(port_input.text) if port_input else NetworkManager.DEFAULT_PORT
	if multiplayer.has_multiplayer_peer() and not NetworkManager.is_host():
		NetworkManager.set_player_ready.rpc_id(1, true)
		_set_status("Pret. En attente du lancement par l'hote.")
		_refresh_lobby_controls()
		return
	if not multiplayer.has_multiplayer_peer():
		var error := NetworkManager.host_game(port)
		if error != OK:
			_set_status("Failed to start: %s" % error_string(error))
			return
	_set_status("Launching shared game on port %d..." % port)
	NetworkManager.host_start_game()

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
	_refresh_lobby_controls()
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
	_refresh_lobby_controls()

func _on_start_pressed() -> void:
	if not NetworkManager.is_host():
		return
	NetworkManager.host_start_game()

func _on_server_started() -> void:
	_set_status("Server running. Waiting for players...")
	_refresh_player_list()

func _on_connection_succeeded() -> void:
	_set_status("Connected!")
	if start_button:
		start_button.visible = false
	_refresh_lobby_controls()
	_refresh_player_list()

func _on_connection_failed() -> void:
	_set_status("Connection failed.")
	if host_button:
		host_button.disabled = false
	if join_button:
		join_button.disabled = false
	_refresh_lobby_controls()

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
	_refresh_lobby_controls()

func _refresh_lobby_controls() -> void:
	if solo_button == null:
		return
	if not multiplayer.has_multiplayer_peer():
		solo_button.text = "Creer et jouer"
		solo_button.disabled = false
	elif NetworkManager.is_host():
		solo_button.text = "Lancer la partie"
		solo_button.disabled = false
	else:
		solo_button.text = "Pret"
		solo_button.disabled = false

func _set_status(text: String) -> void:
	if status_label:
		status_label.text = text

func _on_chat_send_pressed() -> void:
	if chat_input:
		_on_chat_submitted(chat_input.text)

func _on_chat_submitted(text: String) -> void:
	NetworkManager.send_chat_message(text)
	if chat_input:
		chat_input.clear()

func _on_chat_message_received(_peer_id: int, player_name: String, message: String, is_system: bool) -> void:
	if chat_log == null:
		return
	var prefix := "*" if is_system else player_name + ":"
	chat_log.append_text("%s %s\n" % [prefix, message])
	chat_log.scroll_to_line(chat_log.get_line_count())
