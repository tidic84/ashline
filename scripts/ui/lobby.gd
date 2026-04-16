extends Control

@onready var name_input: LineEdit = $MainHBox/LeftPanel/LeftMargin/LeftVBox/NameInput
@onready var address_input: LineEdit = $MainHBox/LeftPanel/LeftMargin/LeftVBox/AddressInput
@onready var port_input: LineEdit = $MainHBox/LeftPanel/LeftMargin/LeftVBox/PortInput
@onready var host_button: Button = $MainHBox/LeftPanel/LeftMargin/LeftVBox/HBoxContainer/HostButton
@onready var join_button: Button = $MainHBox/LeftPanel/LeftMargin/LeftVBox/HBoxContainer/JoinButton
@onready var start_button: Button = $MainHBox/LeftPanel/LeftMargin/LeftVBox/StartButton
@onready var solo_button: Button = $MainHBox/LeftPanel/LeftMargin/LeftVBox/SoloButton
@onready var status_label: Label = $MainHBox/LeftPanel/LeftMargin/LeftVBox/StatusLabel
@onready var player_list: ItemList = $MainHBox/RightPanel/RightMargin/RightVBox/PlayerList
@onready var chat_log: RichTextLabel = $MainHBox/RightPanel/RightMargin/RightVBox/ChatLog
@onready var chat_input: LineEdit = $MainHBox/RightPanel/RightMargin/RightVBox/ChatRow/ChatInput
@onready var chat_send_button: Button = $MainHBox/RightPanel/RightMargin/RightVBox/ChatRow/ChatSendButton

func _ready() -> void:
	_apply_panel_styles()
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	start_button.pressed.connect(_on_start_pressed)
	start_button.visible = false
	solo_button.pressed.connect(_on_solo_pressed)
	chat_input.text_submitted.connect(_on_chat_submitted)
	chat_send_button.pressed.connect(_on_chat_send_pressed)

	_connect_network_signal(NetworkManager.player_connected, _on_player_connected)
	_connect_network_signal(NetworkManager.player_disconnected, _on_player_disconnected)
	_connect_network_signal(NetworkManager.server_started, _on_server_started)
	_connect_network_signal(NetworkManager.connection_succeeded, _on_connection_succeeded)
	_connect_network_signal(NetworkManager.connection_failed, _on_connection_failed)
	_connect_network_signal(NetworkManager.lobby_updated, _refresh_player_list)
	_connect_network_signal(NetworkManager.chat_message_received, _on_chat_message_received)

	address_input.text = "localhost"
	port_input.text = str(NetworkManager.DEFAULT_PORT)
	name_input.text = "Player"
	_refresh_lobby_controls()
	AudioManager.play_ambient("train_ambience")

func _apply_panel_styles() -> void:
	var left_style := StyleBoxFlat.new()
	left_style.bg_color = Color(0.08, 0.10, 0.07, 0.92)
	left_style.border_width_right = 2
	left_style.border_color = Color(0.35, 0.28, 0.15, 0.6)
	$MainHBox/LeftPanel.add_theme_stylebox_override("panel", left_style)

	var right_style := StyleBoxFlat.new()
	right_style.bg_color = Color(0.06, 0.08, 0.06, 0.88)
	$MainHBox/RightPanel.add_theme_stylebox_override("panel", right_style)

	for btn in [solo_button, host_button, join_button]:
		var normal := StyleBoxFlat.new()
		normal.bg_color = Color(0.18, 0.22, 0.15, 0.85)
		normal.border_width_top = 1
		normal.border_width_bottom = 1
		normal.border_width_left = 1
		normal.border_width_right = 1
		normal.border_color = Color(0.4, 0.35, 0.2, 0.6)
		normal.corner_radius_top_left = 3
		normal.corner_radius_top_right = 3
		normal.corner_radius_bottom_left = 3
		normal.corner_radius_bottom_right = 3
		btn.add_theme_stylebox_override("normal", normal)
		var hover := normal.duplicate() as StyleBoxFlat
		hover.bg_color = Color(0.25, 0.30, 0.18, 0.95)
		hover.border_color = Color(0.8, 0.7, 0.4, 0.8)
		btn.add_theme_stylebox_override("hover", hover)
		var pressed := normal.duplicate() as StyleBoxFlat
		pressed.bg_color = Color(0.35, 0.28, 0.15, 0.95)
		btn.add_theme_stylebox_override("pressed", pressed)

	var start_normal := StyleBoxFlat.new()
	start_normal.bg_color = Color(0.72, 0.62, 0.32, 0.95)
	start_normal.border_width_top = 2
	start_normal.border_width_bottom = 2
	start_normal.border_width_left = 2
	start_normal.border_width_right = 2
	start_normal.border_color = Color(0.85, 0.75, 0.4, 0.9)
	start_normal.corner_radius_top_left = 4
	start_normal.corner_radius_top_right = 4
	start_normal.corner_radius_bottom_left = 4
	start_normal.corner_radius_bottom_right = 4
	start_button.add_theme_stylebox_override("normal", start_normal)
	var start_hover := start_normal.duplicate() as StyleBoxFlat
	start_hover.bg_color = Color(0.82, 0.72, 0.38, 1.0)
	start_button.add_theme_stylebox_override("hover", start_hover)

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
			_set_status("Erreur: %s" % error_string(error))
			return
	_set_status("Lancement sur le port %d..." % port)
	NetworkManager.host_start_game()

func _on_host_pressed() -> void:
	NetworkManager.local_player_name = name_input.text if name_input else "Player"
	var port := int(port_input.text) if port_input else NetworkManager.DEFAULT_PORT
	var error := NetworkManager.host_game(port)
	if error != OK:
		_set_status("Erreur: %s" % error_string(error))
		return
	_set_status("Hebergement sur le port %d..." % port)
	host_button.disabled = true
	join_button.disabled = true
	_refresh_lobby_controls()
	_refresh_player_list()

func _on_join_pressed() -> void:
	NetworkManager.local_player_name = name_input.text if name_input else "Player"
	var address := address_input.text if address_input else "localhost"
	var port := int(port_input.text) if port_input else NetworkManager.DEFAULT_PORT
	var error := NetworkManager.join_game(address, port)
	if error != OK:
		_set_status("Erreur: %s" % error_string(error))
		return
	_set_status("Connexion a %s:%d..." % [address, port])
	host_button.disabled = true
	join_button.disabled = true
	_refresh_lobby_controls()

func _on_start_pressed() -> void:
	if not NetworkManager.is_host():
		return
	NetworkManager.host_start_game()

func _on_server_started() -> void:
	_set_status("Serveur en cours. En attente de joueurs...")
	_refresh_player_list()

func _on_connection_succeeded() -> void:
	_set_status("Connecte!")
	_refresh_lobby_controls()
	_refresh_player_list()

func _on_connection_failed() -> void:
	_set_status("Echec de connexion.")
	host_button.disabled = false
	join_button.disabled = false
	_refresh_lobby_controls()

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
	_refresh_lobby_controls()

func _refresh_lobby_controls() -> void:
	if not multiplayer.has_multiplayer_peer():
		solo_button.text = "Jouer en solo"
		solo_button.disabled = false
	elif NetworkManager.is_host():
		solo_button.text = "Lancer la partie"
		solo_button.disabled = false
	else:
		solo_button.text = "Pret"
		solo_button.disabled = false

func _set_status(text: String) -> void:
	status_label.text = text

func _on_chat_send_pressed() -> void:
	_on_chat_submitted(chat_input.text)

func _on_chat_submitted(text: String) -> void:
	NetworkManager.send_chat_message(text)
	chat_input.clear()

func _on_chat_message_received(_peer_id: int, player_name: String, message: String, is_system: bool) -> void:
	var prefix := "*" if is_system else player_name + ":"
	chat_log.append_text("%s %s\n" % [prefix, message])
	chat_log.scroll_to_line(chat_log.get_line_count())
