extends Control

signal inventory_toggle_requested

const HOTBAR_KEY_LABELS: Array[String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

@onready var build_panel: PanelContainer = $BuildPanel
@onready var build_label: Label = $BuildPanel/BuildLabel
@onready var crosshair: ColorRect = $Crosshair
@onready var interact_hint: Label = $InteractHint
@onready var harvest_hp_label: Label = $HarvestHpLabel
@onready var target_info_bg: ColorRect = $TargetInfoBg
@onready var target_name_label: Label = $TargetInfoBg/TargetNameLabel
@onready var speed_label: Label = $SpeedLabel
@onready var distance_label: Label = $DistanceLabel
@onready var slope_label: Label = $SlopeLabel
@onready var time_label: Label = $TimeLabel
@onready var build_menu: BuildMenu = $BuildMenu
@onready var settings_menu: SettingsMenu = $SettingsMenu
@onready var pause_menu: PauseMenu = $PauseMenu
@onready var stats_display: Control = $StatsDisplay
@onready var hotbar_slots: HBoxContainer = $HotbarPanel/HotbarSlots
@onready var item_tooltip_panel: PanelContainer = $ItemTooltip
@onready var item_tooltip_label: Label = $ItemTooltip/Name
@onready var pickup_notif_container: VBoxContainer = $PickupNotifContainer

var _inventory_menu: InventoryMenu = null

var tracked_chassis: Node = null  # TrainChassis or WagonFrame
var _hud_refresh_accum: float = 0.0
const HUD_REFRESH_INTERVAL: float = 0.1
const TOOLTIP_OFFSET: Vector2 = Vector2(18.0, 18.0)

var _hotbar_ui: Array[InventorySlotUI] = []
var _preview_tuner_panel: PanelContainer
var _preview_tuner_item_select: OptionButton
var _preview_tuner_texture: TextureRect
var _preview_tuner_rot_x: SpinBox
var _preview_tuner_rot_y: SpinBox
var _preview_tuner_rot_z: SpinBox
var _preview_tuner_scale: SpinBox
var _preview_tuner_config_label: Label
var _preview_tuner_syncing: bool = false
var _preview_tuner_item_ids: Array[String] = []
var _selected_preview_item_id: String = ""
var _chat_panel: PanelContainer
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _chat_open: bool = false
var _build_drag_text: String = ""

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if get_viewport():
		get_viewport().size_changed.connect(func(): set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT))
	GameManager.game_state_changed.connect(_on_game_state_changed)
	BuildSystem.build_mode_entered.connect(_on_build_entered)
	BuildSystem.build_mode_exited.connect(_on_build_exited)
	Inventory.inventory_updated.connect(_on_inventory_updated)
	Inventory.hotbar_updated.connect(_refresh_hotbar_slots)
	Inventory.selected_hotbar_changed.connect(_on_hotbar_selected)
	Inventory.survival_changed.connect(_on_survival_changed)
	Inventory.item_icon_preview_settings_changed.connect(_on_item_icon_preview_settings_changed)
	Inventory.item_picked_up.connect(_on_item_picked_up)
	NetworkManager.chat_message_received.connect(_on_chat_message_received)

	build_panel.visible = false
	interact_hint.visible = false
	target_info_bg.visible = false
	speed_label.visible = false
	slope_label.visible = false
	item_tooltip_panel.visible = false

	# Hide legacy inventory panel — replaced by InventoryMenu
	var legacy_panel := get_node_or_null("InventoryPanel")
	if legacy_panel:
		legacy_panel.visible = false

	_build_hotbar_ui()
	_build_preview_tuner_ui()
	_build_chat_ui()
	_build_inventory_menu()
	pause_menu.resume_requested.connect(_on_pause_resume_requested)
	pause_menu.respawn_requested.connect(_on_pause_respawn_requested)
	pause_menu.move_to_front()

	_on_inventory_updated()
	_on_survival_changed(Inventory.health, Inventory.hunger, Inventory.thirst)
	_on_game_state_changed(GameManager.current_state)
	_build_workbench_ui()

var _workbench_ui: Control = null

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("chat") and not _chat_open:
		open_chat()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel") and _chat_open:
		close_chat()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_hud_refresh_accum += delta
	if _hud_refresh_accum < HUD_REFRESH_INTERVAL:
		return
	_hud_refresh_accum = 0.0

	if BuildSystem.is_building:
		var cost_text: String = _current_build_cost_text()
		var drag_text: String = "\n%s" % _build_drag_text if not _build_drag_text.is_empty() else ""
		build_label.text = "%s%s%s\n[B] Menu  [R] Rotation  [Clic] Placer  [X] Retirer  [Clic droit] Annuler" % [BuildSystem.get_mode_name(), cost_text, drag_text]
		if BuildSystem.mode == BuildSystem.BuildMode.OFF:
			crosshair.color = Color(1, 1, 1, 0.8)
		elif BuildSystem.can_place:
			crosshair.color = Color(0.3, 1.0, 0.3, 0.9)
		else:
			crosshair.color = Color(1.0, 0.3, 0.3, 0.9)

	tracked_chassis = _find_nearest_chassis()
	if tracked_chassis and is_instance_valid(tracked_chassis):
		var on_rails: bool = false
		var spd: float = 0.0
		var dist: float = 0.0
		var slope_deg: float = 0.0
		var slope_source: Node3D = null
		if tracked_chassis is WagonFrame:
			var wf := tracked_chassis as WagonFrame
			on_rails = wf.is_on_rails and wf.front_bogie != null
			if on_rails:
				spd = absf(wf.front_bogie.speed)
				dist = wf.front_bogie.distance_traveled
				slope_source = wf
		elif tracked_chassis is TrainChassis:
			on_rails = (tracked_chassis as TrainChassis).is_on_rails
			spd = absf((tracked_chassis as TrainChassis).speed)
			dist = (tracked_chassis as TrainChassis).distance_traveled
			slope_source = tracked_chassis as Node3D
		if on_rails:
			if slope_source != null:
				slope_deg = _get_signed_slope_degrees(slope_source)
			speed_label.visible = true
			distance_label.visible = true
			slope_label.visible = true
			speed_label.text = "%.1f km/h" % (spd * 3.6)
			distance_label.text = "%d m" % int(dist)
			slope_label.text = "Pente: %.1f°" % slope_deg
		else:
			speed_label.visible = false
			distance_label.visible = false
			slope_label.visible = false
	else:
		speed_label.visible = false
		distance_label.visible = false
		slope_label.visible = false

	var main: Node = get_tree().current_scene
	if main and "is_night" in main:
		var night: bool = main.get("is_night")
		time_label.text = "Nuit" if night else "Jour"
		time_label.modulate = Color(0.6, 0.7, 1.0) if night else Color(1, 0.95, 0.7)



func _find_nearest_chassis() -> Node:
	# Prefer WagonFrame (the main movable unit) over standalone bogies.
	var frames := get_tree().get_nodes_in_group("wagon_frame")
	if not frames.is_empty():
		return _find_best_wagon_frame(frames)
	var nodes := get_tree().get_nodes_in_group("chassis")
	if nodes.is_empty():
		return null
	return _find_best_train_node(nodes)

func _find_best_wagon_frame(frames: Array) -> Node:
	return _find_best_train_node(frames)

func _find_best_train_node(nodes: Array) -> Node:
	var local_peer_id := Inventory.get_local_peer_id()
	var has_owned_frames := false
	var local_pos := _get_telemetry_reference_position()
	var best_owned: Node = null
	var best_owned_dist := INF
	var best_any: Node = null
	var best_any_dist := INF
	for node_variant in nodes:
		if not (node_variant is Node) or not is_instance_valid(node_variant):
			continue
		var train_node := _resolve_tracked_train(node_variant)
		if train_node == null or not is_instance_valid(train_node):
			continue
		if not _train_can_show_telemetry(train_node):
			continue
		var train_3d := train_node as Node3D
		if train_3d == null:
			continue
		var dist := train_3d.global_position.distance_squared_to(local_pos)
		if dist < best_any_dist:
			best_any_dist = dist
			best_any = train_node
		if train_node.has_meta("owner_peer_id"):
			has_owned_frames = true
			if int(train_node.get_meta("owner_peer_id")) == local_peer_id and dist < best_owned_dist:
				best_owned_dist = dist
				best_owned = train_node
	if best_owned != null:
		return best_owned
	if has_owned_frames:
		return null
	return best_any

func _get_telemetry_reference_position() -> Vector3:
	var player_node := _get_local_player_controller()
	if player_node != null:
		return player_node.global_position
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		return camera.global_position
	return Vector3.ZERO

func _resolve_tracked_train(node_variant: Variant) -> Node:
	if node_variant == null:
		return null
	if not (node_variant is Object):
		return null
	if not is_instance_valid(node_variant):
		return null
	var node := node_variant as Node
	if node == null:
		return null
	if node is TrainChassis:
		var parent := node.get_parent()
		if parent is WagonFrame:
			return parent
	return node

func _train_can_show_telemetry(node_variant: Variant) -> bool:
	if node_variant == null or not (node_variant is Object):
		return false
	if not is_instance_valid(node_variant):
		return false
	var node := node_variant as Node
	if node == null:
		return false
	if node.has_meta("owner_peer_id") and int(node.get_meta("owner_peer_id")) != Inventory.get_local_peer_id():
		return false
	if node is WagonFrame:
		var wf := node as WagonFrame
		return wf.is_on_rails and wf.front_bogie != null
	if node is TrainChassis:
		return (node as TrainChassis).is_on_rails
	return false

func _get_signed_slope_degrees(node: Node3D) -> float:
	var forward: Vector3 = node.global_basis.z.normalized()
	var horizontal_length: float = Vector2(forward.x, forward.z).length()
	return rad_to_deg(atan2(forward.y, horizontal_length))


func _on_inventory_updated() -> void:
	_refresh_hotbar_slots()
	_refresh_preview_tuner_preview()

func _on_survival_changed(health: float, hunger: float, thirst: float) -> void:
	if stats_display and stats_display.has_method("set_stats"):
		stats_display.call("set_stats", health, hunger, thirst)

func _on_hotbar_selected(_index: int, _item_id: String) -> void:
	_refresh_hotbar_slots()

func _on_build_entered() -> void:
	build_panel.visible = true

func _on_build_exited() -> void:
	build_panel.visible = false
	crosshair.color = Color.WHITE
	hide_build_drag_info()


func show_build_drag_info(text: String) -> void:
	_build_drag_text = text


func hide_build_drag_info() -> void:
	_build_drag_text = ""


func show_interact_hint(text: String) -> void:
	interact_hint.text = text
	interact_hint.visible = true

func hide_interact_hint() -> void:
	interact_hint.visible = false
	harvest_hp_label.visible = false

func show_harvest_hp(current: int, max_hits: int) -> void:
	var filled: int = current
	var empty: int = max_hits - current
	harvest_hp_label.text = "█".repeat(filled) + "░".repeat(empty) + "  %d/%d" % [current, max_hits]
	harvest_hp_label.visible = true

func hide_harvest_hp() -> void:
	harvest_hp_label.visible = false

func show_target_name(text: String) -> void:
	target_name_label.text = text
	target_info_bg.visible = true

func hide_target_name() -> void:
	target_info_bg.visible = false

func _on_game_state_changed(new_state: int) -> void:
	if pause_menu == null:
		return
	if new_state == GameManager.GameState.PAUSED:
		_hide_transient_menus_for_pause()
		pause_menu.open()
	else:
		pause_menu.close()

func _on_pause_resume_requested() -> void:
	GameManager.change_state(GameManager.GameState.PLAYING)

func _on_pause_respawn_requested() -> void:
	var player_node := _get_local_player_controller()
	if player_node == null:
		return
	if player_node.has_method("respawn_to_spawn"):
		player_node.call("respawn_to_spawn")
	GameManager.change_state(GameManager.GameState.PLAYING)

func _hide_transient_menus_for_pause() -> void:
	if build_menu:
		build_menu.hide_menu()
	if settings_menu:
		settings_menu.visible = false
	if _inventory_menu and _inventory_menu.visible:
		toggle_inventory_panel(false)
	if _workbench_ui and _workbench_ui.visible:
		_workbench_ui.call("close")
	BuildSystem.hide_preview()

func _get_local_player_controller() -> CharacterBody3D:
	for node in get_tree().get_nodes_in_group("player"):
		if not (node is CharacterBody3D):
			continue
		if bool(node.get("is_local")):
			return node as CharacterBody3D
	return null


func _current_build_cost_text() -> String:
	var cost: Dictionary = {}
	match BuildSystem.mode:
		BuildSystem.BuildMode.CHASSIS: cost = BuildSystem.CHASSIS_COST
		BuildSystem.BuildMode.FLOOR:   cost = BuildSystem.FLOOR_COST
		BuildSystem.BuildMode.ITEM:
			if BuildSystem.current_buildable_data:
				cost = BuildSystem.current_buildable_data.cost
	if cost.is_empty():
		return ""
	var parts: Array[String] = []
	for k in cost:
		parts.append("%d %s" % [cost[k], k])
	var txt := "  (" + ", ".join(parts) + ")"
	if Inventory.get_selected_item() != "hammer":
		txt += "  [marteau requis]"
	return txt


func is_inventory_open() -> bool:
	return _inventory_menu != null and _inventory_menu.visible

func toggle_inventory_panel(force_state: Variant = null) -> bool:
	if _inventory_menu == null:
		return false
	var new_state: bool = not _inventory_menu.visible
	if force_state is bool:
		new_state = force_state
	_inventory_menu.visible = new_state
	if _preview_tuner_panel != null:
		_preview_tuner_panel.visible = new_state
	if new_state:
		_ensure_preview_tuner_selection(Inventory.get_selected_item())
		_refresh_preview_tuner_preview()
	return _inventory_menu.visible


func _build_inventory_menu() -> void:
	_inventory_menu = InventoryMenu.new()
	_inventory_menu.visible = false
	_inventory_menu.z_index = 10
	add_child(_inventory_menu)
	_inventory_menu.closed.connect(func(): toggle_inventory_panel(false))

func is_chat_open() -> bool:
	return _chat_open

func open_chat() -> void:
	if _chat_input == null:
		return
	_chat_open = true
	_chat_panel.visible = true
	_chat_input.visible = true
	_chat_input.grab_focus()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func close_chat() -> void:
	if _chat_input == null:
		return
	_chat_open = false
	_chat_input.release_focus()
	_chat_input.visible = false
	if GameManager.current_state == GameManager.GameState.PLAYING:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _build_chat_ui() -> void:
	_chat_panel = PanelContainer.new()
	_chat_panel.name = "ChatPanel"
	_chat_panel.anchor_left = 0.0
	_chat_panel.anchor_top = 1.0
	_chat_panel.anchor_right = 0.0
	_chat_panel.anchor_bottom = 1.0
	_chat_panel.offset_left = 14.0
	_chat_panel.offset_top = -244.0
	_chat_panel.offset_right = 434.0
	_chat_panel.offset_bottom = -116.0
	_chat_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_chat_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_chat_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	_chat_log = RichTextLabel.new()
	_chat_log.custom_minimum_size = Vector2(0, 74)
	_chat_log.bbcode_enabled = false
	_chat_log.scroll_following = true
	_chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_chat_log)

	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "T pour parler"
	_chat_input.max_length = 160
	_chat_input.visible = false
	_chat_input.text_submitted.connect(_on_chat_submitted)
	vbox.add_child(_chat_input)

func _build_workbench_ui() -> void:
	var script := load("res://scripts/ui/workbench_ui.gd")
	_workbench_ui = script.new()
	_workbench_ui.name = "WorkbenchUI"
	_workbench_ui.connect("closed", _on_workbench_closed)
	add_child(_workbench_ui)
	_workbench_ui.move_to_front()

func open_workbench() -> void:
	if _workbench_ui == null:
		return
	if inventory_panel.visible:
		toggle_inventory_panel(false)
	if build_menu:
		build_menu.hide_menu()
	_workbench_ui.call("open")

func _on_workbench_closed() -> void:
	pass

func _on_chat_submitted(text: String) -> void:
	NetworkManager.send_chat_message(text)
	if _chat_input:
		_chat_input.clear()
	close_chat()

func _on_chat_message_received(_peer_id: int, player_name: String, message: String, is_system: bool) -> void:
	if _chat_log == null:
		return
	var prefix := "*" if is_system else player_name + ":"
	_chat_log.append_text("%s %s\n" % [prefix, message])
	_chat_log.scroll_to_line(_chat_log.get_line_count())


func select_next_recipe() -> void:
	if _inventory_menu:
		_inventory_menu.select_next_recipe()

func select_previous_recipe() -> void:
	if _inventory_menu:
		_inventory_menu.select_previous_recipe()

func craft_selected_recipe() -> void:
	if _inventory_menu:
		_inventory_menu.craft_selected_recipe()




func _build_hotbar_ui() -> void:
	for child in hotbar_slots.get_children():
		child.queue_free()
	_hotbar_ui.clear()
	for i in range(Inventory.HOTBAR_SIZE):
		var slot := InventorySlotUI.new()
		slot.setup(i, HOTBAR_KEY_LABELS[i])
		slot.slot_pressed.connect(_on_slot_pressed)
		slot.slot_dropped.connect(_on_slot_dropped)
		slot.slot_drag_started.connect(_on_slot_drag_started)
		slot.slot_hovered.connect(_on_slot_hovered)
		slot.slot_unhovered.connect(_on_slot_unhovered)
		hotbar_slots.add_child(slot)
		_hotbar_ui.append(slot)


func _build_preview_tuner_ui() -> void:
	_preview_tuner_panel = PanelContainer.new()
	_preview_tuner_panel.name = "PreviewTunerPanel"
	_preview_tuner_panel.visible = false
	_preview_tuner_panel.anchor_left = 0.5
	_preview_tuner_panel.anchor_top = 0.5
	_preview_tuner_panel.anchor_right = 0.5
	_preview_tuner_panel.anchor_bottom = 0.5
	_preview_tuner_panel.offset_left = 346.0
	_preview_tuner_panel.offset_top = -220.0
	_preview_tuner_panel.offset_right = 618.0
	_preview_tuner_panel.offset_bottom = 220.0
	add_child(_preview_tuner_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	_preview_tuner_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "PREVIEW TUNER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 15)
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "Ajuste en direct, puis recopie la ligne ci-dessous dans ITEM_ICON_SETTINGS."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.76, 0.76, 0.76, 1.0))
	hint.add_theme_font_size_override("font_size", 11)
	vbox.add_child(hint)

	_preview_tuner_item_select = OptionButton.new()
	_preview_tuner_item_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_tuner_item_select.item_selected.connect(_on_preview_tuner_item_selected)
	vbox.add_child(_preview_tuner_item_select)

	var preview_frame := PanelContainer.new()
	preview_frame.custom_minimum_size = Vector2(0, 144)
	preview_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(preview_frame)

	var preview_center := CenterContainer.new()
	preview_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_frame.add_child(preview_center)

	_preview_tuner_texture = TextureRect.new()
	_preview_tuner_texture.custom_minimum_size = Vector2(128, 128)
	_preview_tuner_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_tuner_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview_center.add_child(_preview_tuner_texture)

	_preview_tuner_rot_x = _make_preview_tuner_spinbox(vbox, "Rot X", -180.0, 180.0, 1.0)
	_preview_tuner_rot_y = _make_preview_tuner_spinbox(vbox, "Rot Y", -180.0, 180.0, 1.0)
	_preview_tuner_rot_z = _make_preview_tuner_spinbox(vbox, "Rot Z", -180.0, 180.0, 1.0)
	_preview_tuner_scale = _make_preview_tuner_spinbox(vbox, "Scale", 0.2, 2.5, 0.01)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	vbox.add_child(buttons)

	var reset_button := Button.new()
	reset_button.text = "Reset"
	reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_button.pressed.connect(_on_preview_tuner_reset_pressed)
	buttons.add_child(reset_button)

	_preview_tuner_config_label = Label.new()
	_preview_tuner_config_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_tuner_config_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview_tuner_config_label.add_theme_font_size_override("font_size", 11)
	_preview_tuner_config_label.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88, 1.0))
	vbox.add_child(_preview_tuner_config_label)

	_populate_preview_tuner_items()
	_ensure_preview_tuner_selection()

func _make_preview_tuner_spinbox(parent: VBoxContainer, label_text: String, min_value: float, max_value: float, step: float) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(52, 0)
	row.add_child(label)

	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(_on_preview_tuner_value_changed)
	row.add_child(spin)
	return spin

func _populate_preview_tuner_items() -> void:
	_preview_tuner_item_ids = Inventory.get_previewable_item_ids()
	while _preview_tuner_item_select.item_count > 0:
		_preview_tuner_item_select.remove_item(0)
	for item_id in _preview_tuner_item_ids:
		var item_name: String = Inventory.get_item_name(item_id)
		var display_name: String = "%s (%s)" % [item_name, item_id]
		_preview_tuner_item_select.add_item(display_name)
		var index: int = _preview_tuner_item_select.item_count - 1
		_preview_tuner_item_select.set_item_metadata(index, item_id)

func _get_preview_tuner_item_index(item_id: String) -> int:
	for i in range(_preview_tuner_item_select.item_count):
		if String(_preview_tuner_item_select.get_item_metadata(i)) == item_id:
			return i
	return -1

func _ensure_preview_tuner_selection(preferred_item_id: String = "") -> void:
	if _preview_tuner_item_ids.is_empty():
		_populate_preview_tuner_items()
	if _preview_tuner_item_ids.is_empty():
		_selected_preview_item_id = ""
		_refresh_preview_tuner_preview()
		return

	var target_item_id: String = preferred_item_id
	if target_item_id.is_empty() or not Inventory.has_item_model_preview(target_item_id):
		target_item_id = _selected_preview_item_id
	if target_item_id.is_empty() or not Inventory.has_item_model_preview(target_item_id):
		target_item_id = _preview_tuner_item_ids[0]
	_set_preview_tuner_item(target_item_id)

func _set_preview_tuner_item(item_id: String) -> void:
	if item_id.is_empty() or not Inventory.has_item_model_preview(item_id):
		return
	_selected_preview_item_id = item_id
	var item_index: int = _get_preview_tuner_item_index(item_id)
	if item_index >= 0 and _preview_tuner_item_select.selected != item_index:
		_preview_tuner_syncing = true
		_preview_tuner_item_select.select(item_index)
		_preview_tuner_syncing = false
	_sync_preview_tuner_controls()
	_refresh_preview_tuner_preview()

func _sync_preview_tuner_controls() -> void:
	if _selected_preview_item_id.is_empty():
		return
	var settings: Dictionary = Inventory.get_item_icon_settings(_selected_preview_item_id)
	var rot_deg: Vector3 = settings.get("rotation_deg", Vector3.ZERO)
	var scale_mult: float = float(settings.get("scale_mult", 1.0))
	_preview_tuner_syncing = true
	_preview_tuner_rot_x.value = rot_deg.x
	_preview_tuner_rot_y.value = rot_deg.y
	_preview_tuner_rot_z.value = rot_deg.z
	_preview_tuner_scale.value = scale_mult
	_preview_tuner_syncing = false
	_update_preview_tuner_config_label()

func _refresh_preview_tuner_preview() -> void:
	if _preview_tuner_texture == null:
		return
	if _selected_preview_item_id.is_empty():
		_preview_tuner_texture.texture = null
		if _preview_tuner_config_label:
			_preview_tuner_config_label.text = "Aucun item avec preview 3D disponible."
		return
	_preview_tuner_texture.texture = Inventory.get_item_icon(_selected_preview_item_id)
	_update_preview_tuner_config_label()

func _update_preview_tuner_config_label() -> void:
	if _preview_tuner_config_label == null:
		return
	if _selected_preview_item_id.is_empty():
		_preview_tuner_config_label.text = "Aucun item selectionne."
		return
	_preview_tuner_config_label.text = "Ligne a recopier:\n%s" % Inventory.get_item_icon_settings_line(_selected_preview_item_id)

func _apply_preview_tuner_settings() -> void:
	if _preview_tuner_syncing or _selected_preview_item_id.is_empty():
		return
	var rot_deg := Vector3(
		_preview_tuner_rot_x.value,
		_preview_tuner_rot_y.value,
		_preview_tuner_rot_z.value
	)
	Inventory.set_item_icon_settings(_selected_preview_item_id, rot_deg, _preview_tuner_scale.value)
	_refresh_preview_tuner_preview()

func _on_preview_tuner_item_selected(index: int) -> void:
	if _preview_tuner_syncing:
		return
	var item_id: String = String(_preview_tuner_item_select.get_item_metadata(index))
	_set_preview_tuner_item(item_id)

func _on_preview_tuner_value_changed(_value: float) -> void:
	_apply_preview_tuner_settings()

func _on_preview_tuner_reset_pressed() -> void:
	if _selected_preview_item_id.is_empty():
		return
	Inventory.reset_item_icon_settings(_selected_preview_item_id)

func _on_item_icon_preview_settings_changed(item_id: String, _settings: Dictionary) -> void:
	if item_id != _selected_preview_item_id:
		return
	_sync_preview_tuner_controls()
	_refresh_preview_tuner_preview()

func _refresh_hotbar_slots() -> void:
	for i in range(_hotbar_ui.size()):
		var data: Dictionary = Inventory.get_hotbar_slot_data(i)
		var has_item: bool = String(data.get("item_id", "")) != "" and int(data.get("amount", 0)) > 0
		var item_id: String = String(data.get("item_id", ""))
		var icon: Texture2D = Inventory.get_item_icon(item_id) if has_item else null
		_hotbar_ui[i].set_slot_visual(icon, int(data.get("amount", 0)), i == Inventory.selected_hotbar_index, has_item, HOTBAR_KEY_LABELS[i], item_id)

# Compatibility — build_controller.gd calls these
func select_next_recipe_compat() -> void:   select_next_recipe()
func select_previous_recipe_compat() -> void: select_previous_recipe()
func craft_selected_recipe_compat() -> void: craft_selected_recipe()

func _on_slot_pressed(slot_index: int, button_index: int) -> void:
	if button_index == MOUSE_BUTTON_LEFT and slot_index < Inventory.HOTBAR_SIZE:
		Inventory.select_hotbar_slot(slot_index)

func _on_slot_drag_started(_slot_index: int) -> void:
	pass

func _on_slot_dropped(source_index: int, target_index: int) -> void:
	Inventory.move_slot(source_index, target_index)

func _on_slot_hovered(_slot_index: int, _item_id: String) -> void:
	pass

func _on_slot_unhovered(_slot_index: int) -> void:
	pass


func _on_item_picked_up(item_id: String, amount: int) -> void:
	var item_name: String = Inventory.ITEM_NAMES.get(item_id, item_id)
	var label := Label.new()
	label.text = "+ %d  %s" % [amount, item_name]
	label.modulate = Color(1.0, 1.0, 1.0, 0.0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(0.85, 1.0, 0.6, 1.0))
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 1.0))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.position = Vector2(40.0, 0.0)
	pickup_notif_container.add_child(label)
	var tween := create_tween().set_parallel(false)
	tween.tween_property(label, "modulate:a", 1.0, 0.15)
	tween.tween_property(label, "position:x", 0.0, 0.15)
	tween.tween_interval(1.8)
	tween.tween_property(label, "modulate:a", 0.0, 0.4)
	tween.tween_callback(label.queue_free)
