extends Control

enum Page { MAIN, COOP, LOBBY }

@onready var main_page: VBoxContainer = $MenuRoot/PanelStack/StackMargin/StackRoot/MainPage
@onready var coop_page: VBoxContainer = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage
@onready var lobby_page: VBoxContainer = $MenuRoot/PanelStack/StackMargin/StackRoot/LobbyPage

@onready var solo_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/MainPage/SoloButton
@onready var coop_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/MainPage/CoopButton
@onready var settings_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/MainPage/SettingsButton
@onready var quit_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/MainPage/QuitButton

@onready var name_input: LineEdit = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage/NameInput
@onready var address_input: LineEdit = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage/AddressRow/AddressInput
@onready var port_input: LineEdit = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage/AddressRow/PortInput
@onready var action_row: HBoxContainer = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage/ActionRow
@onready var host_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage/ActionRow/HostButton
@onready var join_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage/ActionRow/JoinButton
@onready var connecting_row: VBoxContainer = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage/ConnectingRow
@onready var connecting_label: Label = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage/ConnectingRow/ConnectingLabel
@onready var cancel_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage/ConnectingRow/CancelButton
@onready var back_coop_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/CoopPage/BackCoopButton

@onready var player_list: ItemList = $MenuRoot/PanelStack/StackMargin/StackRoot/LobbyPage/PlayerList
@onready var player_count_label: Label = $MenuRoot/PanelStack/StackMargin/StackRoot/LobbyPage/LobbyHeader/PlayerCountLabel
@onready var chat_log: RichTextLabel = $MenuRoot/PanelStack/StackMargin/StackRoot/LobbyPage/ChatLog
@onready var chat_input: LineEdit = $MenuRoot/PanelStack/StackMargin/StackRoot/LobbyPage/ChatRow/ChatInput
@onready var chat_send_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/LobbyPage/ChatRow/ChatSendButton
@onready var start_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/LobbyPage/StartButton
@onready var back_lobby_button: Button = $MenuRoot/PanelStack/StackMargin/StackRoot/LobbyPage/BackLobbyButton

@onready var status_label: Label = $MenuRoot/PanelStack/StackMargin/StackRoot/StatusLabel
@onready var settings_menu: SettingsMenu = $SettingsLayer/SettingsMenu

var _current_page: int = Page.MAIN
var _connecting: bool = false

func _ready() -> void:
	_apply_styles()

	solo_button.pressed.connect(_on_solo_pressed)
	coop_button.pressed.connect(_on_coop_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	quit_button.pressed.connect(_on_quit_pressed)

	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	cancel_button.pressed.connect(_on_cancel_connection)
	back_coop_button.pressed.connect(_on_back_to_main)

	start_button.pressed.connect(_on_start_pressed)
	back_lobby_button.pressed.connect(_on_leave_lobby)
	chat_input.text_submitted.connect(_on_chat_submitted)
	chat_send_button.pressed.connect(_on_chat_send_pressed)

	settings_menu.closed.connect(_on_settings_closed)

	_connect_network_signal(NetworkManager.player_connected, _on_player_connected)
	_connect_network_signal(NetworkManager.player_disconnected, _on_player_disconnected)
	_connect_network_signal(NetworkManager.server_started, _on_server_started)
	_connect_network_signal(NetworkManager.connection_succeeded, _on_connection_succeeded)
	_connect_network_signal(NetworkManager.connection_failed, _on_connection_failed)
	_connect_network_signal(NetworkManager.lobby_updated, _refresh_player_list)
	_connect_network_signal(NetworkManager.chat_message_received, _on_chat_message_received)

	address_input.text = "localhost"
	port_input.text = str(NetworkManager.DEFAULT_PORT)
	name_input.text = NetworkManager.local_player_name if NetworkManager.local_player_name != "" else "Player"

	_show_page(Page.MAIN)
	AudioManager.play_ambient("train_ambience")

func _apply_styles() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.10, 0.07, 0.92)
	panel_style.border_width_top = 1
	panel_style.border_width_bottom = 1
	panel_style.border_width_left = 1
	panel_style.border_width_right = 1
	panel_style.border_color = Color(0.35, 0.28, 0.15, 0.55)
	panel_style.corner_radius_top_left = 6
	panel_style.corner_radius_top_right = 6
	panel_style.corner_radius_bottom_left = 6
	panel_style.corner_radius_bottom_right = 6
	panel_style.shadow_color = Color(0, 0, 0, 0.55)
	panel_style.shadow_size = 18
	$MenuRoot/PanelStack.add_theme_stylebox_override("panel", panel_style)

	_style_primary_button(solo_button)
	_style_primary_button(start_button)
	for btn in [coop_button, host_button, join_button]:
		_style_secondary_button(btn)
	_style_cancel_button(cancel_button)
	for btn in [settings_button, quit_button, back_coop_button, back_lobby_button, chat_send_button]:
		_style_tertiary_button(btn)

func _style_primary_button(btn: Button) -> void:
	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.78, 0.65, 0.32, 0.98)
	n.border_width_top = 2
	n.border_width_bottom = 2
	n.border_width_left = 2
	n.border_width_right = 2
	n.border_color = Color(0.92, 0.8, 0.45, 0.95)
	n.corner_radius_top_left = 4
	n.corner_radius_top_right = 4
	n.corner_radius_bottom_left = 4
	n.corner_radius_bottom_right = 4
	btn.add_theme_stylebox_override("normal", n)
	var h := n.duplicate() as StyleBoxFlat
	h.bg_color = Color(0.92, 0.78, 0.4, 1.0)
	btn.add_theme_stylebox_override("hover", h)
	var p := n.duplicate() as StyleBoxFlat
	p.bg_color = Color(0.58, 0.48, 0.22, 1.0)
	btn.add_theme_stylebox_override("pressed", p)

func _style_secondary_button(btn: Button) -> void:
	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.18, 0.22, 0.15, 0.9)
	n.border_width_top = 1
	n.border_width_bottom = 1
	n.border_width_left = 1
	n.border_width_right = 1
	n.border_color = Color(0.45, 0.4, 0.22, 0.65)
	n.corner_radius_top_left = 3
	n.corner_radius_top_right = 3
	n.corner_radius_bottom_left = 3
	n.corner_radius_bottom_right = 3
	btn.add_theme_stylebox_override("normal", n)
	var h := n.duplicate() as StyleBoxFlat
	h.bg_color = Color(0.28, 0.32, 0.2, 0.98)
	h.border_color = Color(0.85, 0.72, 0.42, 0.8)
	btn.add_theme_stylebox_override("hover", h)
	var p := n.duplicate() as StyleBoxFlat
	p.bg_color = Color(0.36, 0.3, 0.16, 1.0)
	btn.add_theme_stylebox_override("pressed", p)

func _style_cancel_button(btn: Button) -> void:
	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.32, 0.12, 0.1, 0.9)
	n.border_width_top = 1
	n.border_width_bottom = 1
	n.border_width_left = 1
	n.border_width_right = 1
	n.border_color = Color(0.7, 0.35, 0.3, 0.7)
	n.corner_radius_top_left = 3
	n.corner_radius_top_right = 3
	n.corner_radius_bottom_left = 3
	n.corner_radius_bottom_right = 3
	btn.add_theme_stylebox_override("normal", n)
	var h := n.duplicate() as StyleBoxFlat
	h.bg_color = Color(0.5, 0.18, 0.14, 1.0)
	h.border_color = Color(0.95, 0.6, 0.5, 0.9)
	btn.add_theme_stylebox_override("hover", h)
	var p := n.duplicate() as StyleBoxFlat
	p.bg_color = Color(0.6, 0.22, 0.16, 1.0)
	btn.add_theme_stylebox_override("pressed", p)

func _style_tertiary_button(btn: Button) -> void:
	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.08, 0.10, 0.08, 0.0)
	btn.add_theme_stylebox_override("normal", n)
	var h := StyleBoxFlat.new()
	h.bg_color = Color(0.2, 0.22, 0.16, 0.6)
	h.corner_radius_top_left = 3
	h.corner_radius_top_right = 3
	h.corner_radius_bottom_left = 3
	h.corner_radius_bottom_right = 3
	btn.add_theme_stylebox_override("hover", h)
	var p := h.duplicate() as StyleBoxFlat
	p.bg_color = Color(0.32, 0.26, 0.14, 0.8)
	btn.add_theme_stylebox_override("pressed", p)

func _connect_network_signal(sig: Signal, callback: Callable) -> void:
	if not sig.is_connected(callback):
		sig.connect(callback)

func _show_page(page: int) -> void:
	_current_page = page
	main_page.visible = page == Page.MAIN
	coop_page.visible = page == Page.COOP
	lobby_page.visible = page == Page.LOBBY
	match page:
		Page.MAIN:
			status_label.text = ""
			solo_button.grab_focus.call_deferred()
		Page.COOP:
			name_input.grab_focus.call_deferred()
		Page.LOBBY:
			_refresh_lobby_controls()
			_refresh_player_list()

func _on_solo_pressed() -> void:
	NetworkManager.local_player_name = _get_player_name()
	var port := _get_port()
	if multiplayer.has_multiplayer_peer():
		NetworkManager.disconnect_game()
	var error := NetworkManager.host_game(port)
	if error != OK:
		_set_status("Erreur: %s" % error_string(error))
		return
	NetworkManager.host_start_game()

func _on_coop_pressed() -> void:
	_show_page(Page.COOP)

func _on_settings_pressed() -> void:
	settings_menu.open()

func _on_settings_closed() -> void:
	if _current_page == Page.MAIN:
		solo_button.grab_focus.call_deferred()

func _on_quit_pressed() -> void:
	get_tree().quit()

func _on_back_to_main() -> void:
	_show_page(Page.MAIN)

func _on_host_pressed() -> void:
	NetworkManager.local_player_name = _get_player_name()
	var port := _get_port()
	var error := NetworkManager.host_game(port)
	if error != OK:
		_set_status("Erreur: %s" % error_string(error))
		return
	_set_status("Hebergement sur le port %d. En attente de joueurs..." % port)
	_show_page(Page.LOBBY)

func _on_join_pressed() -> void:
	NetworkManager.local_player_name = _get_player_name()
	var address := address_input.text if address_input.text != "" else "localhost"
	var port := _get_port()
	var error := NetworkManager.join_game(address, port)
	if error != OK:
		_set_status("Erreur: %s" % error_string(error))
		return
	_set_status("Connexion a %s:%d..." % [address, port])
	_set_connecting(true, "Connexion a %s:%d..." % [address, port])

func _on_cancel_connection() -> void:
	NetworkManager.disconnect_game()
	_set_connecting(false)
	_set_status("Connexion annulee.")

func _set_connecting(on: bool, message: String = "") -> void:
	_connecting = on
	action_row.visible = not on
	connecting_row.visible = on
	back_coop_button.disabled = on
	if on:
		connecting_label.text = message
		cancel_button.grab_focus.call_deferred()
	else:
		host_button.disabled = false
		join_button.disabled = false

func _on_leave_lobby() -> void:
	NetworkManager.disconnect_game()
	_set_connecting(false)
	_set_status("Deconnecte.")
	_show_page(Page.MAIN)

func _on_start_pressed() -> void:
	if NetworkManager.is_host():
		NetworkManager.host_start_game()
	else:
		var ready_state := not _is_local_ready()
		NetworkManager.set_player_ready.rpc_id(1, ready_state)
		_refresh_lobby_controls()

func _on_server_started() -> void:
	_set_status("Serveur pret. Attendez vos equipiers.")
	_refresh_player_list()

func _on_connection_succeeded() -> void:
	_set_connecting(false)
	_set_status("Connecte.")
	_show_page(Page.LOBBY)
	_refresh_player_list()

func _on_connection_failed() -> void:
	_set_connecting(false)
	_set_status("Echec de connexion. Verifiez l'adresse et le port.")

func _on_player_connected(_id: int) -> void:
	_refresh_player_list()

func _on_player_disconnected(_id: int) -> void:
	_refresh_player_list()

func _refresh_player_list() -> void:
	if not is_inside_tree():
		return
	player_list.clear()
	for id in NetworkManager.players_info:
		var info: Dictionary = NetworkManager.players_info[id]
		var host_tag: String = " (Hote)" if id == 1 else ""
		var ready_tag: String = "  [pret]" if info.get("ready", false) else ""
		player_list.add_item("%s%s%s" % [info.get("name", "Player"), host_tag, ready_tag])
	player_count_label.text = "%d / %d" % [NetworkManager.get_player_count(), NetworkManager.MAX_PLAYERS]
	_refresh_lobby_controls()

func _refresh_lobby_controls() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if NetworkManager.is_host():
		start_button.text = "LANCER LA PARTIE"
		start_button.disabled = false
	else:
		start_button.text = "ANNULER" if _is_local_ready() else "PRET"
		start_button.disabled = false

func _is_local_ready() -> bool:
	var id := multiplayer.get_unique_id()
	if not NetworkManager.players_info.has(id):
		return false
	return bool(NetworkManager.players_info[id].get("ready", false))

func _set_status(text: String) -> void:
	status_label.text = text

func _on_chat_send_pressed() -> void:
	_on_chat_submitted(chat_input.text)

func _on_chat_submitted(text: String) -> void:
	if text.strip_edges() == "":
		return
	NetworkManager.send_chat_message(text)
	chat_input.clear()

func _on_chat_message_received(_peer_id: int, player_name: String, message: String, is_system: bool) -> void:
	var prefix := "*" if is_system else player_name + ":"
	chat_log.append_text("%s %s\n" % [prefix, message])
	chat_log.scroll_to_line(chat_log.get_line_count())

func _get_player_name() -> String:
	var n := name_input.text.strip_edges()
	return n if n != "" else "Player"

func _get_port() -> int:
	var p := int(port_input.text)
	return p if p > 0 else NetworkManager.DEFAULT_PORT

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if settings_menu.visible:
			return
		match _current_page:
			Page.COOP:
				if _connecting:
					_on_cancel_connection()
				else:
					_on_back_to_main()
				get_viewport().set_input_as_handled()
			Page.LOBBY:
				_on_leave_lobby()
				get_viewport().set_input_as_handled()
