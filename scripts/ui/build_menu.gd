extends PanelContainer
class_name BuildMenu

signal item_selected(buildable_id: String)
signal mode_selected(mode: int)
signal close_requested
signal exit_build_requested

@onready var list_container: VBoxContainer = $Margin/VBox/Scroll/ItemList
@onready var exit_button: Button = $Margin/VBox/ExitButton
@onready var close_button: Button = $Margin/VBox/TitleBar/CloseButton
@onready var title_label: Label = $Margin/VBox/TitleBar/Title

const C_BG_PANEL   := Color(0.09, 0.07, 0.05, 0.98)
const C_BG_CARD    := Color(0.135, 0.110, 0.080, 1.0)
const C_BG_CARD_HL := Color(0.195, 0.155, 0.095, 1.0)
const C_BORDER     := Color(0.245, 0.195, 0.130, 1.0)
const C_GOLD       := Color(0.985, 0.830, 0.430, 1.0)
const C_GOLD_DIM   := Color(0.720, 0.580, 0.280, 1.0)
const C_TEXT       := Color(0.920, 0.880, 0.770, 1.0)
const C_TEXT_DIM   := Color(0.620, 0.560, 0.430, 1.0)
const C_OK         := Color(0.55, 0.82, 0.45, 1.0)
const C_MISS       := Color(0.88, 0.38, 0.35, 1.0)
const C_TIER_BASIC := Color(0.55, 0.75, 0.95, 1.0)
const C_TIER_REINF := Color(0.95, 0.70, 0.30, 1.0)
const C_CAT_STRUCT := Color(0.70, 0.55, 0.30, 1.0)
const C_CAT_WALL   := Color(0.55, 0.70, 0.95, 1.0)
const C_CAT_DEF    := Color(0.85, 0.45, 0.35, 1.0)
const C_CAT_UTIL   := Color(0.60, 0.85, 0.65, 1.0)
const C_CAT_FURN   := Color(0.85, 0.70, 0.45, 1.0)
const C_CAT_TOOL   := Color(0.95, 0.55, 0.25, 1.0)

var _selected_buildable_id: String = ""
var _selected_mode: int = -1

func _ready() -> void:
	visible = false
	exit_button.pressed.connect(func(): exit_build_requested.emit())
	close_button.pressed.connect(func(): close_requested.emit())
	_apply_panel_style()
	_style_title()
	_style_close_button()
	_style_exit_button()
	if Inventory.has_signal("inventory_updated"):
		Inventory.inventory_updated.connect(_on_inventory_updated)
	if Inventory.has_signal("selected_hotbar_changed"):
		Inventory.selected_hotbar_changed.connect(_on_inventory_updated.unbind(2))
	if BuildSystem.has_signal("buildable_selected"):
		BuildSystem.buildable_selected.connect(_on_buildable_selected)
	if BuildSystem.has_signal("build_mode_exited"):
		BuildSystem.build_mode_exited.connect(_on_build_mode_exited)

func _apply_panel_style() -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = C_BG_PANEL
	s.border_color = C_GOLD
	s.set_border_width_all(2)
	s.set_corner_radius_all(8)
	s.shadow_color = Color(0, 0, 0, 0.6)
	s.shadow_size = 18
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	add_theme_stylebox_override("panel", s)

func _style_title() -> void:
	title_label.text = "CONSTRUCTION"
	title_label.add_theme_font_size_override("font_size", 22)
	title_label.add_theme_color_override("font_color", C_GOLD)
	title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	title_label.add_theme_constant_override("shadow_offset_x", 1)
	title_label.add_theme_constant_override("shadow_offset_y", 1)

func _style_close_button() -> void:
	close_button.text = "✕"
	close_button.flat = true
	close_button.add_theme_font_size_override("font_size", 20)
	close_button.add_theme_color_override("font_color", C_GOLD_DIM)
	close_button.add_theme_color_override("font_hover_color", C_MISS)

func _style_exit_button() -> void:
	exit_button.text = "✕  QUITTER LA CONSTRUCTION"
	exit_button.add_theme_font_size_override("font_size", 14)
	var ns := StyleBoxFlat.new()
	ns.bg_color = Color(0.25, 0.10, 0.08, 1.0)
	ns.border_color = C_MISS
	ns.set_border_width_all(1)
	ns.set_corner_radius_all(4)
	ns.content_margin_top = 8
	ns.content_margin_bottom = 8
	var hs := ns.duplicate() as StyleBoxFlat
	hs.bg_color = Color(0.38, 0.14, 0.10, 1.0)
	exit_button.add_theme_stylebox_override("normal", ns)
	exit_button.add_theme_stylebox_override("hover", hs)
	exit_button.add_theme_stylebox_override("pressed", ns)
	exit_button.add_theme_stylebox_override("focus", ns)
	exit_button.add_theme_color_override("font_color", C_TEXT)
	exit_button.add_theme_color_override("font_hover_color", Color.WHITE)

func _populate() -> void:
	for child in list_container.get_children():
		child.queue_free()

	_add_hammer_status_bar()

	_add_section("Structure", C_CAT_STRUCT)
	_add_mode_card("Chassis / Wagon", "Pose un chassis de wagon sur les rails.",
			BuildSystem.CHASSIS_COST, _hammer_tier_for_chassis(), BuildSystem.BuildMode.CHASSIS, C_CAT_STRUCT)
	_add_mode_card("Plancher", "Sol posable sur un wagon.",
			BuildSystem.FLOOR_COST, "any", BuildSystem.BuildMode.FLOOR, C_CAT_STRUCT)
	_add_mode_card("Plafond", "Plafond posable au niveau supérieur du wagon.",
			BuildSystem.CEILING_COST, "any", BuildSystem.BuildMode.CEILING, C_CAT_STRUCT)

	_add_section("Outils", C_CAT_TOOL)
	_add_demolish_card()

	var by_category: Dictionary = {}
	for id in BuildSystem.buildable_catalog:
		var data: BuildableData = BuildSystem.buildable_catalog[id]
		var cat: int = data.category
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(data)

	var cat_meta: Dictionary = {
		BuildableData.Category.WALL: {"name": "Murs", "color": C_CAT_WALL},
		BuildableData.Category.BARRICADE: {"name": "Barricades", "color": C_CAT_WALL},
		BuildableData.Category.TURRET: {"name": "Défenses", "color": C_CAT_DEF},
		BuildableData.Category.UTILITY: {"name": "Utilitaires", "color": C_CAT_UTIL},
		BuildableData.Category.FURNITURE: {"name": "Meubles", "color": C_CAT_FURN},
	}

	var ordered_cats: Array = [
		BuildableData.Category.WALL,
		BuildableData.Category.BARRICADE,
		BuildableData.Category.UTILITY,
		BuildableData.Category.TURRET,
		BuildableData.Category.FURNITURE,
	]

	for cat in ordered_cats:
		if not by_category.has(cat):
			continue
		var meta: Dictionary = cat_meta.get(cat, {"name": "Divers", "color": C_TEXT_DIM})
		_add_section(String(meta["name"]), meta["color"])
		for data in by_category[cat]:
			_add_item_card(data, meta["color"])

func _hammer_tier_for_chassis() -> String:
	if BuildSystem.has_method("get") and "CHASSIS_HAMMER" in BuildSystem:
		return String(BuildSystem.CHASSIS_HAMMER)
	return "any"

func _add_hammer_status_bar() -> void:
	var bar := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.060, 0.050, 0.035, 1.0)
	s.border_color = C_BORDER
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	bar.add_theme_stylebox_override("panel", s)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	bar.add_child(row)

	var icon := Label.new()
	icon.text = "🔨"
	icon.add_theme_font_size_override("font_size", 16)
	row.add_child(icon)

	var hammer_id := _current_hammer_id()
	var lbl := Label.new()
	if hammer_id.is_empty():
		lbl.text = "Aucun marteau équipé"
		lbl.add_theme_color_override("font_color", C_MISS)
	else:
		var dname: String = Inventory.ITEM_NAMES.get(hammer_id, hammer_id)
		var pct: float = _equipped_hammer_pct()
		if pct >= 0.0:
			lbl.text = "%s — %d%%" % [dname, int(round(pct * 100.0))]
		else:
			lbl.text = dname
		lbl.add_theme_color_override("font_color", C_GOLD if hammer_id == "hammer" else C_TIER_BASIC)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var tier_pill := _make_tier_pill("reinforced" if hammer_id == "hammer" else ("any" if hammer_id == "hammer_crude" else ""))
	if tier_pill:
		row.add_child(tier_pill)

	list_container.add_child(bar)

func _current_hammer_id() -> String:
	var sel := Inventory.get_selected_item()
	if sel in Inventory.HAMMER_ITEMS:
		return sel
	for i in range(Inventory.HOTBAR_SIZE):
		var data: Dictionary = Inventory.get_hotbar_slot_data(i)
		var item_id: String = String(data.get("item_id", ""))
		if item_id in Inventory.HAMMER_ITEMS:
			return item_id
	return ""

func _equipped_hammer_pct() -> float:
	var sel := Inventory.get_selected_item()
	if sel in Inventory.HAMMER_ITEMS:
		return Inventory.get_tool_durability_pct(Inventory.selected_hotbar_index)
	return -1.0

func _add_section(section_name: String, color: Color) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	list_container.add_child(spacer)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(4, 18)
	dot.color = color
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(dot)

	var label := Label.new()
	label.text = section_name.to_upper()
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", color)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	list_container.add_child(row)

	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(0, 1)
	line.color = Color(color.r, color.g, color.b, 0.25)
	list_container.add_child(line)

func _add_mode_card(name_text: String, desc: String, cost: Dictionary, tier: String, mode: int, accent: Color) -> void:
	var card := _make_card(accent, _selected_mode == mode)
	var vbox: VBoxContainer = card.get_meta("vbox")

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)

	var name_lbl := Label.new()
	name_lbl.text = name_text
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", C_TEXT)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_lbl)

	var pill := _make_tier_pill(tier)
	if pill:
		header.add_child(pill)

	if desc != "":
		var d_lbl := Label.new()
		d_lbl.text = desc
		d_lbl.add_theme_font_size_override("font_size", 10)
		d_lbl.add_theme_color_override("font_color", C_TEXT_DIM)
		d_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(d_lbl)

	_add_cost_row(vbox, cost)

	_bind_card(card, cost, tier, func(): mode_selected.emit(mode))
	list_container.add_child(card)

func _add_item_card(data: BuildableData, accent: Color) -> void:
	var card := _make_card(accent, _selected_buildable_id == data.id)
	var vbox: VBoxContainer = card.get_meta("vbox")

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)

	var name_lbl := Label.new()
	name_lbl.text = data.display_name
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", C_TEXT)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_lbl)

	var tier := String(data.required_hammer) if data.required_hammer != "" else "any"
	var pill := _make_tier_pill(tier)
	if pill:
		header.add_child(pill)

	if data.description != "":
		var d_lbl := Label.new()
		d_lbl.text = data.description
		d_lbl.add_theme_font_size_override("font_size", 10)
		d_lbl.add_theme_color_override("font_color", C_TEXT_DIM)
		d_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(d_lbl)

	_add_cost_row(vbox, data.cost)

	var id: String = data.id
	_bind_card(card, data.cost, tier, func(): item_selected.emit(id))
	list_container.add_child(card)

func _add_demolish_card() -> void:
	var card := _make_card(C_CAT_TOOL, _selected_mode == BuildSystem.BuildMode.DEMOLISH)
	var vbox: VBoxContainer = card.get_meta("vbox")

	var header := HBoxContainer.new()
	vbox.add_child(header)
	var name_lbl := Label.new()
	name_lbl.text = "Démolir"
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", C_CAT_TOOL)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_lbl)

	var d_lbl := Label.new()
	d_lbl.text = "Retire un élément et récupère 50 % des ressources."
	d_lbl.add_theme_font_size_override("font_size", 10)
	d_lbl.add_theme_color_override("font_color", C_TEXT_DIM)
	d_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(d_lbl)

	_bind_card(card, {}, "any", func(): mode_selected.emit(BuildSystem.BuildMode.DEMOLISH))
	list_container.add_child(card)

func _add_cost_row(parent: VBoxContainer, cost: Dictionary) -> void:
	if cost.is_empty():
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	for item_id in cost:
		var need: int = int(cost[item_id])
		var have: int = Inventory.get_item_amount(item_id) if Inventory.has_method("get_item_amount") else 0
		var ok: bool = have >= need
		row.add_child(_make_cost_pill(item_id, need, have, ok))

func _make_cost_pill(item_id: String, need: int, have: int, ok: bool) -> Control:
	var pill := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.075, 0.060, 0.045, 1.0)
	s.border_color = C_OK if ok else C_MISS
	s.set_border_width_all(1)
	s.set_corner_radius_all(9)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	pill.add_theme_stylebox_override("panel", s)

	var lbl := Label.new()
	var item_name: String = String(Inventory.ITEM_NAMES.get(item_id, item_id))
	lbl.text = "%d / %d  %s" % [have, need, item_name]
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", C_OK if ok else C_MISS)
	pill.add_child(lbl)
	return pill

func _make_tier_pill(tier: String) -> Control:
	if tier == "" or tier == "any":
		var basic := PanelContainer.new()
		var s := StyleBoxFlat.new()
		s.bg_color = Color(0.07, 0.11, 0.18, 1.0)
		s.border_color = C_TIER_BASIC
		s.set_border_width_all(1)
		s.set_corner_radius_all(9)
		s.content_margin_left = 7
		s.content_margin_right = 7
		s.content_margin_top = 1
		s.content_margin_bottom = 1
		basic.add_theme_stylebox_override("panel", s)
		var l := Label.new()
		l.text = "TOUT MARTEAU"
		l.add_theme_font_size_override("font_size", 9)
		l.add_theme_color_override("font_color", C_TIER_BASIC)
		basic.add_child(l)
		return basic
	if tier == "reinforced":
		var reinf := PanelContainer.new()
		var s2 := StyleBoxFlat.new()
		s2.bg_color = Color(0.18, 0.12, 0.04, 1.0)
		s2.border_color = C_TIER_REINF
		s2.set_border_width_all(1)
		s2.set_corner_radius_all(9)
		s2.content_margin_left = 7
		s2.content_margin_right = 7
		s2.content_margin_top = 1
		s2.content_margin_bottom = 1
		reinf.add_theme_stylebox_override("panel", s2)
		var l2 := Label.new()
		l2.text = "MARTEAU RENFORCÉ"
		l2.add_theme_font_size_override("font_size", 9)
		l2.add_theme_color_override("font_color", C_TIER_REINF)
		reinf.add_child(l2)
		return reinf
	return null

func _make_card(accent: Color, selected: bool) -> Button:
	var card := Button.new()
	card.flat = true
	card.toggle_mode = false
	card.focus_mode = Control.FOCUS_NONE
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.custom_minimum_size = Vector2(0, 56)

	var ns := StyleBoxFlat.new()
	ns.bg_color = C_BG_CARD
	ns.border_color = C_BORDER
	ns.border_width_left = 4
	ns.border_width_top = 1
	ns.border_width_right = 1
	ns.border_width_bottom = 1
	ns.set_corner_radius_all(4)
	ns.content_margin_left = 10
	ns.content_margin_right = 10
	ns.content_margin_top = 8
	ns.content_margin_bottom = 8
	# Override left border color via extra stylebox trick: just set all then reassign
	ns.border_color = accent
	if selected:
		ns.bg_color = C_BG_CARD_HL
		ns.shadow_color = Color(accent.r, accent.g, accent.b, 0.25)
		ns.shadow_size = 6

	var hs := ns.duplicate() as StyleBoxFlat
	hs.bg_color = C_BG_CARD_HL

	var ds := ns.duplicate() as StyleBoxFlat
	ds.bg_color = Color(0.08, 0.06, 0.05, 1.0)

	card.add_theme_stylebox_override("normal", ns)
	card.add_theme_stylebox_override("hover", hs)
	card.add_theme_stylebox_override("pressed", hs)
	card.add_theme_stylebox_override("focus", ns)
	card.add_theme_stylebox_override("disabled", ds)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 10
	vbox.offset_right = -10
	vbox.offset_top = 8
	vbox.offset_bottom = -8
	card.add_child(vbox)
	card.set_meta("vbox", vbox)
	return card

func _bind_card(card: Button, cost: Dictionary, tier: String, on_press: Callable) -> void:
	var affordable: bool = cost.is_empty() or Inventory.has_resources(cost)
	var tier_ok: bool = _tier_ok(tier)
	var enabled: bool = affordable and tier_ok
	card.disabled = not enabled
	if not enabled:
		card.modulate = Color(1.0, 1.0, 1.0, 0.55) if affordable else Color(1.0, 0.70, 0.70, 0.60)
	else:
		card.modulate = Color(1, 1, 1, 1)
	if enabled:
		card.pressed.connect(on_press)

func _tier_ok(tier: String) -> bool:
	if tier == "" or tier == "any":
		return not _current_hammer_id().is_empty()
	if tier == "reinforced":
		return _current_hammer_id() == "hammer"
	return true

func _on_inventory_updated() -> void:
	if visible:
		_populate()

func _on_buildable_selected(data: BuildableData) -> void:
	_selected_buildable_id = data.id if data != null else ""
	_selected_mode = BuildSystem.mode
	if visible:
		_populate()

func _on_build_mode_exited() -> void:
	_selected_mode = -1
	_selected_buildable_id = ""
	if visible:
		_populate()

func show_menu() -> void:
	_selected_buildable_id = BuildSystem.current_buildable_data.id if BuildSystem.current_buildable_data else ""
	_selected_mode = BuildSystem.mode
	_populate()
	visible = true

func hide_menu() -> void:
	visible = false
