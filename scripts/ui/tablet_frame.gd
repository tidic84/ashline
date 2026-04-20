extends Control
class_name TabletFrame

# Reusable sci-fi tablet chassis. Wraps a content Control inside a stylized
# tablet body with a right-side icon tab rail (Subnautica-style) and an
# open/close animation.
#
# Note: a real 3D tablet model was intended (Sketchfab asset) but the source
# was blocked from this sandbox — the chassis is assembled procedurally from
# panels/borders to match the sci-fi aesthetic. Swap in a SubViewport+mesh
# later by replacing `_build_chassis()`.

signal closed
signal tab_selected(tab_id: String)

# Palette — cool cyan sci-fi, matches the rest of the HUD's dark chrome
const C_VOID       := Color(0.010, 0.012, 0.016, 1.00)
const C_CHASSIS    := Color(0.055, 0.065, 0.080, 1.00)
const C_CHASSIS_HI := Color(0.105, 0.120, 0.140, 1.00)
const C_BEZEL      := Color(0.030, 0.038, 0.050, 1.00)
const C_SCREEN     := Color(0.020, 0.042, 0.068, 1.00)
const C_SCREEN_TOP := Color(0.008, 0.020, 0.038, 1.00)
const C_ACCENT     := Color(0.35, 0.85, 1.00, 1.00)
const C_ACCENT_DIM := Color(0.22, 0.55, 0.72, 1.00)
const C_ACCENT_MUT := Color(0.18, 0.35, 0.48, 1.00)
const C_TEXT_HI    := Color(0.92, 0.97, 1.00, 1.00)
const C_TEXT_DIM   := Color(0.55, 0.72, 0.82, 1.00)

const TABLET_SIZE := Vector2(1320, 760)
# Screen = inner usable content rect (inside bezels), relative to tablet top-left.
# Right bezel is wider to host the tab rail (Subnautica-style).
const SCREEN_INSET := Vector4(44, 64, 118, 64) # left, top, right, bottom

const TAB_RAIL_W := 80.0
const TAB_BTN_SIZE := Vector2(56, 56)

var _dim_bg: ColorRect
var _tablet_wrap: Control       # anchors + scale pivot
var _tablet_chassis: Control    # the tablet body (scales/animates)
var _screen_area: Control       # inner area where content sits
var _content_holder: Control    # parent of user-provided content
var _tab_rail: VBoxContainer
var _status_label: Label
var _clock_label: Label
var _anim_tween: Tween
var _pulse_time: float = 0.0
var _accent_lines: Array[ColorRect] = []
var _tabs_info: Array = []
var _selected_tab_id: String = ""
var _is_open: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	visible = false
	set_process(true)


func _build() -> void:
	_dim_bg = ColorRect.new()
	_dim_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim_bg.color = Color(0, 0, 0, 0.72)
	_dim_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim_bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(center)

	_tablet_wrap = Control.new()
	_tablet_wrap.custom_minimum_size = TABLET_SIZE
	_tablet_wrap.size = TABLET_SIZE
	_tablet_wrap.pivot_offset = TABLET_SIZE * 0.5
	_tablet_wrap.mouse_filter = Control.MOUSE_FILTER_PASS
	center.add_child(_tablet_wrap)

	_tablet_chassis = Control.new()
	_tablet_chassis.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tablet_chassis.mouse_filter = Control.MOUSE_FILTER_PASS
	_tablet_wrap.add_child(_tablet_chassis)

	_build_chassis(_tablet_chassis)
	_build_bezel_details(_tablet_chassis)
	_build_screen(_tablet_chassis)
	_build_tab_rail(_tablet_wrap)


# ─── Chassis shell ────────────────────────────────────────────────────────────

func _build_chassis(parent: Control) -> void:
	# Outer glow halo — soft cyan rim around the tablet
	var halo := Panel.new()
	halo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	halo.offset_left = -14
	halo.offset_top = -14
	halo.offset_right = 14
	halo.offset_bottom = 14
	halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var halo_sb := StyleBoxFlat.new()
	halo_sb.bg_color = Color(0, 0, 0, 0)
	halo_sb.border_width_top    = 2
	halo_sb.border_width_left   = 2
	halo_sb.border_width_right  = 2
	halo_sb.border_width_bottom = 2
	halo_sb.border_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.18)
	halo_sb.set_corner_radius_all(46)
	halo_sb.shadow_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.22)
	halo_sb.shadow_size = 40
	halo.add_theme_stylebox_override("panel", halo_sb)
	parent.add_child(halo)

	# Main chassis body
	var body := Panel.new()
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.mouse_filter = Control.MOUSE_FILTER_PASS
	var body_sb := StyleBoxFlat.new()
	body_sb.bg_color = C_CHASSIS
	body_sb.border_width_top    = 2
	body_sb.border_width_left   = 2
	body_sb.border_width_right  = 2
	body_sb.border_width_bottom = 2
	body_sb.border_color = Color(0.28, 0.36, 0.44, 1.0)
	body_sb.set_corner_radius_all(38)
	body_sb.shadow_color = Color(0, 0, 0, 0.85)
	body_sb.shadow_size = 30
	body.add_theme_stylebox_override("panel", body_sb)
	parent.add_child(body)

	# Inner chassis rim (gives a thin inset bevel line)
	var rim := Panel.new()
	rim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rim.offset_left = 8
	rim.offset_top = 8
	rim.offset_right = -8
	rim.offset_bottom = -8
	rim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rim_sb := StyleBoxFlat.new()
	rim_sb.bg_color = Color(0, 0, 0, 0)
	rim_sb.border_width_top    = 1
	rim_sb.border_width_left   = 1
	rim_sb.border_width_right  = 1
	rim_sb.border_width_bottom = 1
	rim_sb.border_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.45)
	rim_sb.set_corner_radius_all(30)
	rim.add_theme_stylebox_override("panel", rim_sb)
	parent.add_child(rim)


func _build_bezel_details(parent: Control) -> void:
	# Top bezel: brand + status LED + clock
	var top_bar := HBoxContainer.new()
	top_bar.anchor_left = 0.0
	top_bar.anchor_right = 1.0
	top_bar.offset_left = 56
	top_bar.offset_right = -56
	top_bar.offset_top = 20
	top_bar.offset_bottom = 48
	top_bar.add_theme_constant_override("separation", 12)
	top_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(top_bar)

	var led := Panel.new()
	led.custom_minimum_size = Vector2(10, 10)
	var led_sb := StyleBoxFlat.new()
	led_sb.bg_color = Color(0.45, 1.0, 0.75, 1.0)
	led_sb.set_corner_radius_all(10)
	led.add_theme_stylebox_override("panel", led_sb)
	led.mouse_filter = Control.MOUSE_FILTER_IGNORE
	led.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top_bar.add_child(led)

	var brand := Label.new()
	brand.text = "ASHLINE ◆ COMBAT TABLET ◆ MK-IV"
	brand.add_theme_font_size_override("font_size", 11)
	brand.add_theme_color_override("font_color", C_ACCENT)
	brand.add_theme_constant_override("outline_size", 0)
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_bar.add_child(brand)

	_status_label = Label.new()
	_status_label.text = "  ∕  SYS OK  ∕  LINK ▲  ∕  PWR 87%%"
	_status_label.add_theme_font_size_override("font_size", 10)
	_status_label.add_theme_color_override("font_color", C_TEXT_DIM)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_bar.add_child(_status_label)

	_clock_label = Label.new()
	_clock_label.text = "00:00"
	_clock_label.add_theme_font_size_override("font_size", 11)
	_clock_label.add_theme_color_override("font_color", C_TEXT_HI)
	_clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_bar.add_child(_clock_label)

	# Bottom bezel: central home ring + side bars
	var bottom_bar := Control.new()
	bottom_bar.anchor_left = 0.0
	bottom_bar.anchor_right = 1.0
	bottom_bar.anchor_top = 1.0
	bottom_bar.anchor_bottom = 1.0
	bottom_bar.offset_left = 0
	bottom_bar.offset_right = 0
	bottom_bar.offset_top = -52
	bottom_bar.offset_bottom = -16
	bottom_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bottom_bar)

	var home_wrap := CenterContainer.new()
	home_wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	home_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom_bar.add_child(home_wrap)

	var home_ring := Panel.new()
	home_ring.custom_minimum_size = Vector2(28, 28)
	var home_sb := StyleBoxFlat.new()
	home_sb.bg_color = Color(0, 0, 0, 0)
	home_sb.border_width_top    = 2
	home_sb.border_width_left   = 2
	home_sb.border_width_right  = 2
	home_sb.border_width_bottom = 2
	home_sb.border_color = C_ACCENT_DIM
	home_sb.set_corner_radius_all(30)
	home_ring.add_theme_stylebox_override("panel", home_sb)
	home_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	home_wrap.add_child(home_ring)

	# Decorative accent lines left/right of the home ring
	_add_accent_bar(bottom_bar, Vector2(60, 20), Vector2(160, 3))
	_add_accent_bar(bottom_bar, Vector2(60, 30), Vector2(90, 2))
	_add_accent_bar(bottom_bar, Vector2(-220, 20), Vector2(160, 3), true)
	_add_accent_bar(bottom_bar, Vector2(-150, 30), Vector2(90, 2), true)

	# Side vents (diagonal emissive lines)
	for i in range(5):
		var y := 120 + i * 42
		_add_side_notch(parent, y, true)
		_add_side_notch(parent, y, false)


func _add_accent_bar(parent: Control, offset: Vector2, dims: Vector2, right_aligned: bool = false) -> void:
	var r := ColorRect.new()
	r.color = C_ACCENT_MUT
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if right_aligned:
		r.anchor_left = 1.0
		r.anchor_right = 1.0
		r.offset_left = offset.x
		r.offset_right = offset.x + dims.x
	else:
		r.offset_left = offset.x
		r.offset_right = offset.x + dims.x
	r.offset_top = offset.y
	r.offset_bottom = offset.y + dims.y
	parent.add_child(r)
	_accent_lines.append(r)


func _add_side_notch(parent: Control, y: float, left: bool) -> void:
	var r := ColorRect.new()
	r.color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.55)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if left:
		r.offset_left = 18
		r.offset_right = 30
	else:
		r.anchor_left = 1.0
		r.anchor_right = 1.0
		r.offset_left = -30
		r.offset_right = -18
	r.offset_top = y
	r.offset_bottom = y + 2
	parent.add_child(r)
	_accent_lines.append(r)


# ─── Screen (content host) ────────────────────────────────────────────────────

func _build_screen(parent: Control) -> void:
	var screen_bg := Panel.new()
	screen_bg.anchor_left = 0.0
	screen_bg.anchor_right = 1.0
	screen_bg.anchor_top = 0.0
	screen_bg.anchor_bottom = 1.0
	screen_bg.offset_left = SCREEN_INSET.x
	screen_bg.offset_top = SCREEN_INSET.y
	screen_bg.offset_right = -SCREEN_INSET.z
	screen_bg.offset_bottom = -SCREEN_INSET.w
	screen_bg.mouse_filter = Control.MOUSE_FILTER_PASS

	var screen_sb := StyleBoxFlat.new()
	screen_sb.bg_color = C_SCREEN
	screen_sb.border_width_top    = 1
	screen_sb.border_width_left   = 1
	screen_sb.border_width_right  = 1
	screen_sb.border_width_bottom = 1
	screen_sb.border_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.85)
	screen_sb.set_corner_radius_all(16)
	screen_sb.shadow_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.35)
	screen_sb.shadow_size = 12
	screen_sb.content_margin_left = 18
	screen_sb.content_margin_right = 18
	screen_sb.content_margin_top = 16
	screen_sb.content_margin_bottom = 16
	screen_bg.add_theme_stylebox_override("panel", screen_sb)
	parent.add_child(screen_bg)

	_screen_area = screen_bg

	# Subtle corner reticle marks on the screen
	for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		_add_screen_reticle(screen_bg, corner)

	# Content holder sits inside the screen, inset from the glowing bezel
	_content_holder = Control.new()
	_content_holder.anchor_left = 0.0
	_content_holder.anchor_right = 1.0
	_content_holder.anchor_top = 0.0
	_content_holder.anchor_bottom = 1.0
	_content_holder.offset_left = 20
	_content_holder.offset_top = 20
	_content_holder.offset_right = -20
	_content_holder.offset_bottom = -20
	_content_holder.mouse_filter = Control.MOUSE_FILTER_PASS
	screen_bg.add_child(_content_holder)


func _add_screen_reticle(parent: Control, corner: Vector2) -> void:
	var size := 14
	var thickness := 2
	var margin := 8
	var h_bar := ColorRect.new()
	var v_bar := ColorRect.new()
	h_bar.color = C_ACCENT
	v_bar.color = C_ACCENT
	h_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h_bar.anchor_left = corner.x
	h_bar.anchor_right = corner.x
	h_bar.anchor_top = corner.y
	h_bar.anchor_bottom = corner.y
	v_bar.anchor_left = corner.x
	v_bar.anchor_right = corner.x
	v_bar.anchor_top = corner.y
	v_bar.anchor_bottom = corner.y
	var hx := margin if corner.x < 0.5 else -margin - size
	var hy := margin if corner.y < 0.5 else -margin - thickness
	var vx := margin if corner.x < 0.5 else -margin - thickness
	var vy := margin if corner.y < 0.5 else -margin - size
	h_bar.offset_left = hx
	h_bar.offset_right = hx + size
	h_bar.offset_top = hy
	h_bar.offset_bottom = hy + thickness
	v_bar.offset_left = vx
	v_bar.offset_right = vx + thickness
	v_bar.offset_top = vy
	v_bar.offset_bottom = vy + size
	parent.add_child(h_bar)
	parent.add_child(v_bar)


# ─── Right-side tab rail (Subnautica-style) ───────────────────────────────────

func _build_tab_rail(parent: Control) -> void:
	var rail_wrap := Control.new()
	# Place the rail inside the right bezel of the tablet chassis
	rail_wrap.anchor_left = 1.0
	rail_wrap.anchor_right = 1.0
	rail_wrap.anchor_top = 0.0
	rail_wrap.anchor_bottom = 1.0
	rail_wrap.offset_left = -(TAB_RAIL_W + 20)
	rail_wrap.offset_right = -20
	rail_wrap.offset_top = 120
	rail_wrap.offset_bottom = -120
	rail_wrap.mouse_filter = Control.MOUSE_FILTER_PASS
	parent.add_child(rail_wrap)

	# Rail backing panel
	var rail_bg := Panel.new()
	rail_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rail_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rail_sb := StyleBoxFlat.new()
	rail_sb.bg_color = C_CHASSIS_HI
	rail_sb.border_width_top    = 2
	rail_sb.border_width_left   = 2
	rail_sb.border_width_right  = 2
	rail_sb.border_width_bottom = 2
	rail_sb.border_color = Color(0.28, 0.36, 0.44, 1.0)
	rail_sb.set_corner_radius_all(18)
	rail_sb.shadow_color = Color(0, 0, 0, 0.7)
	rail_sb.shadow_size = 14
	rail_bg.add_theme_stylebox_override("panel", rail_sb)
	rail_wrap.add_child(rail_bg)

	var rail_inner_margin := MarginContainer.new()
	rail_inner_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rail_inner_margin.add_theme_constant_override("margin_left", 6)
	rail_inner_margin.add_theme_constant_override("margin_right", 6)
	rail_inner_margin.add_theme_constant_override("margin_top", 10)
	rail_inner_margin.add_theme_constant_override("margin_bottom", 10)
	rail_wrap.add_child(rail_inner_margin)

	_tab_rail = VBoxContainer.new()
	_tab_rail.add_theme_constant_override("separation", 8)
	_tab_rail.alignment = BoxContainer.ALIGNMENT_BEGIN
	_tab_rail.mouse_filter = Control.MOUSE_FILTER_PASS
	rail_inner_margin.add_child(_tab_rail)


# ─── Public API ───────────────────────────────────────────────────────────────

func set_content(ctrl: Control) -> void:
	if ctrl == null or _content_holder == null:
		return
	for c in _content_holder.get_children():
		_content_holder.remove_child(c)
	_content_holder.add_child(ctrl)
	ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func get_content_holder() -> Control:
	return _content_holder


func add_tab(tab_id: String, label: String, glyph: String, description: String = "") -> void:
	# glyph is a short unicode string used as icon (keeps assets-free).
	var btn := Button.new()
	btn.custom_minimum_size = TAB_BTN_SIZE
	btn.text = glyph
	btn.tooltip_text = label if description.is_empty() else "%s\n%s" % [label, description]
	btn.add_theme_font_size_override("font_size", 20)
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.toggle_mode = true
	_style_tab_button(btn, false)
	btn.pressed.connect(func(): _on_tab_pressed(tab_id))
	_tab_rail.add_child(btn)

	var caption := Label.new()
	caption.text = label.to_upper()
	caption.add_theme_font_size_override("font_size", 8)
	caption.add_theme_color_override("font_color", C_TEXT_DIM)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_rail.add_child(caption)

	_tabs_info.append({"id": tab_id, "button": btn, "caption": caption})

	if _selected_tab_id.is_empty():
		set_active_tab(tab_id, false)


func set_active_tab(tab_id: String, emit_signal_flag: bool = true) -> void:
	_selected_tab_id = tab_id
	for t in _tabs_info:
		var is_sel: bool = String(t["id"]) == tab_id
		_style_tab_button(t["button"] as Button, is_sel)
		(t["button"] as Button).button_pressed = is_sel
		(t["caption"] as Label).add_theme_color_override("font_color", C_ACCENT if is_sel else C_TEXT_DIM)
	if emit_signal_flag:
		tab_selected.emit(tab_id)


func add_close_button() -> void:
	# A small X button at the top-right of the tablet chassis (hardware-style)
	var x := Button.new()
	x.text = "×"
	x.add_theme_font_size_override("font_size", 22)
	x.custom_minimum_size = Vector2(36, 32)
	x.flat = true
	x.focus_mode = Control.FOCUS_NONE
	x.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	x.add_theme_color_override("font_color", C_TEXT_DIM)
	x.add_theme_color_override("font_hover_color", Color(1, 0.55, 0.55, 1))
	x.anchor_left = 1.0
	x.anchor_right = 1.0
	x.offset_left = -72
	x.offset_right = -36
	x.offset_top = 14
	x.offset_bottom = 46
	x.pressed.connect(func(): closed.emit())
	_tablet_chassis.add_child(x)


func open() -> void:
	_is_open = true
	visible = true
	_play_open_animation()


func close() -> void:
	_is_open = false
	visible = false
	if _anim_tween and _anim_tween.is_valid():
		_anim_tween.kill()
	closed.emit()


func is_open() -> bool:
	return _is_open


# ─── Animation ────────────────────────────────────────────────────────────────

func _play_open_animation() -> void:
	if _tablet_wrap == null:
		return
	if _anim_tween and _anim_tween.is_valid():
		_anim_tween.kill()

	_tablet_wrap.scale = Vector2(0.72, 0.72)
	_tablet_wrap.rotation = 0.18
	_tablet_wrap.modulate = Color(1, 1, 1, 0)
	_dim_bg.color = Color(0, 0, 0, 0)

	_anim_tween = create_tween().set_parallel(true)
	_anim_tween.tween_property(_dim_bg, "color", Color(0, 0, 0, 0.72), 0.28).set_trans(Tween.TRANS_SINE)
	_anim_tween.tween_property(_tablet_wrap, "scale", Vector2(1, 1), 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_anim_tween.tween_property(_tablet_wrap, "rotation", 0.0, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_anim_tween.tween_property(_tablet_wrap, "modulate", Color(1, 1, 1, 1), 0.32).set_trans(Tween.TRANS_SINE)


func _process(delta: float) -> void:
	if not visible:
		return
	_pulse_time += delta
	# Pulse accent lines gently
	var pulse: float = 0.45 + 0.25 * (0.5 + 0.5 * sin(_pulse_time * 1.4))
	var c := Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, pulse)
	for r in _accent_lines:
		if is_instance_valid(r):
			r.color = Color(C_ACCENT_MUT.r, C_ACCENT_MUT.g, C_ACCENT_MUT.b, pulse * 0.9)
	if _clock_label:
		_clock_label.text = _format_clock()


func _format_clock() -> String:
	var t := Time.get_time_dict_from_system()
	return "%02d:%02d" % [int(t.hour), int(t.minute)]


# ─── Tab button styling ───────────────────────────────────────────────────────

func _on_tab_pressed(tab_id: String) -> void:
	if tab_id == _selected_tab_id:
		# Keep it pressed visually
		for t in _tabs_info:
			if String(t["id"]) == tab_id:
				(t["button"] as Button).button_pressed = true
		return
	set_active_tab(tab_id, true)


func _style_tab_button(btn: Button, active: bool) -> void:
	var ns := StyleBoxFlat.new()
	ns.bg_color = C_BEZEL if not active else Color(C_ACCENT.r * 0.30, C_ACCENT.g * 0.30, C_ACCENT.b * 0.40, 1.0)
	ns.border_width_top    = 2
	ns.border_width_left   = 2
	ns.border_width_right  = 2
	ns.border_width_bottom = 2
	ns.border_color = C_ACCENT if active else Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.25)
	ns.set_corner_radius_all(12)
	ns.content_margin_left = 4
	ns.content_margin_right = 4
	ns.content_margin_top = 4
	ns.content_margin_bottom = 4
	if active:
		ns.shadow_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.55)
		ns.shadow_size = 10

	var hs := ns.duplicate() as StyleBoxFlat
	hs.bg_color = Color(C_ACCENT.r * 0.22, C_ACCENT.g * 0.22, C_ACCENT.b * 0.30, 1.0)
	hs.border_color = C_ACCENT
	var ps := ns.duplicate() as StyleBoxFlat
	btn.add_theme_stylebox_override("normal", ns)
	btn.add_theme_stylebox_override("hover", hs)
	btn.add_theme_stylebox_override("pressed", ps)
	btn.add_theme_stylebox_override("focus", ns)
	btn.add_theme_color_override("font_color", C_ACCENT if active else C_TEXT_DIM)
	btn.add_theme_color_override("font_hover_color", C_TEXT_HI)
	btn.add_theme_color_override("font_pressed_color", C_ACCENT)
