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
const TABLET_TEX_DIR    := "res://assets/models/ui/tablet/"

# Body UV rectangles where the screen is painted directly into the body's
# BaseColor texture. We discard those fragments so the painted teal screens
# don't show through after removing the separate screen mesh.
# UV space: (0,0) top-left, (1,1) bottom-right.
const BODY_SCREEN_UV_RECTS: Array = [
	Rect2(0.255, 0.035, 0.325, 0.485),  # front screen panel
	Rect2(0.595, 0.165, 0.340, 0.575),  # back screen panel
]

# ─── Screen alignment (UV, 0-1 relative to tablet size) ──────────────────────
# Adjust until 2D content aligns with the transparent screen in the 3D model.
# Enable DEBUG_SCREEN_RECT to see a highlight while tuning.
const SCREEN_UV_RECT    := Rect2(0.08, 0.10, 0.74, 0.80)
const DEBUG_SCREEN_RECT := false  # set true to show alignment helper

# Camera setup for the 3D model (tweak if model is wrong orientation/size)
const CAM_POSITION   := Vector3(0.0, 0.0, 0.0)   # auto-framed, used as fallback
const CAM_FOV        := 32.0
# Base rotation applied first. Additional 90° Z swap is applied automatically
# if the model's AABB comes out portrait (taller than wide).
const MODEL_ROTATION := Vector3(0.0, 0.0, 0.0)
const FRAME_FILL     := 1.0   # how much of the viewport the tablet should fill

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
const TABLET_SIZE   := Vector2(1480, 860)
const SCREEN_INSET  := Vector4(44, 64, 118, 64)  # for procedural fallback
const TAB_RAIL_W    := 80.0
const TAB_BTN_SIZE  := Vector2(56, 56)
# Inset of the menu content within the tablet frame (matches the tablet's
# screen area on the 3D model).
const SCREEN_UV_RECT_OVERLAY := Rect2(0.10, 0.12, 0.72, 0.76)
# Bounding rect of the tablet body (excludes the handle bar on the right edge).
# Used to clip the blue backdrop so it hugs the tablet silhouette.
const BODY_RECT := Rect2(0.035, 0.055, 0.755, 0.88)

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
	_dim_bg.color = Color(0, 0, 0, 0.32)
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
	# Blue backdrop clipped to the tablet body (excludes the handle bar on the
	# right). Semi-transparent so the world behind the tablet still reads.
	var backdrop := Panel.new()
	backdrop.anchor_left   = BODY_RECT.position.x
	backdrop.anchor_top    = BODY_RECT.position.y
	backdrop.anchor_right  = BODY_RECT.position.x + BODY_RECT.size.x
	backdrop.anchor_bottom = BODY_RECT.position.y + BODY_RECT.size.y
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var backdrop_sb := StyleBoxFlat.new()
	backdrop_sb.bg_color = Color(0.05, 0.22, 0.42, 0.55)
	backdrop_sb.set_corner_radius_all(38)
	backdrop.add_theme_stylebox_override("panel", backdrop_sb)
	parent.add_child(backdrop)

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
	key_light.light_energy = 2.6
	_3d_viewport.add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.transform = Transform3D(
		Basis().rotated(Vector3.RIGHT, -0.15).rotated(Vector3.UP, -2.1),
		Vector3.ZERO)
	fill_light.light_energy = 1.1
	_3d_viewport.add_child(fill_light)

	var rim_light := DirectionalLight3D.new()
	rim_light.transform = Transform3D(
		Basis().rotated(Vector3.RIGHT, 0.3).rotated(Vector3.UP, 3.14),
		Vector3.ZERO)
	rim_light.light_color = Color(1.0, 1.0, 1.0)
	rim_light.light_energy = 0.5
	_3d_viewport.add_child(rim_light)

	# No WorldEnvironment — it would override the SubViewport's transparent_bg
	# and force the tablet to render fully opaque. PBR ambient comes from the
	# directional lights alone (we boost them to compensate).
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
	# Tint the tablet body toward blue so the chassis visually matches the lit
	# screen backdrop. Chassis PBR detail still shows through; it just reads blue.
	_3d_texture_rect.modulate = Color(0.45, 0.70, 1.00, 1.0)
	parent.add_child(_3d_texture_rect)

	_3d_viewport.ready.connect(func():
		if _3d_texture_rect:
			_3d_texture_rect.texture = _3d_viewport.get_texture()
		if _3d_model and is_instance_valid(_3d_model):
			_apply_pbr_materials(_3d_model)
			call_deferred("_orient_and_frame")
	, CONNECT_ONE_SHOT)


# ─── Material pipeline ────────────────────────────────────────────────────────
# FBX import often fails to auto-link the PBR jpegs. We manually build one
# StandardMaterial3D per original material and override it on every surface.
#
# The model has two materials named "Ui" (the screen) and "tablet" (the body).
# We cache them and detect which surface is which by the original material
# name found on the MeshInstance3D.

var _mat_body: Material = null
var _mat_screen: ShaderMaterial = null

func _apply_pbr_materials(node: Node) -> void:
	if _mat_body == null:
		_mat_body = _build_pbr_material("tablet")
	if _mat_screen == null:
		_mat_screen = _build_screen_material()
	# Collect every surface across the tree and count its verts.
	var surfaces: Array = []
	_collect_surfaces(node, surfaces)
	for s in surfaces:
		s["verts"] = _surface_vertex_count(s["mesh"], s["surf"])
		s["name_screen"] = _surface_is_screen(s["mi"], s["mesh"], s["surf"])
	# Identify the screen surface.
	# Strategy: prefer name match. Else, if 2+ surfaces exist, pick the one
	# with the fewest verts (typical Sketchfab tablets have a quad screen
	# vs a detailed body chassis with hundreds of verts).
	var screen_idx := -1
	for i in range(surfaces.size()):
		if surfaces[i]["name_screen"]:
			screen_idx = i
			break
	if screen_idx < 0 and surfaces.size() >= 2:
		var min_v := INF
		for i in range(surfaces.size()):
			if surfaces[i]["verts"] < min_v:
				min_v = surfaces[i]["verts"]
				screen_idx = i
	# Collect screen MIs to free after the loop (don't mutate while iterating).
	var screens_to_free: Array = []
	for i in range(surfaces.size()):
		var s: Dictionary = surfaces[i]
		var mi := s["mi"] as MeshInstance3D
		var surf: int = s["surf"]
		if i == screen_idx:
			# Remove the screen mesh entirely. Belt-and-suspenders: hide it,
			# null out the mesh, and queue it for deletion so absolutely
			# nothing renders for that surface.
			mi.visible = false
			mi.mesh = null
			screens_to_free.append(mi)
		else:
			mi.set_surface_override_material(surf, _mat_body)
	for mi in screens_to_free:
		(mi as MeshInstance3D).queue_free()


func _surface_vertex_count(mesh_res: Mesh, surf: int) -> int:
	if mesh_res is ArrayMesh:
		var arr := (mesh_res as ArrayMesh).surface_get_arrays(surf)
		if arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] != null:
			return (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return 0


func _collect_surfaces(node: Node, out: Array) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh_res := mi.mesh
		if mesh_res:
			for surf in range(mesh_res.get_surface_count()):
				out.append({"mi": mi, "mesh": mesh_res, "surf": surf, "is_screen": false})
	for child in node.get_children():
		_collect_surfaces(child, out)


func _surface_is_screen(mi: MeshInstance3D, mesh_res: Mesh, surf: int) -> bool:
	# Collect every name-ish string we can find for this surface, keeping only
	# the filename/identifier part (strip folder paths) so that a "/ui/" folder
	# in the asset path doesn't accidentally flag body surfaces as screen.
	var haystack: Array[String] = []
	haystack.append(String(mi.name))
	haystack.append(String(mesh_res.resource_name))
	var mat := mi.get_active_material(surf)
	if mat:
		haystack.append(String(mat.resource_name))
		if mat is BaseMaterial3D:
			var bm := mat as BaseMaterial3D
			if bm.albedo_texture:
				haystack.append(_basename(bm.albedo_texture.resource_path))
	if mesh_res is ArrayMesh:
		var am := mesh_res as ArrayMesh
		var surf_mat := am.surface_get_material(surf)
		haystack.append(String(am.surface_get_name(surf)))
		if surf_mat:
			haystack.append(String(surf_mat.resource_name))
			if surf_mat is BaseMaterial3D:
				var sbm := surf_mat as BaseMaterial3D
				if sbm.albedo_texture:
					haystack.append(_basename(sbm.albedo_texture.resource_path))
	for s in haystack:
		var low := s.to_lower()
		if low.is_empty():
			continue
		# Sketchfab naming: "Tablet_Ui_*", or plain "ui"/"screen"/"display".
		if "_ui_" in low or low.begins_with("ui_") or low.ends_with("_ui") or low == "ui":
			return true
		if "screen" in low or "display" in low:
			return true
	return false


func _basename(path: String) -> String:
	var i := path.rfind("/")
	return path.substr(i + 1) if i >= 0 else path


func _build_pbr_material(stub: String) -> Material:
	# Custom shader: PBR sampling + UV-rect discard for painted screens.
	var base := _load_tex(stub, "BaseColor")
	var normal := _load_tex(stub, "Normal")
	var rough := _load_tex(stub, "Roughness")
	var metal := _load_tex(stub, "Metallic")

	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D tex_albedo : source_color, hint_default_white;
uniform sampler2D tex_normal : hint_normal;
uniform sampler2D tex_rough : hint_default_white;
uniform sampler2D tex_metal : hint_default_black;
uniform bool has_albedo = false;
uniform bool has_normal = false;
uniform bool has_rough = false;
uniform bool has_metal = false;
uniform vec4 albedo_fallback = vec4(0.18, 0.20, 0.23, 1.0);
uniform float metallic_max = 0.85;
uniform vec4 screen_rect_a = vec4(-1.0, -1.0, 0.0, 0.0); // x,y,w,h
uniform vec4 screen_rect_b = vec4(-1.0, -1.0, 0.0, 0.0);

bool in_rect(vec2 uv, vec4 r) {
	return r.z > 0.0
		&& uv.x >= r.x && uv.x <= r.x + r.z
		&& uv.y >= r.y && uv.y <= r.y + r.w;
}

void fragment() {
	if (in_rect(UV, screen_rect_a) || in_rect(UV, screen_rect_b)) {
		discard;
	}
	if (has_albedo) {
		ALBEDO = texture(tex_albedo, UV).rgb;
	} else {
		ALBEDO = albedo_fallback.rgb;
	}
	if (has_rough) {
		ROUGHNESS = texture(tex_rough, UV).r;
	} else {
		ROUGHNESS = 0.8;
	}
	if (has_metal) {
		METALLIC = texture(tex_metal, UV).r * metallic_max;
	} else {
		METALLIC = 0.0;
	}
	if (has_normal) {
		NORMAL_MAP = texture(tex_normal, UV).xyz;
		NORMAL_MAP_DEPTH = 0.6;
	}
}
"""
	sm.shader = sh
	if base:
		sm.set_shader_parameter("tex_albedo", base)
		sm.set_shader_parameter("has_albedo", true)
	if normal:
		sm.set_shader_parameter("tex_normal", normal)
		sm.set_shader_parameter("has_normal", true)
	if rough:
		sm.set_shader_parameter("tex_rough", rough)
		sm.set_shader_parameter("has_rough", true)
	if metal:
		sm.set_shader_parameter("tex_metal", metal)
		sm.set_shader_parameter("has_metal", true)
	# Pack the body screen rects (only on the body material, not screen mat).
	if stub == "tablet":
		var ra: Rect2 = BODY_SCREEN_UV_RECTS[0]
		var rb: Rect2 = BODY_SCREEN_UV_RECTS[1]
		sm.set_shader_parameter("screen_rect_a", Vector4(ra.position.x, ra.position.y, ra.size.x, ra.size.y))
		sm.set_shader_parameter("screen_rect_b", Vector4(rb.position.x, rb.position.y, rb.size.x, rb.size.y))
	return sm


func _build_pbr_shader_material(
		base: Texture2D, normal: Texture2D, rough: Texture2D,
		metal: Texture2D, opacity: Texture2D) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D tex_albedo : source_color, hint_default_white;
uniform sampler2D tex_normal : hint_normal;
uniform sampler2D tex_rough : hint_default_white;
uniform sampler2D tex_metal : hint_default_black;
uniform sampler2D tex_opacity : hint_default_white;
uniform bool has_normal = false;
uniform bool has_rough = false;
uniform bool has_metal = false;
uniform float metallic_max = 0.85;
uniform float opacity_threshold = 0.5;

void fragment() {
	vec4 col = texture(tex_albedo, UV);
	ALBEDO = col.rgb;
	float op = texture(tex_opacity, UV).r;
	if (op < opacity_threshold) {
		discard;
	}
	ALPHA = 1.0;
	if (has_rough) {
		ROUGHNESS = texture(tex_rough, UV).r;
	} else {
		ROUGHNESS = 0.7;
	}
	if (has_metal) {
		METALLIC = texture(tex_metal, UV).r * metallic_max;
	} else {
		METALLIC = 0.0;
	}
	if (has_normal) {
		NORMAL_MAP = texture(tex_normal, UV).xyz;
		NORMAL_MAP_DEPTH = 0.6;
	}
}
"""
	sm.shader = sh
	if base:
		sm.set_shader_parameter("tex_albedo", base)
	if opacity:
		sm.set_shader_parameter("tex_opacity", opacity)
	if normal:
		sm.set_shader_parameter("tex_normal", normal)
		sm.set_shader_parameter("has_normal", true)
	if rough:
		sm.set_shader_parameter("tex_rough", rough)
		sm.set_shader_parameter("has_rough", true)
	if metal:
		sm.set_shader_parameter("tex_metal", metal)
		sm.set_shader_parameter("has_metal", true)
	return sm


func _build_screen_material() -> ShaderMaterial:
	# A shader that discards every fragment — makes the screen surface render
	# literally nothing, so whatever 2D content sits behind the viewport's
	# transparent-bg texture at that pixel shows through with no blending math.
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled, depth_draw_disabled;\nvoid fragment() { discard; }\n"
	mat.shader = sh
	return mat


func _load_tex(stub: String, channel: String) -> Texture2D:
	var path := "%sTablet_%s_%s.jpeg" % [TABLET_TEX_DIR, stub, channel]
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


# ─── Orientation + framing ────────────────────────────────────────────────────

func _orient_and_frame() -> void:
	if _3d_model == null or _3d_camera == null or not is_instance_valid(_3d_model):
		return
	var aabb := _compute_model_aabb(_3d_model)
	# Step 1: make the screen face the camera (thin axis should be Z).
	# If the model imports standing (thin Y), tip it forward 90° on X.
	if aabb.size.y < aabb.size.x * 0.5 and aabb.size.y < aabb.size.z * 0.5:
		_3d_model.rotate_x(deg_to_rad(-90.0))
		aabb = _compute_model_aabb(_3d_model)
	# If thin X (standing sideways), lay it flat on Y.
	elif aabb.size.x < aabb.size.y * 0.5 and aabb.size.x < aabb.size.z * 0.5:
		_3d_model.rotate_y(deg_to_rad(90.0))
		aabb = _compute_model_aabb(_3d_model)
	# Step 2: auto-rotate to landscape if portrait (taller than wide).
	if aabb.size.y > aabb.size.x * 1.05:
		_3d_model.rotate_z(deg_to_rad(90.0))
		aabb = _compute_model_aabb(_3d_model)
	_frame_3d_camera(aabb)


func _frame_3d_camera(aabb: AABB = AABB()) -> void:
	if _3d_model == null or _3d_camera == null or not is_instance_valid(_3d_model):
		return
	if aabb.size == Vector3.ZERO:
		aabb = _compute_model_aabb(_3d_model)
	if aabb.size == Vector3.ZERO:
		_3d_camera.position = Vector3(0, 0, 3.5)
		_3d_camera.look_at(Vector3.ZERO, Vector3.UP)
		return
	# Center model at origin.
	_3d_model.position -= aabb.get_center()
	var size: Vector3 = aabb.size
	var vert_fov: float = deg_to_rad(CAM_FOV)
	var aspect: float = TABLET_SIZE.x / TABLET_SIZE.y
	var horz_fov: float = 2.0 * atan(tan(vert_fov * 0.5) * aspect)
	# Distance needed so each dimension fits the chosen fov.
	var dist_for_height: float = (size.y * 0.5) / tan(vert_fov * 0.5)
	var dist_for_width:  float = (size.x * 0.5) / tan(horz_fov * 0.5)
	var dist: float = maxf(dist_for_height, dist_for_width) / FRAME_FILL
	# Pull camera back slightly more than half-depth to avoid clipping into model.
	dist += size.z * 0.5
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
		var y: float = 120.0 + float(i) * 42.0
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
		# The tablet-wide blue backdrop is built in _build_chassis_3d; content
		# just anchors within the screen area so text stays on the display.
		_content_holder.anchor_left   = SCREEN_UV_RECT_OVERLAY.position.x
		_content_holder.anchor_top    = SCREEN_UV_RECT_OVERLAY.position.y
		_content_holder.anchor_right  = SCREEN_UV_RECT_OVERLAY.position.x + SCREEN_UV_RECT_OVERLAY.size.x
		_content_holder.anchor_bottom = SCREEN_UV_RECT_OVERLAY.position.y + SCREEN_UV_RECT_OVERLAY.size.y
		_tablet_chassis.add_child(_content_holder)  # on top of backdrop
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
