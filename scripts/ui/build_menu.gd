extends PanelContainer
class_name BuildMenu

signal item_selected(buildable_id: String)
signal mode_selected(mode: int)
signal close_requested
signal exit_build_requested

@onready var list_container: VBoxContainer = $Margin/VBox/Body/Scroll/ItemList
@onready var preview_panel: PanelContainer = $Margin/VBox/Body/PreviewPanel
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

# Preview state — decoupled so hover can override selection without losing it.
var _preview_kind: String = ""        # "", "buildable", "mode", "demolish"
var _preview_buildable_id: String = ""
var _preview_mode: int = -1
var _preview_viewport: SubViewport = null
var _preview_camera: Camera3D = null
var _preview_root: Node3D = null
var _preview_model: Node3D = null
var _preview_pivot: Node3D = null
var _preview_texture_rect: TextureRect = null
var _preview_title: Label = null
var _preview_subtitle: Label = null
var _preview_desc: Label = null
var _preview_meta_row: HBoxContainer = null
var _preview_cost_row: HBoxContainer = null
var _preview_empty_label: Label = null
var _preview_rotation: float = 0.0

func _ready() -> void:
	visible = false
	exit_button.pressed.connect(func(): exit_build_requested.emit())
	close_button.pressed.connect(func(): close_requested.emit())
	_apply_panel_style()
	_style_title()
	_style_close_button()
	_style_exit_button()
	_build_preview_panel()
	if Inventory.has_signal("inventory_updated"):
		Inventory.inventory_updated.connect(_on_inventory_updated)
	if Inventory.has_signal("selected_hotbar_changed"):
		Inventory.selected_hotbar_changed.connect(_on_inventory_updated)
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

	_update_preview()

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
	_bind_card_preview(card, "mode", "", mode)
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
	_bind_card_preview(card, "buildable", id, -1)
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
	_bind_card_preview(card, "demolish", "", BuildSystem.BuildMode.DEMOLISH)
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
	_sync_preview_to_selection()
	if visible:
		_populate()

func _on_build_mode_exited() -> void:
	_selected_mode = -1
	_selected_buildable_id = ""
	_sync_preview_to_selection()
	if visible:
		_populate()

func show_menu() -> void:
	_selected_buildable_id = BuildSystem.current_buildable_data.id if BuildSystem.current_buildable_data else ""
	_selected_mode = BuildSystem.mode
	_sync_preview_to_selection()
	_populate()
	visible = true
	set_process(true)

func hide_menu() -> void:
	visible = false
	set_process(false)


# ─── PREVIEW PANEL ───────────────────────────────────────────────────────────

func _build_preview_panel() -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.060, 0.050, 0.040, 1.0)
	s.border_color = C_BORDER
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	preview_panel.add_theme_stylebox_override("panel", s)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	preview_panel.add_child(vbox)

	var header := Label.new()
	header.text = "APERÇU"
	header.add_theme_font_size_override("font_size", 11)
	header.add_theme_color_override("font_color", C_TEXT_DIM)
	vbox.add_child(header)

	var viewport_frame := PanelContainer.new()
	var vf_sb := StyleBoxFlat.new()
	vf_sb.bg_color = Color(0.028, 0.030, 0.034, 1.0)
	vf_sb.border_color = C_BORDER
	vf_sb.set_border_width_all(1)
	vf_sb.set_corner_radius_all(3)
	viewport_frame.add_theme_stylebox_override("panel", vf_sb)
	viewport_frame.custom_minimum_size = Vector2(0, 240)
	vbox.add_child(viewport_frame)

	_preview_texture_rect = TextureRect.new()
	_preview_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_texture_rect.custom_minimum_size = Vector2(0, 240)
	viewport_frame.add_child(_preview_texture_rect)

	_preview_empty_label = Label.new()
	_preview_empty_label.text = "Survolez un élément\npour voir son aperçu"
	_preview_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_preview_empty_label.add_theme_font_size_override("font_size", 11)
	_preview_empty_label.add_theme_color_override("font_color", C_TEXT_DIM)
	_preview_empty_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport_frame.add_child(_preview_empty_label)

	_preview_title = Label.new()
	_preview_title.add_theme_font_size_override("font_size", 16)
	_preview_title.add_theme_color_override("font_color", C_GOLD)
	_preview_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_preview_title)

	_preview_subtitle = Label.new()
	_preview_subtitle.add_theme_font_size_override("font_size", 10)
	_preview_subtitle.add_theme_color_override("font_color", C_TEXT_DIM)
	vbox.add_child(_preview_subtitle)

	_preview_desc = Label.new()
	_preview_desc.add_theme_font_size_override("font_size", 11)
	_preview_desc.add_theme_color_override("font_color", C_TEXT)
	_preview_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_preview_desc)

	_preview_meta_row = HBoxContainer.new()
	_preview_meta_row.add_theme_constant_override("separation", 6)
	vbox.add_child(_preview_meta_row)

	var cost_header := Label.new()
	cost_header.text = "COÛT"
	cost_header.add_theme_font_size_override("font_size", 10)
	cost_header.add_theme_color_override("font_color", C_TEXT_DIM)
	vbox.add_child(cost_header)

	_preview_cost_row = HBoxContainer.new()
	_preview_cost_row.add_theme_constant_override("separation", 6)
	vbox.add_child(_preview_cost_row)

	_preview_viewport = SubViewport.new()
	_preview_viewport.size = Vector2i(420, 320)
	_preview_viewport.transparent_bg = true
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_preview_viewport.own_world_3d = true
	_preview_viewport.world_3d = World3D.new()
	_preview_viewport.msaa_3d = Viewport.MSAA_4X

	_preview_root = Node3D.new()
	_preview_viewport.add_child(_preview_root)

	var key_light := DirectionalLight3D.new()
	key_light.transform = Transform3D(Basis().rotated(Vector3.RIGHT, -0.75).rotated(Vector3.UP, 0.6), Vector3.ZERO)
	key_light.light_energy = 1.3
	_preview_root.add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.transform = Transform3D(Basis().rotated(Vector3.RIGHT, -0.2).rotated(Vector3.UP, -2.0), Vector3.ZERO)
	fill_light.light_energy = 0.45
	_preview_root.add_child(fill_light)

	_preview_camera = Camera3D.new()
	_preview_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_preview_camera.fov = 42.0
	_preview_camera.near = 0.05
	_preview_camera.far = 80.0
	_preview_root.add_child(_preview_camera)

	_preview_pivot = Node3D.new()
	_preview_root.add_child(_preview_pivot)

	get_tree().root.add_child.call_deferred(_preview_viewport)
	_preview_viewport.ready.connect(func():
		if _preview_texture_rect:
			_preview_texture_rect.texture = _preview_viewport.get_texture()
	, CONNECT_ONE_SHOT)

func _exit_tree() -> void:
	if _preview_viewport and is_instance_valid(_preview_viewport):
		_preview_viewport.queue_free()
		_preview_viewport = null

func _process(delta: float) -> void:
	if not visible or _preview_pivot == null:
		return
	if _preview_model == null:
		return
	_preview_rotation += delta * 0.5
	_preview_pivot.rotation.y = _preview_rotation

func _bind_card_preview(card: Button, kind: String, buildable_id: String, mode: int) -> void:
	card.mouse_entered.connect(func(): _on_card_hover(kind, buildable_id, mode))
	card.mouse_exited.connect(func(): _on_card_unhover())

func _on_card_hover(kind: String, buildable_id: String, mode: int) -> void:
	_preview_kind = kind
	_preview_buildable_id = buildable_id
	_preview_mode = mode
	_update_preview()

func _on_card_unhover() -> void:
	_sync_preview_to_selection()
	_update_preview()

func _sync_preview_to_selection() -> void:
	if not _selected_buildable_id.is_empty():
		_preview_kind = "buildable"
		_preview_buildable_id = _selected_buildable_id
		_preview_mode = -1
	elif _selected_mode >= 0 and _selected_mode != BuildSystem.BuildMode.OFF:
		_preview_kind = "mode"
		_preview_buildable_id = ""
		_preview_mode = _selected_mode
		if _selected_mode == BuildSystem.BuildMode.DEMOLISH:
			_preview_kind = "demolish"
	else:
		_preview_kind = ""
		_preview_buildable_id = ""
		_preview_mode = -1

func _update_preview() -> void:
	if _preview_title == null:
		return

	if _preview_kind == "" or _preview_kind == "demolish":
		_clear_preview_model()
		_preview_texture_rect.visible = false
		_preview_empty_label.visible = true
		if _preview_kind == "demolish":
			_preview_empty_label.text = "Mode démolition\nCasse et récupère 50 %"
			_preview_title.text = "Démolir"
			_preview_subtitle.text = "Outil"
			_preview_desc.text = "Retire un élément et récupère 50 % des ressources."
		else:
			_preview_empty_label.text = "Survolez un élément\npour voir son aperçu"
			_preview_title.text = ""
			_preview_subtitle.text = ""
			_preview_desc.text = ""
		_clear_children(_preview_meta_row)
		_clear_children(_preview_cost_row)
		return

	var data := _resolve_preview(_preview_kind, _preview_buildable_id, _preview_mode)
	if data.is_empty():
		_clear_preview_model()
		_preview_texture_rect.visible = false
		_preview_empty_label.visible = true
		_preview_empty_label.text = "Aperçu indisponible"
		return

	_preview_title.text = String(data.get("name", ""))
	_preview_subtitle.text = String(data.get("category", ""))
	_preview_desc.text = String(data.get("description", ""))

	_clear_children(_preview_meta_row)
	var tier := String(data.get("tier", ""))
	var tier_pill := _make_tier_pill(tier)
	if tier_pill:
		_preview_meta_row.add_child(tier_pill)
	var health: float = float(data.get("health", 0.0))
	if health > 0.0:
		_preview_meta_row.add_child(_make_meta_pill("Résistance", "%d PV" % int(health)))
	var footprint: Vector2i = data.get("footprint", Vector2i(1, 1))
	if footprint != Vector2i(1, 1):
		_preview_meta_row.add_child(_make_meta_pill("Emprise", "%d×%d" % [footprint.x, footprint.y]))

	_clear_children(_preview_cost_row)
	var cost: Dictionary = data.get("cost", {})
	if cost.is_empty():
		var free_lbl := Label.new()
		free_lbl.text = "Aucun"
		free_lbl.add_theme_font_size_override("font_size", 10)
		free_lbl.add_theme_color_override("font_color", C_TEXT_DIM)
		_preview_cost_row.add_child(free_lbl)
	else:
		for item_id in cost:
			var need: int = int(cost[item_id])
			var have: int = Inventory.get_item_amount(item_id) if Inventory.has_method("get_item_amount") else 0
			_preview_cost_row.add_child(_make_cost_pill(item_id, need, have, have >= need))

	var scene: PackedScene = data.get("scene", null)
	_load_preview_model(scene)

func _resolve_preview(kind: String, buildable_id: String, mode: int) -> Dictionary:
	if kind == "buildable":
		if not BuildSystem.buildable_catalog.has(buildable_id):
			return {}
		var data: BuildableData = BuildSystem.buildable_catalog[buildable_id]
		return {
			"name": data.display_name,
			"category": _category_name(data.category),
			"description": data.description,
			"cost": data.cost,
			"tier": String(data.required_hammer) if data.required_hammer != "" else "any",
			"health": data.health,
			"footprint": data.footprint_size,
			"scene": data.scene,
		}
	if kind == "mode":
		match mode:
			BuildSystem.BuildMode.CHASSIS:
				return {
					"name": "Chassis / Wagon",
					"category": "Structure",
					"description": "Pose un chassis de wagon sur les rails.",
					"cost": BuildSystem.CHASSIS_COST,
					"tier": _hammer_tier_for_chassis(),
					"health": 0.0,
					"footprint": Vector2i(1, 1),
					"scene": BuildSystem.chassis_scene,
				}
			BuildSystem.BuildMode.FLOOR:
				return {
					"name": "Plancher",
					"category": "Structure",
					"description": "Sol posable sur un wagon.",
					"cost": BuildSystem.FLOOR_COST,
					"tier": "any",
					"health": 0.0,
					"footprint": Vector2i(1, 1),
					"scene": BuildSystem.floor_scene,
				}
			BuildSystem.BuildMode.CEILING:
				return {
					"name": "Plafond",
					"category": "Structure",
					"description": "Plafond posable au niveau supérieur du wagon.",
					"cost": BuildSystem.CEILING_COST,
					"tier": "any",
					"health": 0.0,
					"footprint": Vector2i(1, 1),
					"scene": BuildSystem.ceiling_scene,
				}
	return {}

func _category_name(cat: int) -> String:
	match cat:
		BuildableData.Category.WALL: return "Mur"
		BuildableData.Category.FLOOR: return "Sol"
		BuildableData.Category.BARRICADE: return "Barricade"
		BuildableData.Category.TURRET: return "Défense"
		BuildableData.Category.FURNITURE: return "Meuble"
		BuildableData.Category.UTILITY: return "Utilitaire"
	return "Divers"

func _clear_preview_model() -> void:
	if _preview_model and is_instance_valid(_preview_model):
		_preview_model.queue_free()
	_preview_model = null

func _load_preview_model(scene: PackedScene) -> void:
	_clear_preview_model()
	if scene == null or _preview_pivot == null:
		_preview_texture_rect.visible = false
		_preview_empty_label.visible = true
		return

	var inst := scene.instantiate()
	if inst == null:
		return
	_strip_preview_interactivity(inst)
	var model_node: Node3D = inst if inst is Node3D else null
	if model_node == null:
		inst.queue_free()
		return

	_preview_model = model_node
	_preview_pivot.add_child(_preview_model)
	_preview_rotation = 0.0
	_preview_pivot.rotation = Vector3.ZERO
	_frame_preview_camera()
	_preview_texture_rect.visible = true
	_preview_empty_label.visible = false

func _strip_preview_interactivity(node: Node) -> void:
	if node is CollisionObject3D:
		(node as CollisionObject3D).input_ray_pickable = false
	node.set_process(false)
	node.set_physics_process(false)
	for child in node.get_children():
		_strip_preview_interactivity(child)

func _frame_preview_camera() -> void:
	if _preview_model == null or _preview_camera == null or _preview_pivot == null:
		return
	var aabb := _compute_visual_aabb(_preview_model)
	if aabb.size == Vector3.ZERO:
		_preview_camera.position = Vector3(0, 1.5, 4.0)
		_preview_camera.look_at(Vector3.ZERO, Vector3.UP)
		return

	var center: Vector3 = aabb.position + aabb.size * 0.5
	_preview_model.position -= center
	_preview_pivot.position = Vector3.ZERO

	var radius: float = aabb.size.length() * 0.5
	var fov_rad := deg_to_rad(_preview_camera.fov)
	var distance: float = radius / sin(fov_rad * 0.5) * 1.35
	distance = max(distance, 1.5)

	var dir := Vector3(0.7, 0.5, 1.0).normalized()
	_preview_camera.position = dir * distance
	_preview_camera.look_at(Vector3.ZERO, Vector3.UP)

func _compute_visual_aabb(root: Node3D) -> AABB:
	var aabb := AABB()
	var first := true
	var root_inv := root.global_transform.affine_inverse() if root.is_inside_tree() else root.transform.affine_inverse()
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			var vi := n as VisualInstance3D
			var box := vi.get_aabb()
			var xf := vi.global_transform if vi.is_inside_tree() else vi.transform
			box = (root_inv * xf) * box
			if first:
				aabb = box
				first = false
			else:
				aabb = aabb.merge(box)
		for c in n.get_children():
			stack.append(c)
	return aabb

func _make_meta_pill(label: String, value: String) -> Control:
	var pill := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.075, 0.060, 0.045, 1.0)
	s.border_color = C_BORDER
	s.set_border_width_all(1)
	s.set_corner_radius_all(9)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 1
	s.content_margin_bottom = 1
	pill.add_theme_stylebox_override("panel", s)
	var lbl := Label.new()
	lbl.text = "%s : %s" % [label, value]
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", C_TEXT)
	pill.add_child(lbl)
	return pill

func _clear_children(node: Node) -> void:
	if node == null:
		return
	for c in node.get_children():
		c.queue_free()
