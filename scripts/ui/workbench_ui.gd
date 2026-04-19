extends Control
class_name WorkbenchUI

signal closed

const _BlueprintGridScript := preload("res://scripts/ui/blueprint_grid.gd")
const _WireCanvasScript    := preload("res://scripts/ui/wire_canvas.gd")

# ── Blueprint colours ──────────────────────────────────────────────────────────
const C_BG        := Color(0.030, 0.055, 0.140, 0.97)
const C_GRID      := Color(0.25,  0.50,  0.90,  0.18)
const C_ACCENT    := Color(0.45,  0.75,  1.00,  0.55)
const C_TITLE     := Color(0.75,  0.92,  1.00,  1.00)
const C_TEXT      := Color(0.65,  0.85,  1.00,  1.00)
const C_DIM       := Color(0.35,  0.55,  0.80,  0.70)
const C_FILLED    := Color(0.28,  0.88,  0.55,  1.00)
const C_MISSING   := Color(0.90,  0.28,  0.28,  0.80)
const C_WIRE      := Color(0.45,  0.75,  1.00,  0.38)
const C_RESULT    := Color(0.88,  0.72,  0.20,  1.00)
const GRID_STEP   := 22

# ── State ──────────────────────────────────────────────────────────────────────
var _recipe_ids:    Array[String] = []
var _selected_idx:  int  = 0
var _crafting:      bool = false
var _craft_progress: float = 0.0
var _craft_time:    float = 5.0

# ingredient_id → amount placed (staged from inventory)
var _staged: Dictionary = {}

var _crafting_system: Node = null

# ── UI refs ────────────────────────────────────────────────────────────────────
var _tab_bar:       HBoxContainer
var _canvas:        Control          # blueprint draw area
var _slot_nodes:    Array[Control]   # one per ingredient slot
var _result_box:    Control
var _wire_canvas:   Control          # draws connector lines (behind slots)
var _status_lbl:    Label
var _progress_bar:  ProgressBar
var _progress_lbl:  Label
var _craft_btn:     Button
var _reset_btn:     Button
var _craft_tween:   Tween

# ── Layout constants ───────────────────────────────────────────────────────────
# Slot anchor positions as (cx%, cy%) of _canvas size, for 1–4 ingredients
const SLOT_LAYOUTS: Array = [
	[Vector2(0.50, 0.50)],                                             # 1
	[Vector2(0.28, 0.50), Vector2(0.72, 0.50)],                        # 2
	[Vector2(0.22, 0.32), Vector2(0.64, 0.28), Vector2(0.42, 0.72)],  # 3
	[Vector2(0.22, 0.30), Vector2(0.66, 0.30),
	 Vector2(0.22, 0.70), Vector2(0.66, 0.70)],                        # 4
]
const RESULT_ANC := Vector2(0.84, 0.50)
const SLOT_W     := 116.0
const SLOT_H     := 68.0


func _ready() -> void:
	_crafting_system = get_node_or_null("/root/CraftingSystem")
	if _crafting_system and _crafting_system.has_signal("crafted"):
		_crafting_system.crafted.connect(_on_crafted)
	_build_ui()
	visible = false


func open() -> void:
	_recipe_ids = _get_recipe_ids()
	_selected_idx = 0
	_crafting = false
	_staged.clear()
	_rebuild_canvas()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	if _crafting:
		_cancel_craft()
	visible = false
	if GameManager.current_state == GameManager.GameState.PLAYING:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	closed.emit()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


# ═══════════════════════════════════════════════════════════════════════════════
# UI CONSTRUCTION
# ═══════════════════════════════════════════════════════════════════════════════

func _build_ui() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Dim overlay
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.60)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Main panel
	var panel := _make_panel()
	panel.anchor_left   = 0.5;  panel.anchor_right  = 0.5
	panel.anchor_top    = 0.5;  panel.anchor_bottom = 0.5
	panel.offset_left   = -420; panel.offset_right  = 420
	panel.offset_top    = -280; panel.offset_bottom = 280
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   18)
	margin.add_theme_constant_override("margin_top",    14)
	margin.add_theme_constant_override("margin_right",  18)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	_add_title_bar(vbox)
	_add_tab_bar(vbox)
	_add_canvas_area(vbox)
	_add_bottom_bar(vbox)


func _make_panel() -> PanelContainer:
	var p := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = C_BG
	s.border_color = C_ACCENT
	s.set_border_width_all(2)
	s.set_corner_radius_all(6)
	s.shadow_color = Color(0, 0, 0, 0.8)
	s.shadow_size  = 20
	p.add_theme_stylebox_override("panel", s)
	return p


func _add_title_bar(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	var icon := Label.new()
	icon.text = "⚙"
	icon.add_theme_font_size_override("font_size", 20)
	icon.add_theme_color_override("font_color", C_ACCENT)
	row.add_child(icon)

	var title := Label.new()
	title.text = "ÉTABLI — SCHÉMA TECHNIQUE"
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", C_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)

	var rev := Label.new()
	rev.text = "REV. 1.0"
	rev.add_theme_font_size_override("font_size", 10)
	rev.add_theme_color_override("font_color", C_DIM)
	rev.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(rev)

	var x_btn := _make_close_button()
	row.add_child(x_btn)

	var sep := _make_separator()
	parent.add_child(sep)


func _add_tab_bar(parent: VBoxContainer) -> void:
	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 4)
	parent.add_child(_tab_bar)


func _refresh_tab_bar() -> void:
	for c in _tab_bar.get_children():
		c.queue_free()
	for i in range(_recipe_ids.size()):
		var rid   := _recipe_ids[i]
		var rec   := _get_recipe(rid)
		var name_: String = rec.get("display_name", rid)
		var sel   := i == _selected_idx

		var btn := Button.new()
		btn.text = name_.to_upper()
		btn.add_theme_font_size_override("font_size", 12)
		btn.toggle_mode = false

		var ns := StyleBoxFlat.new()
		ns.bg_color     = Color(0.10, 0.22, 0.50, 1.0) if sel else Color(0.05, 0.10, 0.25, 0.8)
		ns.border_color = C_ACCENT if sel else Color(0.25, 0.45, 0.80, 0.40)
		ns.set_border_width_all(1)
		ns.set_corner_radius_all(4)
		ns.content_margin_left   = 12
		ns.content_margin_right  = 12
		ns.content_margin_top    = 5
		ns.content_margin_bottom = 5
		var hs := ns.duplicate() as StyleBoxFlat
		hs.bg_color = Color(0.14, 0.28, 0.60, 1.0)
		btn.add_theme_stylebox_override("normal", ns)
		btn.add_theme_stylebox_override("hover",  hs)
		btn.add_theme_stylebox_override("pressed", ns)
		btn.add_theme_stylebox_override("focus",   ns)
		btn.add_theme_color_override("font_color", C_TITLE if sel else C_DIM)

		var idx := i
		btn.pressed.connect(func() -> void: _select_recipe(idx))
		_tab_bar.add_child(btn)


func _add_canvas_area(parent: VBoxContainer) -> void:
	var wrap := Panel.new()
	wrap.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.custom_minimum_size   = Vector2(0, 220)
	var ws := StyleBoxFlat.new()
	ws.bg_color     = Color(0.022, 0.042, 0.115, 1.0)
	ws.border_color = C_ACCENT
	ws.set_border_width_all(1)
	ws.set_corner_radius_all(4)
	wrap.add_theme_stylebox_override("panel", ws)
	parent.add_child(wrap)

	# Blueprint grid (draws behind everything)
	_canvas = _BlueprintGridScript.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(_canvas)

	# Wire canvas (draws connector lines, also behind slots)
	_wire_canvas = _WireCanvasScript.new()
	_wire_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wire_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_wire_canvas)

	# Result box
	_result_box = _make_result_box()
	_canvas.add_child(_result_box)


func _add_bottom_bar(parent: VBoxContainer) -> void:
	var sep := _make_separator()
	parent.add_child(sep)

	# Progress row
	var prog_row := HBoxContainer.new()
	prog_row.add_theme_constant_override("separation", 10)
	parent.add_child(prog_row)

	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(0, 18)
	_progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.value     = 0.0
	_progress_bar.show_percentage = false
	var pb_style := StyleBoxFlat.new()
	pb_style.bg_color = Color(0.05, 0.12, 0.28)
	pb_style.border_color = C_ACCENT
	pb_style.set_border_width_all(1)
	pb_style.set_corner_radius_all(3)
	var pb_fill := StyleBoxFlat.new()
	pb_fill.bg_color = Color(0.28, 0.70, 0.95)
	pb_fill.set_corner_radius_all(3)
	_progress_bar.add_theme_stylebox_override("background", pb_style)
	_progress_bar.add_theme_stylebox_override("fill",       pb_fill)
	prog_row.add_child(_progress_bar)

	_progress_lbl = Label.new()
	_progress_lbl.text = ""
	_progress_lbl.add_theme_font_size_override("font_size", 12)
	_progress_lbl.add_theme_color_override("font_color", C_DIM)
	_progress_lbl.custom_minimum_size = Vector2(120, 0)
	prog_row.add_child(_progress_lbl)

	# Status + buttons row
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	parent.add_child(action_row)

	_status_lbl = Label.new()
	_status_lbl.text = ""
	_status_lbl.add_theme_font_size_override("font_size", 12)
	_status_lbl.add_theme_color_override("font_color", C_DIM)
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	action_row.add_child(_status_lbl)

	_reset_btn = _make_action_button("↺  RESET", Color(0.55, 0.35, 0.10))
	_reset_btn.pressed.connect(_on_reset_pressed)
	_reset_btn.custom_minimum_size = Vector2(110, 36)
	action_row.add_child(_reset_btn)

	_craft_btn = _make_action_button("▶  LANCER LA FABRICATION", Color(0.12, 0.35, 0.70))
	_craft_btn.pressed.connect(_on_craft_pressed)
	_craft_btn.custom_minimum_size = Vector2(220, 36)
	action_row.add_child(_craft_btn)


# ═══════════════════════════════════════════════════════════════════════════════
# CANVAS REBUILD  (called on recipe change or staged change)
# ═══════════════════════════════════════════════════════════════════════════════

func _rebuild_canvas() -> void:
	_refresh_tab_bar()

	# Remove old slot nodes
	for n in _slot_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_slot_nodes.clear()

	if _recipe_ids.is_empty():
		_update_status()
		return

	var rid     := _recipe_ids[_selected_idx]
	var recipe  := _get_recipe(rid)
	var ingrs   : Dictionary = recipe.get("ingredients", {})
	_craft_time = float(recipe.get("craft_time", 5.0))

	var keys    := ingrs.keys()
	var count   := mini(keys.size(), 4)
	var layout: Array = SLOT_LAYOUTS[clampi(count - 1, 0, 3)] if count > 0 else []

	# Build wire data and slot nodes AFTER layout (need canvas size)
	# Use call_deferred so canvas has its final size
	call_deferred("_place_slots_deferred", keys, layout, ingrs, rid)


func _place_slots_deferred(keys: Array, layout: Array, ingrs: Dictionary, _rid: String) -> void:
	if _canvas == null or not is_instance_valid(_canvas):
		return
	var csize := _canvas.size
	if csize == Vector2.ZERO:
		csize = Vector2(840, 340)

	_wire_canvas.set("wires", [])

	var result_center := RESULT_ANC * csize

	# Position result box (use fixed size, layout not settled yet)
	_result_box.position = result_center - Vector2(90.0, 56.0) * 0.5

	var rid    := _recipe_ids[_selected_idx]
	var recipe := _get_recipe(rid)

	# Update result name
	var res_lbl := _result_box.get_node_or_null("Name") as Label
	if res_lbl:
		res_lbl.text = recipe.get("display_name", rid).to_upper()

	for i in range(mini(keys.size(), 4)):
		var item_id : String = keys[i]
		var need    : int    = int(ingrs[item_id])
		var placed  : int    = int(_staged.get(item_id, 0))
		var anc     := (layout[i] as Vector2) * csize
		var slot    := _make_ingredient_slot(item_id, need, placed)
		slot.position = anc - Vector2(SLOT_W, SLOT_H) * 0.5
		_canvas.add_child(slot)
		_slot_nodes.append(slot)

		# Wire from slot center to result center
		var wires_arr: Array = _wire_canvas.get("wires")
		wires_arr.append([anc, result_center])
		_wire_canvas.set("wires", wires_arr)

	_wire_canvas.queue_redraw()
	_update_status()


# ═══════════════════════════════════════════════════════════════════════════════
# SLOT WIDGET
# ═══════════════════════════════════════════════════════════════════════════════

func _make_ingredient_slot(item_id: String, need: int, placed: int) -> Control:
	var root := Control.new()
	root.custom_minimum_size = Vector2(SLOT_W, SLOT_H)

	var bg := PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var have  := _get_item_amount(item_id)
	var full  := placed >= need
	var ok    := have  >= need

	var bs := StyleBoxFlat.new()
	if full:
		bs.bg_color     = Color(0.06, 0.22, 0.12, 0.92)
		bs.border_color = C_FILLED
	elif not ok:
		bs.bg_color     = Color(0.20, 0.06, 0.06, 0.88)
		bs.border_color = C_MISSING
	else:
		bs.bg_color     = Color(0.06, 0.12, 0.28, 0.88)
		bs.border_color = C_ACCENT
	bs.set_border_width_all(1)
	bs.set_corner_radius_all(4)
	bg.add_theme_stylebox_override("panel", bs)
	root.add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left",   8)
	margin.add_theme_constant_override("margin_top",    6)
	margin.add_theme_constant_override("margin_right",  8)
	margin.add_theme_constant_override("margin_bottom", 5)
	bg.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	margin.add_child(vb)

	var name_lbl := Label.new()
	name_lbl.text = _get_item_name(item_id).to_upper()
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", C_FILLED if full else (C_MISSING if not ok else C_ACCENT))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(name_lbl)

	var qty_lbl := Label.new()
	qty_lbl.text = "%d / %d" % [placed, need]
	qty_lbl.add_theme_font_size_override("font_size", 13)
	qty_lbl.add_theme_color_override("font_color", C_FILLED if full else (C_MISSING if not ok else C_TEXT))
	qty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(qty_lbl)

	if not full and not _crafting:
		var btn := Button.new()
		btn.text = "[ PLACER ]" if ok else "[ MANQUE ]"
		btn.flat = false
		btn.disabled = not ok
		btn.add_theme_font_size_override("font_size", 10)
		var bns := StyleBoxFlat.new()
		bns.bg_color     = Color(0.08, 0.20, 0.50, 0.9) if ok else Color(0.18, 0.08, 0.08, 0.7)
		bns.border_color = C_ACCENT if ok else C_MISSING
		bns.set_border_width_all(1)
		bns.set_corner_radius_all(3)
		bns.content_margin_top    = 2
		bns.content_margin_bottom = 2
		btn.add_theme_stylebox_override("normal", bns)
		btn.add_theme_stylebox_override("hover",  _lighter_style(bns))
		btn.add_theme_color_override("font_color", C_TEXT if ok else C_MISSING)
		btn.add_theme_color_override("font_disabled_color", C_MISSING)
		btn.pressed.connect(func() -> void: _place_component(item_id, need))
		vb.add_child(btn)
	elif full:
		var done_lbl := Label.new()
		done_lbl.text = "✓ OK"
		done_lbl.add_theme_font_size_override("font_size", 11)
		done_lbl.add_theme_color_override("font_color", C_FILLED)
		done_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(done_lbl)

	return root


func _make_result_box() -> Control:
	var root := Control.new()
	root.custom_minimum_size = Vector2(90, 56)

	var bg := PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bs := StyleBoxFlat.new()
	bs.bg_color     = Color(0.12, 0.10, 0.04, 0.95)
	bs.border_color = C_RESULT
	bs.set_border_width_all(2)
	bs.set_corner_radius_all(5)
	bg.add_theme_stylebox_override("panel", bs)
	root.add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left",  10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top",    6)
	margin.add_theme_constant_override("margin_bottom", 6)
	bg.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 1)
	margin.add_child(vb)

	var lbl_out := Label.new()
	lbl_out.name = "OutLabel"
	lbl_out.text = "RÉSULTAT"
	lbl_out.add_theme_font_size_override("font_size", 9)
	lbl_out.add_theme_color_override("font_color", C_DIM)
	lbl_out.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(lbl_out)

	var lbl_name := Label.new()
	lbl_name.name = "Name"
	lbl_name.text = "???"
	lbl_name.add_theme_font_size_override("font_size", 13)
	lbl_name.add_theme_color_override("font_color", C_RESULT)
	lbl_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(lbl_name)

	return root


# ═══════════════════════════════════════════════════════════════════════════════
# INTERACTIONS
# ═══════════════════════════════════════════════════════════════════════════════

func _place_component(item_id: String, need: int) -> void:
	if _crafting:
		return
	var already := int(_staged.get(item_id, 0))
	if already >= need:
		return
	var to_place := need - already
	var inv := get_node_or_null("/root/Inventory")
	if inv == null or not inv.has_method("spend_items"):
		return
	if not bool(inv.call("has_items", {item_id: to_place})):
		return
	inv.call("spend_items", {item_id: to_place})
	_staged[item_id] = need
	_rebuild_canvas()


func _on_reset_pressed() -> void:
	if _crafting:
		return
	# Refund all staged ingredients
	var inv := get_node_or_null("/root/Inventory")
	for item_id in _staged:
		var amt := int(_staged[item_id])
		if amt > 0 and inv != null and inv.has_method("add_item"):
			inv.call("add_item", item_id, amt)
	_staged.clear()
	_rebuild_canvas()


func _on_craft_pressed() -> void:
	if _crafting or not _schema_valid():
		return
	_start_craft()


func _start_craft() -> void:
	_crafting = true
	_craft_progress = 0.0
	_progress_bar.value = 0.0
	_craft_btn.disabled = true
	_reset_btn.disabled = true
	_status_lbl.text    = "Fabrication en cours..."
	_status_lbl.add_theme_color_override("font_color", Color(0.60, 0.88, 1.0))

	_craft_tween = create_tween()
	_craft_tween.tween_method(_set_progress, 0.0, 1.0, _craft_time)
	_craft_tween.tween_callback(_finish_craft)


func _set_progress(v: float) -> void:
	_craft_progress = v
	_progress_bar.value = v
	var remaining := _craft_time * (1.0 - v)
	_progress_lbl.text = "%.1fs" % remaining


func _finish_craft() -> void:
	_crafting = false
	_progress_bar.value = 1.0
	_progress_lbl.text  = "0.0s"

	# Give the result directly (ingredients already consumed on slot placement)
	var rid := _recipe_ids[_selected_idx]
	var inv  := get_node_or_null("/root/Inventory")
	if inv and inv.has_method("add_item"):
		inv.call("add_item", rid, 1)
	if _crafting_system and _crafting_system.has_signal("crafted"):
		_crafting_system.crafted.emit(rid)

	_staged.clear()
	_rebuild_canvas()


func _cancel_craft() -> void:
	if _craft_tween and _craft_tween.is_valid():
		_craft_tween.kill()
	# Refund staged
	_on_reset_pressed()
	_crafting = false
	_progress_bar.value = 0.0
	_progress_lbl.text  = ""


func _on_crafted(_item_id: String) -> void:
	pass


func _select_recipe(idx: int) -> void:
	if _crafting:
		return
	_staged.clear()
	_selected_idx = idx
	_rebuild_canvas()


# ═══════════════════════════════════════════════════════════════════════════════
# STATUS / VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

func _schema_valid() -> bool:
	if _recipe_ids.is_empty():
		return false
	var rid    := _recipe_ids[_selected_idx]
	var recipe := _get_recipe(rid)
	var ingrs  : Dictionary = recipe.get("ingredients", {})
	for item_id in ingrs:
		var need   := int(ingrs[item_id])
		var placed := int(_staged.get(item_id, 0))
		if placed < need:
			return false
	return true


func _update_status() -> void:
	if _recipe_ids.is_empty():
		_status_lbl.text = "Aucune recette disponible."
		_craft_btn.disabled = true
		_reset_btn.disabled = true
		return

	if _crafting:
		return

	var valid := _schema_valid()
	_craft_btn.disabled = not valid
	_reset_btn.disabled = _staged.is_empty()

	if valid:
		_status_lbl.text = "✓  Schéma validé — prêt à fabriquer"
		_status_lbl.add_theme_color_override("font_color", C_FILLED)
		_progress_lbl.text = "%.0fs" % _craft_time
	else:
		var rid    := _recipe_ids[_selected_idx]
		var recipe := _get_recipe(rid)
		var ingrs  : Dictionary = recipe.get("ingredients", {})
		var missing := 0
		for item_id in ingrs:
			if int(_staged.get(item_id, 0)) < int(ingrs[item_id]):
				missing += 1
		_status_lbl.text = "%d composant(s) manquant(s)" % missing
		_status_lbl.add_theme_color_override("font_color", C_DIM)
		_progress_lbl.text = "%.0fs" % _craft_time


# ═══════════════════════════════════════════════════════════════════════════════
# HELPERS / DATA
# ═══════════════════════════════════════════════════════════════════════════════

func _make_close_button() -> Button:
	var b := Button.new()
	b.text = "✕"
	b.flat = true
	b.add_theme_font_size_override("font_size", 17)
	b.add_theme_color_override("font_color",       Color(0.65, 0.35, 0.35))
	b.add_theme_color_override("font_hover_color", Color(1.0, 0.45, 0.45))
	b.pressed.connect(close)
	return b


func _make_separator() -> HSeparator:
	var sep := HSeparator.new()
	var ss := StyleBoxFlat.new()
	ss.bg_color = Color(0.30, 0.55, 0.90, 0.35)
	ss.content_margin_top = 1
	sep.add_theme_stylebox_override("separator", ss)
	return sep


func _make_action_button(text_: String, base_color: Color) -> Button:
	var btn := Button.new()
	btn.text = text_
	btn.add_theme_font_size_override("font_size", 13)
	var ns := StyleBoxFlat.new()
	ns.bg_color     = base_color.darkened(0.2)
	ns.border_color = base_color.lightened(0.35)
	ns.set_border_width_all(1)
	ns.set_corner_radius_all(4)
	ns.content_margin_left   = 14
	ns.content_margin_right  = 14
	ns.content_margin_top    = 8
	ns.content_margin_bottom = 8
	var hs := ns.duplicate() as StyleBoxFlat
	hs.bg_color = base_color.lightened(0.1)
	var ds := ns.duplicate() as StyleBoxFlat
	ds.bg_color     = Color(0.05, 0.08, 0.15)
	ds.border_color = Color(0.20, 0.30, 0.45)
	btn.add_theme_stylebox_override("normal",   ns)
	btn.add_theme_stylebox_override("hover",    hs)
	btn.add_theme_stylebox_override("pressed",  ns)
	btn.add_theme_stylebox_override("disabled", ds)
	btn.add_theme_color_override("font_color",          C_TITLE)
	btn.add_theme_color_override("font_hover_color",    Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", Color(0.30, 0.40, 0.55))
	return btn


func _lighter_style(base: StyleBoxFlat) -> StyleBoxFlat:
	var s := base.duplicate() as StyleBoxFlat
	s.bg_color = base.bg_color.lightened(0.15)
	return s


func _get_recipe_ids() -> Array[String]:
	# Workbench UI only lists recipes tagged for the workbench station.
	if _crafting_system and _crafting_system.has_method("get_recipe_ids_for_station"):
		var ids: Variant = _crafting_system.call("get_recipe_ids_for_station", "workbench")
		if ids is Array:
			var typed: Array[String] = []
			for id in ids:
				typed.append(String(id))
			return typed
	if _crafting_system and _crafting_system.has_method("get_recipe_ids"):
		var ids: Variant = _crafting_system.call("get_recipe_ids")
		if ids is Array:
			var typed: Array[String] = []
			for id in ids:
				typed.append(String(id))
			return typed
	return []


func _get_recipe(rid: String) -> Dictionary:
	if _crafting_system and _crafting_system.has_method("get_recipe"):
		var r: Variant = _crafting_system.call("get_recipe", rid)
		if r is Dictionary:
			return r
	return {}


func _can_craft(rid: String) -> bool:
	if _crafting_system and _crafting_system.has_method("can_craft"):
		return bool(_crafting_system.call("can_craft", rid))
	return false


func _get_item_amount(item_id: String) -> int:
	var inv := get_node_or_null("/root/Inventory")
	if inv and inv.has_method("get_item_amount"):
		return int(inv.call("get_item_amount", item_id))
	return 0


func _get_item_name(item_id: String) -> String:
	var inv := get_node_or_null("/root/Inventory")
	if inv and inv.has_method("get_item_name"):
		return String(inv.call("get_item_name", item_id))
	return item_id
