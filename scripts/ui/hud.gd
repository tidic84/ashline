extends Control

signal inventory_toggle_requested

const HOTBAR_KEY_LABELS: Array[String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

@onready var build_panel: PanelContainer = $BuildPanel
@onready var build_label: Label = $BuildPanel/BuildLabel
@onready var crosshair: ColorRect = $Crosshair
@onready var interact_hint: Label = $InteractHint
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
@onready var inventory_panel: PanelContainer = $InventoryPanel
@onready var inventory_items_grid: GridContainer = $InventoryPanel/Margin/VBox/InventoryItemsGrid
@onready var inventory_recipes_label: Label = $InventoryPanel/Margin/VBox/Right/RecipeList
@onready var craft_preview_label: Label = $InventoryPanel/Margin/VBox/Right/CraftInfo

var tracked_chassis: Node = null  # TrainChassis or WagonFrame
var _hud_refresh_accum: float = 0.0
const HUD_REFRESH_INTERVAL: float = 0.1

var _recipe_ids: Array[String] = []
var _selected_recipe_index: int = 0
var _crafting_system: Node = null

var _hotbar_ui: Array[InventorySlotUI] = []
var _inventory_ui: Array[InventorySlotUI] = []
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

	_crafting_system = get_node_or_null("/root/CraftingSystem")
	if _crafting_system and _crafting_system.has_signal("crafted"):
		_crafting_system.connect("crafted", _on_recipe_crafted)

	build_panel.visible = false
	interact_hint.visible = false
	target_info_bg.visible = false
	speed_label.visible = false
	slope_label.visible = false
	inventory_panel.visible = false

	_build_hotbar_ui()
	_build_inventory_slots_ui()
	_build_preview_tuner_ui()
	pause_menu.resume_requested.connect(_on_pause_resume_requested)
	pause_menu.move_to_front()

	_recipe_ids = _crafting_get_recipe_ids()
	_on_inventory_updated()
	_on_survival_changed(Inventory.health, Inventory.hunger, Inventory.thirst)
	_on_game_state_changed(GameManager.current_state)


func _process(delta: float) -> void:
	_hud_refresh_accum += delta
	if _hud_refresh_accum < HUD_REFRESH_INTERVAL:
		return
	_hud_refresh_accum = 0.0

	if BuildSystem.is_building:
		var cost_text := _current_build_cost_text()
		build_label.text = "%s%s\n[B] Menu  [R] Rotation  [Clic] Placer  [X] Retirer  [Clic droit] Annuler" % [BuildSystem.get_mode_name(), cost_text]
		if BuildSystem.mode == BuildSystem.BuildMode.OFF:
			crosshair.color = Color(1, 1, 1, 0.8)
		elif BuildSystem.can_place:
			crosshair.color = Color(0.3, 1.0, 0.3, 0.9)
		else:
			crosshair.color = Color(1.0, 0.3, 0.3, 0.9)

	if tracked_chassis == null or not is_instance_valid(tracked_chassis):
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
			speed_label.text = "%.1f m/s" % spd
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
		return frames[0]
	var nodes := get_tree().get_nodes_in_group("chassis")
	return nodes[0] as TrainChassis if not nodes.is_empty() else null

func _get_signed_slope_degrees(node: Node3D) -> float:
	var forward: Vector3 = node.global_basis.z.normalized()
	var horizontal_length: float = Vector2(forward.x, forward.z).length()
	return rad_to_deg(atan2(forward.y, horizontal_length))


func _on_inventory_updated() -> void:
	_refresh_hotbar_slots()
	if inventory_panel.visible:
		_update_inventory_panel()
	_refresh_preview_tuner_preview()

func _on_survival_changed(health: float, hunger: float, thirst: float) -> void:
	if stats_display and stats_display.has_method("set_stats"):
		stats_display.call("set_stats", health, hunger, thirst)

func _on_hotbar_selected(_index: int, _item_id: String) -> void:
	_refresh_hotbar_slots()

func _on_recipe_crafted(_item_id: String) -> void:
	_update_inventory_panel()

func _on_build_entered() -> void:
	build_panel.visible = true

func _on_build_exited() -> void:
	build_panel.visible = false
	crosshair.color = Color.WHITE


func show_interact_hint(text: String) -> void:
	interact_hint.text = text
	interact_hint.visible = true

func hide_interact_hint() -> void:
	interact_hint.visible = false

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

func _hide_transient_menus_for_pause() -> void:
	if build_menu:
		build_menu.hide_menu()
	if settings_menu:
		settings_menu.visible = false
	if inventory_panel.visible:
		toggle_inventory_panel(false)
	BuildSystem.hide_preview()


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
	return inventory_panel.visible

func toggle_inventory_panel(force_state: Variant = null) -> bool:
	var new_state: bool = not inventory_panel.visible
	if force_state is bool:
		new_state = force_state
	inventory_panel.visible = new_state
	if _preview_tuner_panel != null:
		_preview_tuner_panel.visible = new_state
	if new_state:
		_ensure_preview_tuner_selection(Inventory.get_selected_item())
		_update_inventory_panel()
		_refresh_preview_tuner_preview()
	return inventory_panel.visible


func select_next_recipe() -> void:
	if _recipe_ids.is_empty(): return
	_selected_recipe_index = (_selected_recipe_index + 1) % _recipe_ids.size()
	_update_inventory_panel()

func select_previous_recipe() -> void:
	if _recipe_ids.is_empty(): return
	_selected_recipe_index = posmod(_selected_recipe_index - 1, _recipe_ids.size())
	_update_inventory_panel()

func craft_selected_recipe() -> void:
	if _recipe_ids.is_empty(): return
	_crafting_craft(_recipe_ids[_selected_recipe_index])
	_update_inventory_panel()


func _update_inventory_panel() -> void:
	_refresh_inventory_slots()
	_update_recipe_panel()

func _update_recipe_panel() -> void:
	if _recipe_ids.is_empty():
		inventory_recipes_label.text = "Aucune recette"
		craft_preview_label.text = ""
		return

	_selected_recipe_index = clampi(_selected_recipe_index, 0, _recipe_ids.size() - 1)

	var lines: Array[String] = []
	for i in range(_recipe_ids.size()):
		var recipe: Dictionary = _crafting_get_recipe(_recipe_ids[i])
		var ok: bool = _crafting_can_craft(_recipe_ids[i])
		var sel: String = "▶ " if i == _selected_recipe_index else "  "
		var status: String = "✓" if ok else "✗"
		lines.append("%s%s  [%s]" % [sel, recipe.get("display_name", _recipe_ids[i]), status])
	inventory_recipes_label.text = "\n".join(lines)

	var rid: String = _recipe_ids[_selected_recipe_index]
	var recipe: Dictionary = _crafting_get_recipe(rid)
	var ingredients: Dictionary = recipe.get("ingredients", {})
	var ingr_lines: Array[String] = []
	for item_id in ingredients:
		var need: int = int(ingredients[item_id])
		var have: int = Inventory.get_item_amount(item_id)
		var ok_c: String = "✓" if have >= need else "✗"
		ingr_lines.append("%s  %s × %d  (/%d)" % [ok_c, Inventory.get_item_name(item_id), need, have])
	craft_preview_label.text = "─── %s ───\n%s\n\n[F] Crafter" % [
		recipe.get("display_name", rid),
		"\n".join(ingr_lines)
	]


func _build_hotbar_ui() -> void:
	for child in hotbar_slots.get_children():
		child.queue_free()
	_hotbar_ui.clear()
	for i in range(Inventory.HOTBAR_SIZE):
		var slot := InventorySlotUI.new()
		slot.setup(i, HOTBAR_KEY_LABELS[i])
		slot.slot_pressed.connect(_on_slot_pressed)
		slot.slot_dropped.connect(_on_slot_dropped)
		hotbar_slots.add_child(slot)
		_hotbar_ui.append(slot)

func _build_inventory_slots_ui() -> void:
	for child in inventory_items_grid.get_children():
		child.queue_free()
	_inventory_ui.clear()
	inventory_items_grid.columns = 9
	for i in range(Inventory.get_inventory_slot_count()):
		var global_index: int = Inventory.HOTBAR_SIZE + i
		var slot := InventorySlotUI.new()
		slot.setup(global_index, "")
		slot.slot_pressed.connect(_on_slot_pressed)
		slot.slot_dropped.connect(_on_slot_dropped)
		inventory_items_grid.add_child(slot)
		_inventory_ui.append(slot)

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
		_hotbar_ui[i].set_slot_visual(icon, int(data.get("amount", 0)), i == Inventory.selected_hotbar_index, has_item, HOTBAR_KEY_LABELS[i])

func _refresh_inventory_slots() -> void:
	for i in range(_inventory_ui.size()):
		var global_index: int = Inventory.HOTBAR_SIZE + i
		var data: Dictionary = Inventory.get_slot_data(global_index)
		var has_item: bool = String(data.get("item_id", "")) != "" and int(data.get("amount", 0)) > 0
		var item_id: String = String(data.get("item_id", ""))
		var icon: Texture2D = Inventory.get_item_icon(item_id) if has_item else null
		_inventory_ui[i].set_slot_visual(icon, int(data.get("amount", 0)), false, has_item, "")


func _on_slot_pressed(slot_index: int, button_index: int) -> void:
	if button_index != MOUSE_BUTTON_LEFT:
		return
	if slot_index < Inventory.HOTBAR_SIZE:
		Inventory.select_hotbar_slot(slot_index)

func _on_slot_dropped(source_index: int, target_index: int) -> void:
	Inventory.move_slot(source_index, target_index)


# Compatibility — build_controller.gd calls these
func select_next_recipe_compat() -> void:   select_next_recipe()
func select_previous_recipe_compat() -> void: select_previous_recipe()
func craft_selected_recipe_compat() -> void: craft_selected_recipe()


func _crafting_get_recipe_ids() -> Array[String]:
	if _crafting_system and _crafting_system.has_method("get_recipe_ids"):
		var ids: Variant = _crafting_system.call("get_recipe_ids")
		if ids is Array:
			return ids
	return []

func _crafting_get_recipe(recipe_id: String) -> Dictionary:
	if _crafting_system and _crafting_system.has_method("get_recipe"):
		var r: Variant = _crafting_system.call("get_recipe", recipe_id)
		if r is Dictionary:
			return r
	return {}

func _crafting_can_craft(recipe_id: String) -> bool:
	if _crafting_system and _crafting_system.has_method("can_craft"):
		return bool(_crafting_system.call("can_craft", recipe_id))
	return false

func _crafting_craft(recipe_id: String) -> bool:
	if _crafting_system and _crafting_system.has_method("craft"):
		return bool(_crafting_system.call("craft", recipe_id))
	return false
