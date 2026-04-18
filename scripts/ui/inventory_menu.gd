extends Control
class_name InventoryMenu

signal closed

const HOTBAR_KEY_LABELS: Array[String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
const TOOLTIP_OFFSET := Vector2(14.0, 14.0)

var _hotbar_ui: Array[InventorySlotUI] = []
var _inventory_ui: Array[InventorySlotUI] = []
var _active_drag_source_index: int = -1

var _crafting_system: Node = null
var _recipe_ids: Array[String] = []
var _selected_recipe_index: int = 0
var _recipe_rows: Array[PanelContainer] = []
var _craft_info_label: Label
var _craft_button: Button

var _char_viewport: SubViewport = null
var _char_camera: Camera3D = null
var _char_model: Node3D = null
var _char_texture_rect: TextureRect = null

var _tooltip_panel: PanelContainer
var _tooltip_label: Label

var _tab_buttons: Array[Button] = []
var _inventory_view: Control
var _craft_view: Control
var _current_tab: int = 0

var _stat_health_fill: ColorRect
var _stat_health_empty: ColorRect
var _stat_hunger_fill: ColorRect
var _stat_hunger_empty: ColorRect
var _stat_thirst_fill: ColorRect
var _stat_thirst_empty: ColorRect


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	_build_ui()

	_crafting_system = get_node_or_null("/root/CraftingSystem")
	if _crafting_system and _crafting_system.has_signal("crafted"):
		_crafting_system.connect("crafted", _on_recipe_crafted)

	Inventory.inventory_updated.connect(_on_inventory_updated)
	Inventory.hotbar_updated.connect(_refresh_hotbar_slots)
	Inventory.selected_hotbar_changed.connect(_on_hotbar_selected)
	Inventory.survival_changed.connect(_on_survival_changed)

	_recipe_ids = _get_recipe_ids()
	_refresh_hotbar_slots()
	_refresh_inventory_slots()
	_update_craft_view()

	call_deferred("_setup_character_viewport")


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		if _active_drag_source_index >= 0 and not get_viewport().gui_is_drag_successful():
			_drop_item_to_world(_active_drag_source_index)
		_active_drag_source_index = -1


func _drop_item_to_world(slot_index: int) -> void:
	var slot := Inventory.get_slot_data(slot_index)
	if String(slot.get("item_id", "")).is_empty() or int(slot.get("amount", 0)) <= 0:
		return
	var player_node := _get_local_player()
	if player_node == null:
		return
	var head: Node3D = player_node.get_node_or_null("Head")
	if head == null:
		return
	var drop_pos := player_node.global_position + head.global_basis * Vector3(0, 0, -1.5)
	Inventory.drop_slot(slot_index, -1, drop_pos)


func _get_local_player() -> CharacterBody3D:
	for node in get_tree().get_nodes_in_group("player"):
		if node is CharacterBody3D and bool(node.get("is_local")):
			return node as CharacterBody3D
	return null


# ─── UI BUILD ─────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.0, 0.0, 0.0, 0.80)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(center)

	# Outer wrapper: 2px amber top accent bar
	var wrapper := VBoxContainer.new()
	wrapper.custom_minimum_size = Vector2(1080, 640)
	wrapper.add_theme_constant_override("separation", 0)
	center.add_child(wrapper)

	var top_accent := ColorRect.new()
	top_accent.custom_minimum_size = Vector2(0, 2)
	top_accent.color = C_ACCENT
	top_accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.add_child(top_accent)

	var main_panel := PanelContainer.new()
	main_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_apply_panel_style(main_panel, C_BG, C_BORDER, 1)
	wrapper.add_child(main_panel)

	var outer_margin := MarginContainer.new()
	_set_margins(outer_margin, 18, 14, 18, 18)
	main_panel.add_child(outer_margin)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 10)
	outer_margin.add_child(root_vbox)

	_build_tab_bar(root_vbox)
	_add_divider(root_vbox)

	var content_stack := Control.new()
	content_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(content_stack)

	_inventory_view = _build_inventory_view()
	_inventory_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content_stack.add_child(_inventory_view)

	_craft_view = _build_craft_view()
	_craft_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_craft_view.visible = false
	content_stack.add_child(_craft_view)

	_build_tooltip()


func _build_tab_bar(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	parent.add_child(row)

	_tab_buttons.clear()
	for i in range(2):
		var label: String = ["INVENTAIRE", "ARTISANAT"][i]
		var btn := Button.new()
		btn.text = label
		btn.add_theme_font_size_override("font_size", 12)
		btn.toggle_mode = true
		btn.button_pressed = (i == 0)
		btn.focus_mode = Control.FOCUS_NONE
		var idx := i
		btn.pressed.connect(func(): _switch_tab(idx))
		_style_tab_button(btn, i == 0)
		row.add_child(btn)
		_tab_buttons.append(btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var close_btn := Button.new()
	close_btn.text = "FERMER  [Echap]"
	close_btn.add_theme_font_size_override("font_size", 10)
	close_btn.focus_mode = Control.FOCUS_NONE
	var sb_close := StyleBoxFlat.new()
	sb_close.bg_color = Color(0, 0, 0, 0)
	sb_close.border_width_top    = 0
	sb_close.border_width_left   = 0
	sb_close.border_width_right  = 0
	sb_close.border_width_bottom = 1
	sb_close.border_color = Color(0.50, 0.18, 0.12, 1.0)
	close_btn.add_theme_stylebox_override("normal", sb_close)
	var sb_close_h := sb_close.duplicate() as StyleBoxFlat
	sb_close_h.bg_color = Color(0.20, 0.06, 0.04, 0.5)
	close_btn.add_theme_stylebox_override("hover", sb_close_h)
	close_btn.add_theme_color_override("font_color", Color(0.68, 0.32, 0.28, 1.0))
	close_btn.pressed.connect(func(): closed.emit())
	row.add_child(close_btn)


func _switch_tab(index: int) -> void:
	_current_tab = index
	_inventory_view.visible = (index == 0)
	_craft_view.visible = (index == 1)
	for i in range(_tab_buttons.size()):
		_style_tab_button(_tab_buttons[i], i == index)
		_tab_buttons[i].button_pressed = (i == index)
	if index == 1:
		_update_craft_view()


# ─── INVENTORY VIEW ──────────────────────────────────────────────────────────

func _build_inventory_view() -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 18)
	hbox.mouse_filter = Control.MOUSE_FILTER_PASS

	hbox.add_child(_build_left_section())
	hbox.add_child(_build_equipment_section())
	hbox.add_child(_build_character_section())

	return hbox


func _build_left_section() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.mouse_filter = Control.MOUSE_FILTER_PASS

	_add_section_label(vbox, "BARRE D'ACTION  ( Glisser pour réorganiser )")

	var hotbar_wrap := PanelContainer.new()
	hotbar_wrap.add_theme_stylebox_override("panel", _make_inset_style())
	hotbar_wrap.mouse_filter = Control.MOUSE_FILTER_PASS
	vbox.add_child(hotbar_wrap)

	var hotbar_margin := MarginContainer.new()
	_set_margins(hotbar_margin, 8, 8, 8, 8)
	hotbar_margin.mouse_filter = Control.MOUSE_FILTER_PASS
	hotbar_wrap.add_child(hotbar_margin)

	var hotbar_row := HBoxContainer.new()
	hotbar_row.add_theme_constant_override("separation", 4)
	hotbar_row.mouse_filter = Control.MOUSE_FILTER_PASS
	hotbar_margin.add_child(hotbar_row)

	_hotbar_ui.clear()
	for i in range(Inventory.HOTBAR_SIZE):
		var slot := InventorySlotUI.new()
		slot.setup(i, HOTBAR_KEY_LABELS[i])
		slot.slot_pressed.connect(_on_slot_pressed)
		slot.slot_dropped.connect(_on_slot_dropped)
		slot.slot_drag_started.connect(_on_slot_drag_started)
		slot.slot_hovered.connect(_on_slot_hovered)
		slot.slot_unhovered.connect(_on_slot_unhovered)
		hotbar_row.add_child(slot)
		_hotbar_ui.append(slot)

	_add_section_label(vbox, "SAC A DOS")

	var backpack_wrap := PanelContainer.new()
	backpack_wrap.add_theme_stylebox_override("panel", _make_inset_style())
	backpack_wrap.mouse_filter = Control.MOUSE_FILTER_PASS
	vbox.add_child(backpack_wrap)

	var backpack_margin := MarginContainer.new()
	_set_margins(backpack_margin, 8, 8, 8, 8)
	backpack_margin.mouse_filter = Control.MOUSE_FILTER_PASS
	backpack_wrap.add_child(backpack_margin)

	var grid := GridContainer.new()
	grid.columns = 9
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	grid.mouse_filter = Control.MOUSE_FILTER_PASS
	backpack_margin.add_child(grid)

	_inventory_ui.clear()
	for i in range(Inventory.get_inventory_slot_count()):
		var global_idx: int = Inventory.HOTBAR_SIZE + i
		var slot := InventorySlotUI.new()
		slot.setup(global_idx, "")
		slot.slot_pressed.connect(_on_slot_pressed)
		slot.slot_dropped.connect(_on_slot_dropped)
		slot.slot_drag_started.connect(_on_slot_drag_started)
		slot.slot_hovered.connect(_on_slot_hovered)
		slot.slot_unhovered.connect(_on_slot_unhovered)
		grid.add_child(slot)
		_inventory_ui.append(slot)

	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(bottom_spacer)

	return vbox


func _build_equipment_section() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.custom_minimum_size = Vector2(156, 0)

	_add_section_label(vbox, "ARMURE")

	var armor_grid := GridContainer.new()
	armor_grid.columns = 2
	armor_grid.add_theme_constant_override("h_separation", 6)
	armor_grid.add_theme_constant_override("v_separation", 6)
	vbox.add_child(armor_grid)

	for name_text in ["TÊTE", "TORSE", "JAMBES", "PIEDS"]:
		armor_grid.add_child(_make_equip_slot(name_text, "⬡"))

	_add_section_label(vbox, "ACCESSOIRES")

	var acc_row := HBoxContainer.new()
	acc_row.add_theme_constant_override("separation", 6)
	vbox.add_child(acc_row)
	for name_text in ["BAGUE", "COLLIER"]:
		acc_row.add_child(_make_equip_slot(name_text, "◈"))

	_add_section_label(vbox, "MUNITIONS")

	var ammo_row := HBoxContainer.new()
	ammo_row.add_theme_constant_override("separation", 6)
	vbox.add_child(ammo_row)
	for name_text in ["PRIM.", "ALT."]:
		ammo_row.add_child(_make_equip_slot(name_text, "◉"))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	return vbox


func _make_equip_slot(slot_label: String, _icon_char: String) -> VBoxContainer:
	var wrapper := VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 2)

	var name_lbl := Label.new()
	name_lbl.text = slot_label
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_lbl.add_theme_font_size_override("font_size", 9)
	name_lbl.add_theme_color_override("font_color", C_MUTED)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.add_child(name_lbl)

	var slot_bg := PanelContainer.new()
	slot_bg.custom_minimum_size = Vector2(64, 58)
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_DEEP
	sb.border_width_top    = 1
	sb.border_width_left   = 1
	sb.border_width_right  = 1
	sb.border_width_bottom = 1
	sb.border_color = C_BORDER
	slot_bg.add_theme_stylebox_override("panel", sb)
	wrapper.add_child(slot_bg)

	# Diagonal cross lines — "empty slot" indicator
	var cross_lbl := Label.new()
	cross_lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cross_lbl.text = "—"
	cross_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cross_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cross_lbl.add_theme_font_size_override("font_size", 18)
	cross_lbl.add_theme_color_override("font_color", Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5))
	cross_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot_bg.add_child(cross_lbl)

	return wrapper


func _build_character_section() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.custom_minimum_size = Vector2(220, 0)

	var char_panel := PanelContainer.new()
	char_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	char_panel.add_theme_stylebox_override("panel", _make_inset_style(C_DEEP))
	vbox.add_child(char_panel)

	# Character viewport texture placeholder (filled after _setup_character_viewport)
	_char_texture_rect = TextureRect.new()
	_char_texture_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_char_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_char_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_char_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	char_panel.add_child(_char_texture_rect)

	# Label overlay while loading
	var loading_lbl := Label.new()
	loading_lbl.text = "Personnage"
	loading_lbl.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	loading_lbl.add_theme_color_override("font_color", C_MUTED)
	loading_lbl.add_theme_font_size_override("font_size", 11)
	loading_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	loading_lbl.name = "LoadingLabel"
	char_panel.add_child(loading_lbl)

	# Stats panel
	var stats_panel := PanelContainer.new()
	stats_panel.add_theme_stylebox_override("panel", _make_inset_style())
	vbox.add_child(stats_panel)

	var stats_margin := MarginContainer.new()
	_set_margins(stats_margin, 10, 8, 10, 8)
	stats_panel.add_child(stats_margin)

	var stats_vbox := VBoxContainer.new()
	stats_vbox.add_theme_constant_override("separation", 5)
	stats_margin.add_child(stats_vbox)

	var h := _add_stat_bar(stats_vbox, "SANTÉ", Color(0.80, 0.22, 0.22, 1.0))
	_stat_health_fill = h[0] as ColorRect
	_stat_health_empty = h[1] as ColorRect
	var f := _add_stat_bar(stats_vbox, "FAIM", Color(0.82, 0.62, 0.18, 1.0))
	_stat_hunger_fill = f[0] as ColorRect
	_stat_hunger_empty = f[1] as ColorRect
	var t := _add_stat_bar(stats_vbox, "SOIF", Color(0.22, 0.55, 0.80, 1.0))
	_stat_thirst_fill = t[0] as ColorRect
	_stat_thirst_empty = t[1] as ColorRect

	return vbox


func _add_stat_bar(parent: VBoxContainer, label_text: String, bar_color: Color) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(48, 0)
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", C_MUTED)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lbl)

	var bar_row := HBoxContainer.new()
	bar_row.custom_minimum_size = Vector2(0, 6)
	bar_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar_row.add_theme_constant_override("separation", 0)
	bar_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar_row)

	var fill_rect := ColorRect.new()
	fill_rect.color = bar_color
	fill_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fill_rect.size_flags_stretch_ratio = 1.0
	fill_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_row.add_child(fill_rect)

	var empty_rect := ColorRect.new()
	empty_rect.color = Color(0.08, 0.09, 0.10, 1.0)
	empty_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	empty_rect.size_flags_stretch_ratio = 0.0
	empty_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_row.add_child(empty_rect)

	return [fill_rect, empty_rect]


# ─── CRAFT VIEW ──────────────────────────────────────────────────────────────

func _build_craft_view() -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 18)
	hbox.mouse_filter = Control.MOUSE_FILTER_PASS

	# Recipe list
	var list_vbox := VBoxContainer.new()
	list_vbox.add_theme_constant_override("separation", 6)
	list_vbox.custom_minimum_size = Vector2(300, 0)
	hbox.add_child(list_vbox)

	_add_section_label(list_vbox, "RECETTES DISPONIBLES")

	var list_scroll := ScrollContainer.new()
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_vbox.add_child(list_scroll)

	var list_inner := VBoxContainer.new()
	list_inner.add_theme_constant_override("separation", 4)
	list_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_inner.name = "RecipeListInner"
	list_scroll.add_child(list_inner)

	# Recipe detail
	var detail_vbox := VBoxContainer.new()
	detail_vbox.add_theme_constant_override("separation", 10)
	detail_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(detail_vbox)

	_add_section_label(detail_vbox, "DÉTAILS")

	var detail_panel := PanelContainer.new()
	detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.add_theme_stylebox_override("panel", _make_inset_style())
	detail_vbox.add_child(detail_panel)

	var detail_margin := MarginContainer.new()
	_set_margins(detail_margin, 14, 14, 14, 14)
	detail_panel.add_child(detail_margin)

	var detail_inner := VBoxContainer.new()
	detail_inner.add_theme_constant_override("separation", 10)
	detail_margin.add_child(detail_inner)

	_craft_info_label = Label.new()
	_craft_info_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_craft_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_craft_info_label.add_theme_font_size_override("font_size", 13)
	_craft_info_label.add_theme_color_override("font_color", C_TEXT)
	_craft_info_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail_inner.add_child(_craft_info_label)

	_craft_button = Button.new()
	_craft_button.text = "FABRIQUER  [F]"
	_craft_button.add_theme_font_size_override("font_size", 12)
	_craft_button.focus_mode = Control.FOCUS_NONE
	var sb_craft := StyleBoxFlat.new()
	sb_craft.bg_color = C_ACCENT
	sb_craft.border_width_top    = 0
	sb_craft.border_width_left   = 0
	sb_craft.border_width_right  = 0
	sb_craft.border_width_bottom = 0
	_craft_button.add_theme_stylebox_override("normal", sb_craft)
	var sb_craft_h := sb_craft.duplicate() as StyleBoxFlat
	sb_craft_h.bg_color = Color(C_ACCENT.r * 1.2, C_ACCENT.g * 1.2, C_ACCENT.b * 1.2, 1.0)
	_craft_button.add_theme_stylebox_override("hover", sb_craft_h)
	var sb_craft_d := StyleBoxFlat.new()
	sb_craft_d.bg_color = Color(0.12, 0.12, 0.14, 1.0)
	_craft_button.add_theme_stylebox_override("disabled", sb_craft_d)
	_craft_button.add_theme_color_override("font_color", Color(0.06, 0.04, 0.02, 1.0))
	_craft_button.add_theme_color_override("font_color_disabled", C_MUTED)
	_craft_button.pressed.connect(_on_craft_pressed)
	detail_inner.add_child(_craft_button)

	return hbox


func _rebuild_recipe_list() -> void:
	if _craft_view == null:
		return
	var list_inner := _craft_view.find_child("RecipeListInner", true, false) as VBoxContainer
	if list_inner == null:
		return
	for child in list_inner.get_children():
		child.queue_free()
	_recipe_rows.clear()

	for i in range(_recipe_ids.size()):
		var recipe_id: String = _recipe_ids[i]
		var recipe := _get_recipe(recipe_id)
		var can_craft := _can_craft(recipe_id)
		var selected := (i == _selected_recipe_index)

		var row := PanelContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		row.focus_mode = Control.FOCUS_NONE

		var sb_row := StyleBoxFlat.new()
		if selected:
			sb_row.bg_color = C_ACCENT2
			sb_row.border_width_top    = 0
			sb_row.border_width_left   = 2
			sb_row.border_width_right  = 0
			sb_row.border_width_bottom = 0
			sb_row.border_color = C_ACCENT
		else:
			sb_row.bg_color = Color(0, 0, 0, 0)
		row.add_theme_stylebox_override("panel", sb_row)

		var row_margin := MarginContainer.new()
		_set_margins(row_margin, 8, 6, 8, 6)
		row.add_child(row_margin)

		var row_hbox := HBoxContainer.new()
		row_margin.add_child(row_hbox)

		var arrow := Label.new()
		arrow.text = "›" if selected else " "
		arrow.custom_minimum_size = Vector2(12, 0)
		arrow.add_theme_font_size_override("font_size", 14)
		arrow.add_theme_color_override("font_color", C_ACCENT)
		arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row_hbox.add_child(arrow)

		var name_lbl := Label.new()
		name_lbl.text = recipe.get("display_name", recipe_id)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", 13)
		name_lbl.add_theme_color_override("font_color", C_TEXT if can_craft else C_MUTED)
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row_hbox.add_child(name_lbl)

		var status_lbl := Label.new()
		status_lbl.text = "✓" if can_craft else "✗"
		status_lbl.add_theme_font_size_override("font_size", 12)
		status_lbl.add_theme_color_override("font_color", Color(0.28, 0.72, 0.28, 1.0) if can_craft else Color(0.55, 0.22, 0.20, 1.0))
		status_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row_hbox.add_child(status_lbl)

		var idx_capture := i
		row.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				_select_recipe(idx_capture)
		)
		list_inner.add_child(row)
		_recipe_rows.append(row)


func _update_craft_view() -> void:
	_rebuild_recipe_list()
	_update_craft_detail()


func _update_craft_detail() -> void:
	if _craft_info_label == null or _recipe_ids.is_empty():
		if _craft_info_label:
			_craft_info_label.text = "Aucune recette disponible."
		if _craft_button:
			_craft_button.disabled = true
		return

	_selected_recipe_index = clampi(_selected_recipe_index, 0, _recipe_ids.size() - 1)
	var rid: String = _recipe_ids[_selected_recipe_index]
	var recipe := _get_recipe(rid)
	var ingredients: Dictionary = recipe.get("ingredients", {})
	var can_craft := _can_craft(rid)

	var lines: Array[String] = []
	lines.append(recipe.get("display_name", rid).to_upper())
	lines.append("")
	lines.append("Ingrédients")
	lines.append("───────────────")
	for item_id in ingredients:
		var need: int = int(ingredients[item_id])
		var have: int = Inventory.get_item_amount(item_id)
		var ok_ch := "✓" if have >= need else "✗"
		var item_name: String = Inventory.get_item_name(item_id)
		lines.append("%s  %s  ×%d   [%d]" % [ok_ch, item_name, need, have])

	_craft_info_label.text = "\n".join(lines)
	_craft_button.disabled = not can_craft


func _select_recipe(index: int) -> void:
	_selected_recipe_index = index
	_update_craft_view()


# ─── CHARACTER VIEWPORT ───────────────────────────────────────────────────────

func _setup_character_viewport() -> void:
	var model_path := "res://assets/models/player/animations/Idle.glb"
	if not ResourceLoader.exists(model_path):
		return

	_char_viewport = SubViewport.new()
	_char_viewport.size = Vector2i(400, 600)
	_char_viewport.transparent_bg = true
	_char_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_char_viewport.own_world_3d = true
	_char_viewport.world_3d = World3D.new()
	_char_viewport.msaa_3d = Viewport.MSAA_4X

	var key_light := DirectionalLight3D.new()
	key_light.transform = Transform3D(
		Basis().rotated(Vector3.RIGHT, -0.55).rotated(Vector3.UP, 0.35),
		Vector3.ZERO
	)
	key_light.light_energy = 1.5
	_char_viewport.add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.transform = Transform3D(
		Basis().rotated(Vector3.RIGHT, -0.2).rotated(Vector3.UP, -2.1),
		Vector3.ZERO
	)
	fill_light.light_energy = 0.45
	_char_viewport.add_child(fill_light)

	var back_light := DirectionalLight3D.new()
	back_light.transform = Transform3D(
		Basis().rotated(Vector3.RIGHT, 0.4).rotated(Vector3.UP, 3.14),
		Vector3.ZERO
	)
	back_light.light_energy = 0.3
	_char_viewport.add_child(back_light)

	_char_camera = Camera3D.new()
	_char_camera.position = Vector3(0.0, 1.0, 2.6)
	_char_camera.rotation_degrees = Vector3(-5.0, 0.0, 0.0)
	_char_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_char_camera.fov = 48.0
	_char_camera.near = 0.1
	_char_camera.far = 20.0
	_char_viewport.add_child(_char_camera)

	var model_scene := load(model_path) as PackedScene
	if model_scene:
		_char_model = model_scene.instantiate() as Node3D
		if _char_model:
			_char_viewport.add_child(_char_model)
			_char_model.position = Vector3(0.0, 0.0, 0.0)

	get_tree().root.add_child(_char_viewport)
	await get_tree().process_frame

	if _char_texture_rect and is_instance_valid(_char_viewport):
		_char_texture_rect.texture = _char_viewport.get_texture()
		var loading_lbl := _char_texture_rect.get_parent().find_child("LoadingLabel", true, false)
		if loading_lbl:
			loading_lbl.visible = false


func _exit_tree() -> void:
	if _char_viewport and is_instance_valid(_char_viewport):
		_char_viewport.queue_free()
		_char_viewport = null


# ─── TOOLTIP ─────────────────────────────────────────────────────────────────

func _build_tooltip() -> void:
	_tooltip_panel = PanelContainer.new()
	_tooltip_panel.visible = false
	_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_tooltip_panel)

	var sb := StyleBoxFlat.new()
	sb.bg_color = C_BG
	sb.border_width_top    = 0
	sb.border_width_left   = 2
	sb.border_width_right  = 0
	sb.border_width_bottom = 0
	sb.border_color = C_ACCENT
	_tooltip_panel.add_theme_stylebox_override("panel", sb)

	var tooltip_margin := MarginContainer.new()
	_set_margins(tooltip_margin, 8, 5, 8, 5)
	_tooltip_panel.add_child(tooltip_margin)

	_tooltip_label = Label.new()
	_tooltip_label.add_theme_font_size_override("font_size", 12)
	_tooltip_label.add_theme_color_override("font_color", C_TEXT)
	_tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tooltip_margin.add_child(_tooltip_label)


func _process(_delta: float) -> void:
	if _tooltip_panel and _tooltip_panel.visible:
		var vp := get_viewport_rect()
		var ts := _tooltip_panel.size
		if ts == Vector2.ZERO:
			ts = _tooltip_panel.get_combined_minimum_size()
		var mp := get_global_mouse_position() + TOOLTIP_OFFSET
		mp.x = minf(mp.x, vp.size.x - ts.x - 8.0)
		mp.y = minf(mp.y, vp.size.y - ts.y - 8.0)
		_tooltip_panel.position = mp


# ─── SLOT SIGNALS ─────────────────────────────────────────────────────────────

func _on_slot_pressed(slot_index: int, button_index: int) -> void:
	if button_index != MOUSE_BUTTON_LEFT:
		return
	if slot_index < Inventory.HOTBAR_SIZE:
		Inventory.select_hotbar_slot(slot_index)

func _on_slot_drag_started(slot_index: int) -> void:
	_active_drag_source_index = slot_index

func _on_slot_dropped(source_index: int, target_index: int) -> void:
	_active_drag_source_index = -1
	Inventory.move_slot(source_index, target_index)
	_tooltip_panel.visible = false

func _on_slot_hovered(slot_index: int, item_id: String) -> void:
	if item_id.is_empty():
		_tooltip_panel.visible = false
		return
	_tooltip_label.text = Inventory.get_item_name(item_id)
	_tooltip_panel.visible = true

func _on_slot_unhovered(_slot_index: int) -> void:
	_tooltip_panel.visible = false


# ─── REFRESH ──────────────────────────────────────────────────────────────────

func _on_inventory_updated() -> void:
	_refresh_hotbar_slots()
	_refresh_inventory_slots()
	if _current_tab == 1:
		_update_craft_view()
	else:
		_update_craft_detail()

func _on_hotbar_updated() -> void:
	_refresh_hotbar_slots()

func _on_hotbar_selected(_index: int, _item_id: String) -> void:
	_refresh_hotbar_slots()

func _on_recipe_crafted(_item_id: String) -> void:
	_update_craft_view()


func _on_survival_changed(health: float, hunger: float, thirst: float) -> void:
	_set_stat_bar(_stat_health_fill, _stat_health_empty, health / 100.0)
	_set_stat_bar(_stat_hunger_fill, _stat_hunger_empty, hunger / 100.0)
	_set_stat_bar(_stat_thirst_fill, _stat_thirst_empty, thirst / 100.0)

func _set_stat_bar(fill: ColorRect, empty: ColorRect, ratio: float) -> void:
	if fill == null or empty == null:
		return
	ratio = clampf(ratio, 0.0, 1.0)
	fill.size_flags_stretch_ratio = ratio
	empty.size_flags_stretch_ratio = 1.0 - ratio


func _refresh_hotbar_slots() -> void:
	for i in range(_hotbar_ui.size()):
		var data := Inventory.get_hotbar_slot_data(i)
		var has_item: bool = String(data.get("item_id", "")) != "" and int(data.get("amount", 0)) > 0
		var item_id: String = String(data.get("item_id", ""))
		var icon: Texture2D = Inventory.get_item_icon(item_id) if has_item else null
		_hotbar_ui[i].set_slot_visual(icon, int(data.get("amount", 0)), i == Inventory.selected_hotbar_index, has_item, HOTBAR_KEY_LABELS[i], item_id)


func _refresh_inventory_slots() -> void:
	for i in range(_inventory_ui.size()):
		var global_idx: int = Inventory.HOTBAR_SIZE + i
		var data := Inventory.get_slot_data(global_idx)
		var has_item: bool = String(data.get("item_id", "")) != "" and int(data.get("amount", 0)) > 0
		var item_id: String = String(data.get("item_id", ""))
		var icon: Texture2D = Inventory.get_item_icon(item_id) if has_item else null
		_inventory_ui[i].set_slot_visual(icon, int(data.get("amount", 0)), false, has_item, "", item_id)


# ─── CRAFTING ACTIONS (called from HUD) ───────────────────────────────────────

func select_next_recipe() -> void:
	if _recipe_ids.is_empty():
		return
	_selected_recipe_index = (_selected_recipe_index + 1) % _recipe_ids.size()
	_update_craft_view()

func select_previous_recipe() -> void:
	if _recipe_ids.is_empty():
		return
	_selected_recipe_index = posmod(_selected_recipe_index - 1, _recipe_ids.size())
	_update_craft_view()

func craft_selected_recipe() -> void:
	if _recipe_ids.is_empty():
		return
	_do_craft(_recipe_ids[_selected_recipe_index])

func _on_craft_pressed() -> void:
	if _recipe_ids.is_empty():
		return
	_do_craft(_recipe_ids[_selected_recipe_index])

func _do_craft(recipe_id: String) -> void:
	if _crafting_system and _crafting_system.has_method("craft"):
		_crafting_system.call("craft", recipe_id)
	_update_craft_view()


# ─── HELPERS ──────────────────────────────────────────────────────────────────

func _get_recipe_ids() -> Array[String]:
	if _crafting_system and _crafting_system.has_method("get_recipe_ids"):
		var ids: Variant = _crafting_system.call("get_recipe_ids")
		if ids is Array:
			return ids
	return []

func _get_recipe(recipe_id: String) -> Dictionary:
	if _crafting_system and _crafting_system.has_method("get_recipe"):
		var r: Variant = _crafting_system.call("get_recipe", recipe_id)
		if r is Dictionary:
			return r
	return {}

func _can_craft(recipe_id: String) -> bool:
	if _crafting_system and _crafting_system.has_method("can_craft"):
		return bool(_crafting_system.call("can_craft", recipe_id))
	return false


const C_BG      := Color(0.060, 0.065, 0.070, 0.98)   # panel background
const C_DEEP    := Color(0.035, 0.038, 0.042, 1.00)   # recessed / inner wells
const C_BORDER  := Color(0.18,  0.20,  0.22,  1.00)   # subtle border
const C_ACCENT  := Color(0.72,  0.42,  0.06,  1.00)   # amber — active / highlight
const C_ACCENT2 := Color(0.72,  0.42,  0.06,  0.30)   # amber dim
const C_TEXT    := Color(0.80,  0.78,  0.74,  1.00)   # primary text
const C_MUTED   := Color(0.38,  0.40,  0.44,  1.00)   # secondary / label text


func _apply_panel_style(panel: Control, bg: Color, border: Color, border_w: int) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_width_top    = border_w
	sb.border_width_left   = border_w
	sb.border_width_right  = border_w
	sb.border_width_bottom = border_w
	sb.border_color = border
	panel.add_theme_stylebox_override("panel", sb)


func _make_inset_style(bg: Color = C_DEEP) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_width_top    = 1
	sb.border_width_left   = 1
	sb.border_width_right  = 1
	sb.border_width_bottom = 1
	sb.border_color = C_BORDER
	return sb


func _style_tab_button(btn: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_ACCENT2 if active else Color(0, 0, 0, 0)
	sb.border_width_top    = 0
	sb.border_width_left   = 0
	sb.border_width_right  = 0
	sb.border_width_bottom = 2 if active else 1
	sb.border_color = C_ACCENT if active else C_BORDER
	sb.expand_margin_left  = 6
	sb.expand_margin_right = 6
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = C_ACCENT2
	btn.add_theme_stylebox_override("hover", sb_h)
	btn.add_theme_color_override("font_color", C_ACCENT if active else C_MUTED)


func _add_section_label(parent: Control, text: String) -> Label:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 7)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(hbox)

	var bar := ColorRect.new()
	bar.custom_minimum_size = Vector2(2, 12)
	bar.color = C_ACCENT
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(bar)

	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", C_MUTED)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(lbl)

	return lbl


func _add_divider(parent: VBoxContainer) -> void:
	var sep := HSeparator.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_BORDER
	sb.content_margin_top    = 0
	sb.content_margin_bottom = 0
	sep.add_theme_stylebox_override("separator", sb)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(sep)


func _set_margins(c: MarginContainer, left: int, top: int, right: int, bottom: int) -> void:
	c.add_theme_constant_override("margin_left",   left)
	c.add_theme_constant_override("margin_top",    top)
	c.add_theme_constant_override("margin_right",  right)
	c.add_theme_constant_override("margin_bottom", bottom)
