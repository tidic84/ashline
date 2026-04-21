extends Control
class_name TabletFrame

# Sci-fi tablet UI frame.
# Uses the real 3D model (res://assets/models/ui/tablet/Tablet.fbx) when
# available (after Godot imports it). Falls back to a procedural chassis.
#
# The 3D SubViewport renders the tablet body with its screen mesh made fully
# transparent. 2D content is placed BEHIND the 3D render, visible through
# the transparent screen hole. The tab rail and HUD overlays sit on top.
#
# TUNING after first run: adjust SCREEN_UV_RECT so the 2D content aligns
# with the transparent screen area of the 3D model. Enable DEBUG_SCREEN_RECT
# to see the current rect highlighted while in-game.

signal closed
signal tab_selected(tab_id: String)

# ─── Model path ───────────────────────────────────────────────────────────────
const TABLET_MODEL_PATH := "res://assets/models/ui/tablet/Tablet.fbx"

# ─── Screen alignment (UV, 0-1 relative to tablet size) ──────────────────────
# Adjust until 2D content aligns with the transparent screen in the 3D model.
# Enable DEBUG_SCREEN_RECT to see a highlight while tuning.
const SCREEN_UV_RECT    := Rect2(0.04, 0.08, 0.78, 0.84)
const DEBUG_SCREEN_RECT := false  # set true to show alignment helper

# Camera setup for the 3D model (tweak if model is wrong orientation/size)
const CAM_POSITION   := Vector3(0.0, 0.0, 0.0)   # auto-framed, used as fallback
const CAM_FOV        := 38.0
const MODEL_ROTATION := Vector3(0.0, 0.0, 0.0)   # deg; adjust if model arrives in wrong orientation

# ─── Palette ──────────────────────────────────────────────────────────────────
const C_VOID       := Color(0.010, 0.012, 0.016, 1.00)
const C_CHASSIS    := Color(0.055, 0.065, 0.080, 1.00)
const C_CHASSIS_HI := Color(0.105, 0.120, 0.140, 1.00)
const C_BEZEL      := Color(0.030, 0.038, 0.050, 1.00)
const C_SCREEN     := Color(0.020, 0.042, 0.068, 1.00)
const C_ACCENT     := Color(0.35, 0.85, 1.00, 1.00)
const C_ACCENT_DIM := Color(0.22, 0.55, 0.72, 1.00)
const C_ACCENT_MUT := Color(0.18, 0.35, 0.48, 1.00)
const C_TEXT_HI    := Color(0.92, 0.97, 1.00, 1.00)
const C_TEXT_DIM   := Color(0.55, 0.72, 0.82, 1.00)

# ─── Layout ───────────────────────────────────────────────────────────────────
const TABLET_SIZE   := Vector2(1320, 760)
const SCREEN_INSET  := Vector4(44, 64, 118, 64)  # for procedural fallback
const TAB_RAIL_W    := 80.0
const TAB_BTN_SIZE  := Vector2(56, 56)

# ─── State ────────────────────────────────────────────────────────────────────
var _use_3d_model: bool = false

var _dim_bg: ColorRect
var _tablet_wrap: Control
var _tablet_chassis: Control
var _content_holder: Control
var _tab_rail: VBoxContainer
var _status_label: Label
var _clock_label: Label
var _anim_tween: Tween
var _pulse_time: float = 0.0
var _accent_lines: Array[ColorRect] = []
var _tabs_info: Array = []
var _selected_tab_id: String = ""
var _is_open: bool = false

# 3D model refs
var _3d_viewport: SubViewport = null
var _3d_camera: Camera3D = null
var _3d_model: Node3D = null
var _3d_texture_rect: TextureRect = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_use_3d_model = ResourceLoader.exists(TABLET_MODEL_PATH)
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

	if _use_3d_model:
		_build_chassis_3d(_tablet_chassis)
	else:
		_build_chassis_procedural(_tablet_chassis)
		_build_bezel_details(_tablet_chassis)

	_build_content_area()
	_build_tab_rail(_tablet_wrap)

	if not _use_3d_model:
		_build_bezel_overlay(_tablet_chassis)
	else:
		_build_hud_overlay(_tablet_chassis)


# ═══════════════════════════════════════════════════════════════════════════════
# 3D CHASSIS
# ═══════════════════════════════════════════════════════════════════════════════

func _build_chassis_3d(parent: Control) -> void:
	# Layer 1: dark background (visible behind the 3D render)
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_sb := StyleBoxFlat.new()
	bg_sb.bg_color = Color(0.02, 0.025, 0.032, 1.0)
	bg.add_theme_stylebox_override("panel", bg_sb)
	parent.add_child(bg)

	# SubViewport renders the 3D tablet
	_3d_viewport = SubViewport.new()
	_3d_viewport.size = Vector2i(int(TABLET_SIZE.x), int(TABLET_SIZE.y))
	_3d_viewport.transparent_bg = true
	_3d_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_3d_viewport.own_world_3d = true
	_3d_viewport.world_3d = World3D.new()
	_3d_viewport.msaa_3d = Viewport.MSAA_4X

	var key_light := DirectionalLight3D.new()
	key_light.transform = Transform3D(
		Basis().rotated(Vector3.RIGHT, -0.55).rotated(Vector3.UP, 0.4),
		Vector3.ZERO)
	key_light.light_energy = 1.4
	_3d_viewport.add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.transform = Transform3D(
		Basis().rotated(Vector3.RIGHT, -0.15).rotated(Vector3.UP, -2.1),
		Vector3.ZERO)
	fill_light.light_energy = 0.45
	_3d_viewport.add_child(fill_light)

	var rim_light := DirectionalLight3D.new()
	rim_light.transform = Transform3D(
		Basis().rotated(Vector3.RIGHT, 0.3).rotated(Vector3.UP, 3.14),
		Vector3.ZERO)
	rim_light.light_color = Color(0.4, 0.85, 1.0)
	rim_light.light_energy = 0.35
	_3d_viewport.add_child(rim_light)

	_3d_camera = Camera3D.new()
	_3d_camera.fov = CAM_FOV
	_3d_camera.near = 0.05
	_3d_camera.far = 100.0
	_3d_viewport.add_child(_3d_camera)

	var scene := load(TABLET_MODEL_PATH) as PackedScene
	if scene:
		_3d_model = scene.instantiate() as Node3D
		if _3d_model:
			_3d_model.rotation_degrees = MODEL_ROTATION
			_3d_viewport.add_child(_3d_model)

	get_tree().root.add_child.call_deferred(_3d_viewport)

	# Layer 3: TextureRect displays the 3D render (transparent screen area shows content below)
	_3d_texture_rect = TextureRect.new()
	_3d_texture_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_3d_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_3d_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_3d_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_3d_texture_rect)

	_3d_viewport.ready.connect(func():
		if _3d_texture_rect:
			_3d_texture_rect.texture = _3d_viewport.get_texture()
		if _3d_model and is_instance_valid(_3d_model):
			_make_screen_transparent(_3d_model)
			call_deferred("_frame_3d_camera")
	, CONNECT_ONE_SHOT)


func _make_screen_transparent(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh_res := mi.mesh
		if mesh_res == null:
			return
		for surf in range(mesh_res.get_surface_count()):
			var mat := mi.get_active_material(surf)
			if mat == null:
				continue
			var mat_name := mat.resource_name.to_lower()
			if "ui" in mat_name or "screen" in mat_name or "display" in mat_name:
				var override_mat := StandardMaterial3D.new()
				override_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				override_mat.albedo_color = Color(0.0, 0.0, 0.0, 0.0)
				override_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				mi.set_surface_override_material(surf, override_mat)
	for child in node.get_children():
		_make_screen_transparent(child)


func _frame_3d_camera() -> void:
	if _3d_model == null or _3d_camera == null or not is_instance_valid(_3d_model):
		return
	var aabb := _compute_model_aabb(_3d_model)
	if aabb.size == Vector3.ZERO:
		_3d_camera.position = Vector3(0, 0, 3.5)
		_3d_camera.look_at(Vector3.ZERO, Vector3.UP)
		return
	var center := aabb.get_center()
	# Center model at origin
	_3d_model.position -= center
	var size := aabb.size
	var radius := max(size.x, max(size.y, size.z)) * 0.5
	var fov_rad := deg_to_rad(CAM_FOV)
	# Account for aspect ratio — tablet is wider than tall
	var aspect := TABLET_SIZE.x / TABLET_SIZE.y
	var vert_fov := 2.0 * atan(tan(fov_rad * 0.5) / aspect)
	var dist := radius / tan(min(fov_rad, vert_fov) * 0.5) * 1.15
	_3d_camera.position = Vector3(0.0, 0.0, dist)
	_3d_camera.look_at(Vector3.ZERO, Vector3.UP)


func _compute_model_aabb(root: Node3D) -> AABB:
	var aabb := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			var vi := n as VisualInstance3D
			var box: AABB
			if vi.is_inside_tree():
				box = vi.global_transform * vi.get_aabb()
			else:
				box = vi.transform * vi.get_aabb()
			if first:
				aabb = box
				first = false
			else:
				aabb = aabb.merge(box)
		for c in n.get_children():
			stack.append(c)
	return aabb


func _exit_tree() -> void:
	if _3d_viewport and is_instance_valid(_3d_viewport):
		_3d_viewport.queue_free()
		_3d_viewport = null


# ═══════════════════════════════════════════════════════════════════════════════
# PROCEDURAL CHASSIS (fallback)
# ═══════════════════════════════════════════════════════════════════════════════

func _build_chassis_procedural(parent: Control) -> void:
	var halo := Panel.new()
	halo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	halo.offset_left = -14;  halo.offset_top = -14
	halo.offset_right = 14; halo.offset_bottom = 14
	halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var halo_sb := StyleBoxFlat.new()
	halo_sb.bg_color = Color(0, 0, 0, 0)
	halo_sb.set_border_width_all(2)
	halo_sb.border_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.18)
	halo_sb.set_corner_radius_all(46)
	halo_sb.shadow_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.22)
	halo_sb.shadow_size = 40
	halo.add_theme_stylebox_override("panel", halo_sb)
	parent.add_child(halo)

	var body := Panel.new()
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.mouse_filter = Control.MOUSE_FILTER_PASS
	var body_sb := StyleBoxFlat.new()
	body_sb.bg_color = C_CHASSIS
	body_sb.set_border_width_all(2)
	body_sb.border_color = Color(0.28, 0.36, 0.44, 1.0)
	body_sb.set_corner_radius_all(38)
	body_sb.shadow_color = Color(0, 0, 0, 0.85)
	body_sb.shadow_size = 30
	body.add_theme_stylebox_override("panel", body_sb)
	parent.add_child(body)

	var rim := Panel.new()
	rim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rim.offset_left = 8;  rim.offset_top = 8
	rim.offset_right = -8; rim.offset_bottom = -8
	rim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rim_sb := StyleBoxFlat.new()
	rim_sb.bg_color = Color(0, 0, 0, 0)
	rim_sb.set_border_width_all(1)
	rim_sb.border_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.45)
	rim_sb.set_corner_radius_all(30)
	rim.add_theme_stylebox_override("panel", rim_sb)
	parent.add_child(rim)

	# Screen panel (for procedural mode)
	var screen_bg := Panel.new()
	screen_bg.anchor_left = 0.0;  screen_bg.anchor_right  = 1.0
	screen_bg.anchor_top  = 0.0;  screen_bg.anchor_bottom = 1.0
	screen_bg.offset_left = SCREEN_INSET.x;  screen_bg.offset_top    = SCREEN_INSET.y
	screen_bg.offset_right = -SCREEN_INSET.z; screen_bg.offset_bottom = -SCREEN_INSET.w
	screen_bg.mouse_filter = Control.MOUSE_FILTER_PASS
	var screen_sb := StyleBoxFlat.new()
	screen_sb.bg_color = C_SCREEN
	screen_sb.set_border_width_all(1)
	screen_sb.border_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.85)
	screen_sb.set_corner_radius_all(16)
	screen_sb.shadow_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.35)
	screen_sb.shadow_size = 12
	screen_bg.add_theme_stylebox_override("panel", screen_sb)
	parent.add_child(screen_bg)

	for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		_add_screen_reticle(screen_bg, corner)

	# Side vents
	for i in range(5):
		var y := 120.0 + i * 42
		_add_side_notch(parent, y, true)
		_add_side_notch(parent, y, false)


# ─── Bezel details (procedural only) ─────────────────────────────────────────

func _build_bezel_details(parent: Control) -> void:
	var top_bar := HBoxContainer.new()
	top_bar.anchor_left = 0.0;  top_bar.anchor_right  = 1.0
	top_bar.offset_left = 56;   top_bar.offset_right  = -56
	top_bar.offset_top  = 20;   top_bar.offset_bottom = 48
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

	var bottom_bar := Control.new()
	bottom_bar.anchor_left = 0.0;  bottom_bar.anchor_right  = 1.0
	bottom_bar.anchor_top  = 1.0;  bottom_bar.anchor_bottom = 1.0
	bottom_bar.offset_top  = -52;  bottom_bar.offset_bottom = -16
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
	home_sb.set_border_width_all(2)
	home_sb.border_color = C_ACCENT_DIM
	home_sb.set_corner_radius_all(30)
	home_ring.add_theme_stylebox_override("panel", home_sb)
	home_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	home_wrap.add_child(home_ring)

	_add_accent_bar(bottom_bar, Vector2(60, 20), Vector2(160, 3))
	_add_accent_bar(bottom_bar, Vector2(60, 30), Vector2(90, 2))
	_add_accent_bar(bottom_bar, Vector2(-220, 20), Vector2(160, 3), true)
	_add_accent_bar(bottom_bar, Vector2(-150, 30), Vector2(90, 2), true)


# ─── Minimal HUD overlay (3D mode) ────────────────────────────────────────────

func _build_hud_overlay(parent: Control) -> void:
	# Clock + system status in top-right corner (subtler, since model has its own design)
	var row := HBoxContainer.new()
	row.anchor_left = 1.0;  row.anchor_right = 1.0
	row.anchor_top = 0.0;   row.anchor_bottom = 0.0
	row.offset_left  = -340; row.offset_right  = -20
	row.offset_top   = 18;   row.offset_bottom = 42
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)

	var status := Label.new()
	status.text = "SYS OK  ∕  LINK ▲"
	status.add_theme_font_size_override("font_size", 10)
	status.add_theme_color_override("font_color", Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.65))
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(status)
	_status_label = status

	_clock_label = Label.new()
	_clock_label.text = "00:00"
	_clock_label.add_theme_font_size_override("font_size", 12)
	_clock_label.add_theme_color_override("font_color", Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.9))
	_clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_clock_label)

	# Debug rect showing SCREEN_UV_RECT alignment
	if DEBUG_SCREEN_RECT:
		var dbg := Panel.new()
		dbg.anchor_left   = SCREEN_UV_RECT.position.x
		dbg.anchor_top    = SCREEN_UV_RECT.position.y
		dbg.anchor_right  = SCREEN_UV_RECT.position.x + SCREEN_UV_RECT.size.x
		dbg.anchor_bottom = SCREEN_UV_RECT.position.y + SCREEN_UV_RECT.size.y
		dbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var dbg_sb := StyleBoxFlat.new()
		dbg_sb.bg_color = Color(1, 0, 0, 0.18)
		dbg_sb.set_border_width_all(2)
		dbg_sb.border_color = Color(1, 0.3, 0.3, 0.9)
		dbg.add_theme_stylebox_override("panel", dbg_sb)
		parent.add_child(dbg)


# ─── Bezel overlay (procedural mode only, runs AFTER screen to stack on top) ──

func _build_bezel_overlay(_parent: Control) -> void:
	pass  # already fully built in _build_bezel_details above


# ═══════════════════════════════════════════════════════════════════════════════
# CONTENT AREA
# ═══════════════════════════════════════════════════════════════════════════════

func _build_content_area() -> void:
	_content_holder = Control.new()
	_content_holder.mouse_filter = Control.MOUSE_FILTER_PASS

	if _use_3d_model:
		# Position under the 3D texture rect (shows through transparent screen)
		_content_holder.anchor_left   = SCREEN_UV_RECT.position.x
		_content_holder.anchor_top    = SCREEN_UV_RECT.position.y
		_content_holder.anchor_right  = SCREEN_UV_RECT.position.x + SCREEN_UV_RECT.size.x
		_content_holder.anchor_bottom = SCREEN_UV_RECT.position.y + SCREEN_UV_RECT.size.y
		# Content holder is child of _tablet_chassis (z-order: behind _3d_texture_rect)
		# We insert before the texture rect so it renders below it.
		_tablet_chassis.add_child(_content_holder)
		_tablet_chassis.move_child(_content_holder, 1)  # after bg panel, before texture rect
	else:
		# Procedural mode: content fills the inset screen area
		_content_holder.anchor_left   = 0.0
		_content_holder.anchor_right  = 1.0
		_content_holder.anchor_top    = 0.0
		_content_holder.anchor_bottom = 1.0
		_content_holder.offset_left   = SCREEN_INSET.x + 18
		_content_holder.offset_top    = SCREEN_INSET.y + 16
		_content_holder.offset_right  = -(SCREEN_INSET.z + 18)
		_content_holder.offset_bottom = -(SCREEN_INSET.w + 16)
		_tablet_chassis.add_child(_content_holder)

	# Add screen reticle corners for 3D mode (same aesthetic but on top)
	if _use_3d_model:
		for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
			_add_screen_reticle(_content_holder, corner)


# ─── Detail helpers ───────────────────────────────────────────────────────────

func _add_screen_reticle(parent: Control, corner: Vector2) -> void:
	var sz := 14;  var thick := 2;  var margin := 0
	var h_bar := ColorRect.new();  var v_bar := ColorRect.new()
	h_bar.color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.8)
	v_bar.color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.8)
	for bar in [h_bar, v_bar]:
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.anchor_left = corner.x;   bar.anchor_right  = corner.x
		bar.anchor_top  = corner.y;   bar.anchor_bottom = corner.y
	var hx := margin if corner.x < 0.5 else -margin - sz
	var hy := margin if corner.y < 0.5 else -margin - thick
	var vx := margin if corner.x < 0.5 else -margin - thick
	var vy := margin if corner.y < 0.5 else -margin - sz
	h_bar.offset_left = hx;  h_bar.offset_right  = hx + sz
	h_bar.offset_top  = hy;  h_bar.offset_bottom = hy + thick
	v_bar.offset_left = vx;  v_bar.offset_right  = vx + thick
	v_bar.offset_top  = vy;  v_bar.offset_bottom = vy + sz
	parent.add_child(h_bar);  parent.add_child(v_bar)


func _add_accent_bar(parent: Control, offset: Vector2, dims: Vector2, right_aligned: bool = false) -> void:
	var r := ColorRect.new()
	r.color = C_ACCENT_MUT
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if right_aligned:
		r.anchor_left = 1.0;  r.anchor_right = 1.0
		r.offset_left = offset.x;  r.offset_right = offset.x + dims.x
	else:
		r.offset_left = offset.x;  r.offset_right = offset.x + dims.x
	r.offset_top = offset.y;  r.offset_bottom = offset.y + dims.y
	parent.add_child(r)
	_accent_lines.append(r)


func _add_side_notch(parent: Control, y: float, left: bool) -> void:
	var r := ColorRect.new()
	r.color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.55)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if left:
		r.offset_left = 18;   r.offset_right = 30
	else:
		r.anchor_left = 1.0;  r.anchor_right = 1.0
		r.offset_left = -30;  r.offset_right = -18
	r.offset_top = y;  r.offset_bottom = y + 2
	parent.add_child(r)
	_accent_lines.append(r)


# ═══════════════════════════════════════════════════════════════════════════════
# TAB RAIL (Subnautica-style right side)
# ═══════════════════════════════════════════════════════════════════════════════

func _build_tab_rail(parent: Control) -> void:
	var rail_wrap := Control.new()
	rail_wrap.anchor_left   = 1.0;  rail_wrap.anchor_right  = 1.0
	rail_wrap.anchor_top    = 0.0;  rail_wrap.anchor_bottom = 1.0
	rail_wrap.offset_left   = -(TAB_RAIL_W + 20)
	rail_wrap.offset_right  = -20
	rail_wrap.offset_top    = 120
	rail_wrap.offset_bottom = -120
	rail_wrap.mouse_filter = Control.MOUSE_FILTER_PASS
	parent.add_child(rail_wrap)

	var rail_bg := Panel.new()
	rail_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rail_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rail_sb := StyleBoxFlat.new()
	rail_sb.bg_color = C_CHASSIS_HI
	rail_sb.set_border_width_all(2)
	rail_sb.border_color = Color(0.28, 0.36, 0.44, 1.0)
	rail_sb.set_corner_radius_all(18)
	rail_sb.shadow_color = Color(0, 0, 0, 0.7)
	rail_sb.shadow_size = 14
	rail_bg.add_theme_stylebox_override("panel", rail_sb)
	rail_wrap.add_child(rail_bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left",   6)
	margin.add_theme_constant_override("margin_right",  6)
	margin.add_theme_constant_override("margin_top",   10)
	margin.add_theme_constant_override("margin_bottom",10)
	rail_wrap.add_child(margin)

	_tab_rail = VBoxContainer.new()
	_tab_rail.add_theme_constant_override("separation", 8)
	_tab_rail.alignment = BoxContainer.ALIGNMENT_BEGIN
	_tab_rail.mouse_filter = Control.MOUSE_FILTER_PASS
	margin.add_child(_tab_rail)


# ═══════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═══════════════════════════════════════════════════════════════════════════════

func set_content(ctrl: Control) -> void:
	if ctrl == null or _content_holder == null:
		return
	for c in _content_holder.get_children():
		if c is ColorRect:
			continue  # keep reticle markers
		_content_holder.remove_child(c)
	_content_holder.add_child(ctrl)
	ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func get_content_holder() -> Control:
	return _content_holder


func add_tab(tab_id: String, label: String, glyph: String, description: String = "") -> void:
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
	var x := Button.new()
	x.text = "×"
	x.add_theme_font_size_override("font_size", 22)
	x.custom_minimum_size = Vector2(36, 32)
	x.flat = true
	x.focus_mode = Control.FOCUS_NONE
	x.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	x.add_theme_color_override("font_color", Color(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8))
	x.add_theme_color_override("font_hover_color", Color(1, 0.55, 0.55, 1))
	x.anchor_left = 1.0;  x.anchor_right  = 1.0
	x.offset_left = -72;  x.offset_right  = -36
	x.offset_top  = 14;   x.offset_bottom = 46
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


# ═══════════════════════════════════════════════════════════════════════════════
# ANIMATION
# ═══════════════════════════════════════════════════════════════════════════════

func _play_open_animation() -> void:
	if _tablet_wrap == null:
		return
	if _anim_tween and _anim_tween.is_valid():
		_anim_tween.kill()

	_tablet_wrap.scale    = Vector2(0.72, 0.72)
	_tablet_wrap.rotation = 0.18
	_tablet_wrap.modulate = Color(1, 1, 1, 0)
	_dim_bg.color         = Color(0, 0, 0, 0)

	_anim_tween = create_tween().set_parallel(true)
	_anim_tween.tween_property(_dim_bg, "color", Color(0, 0, 0, 0.72), 0.28).set_trans(Tween.TRANS_SINE)
	_anim_tween.tween_property(_tablet_wrap, "scale", Vector2(1, 1), 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_anim_tween.tween_property(_tablet_wrap, "rotation", 0.0, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_anim_tween.tween_property(_tablet_wrap, "modulate", Color(1, 1, 1, 1), 0.32).set_trans(Tween.TRANS_SINE)


# ═══════════════════════════════════════════════════════════════════════════════
# PER-FRAME
# ═══════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if not visible:
		return
	_pulse_time += delta
	var pulse: float = 0.45 + 0.25 * (0.5 + 0.5 * sin(_pulse_time * 1.4))
	for r in _accent_lines:
		if is_instance_valid(r):
			r.color = Color(C_ACCENT_MUT.r, C_ACCENT_MUT.g, C_ACCENT_MUT.b, pulse * 0.9)
	if _clock_label:
		_clock_label.text = _format_clock()


func _format_clock() -> String:
	var t := Time.get_time_dict_from_system()
	return "%02d:%02d" % [int(t.hour), int(t.minute)]


# ═══════════════════════════════════════════════════════════════════════════════
# INTERNAL
# ═══════════════════════════════════════════════════════════════════════════════

func _on_tab_pressed(tab_id: String) -> void:
	if tab_id == _selected_tab_id:
		for t in _tabs_info:
			if String(t["id"]) == tab_id:
				(t["button"] as Button).button_pressed = true
		return
	set_active_tab(tab_id, true)


func _style_tab_button(btn: Button, active: bool) -> void:
	var ns := StyleBoxFlat.new()
	ns.bg_color = C_BEZEL if not active else Color(C_ACCENT.r * 0.30, C_ACCENT.g * 0.30, C_ACCENT.b * 0.40, 1.0)
	ns.set_border_width_all(2)
	ns.border_color = C_ACCENT if active else Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.25)
	ns.set_corner_radius_all(12)
	ns.content_margin_left   = 4;  ns.content_margin_right  = 4
	ns.content_margin_top    = 4;  ns.content_margin_bottom = 4
	if active:
		ns.shadow_color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.55)
		ns.shadow_size = 10
	var hs := ns.duplicate() as StyleBoxFlat
	hs.bg_color = Color(C_ACCENT.r * 0.22, C_ACCENT.g * 0.22, C_ACCENT.b * 0.30, 1.0)
	hs.border_color = C_ACCENT
	btn.add_theme_stylebox_override("normal",   ns)
	btn.add_theme_stylebox_override("hover",    hs)
	btn.add_theme_stylebox_override("pressed",  ns.duplicate())
	btn.add_theme_stylebox_override("focus",    ns)
	btn.add_theme_color_override("font_color",       C_ACCENT if active else C_TEXT_DIM)
	btn.add_theme_color_override("font_hover_color", C_TEXT_HI)
	btn.add_theme_color_override("font_pressed_color", C_ACCENT)
