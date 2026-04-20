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

const C_BG_PANEL   := Color(0.082, 0.085, 0.090, 0.96)
const C_BG_CARD    := Color(0.110, 0.115, 0.122, 1.0)
const C_BG_CARD_HL := Color(0.160, 0.150, 0.138, 1.0)
const C_BORDER     := Color(0.185, 0.195, 0.210, 1.0)
const C_GOLD       := Color(0.950, 0.560, 0.280, 1.0)
const C_TEXT       := Color(0.820, 0.830, 0.840, 1.0)
const C_TEXT_HI    := Color(0.955, 0.960, 0.965, 1.0)
const C_TEXT_DIM   := Color(0.480, 0.495, 0.520, 1.0)
const C_MISS       := Color(0.82, 0.34, 0.30, 1.0)

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
var _preview_meta_label: Label = null
var _preview_cost_label: Label = null
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
	s.border_color = C_BORDER
	s.set_border_width_all(1)
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	add_theme_stylebox_override("panel", s)

func _style_title() -> void:
	title_label.text = "Construction"
	title_label.add_theme_font_size_override("font_size", 16)
	title_label.add_theme_color_override("font_color", C_TEXT_HI)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT

func _style_close_button() -> void:
	close_button.text = "×"
	close_button.flat = true
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.add_theme_font_size_override("font_size", 18)
	close_button.add_theme_color_override("font_color", C_TEXT_DIM)
	close_button.add_theme_color_override("font_hover_color", C_TEXT_HI)

func _style_exit_button() -> void:
	exit_button.text = "Quitter la construction"
	exit_button.add_theme_font_size_override("font_size", 12)
	exit_button.focus_mode = Control.FOCUS_NONE
	var ns := StyleBoxFlat.new()
	ns.bg_color = Color(0, 0, 0, 0)
	ns.content_margin_top = 8
	ns.content_margin_bottom = 8
	var hs := ns.duplicate() as StyleBoxFlat
	hs.bg_color = Color(0.140, 0.090, 0.082, 1.0)
	exit_button.add_theme_stylebox_override("normal", ns)
	exit_button.add_theme_stylebox_override("hover", hs)
	exit_button.add_theme_stylebox_override("pressed", hs)
	exit_button.add_theme_stylebox_override("focus", ns)
	exit_button.add_theme_color_override("font_color", C_MISS)
	exit_button.add_theme_color_override("font_hover_color", Color(1, 0.65, 0.60, 1.0))

func _populate() -> void:
	for child in list_container.get_children():
		child.queue_free()

	_add_hammer_status_bar()

	_add_section("Structure")
	_add_mode_card("Chassis / Wagon", "Pose un chassis de wagon sur les rails.",
			BuildSystem.CHASSIS_COST, _hammer_tier_for_chassis(), BuildSystem.BuildMode.CHASSIS)
	_add_mode_card("Plancher", "Sol posable sur un wagon.",
			BuildSystem.FLOOR_COST, "any", BuildSystem.BuildMode.FLOOR)
	_add_mode_card("Plafond", "Plafond posable au niveau supérieur du wagon.",
			BuildSystem.CEILING_COST, "any", BuildSystem.BuildMode.CEILING)

	_add_section("Outils")
	_add_demolish_card()

	var by_category: Dictionary = {}
	for id in BuildSystem.buildable_catalog:
		var data: BuildableData = BuildSystem.buildable_catalog[id]
		var cat: int = data.category
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(data)

	var cat_names: Dictionary = {
		BuildableData.Category.WALL: "Murs",
		BuildableData.Category.BARRICADE: "Barricades",
		BuildableData.Category.TURRET: "Défenses",
		BuildableData.Category.UTILITY: "Utilitaires",
		BuildableData.Category.FURNITURE: "Meubles",
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
		_add_section(String(cat_names.get(cat, "Divers")))
		for data in by_category[cat]:
			_add_item_card(data)

	_update_preview()

func _hammer_tier_for_chassis() -> String:
	if BuildSystem.has_method("get") and "CHASSIS_HAMMER" in BuildSystem:
		return String(BuildSystem.CHASSIS_HAMMER)
	return "any"

func _add_hammer_status_bar() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var hammer_id := _current_hammer_id()
	var lbl := Label.new()
	if hammer_id.is_empty():
		lbl.text = "Marteau : aucun"
		lbl.add_theme_color_override("font_color", C_MISS)
	else:
		var dname: String = Inventory.ITEM_NAMES.get(hammer_id, hammer_id)
		var pct: float = _equipped_hammer_pct()
		if pct >= 0.0:
			lbl.text = "Marteau : %s (%d%%)" % [dname, int(round(pct * 100.0))]
		else:
			lbl.text = "Marteau : %s" % dname
		lbl.add_theme_color_override("font_color", C_TEXT)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	list_container.add_child(row)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	list_container.add_child(spacer)

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

func _add_section(section_name: String) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	list_container.add_child(spacer)

	var label := Label.new()
	label.text = section_name
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", C_TEXT_DIM)
	list_container.add_child(label)

func _add_mode_card(name_text: String, desc: String, cost: Dictionary, tier: String, mode: int) -> void:
	var card := _make_card(_selected_mode == mode)
	var vbox: VBoxContainer = card.get_meta("vbox")
	_fill_card(vbox, name_text, desc, cost, tier)
	_bind_card(card, cost, tier, func(): mode_selected.emit(mode))
	_bind_card_preview(card, "mode", "", mode)
	list_container.add_child(card)

func _add_item_card(data: BuildableData) -> void:
	var card := _make_card(_selected_buildable_id == data.id)
	var vbox: VBoxContainer = card.get_meta("vbox")
	var tier := String(data.required_hammer) if data.required_hammer != "" else "any"
	_fill_card(vbox, data.display_name, data.description, data.cost, tier)
	var id: String = data.id
	_bind_card(card, data.cost, tier, func(): item_selected.emit(id))
	_bind_card_preview(card, "buildable", id, -1)
	list_container.add_child(card)

func _add_demolish_card() -> void:
	var card := _make_card(_selected_mode == BuildSystem.BuildMode.DEMOLISH)
	var vbox: VBoxContainer = card.get_meta("vbox")
	_fill_card(vbox, "Démolir", "Retire un élément et récupère 50 % des ressources.", {}, "any")
	_bind_card(card, {}, "any", func(): mode_selected.emit(BuildSystem.BuildMode.DEMOLISH))
	_bind_card_preview(card, "demolish", "", BuildSystem.BuildMode.DEMOLISH)
	list_container.add_child(card)

func _fill_card(vbox: VBoxContainer, name_text: String, desc: String, cost: Dictionary, tier: String) -> void:
	var name_lbl := Label.new()
	name_lbl.text = name_text
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", C_TEXT_HI)
	vbox.add_child(name_lbl)

	if desc != "":
		var d_lbl := Label.new()
		d_lbl.text = desc
		d_lbl.add_theme_font_size_override("font_size", 10)
		d_lbl.add_theme_color_override("font_color", C_TEXT_DIM)
		d_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(d_lbl)

	var footer := Label.new()
	footer.text = _format_card_footer(cost, tier)
	footer.add_theme_font_size_override("font_size", 10)
	footer.add_theme_color_override("font_color", C_TEXT_DIM)
	vbox.add_child(footer)

func _format_card_footer(cost: Dictionary, tier: String) -> String:
	var parts: Array[String] = []
	for item_id in cost:
		var need: int = int(cost[item_id])
		var have: int = Inventory.get_item_amount(item_id) if Inventory.has_method("get_item_amount") else 0
		var item_name: String = String(Inventory.ITEM_NAMES.get(item_id, item_id))
		parts.append("%s %d/%d" % [item_name, have, need])
	if parts.is_empty():
		parts.append("gratuit")
	if tier == "reinforced":
		parts.append("marteau renforcé")
	return "  ·  ".join(parts)

func _make_card(selected: bool) -> Button:
	var card := Button.new()
	card.flat = true
	card.toggle_mode = false
	card.focus_mode = Control.FOCUS_NONE
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.custom_minimum_size = Vector2(0, 52)

	var ns := StyleBoxFlat.new()
	ns.bg_color = C_BG_CARD if not selected else C_BG_CARD_HL
	ns.content_margin_left = 10
	ns.content_margin_right = 10
	ns.content_margin_top = 6
	ns.content_margin_bottom = 6
	if selected:
		ns.border_width_left = 2
		ns.border_color = C_GOLD

	var hs := ns.duplicate() as StyleBoxFlat
	hs.bg_color = C_BG_CARD_HL

	var ds := ns.duplicate() as StyleBoxFlat
	ds.bg_color = Color(0.060, 0.062, 0.066, 1.0)

	card.add_theme_stylebox_override("normal", ns)
	card.add_theme_stylebox_override("hover", hs)
	card.add_theme_stylebox_override("pressed", hs)
	card.add_theme_stylebox_override("focus", ns)
	card.add_theme_stylebox_override("disabled", ds)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 10
	vbox.offset_right = -10
	vbox.offset_top = 6
	vbox.offset_bottom = -6
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
	s.bg_color = C_BG_CARD
	s.border_color = C_BORDER
	s.set_border_width_all(1)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	preview_panel.add_theme_stylebox_override("panel", s)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	preview_panel.add_child(vbox)

	var viewport_frame := PanelContainer.new()
	var vf_sb := StyleBoxFlat.new()
	vf_sb.bg_color = Color(0.028, 0.030, 0.034, 1.0)
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
	_preview_empty_label.text = "Survolez un élément"
	_preview_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_preview_empty_label.add_theme_font_size_override("font_size", 11)
	_preview_empty_label.add_theme_color_override("font_color", C_TEXT_DIM)
	_preview_empty_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport_frame.add_child(_preview_empty_label)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	vbox.add_child(spacer)

	_preview_title = Label.new()
	_preview_title.add_theme_font_size_override("font_size", 14)
	_preview_title.add_theme_color_override("font_color", C_TEXT_HI)
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

	_preview_meta_label = Label.new()
	_preview_meta_label.add_theme_font_size_override("font_size", 10)
	_preview_meta_label.add_theme_color_override("font_color", C_TEXT_DIM)
	_preview_meta_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_preview_meta_label)

	_preview_cost_label = Label.new()
	_preview_cost_label.add_theme_font_size_override("font_size", 10)
	_preview_cost_label.add_theme_color_override("font_color", C_TEXT_DIM)
	_preview_cost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_preview_cost_label)

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
			_preview_empty_label.text = "Démolition"
			_preview_title.text = "Démolir"
			_preview_subtitle.text = "Outil"
			_preview_desc.text = "Retire un élément et récupère 50 % des ressources."
		else:
			_preview_empty_label.text = "Survolez un élément"
			_preview_title.text = ""
			_preview_subtitle.text = ""
			_preview_desc.text = ""
		_preview_meta_label.text = ""
		_preview_cost_label.text = ""
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

	var meta_parts: Array[String] = []
	var health: float = float(data.get("health", 0.0))
	if health > 0.0:
		meta_parts.append("%d PV" % int(health))
	var footprint: Vector2i = data.get("footprint", Vector2i(1, 1))
	if footprint != Vector2i(1, 1):
		meta_parts.append("%d×%d" % [footprint.x, footprint.y])
	var tier := String(data.get("tier", ""))
	if tier == "reinforced":
		meta_parts.append("marteau renforcé")
	_preview_meta_label.text = "  ·  ".join(meta_parts)

	var cost: Dictionary = data.get("cost", {})
	var cost_parts: Array[String] = []
	for item_id in cost:
		var need: int = int(cost[item_id])
		var have: int = Inventory.get_item_amount(item_id) if Inventory.has_method("get_item_amount") else 0
		var item_name: String = String(Inventory.ITEM_NAMES.get(item_id, item_id))
		cost_parts.append("%s %d/%d" % [item_name, have, need])
	_preview_cost_label.text = "Coût : " + ("gratuit" if cost_parts.is_empty() else "  ·  ".join(cost_parts))

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
