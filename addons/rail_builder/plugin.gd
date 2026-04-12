@tool
extends EditorPlugin

const PANEL_TITLE := "Rail Builder"

var _panel: VBoxContainer
var _status_label: Label
var _segment_len_spin: SpinBox
var _yaw_spin: SpinBox
var _pitch_spin: SpinBox
var _auto_enforce_check: CheckBox
var _preview_enabled_check: CheckBox
var _preview_real_check: CheckBox
var _current_path: Path3D = null
var _curve_signature := ""


func _enter_tree() -> void:
	_build_panel()
	set_process(true)
	var selection := get_editor_interface().get_selection()
	if selection and not selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.connect(_on_selection_changed)
	_on_selection_changed()


func _exit_tree() -> void:
	set_process(false)
	var selection := get_editor_interface().get_selection()
	if selection and selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)
	if _panel != null:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()


func _handles(object: Object) -> bool:
	return _is_rail_path(object)


func _edit(object: Object) -> void:
	_set_current_path(object as Path3D)


func _make_visible(visible: bool) -> void:
	if _panel != null:
		_panel.visible = visible


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	if _current_path == null or _current_path.curve == null:
		return
	if not _auto_enforce_check.button_pressed:
		return
	var signature := _curve_points_signature(_current_path.curve)
	if signature != _curve_signature:
		_curve_signature = signature
		if _try_call_rail_method(_current_path, "_enforce_constraints", "action_enforce"):
			_try_call_rail_method(_current_path, "_apply_smoothing", "action_apply_smoothing")
		_update_status("Contraintes appliquées automatiquement.")


func _build_panel() -> void:
	_panel = VBoxContainer.new()
	_panel.name = PANEL_TITLE
	_panel.custom_minimum_size = Vector2(360, 0)

	var title := Label.new()
	title.text = "Rail Builder"
	title.add_theme_font_size_override("font_size", 18)
	_panel.add_child(title)

	var hint := Label.new()
	hint.text = "Sélectionne un nœud RailPath dans la scène."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(hint)

	_panel.add_child(_make_separator())

	var len_row := HBoxContainer.new()
	var len_label := Label.new()
	len_label.text = "Longueur segment"
	_segment_len_spin = SpinBox.new()
	_segment_len_spin.min_value = 1.0
	_segment_len_spin.max_value = 200.0
	_segment_len_spin.step = 0.5
	_segment_len_spin.value = 12.0
	_segment_len_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	len_row.add_child(len_label)
	len_row.add_child(_segment_len_spin)
	_panel.add_child(len_row)

	var yaw_row := HBoxContainer.new()
	var yaw_label := Label.new()
	yaw_label.text = "Virage Δ yaw (°)"
	_yaw_spin = SpinBox.new()
	_yaw_spin.min_value = -90.0
	_yaw_spin.max_value = 90.0
	_yaw_spin.step = 0.5
	_yaw_spin.value = 0.0
	_yaw_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	yaw_row.add_child(yaw_label)
	yaw_row.add_child(_yaw_spin)
	_panel.add_child(yaw_row)

	var pitch_row := HBoxContainer.new()
	var pitch_label := Label.new()
	pitch_label.text = "Pente segment (°)"
	_pitch_spin = SpinBox.new()
	_pitch_spin.min_value = -30.0
	_pitch_spin.max_value = 30.0
	_pitch_spin.step = 0.25
	_pitch_spin.value = 0.0
	_pitch_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pitch_row.add_child(pitch_label)
	pitch_row.add_child(_pitch_spin)
	_panel.add_child(pitch_row)

	var add_btn := Button.new()
	add_btn.text = "Ajouter un point en fin"
	add_btn.pressed.connect(_on_add_point_pressed)
	_panel.add_child(add_btn)

	_panel.add_child(_make_separator())

	_preview_enabled_check = CheckBox.new()
	_preview_enabled_check.text = "Preview activée"
	_preview_enabled_check.toggled.connect(_on_preview_enabled_toggled)
	_panel.add_child(_preview_enabled_check)

	_preview_real_check = CheckBox.new()
	_preview_real_check.text = "Preview vrai modèle"
	_preview_real_check.toggled.connect(_on_preview_real_toggled)
	_panel.add_child(_preview_real_check)

	var preview_refresh_btn := Button.new()
	preview_refresh_btn.text = "Rafraîchir preview"
	preview_refresh_btn.pressed.connect(_on_preview_refresh_pressed)
	_panel.add_child(preview_refresh_btn)

	_panel.add_child(_make_separator())

	var row_a := HBoxContainer.new()
	var validate_btn := Button.new()
	validate_btn.text = "Valider"
	validate_btn.pressed.connect(_on_validate_pressed)
	var enforce_btn := Button.new()
	enforce_btn.text = "Enforcer"
	enforce_btn.pressed.connect(_on_enforce_pressed)
	row_a.add_child(validate_btn)
	row_a.add_child(enforce_btn)
	_panel.add_child(row_a)

	var row_b := HBoxContainer.new()
	var snap_btn := Button.new()
	snap_btn.text = "Snap sol"
	snap_btn.pressed.connect(_on_snap_pressed)
	var straighten_btn := Button.new()
	straighten_btn.text = "Tangentes droites"
	straighten_btn.pressed.connect(_on_straighten_pressed)
	row_b.add_child(snap_btn)
	row_b.add_child(straighten_btn)
	_panel.add_child(row_b)

	_auto_enforce_check = CheckBox.new()
	_auto_enforce_check.text = "Auto-enforce à chaque modification"
	_auto_enforce_check.button_pressed = false
	_panel.add_child(_auto_enforce_check)

	_status_label = Label.new()
	_status_label.text = "Aucun RailPath sélectionné."
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(_status_label)

	add_control_to_bottom_panel(_panel, PANEL_TITLE)


func _make_separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return sep


func _on_selection_changed() -> void:
	var selection := get_editor_interface().get_selection()
	if selection == null:
		_set_current_path(null)
		return
	var nodes := selection.get_selected_nodes()
	for node in nodes:
		if _is_rail_path(node):
			_set_current_path(node as Path3D)
			return
	_set_current_path(null)


func _set_current_path(path: Path3D) -> void:
	_current_path = path
	if _panel != null:
		_panel.visible = _current_path != null
	if _current_path == null:
		_update_status("Aucun RailPath sélectionné.")
		_curve_signature = ""
		_sync_preview_controls()
		return
	if _current_path.curve == null:
		_current_path.curve = Curve3D.new()
		_current_path.curve.bake_interval = 0.5
	_curve_signature = _curve_points_signature(_current_path.curve)
	_sync_preview_controls()
	_update_status("RailPath actif: %s" % _current_path.name)


func _on_add_point_pressed() -> void:
	if _current_path == null:
		_update_status("Sélectionne un RailPath d'abord.")
		return
	if not _is_rail_path(_current_path):
		_update_status("Le nœud sélectionné n'est pas un RailPath valide.")
		return
	if _current_path.curve == null:
		_current_path.curve = Curve3D.new()
	var c := _current_path.curve
	var n := c.point_count
	if n == 0:
		c.add_point(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		n = 1
	var last := c.get_point_position(n - 1)
	var dir := Vector3.FORWARD
	if n > 1:
		dir = last - c.get_point_position(n - 2)
	if dir.length_squared() < 0.0001:
		dir = Vector3.FORWARD
	var h_dir := Vector3(dir.x, 0.0, dir.z)
	if h_dir.length_squared() < 0.0001:
		h_dir = Vector3.FORWARD
	h_dir = h_dir.normalized()

	var length := maxf(_segment_len_spin.value, 0.1)
	var yaw_rad := deg_to_rad(_yaw_spin.value)
	var pitch_rad := deg_to_rad(_pitch_spin.value)
	var h_rot := h_dir.rotated(Vector3.UP, yaw_rad)
	var new_local := last + Vector3(h_rot.x * length, tan(pitch_rad) * length, h_rot.z * length)
	c.add_point(new_local, Vector3.ZERO, Vector3.ZERO)

	_try_call_rail_method(_current_path, "_apply_smoothing", "action_apply_smoothing")
	if _auto_enforce_check.button_pressed:
		_try_call_rail_method(_current_path, "_enforce_constraints", "action_enforce")

	_curve_signature = _curve_points_signature(c)
	_update_status("Point ajouté (%d points au total)." % c.point_count)


func _on_validate_pressed() -> void:
	if _current_path == null:
		_update_status("Sélectionne un RailPath d'abord.")
		return
	if not _is_rail_path(_current_path):
		_update_status("Le nœud sélectionné n'est pas un RailPath valide.")
		return
	if _try_call_rail_method(_current_path, "_validate_constraints", "action_validate"):
		_update_status("Validation lancée (voir console Godot).")
	else:
		_update_status("Impossible de valider: instance placeholder en éditeur.")


func _on_enforce_pressed() -> void:
	if _current_path == null:
		_update_status("Sélectionne un RailPath d'abord.")
		return
	if not _is_rail_path(_current_path):
		_update_status("Le nœud sélectionné n'est pas un RailPath valide.")
		return
	if not _try_call_rail_method(_current_path, "_enforce_constraints", "action_enforce"):
		_update_status("Impossible d'appliquer les contraintes: instance placeholder en éditeur.")
		return
	_try_call_rail_method(_current_path, "_apply_smoothing", "action_apply_smoothing")
	_curve_signature = _curve_points_signature(_current_path.curve)
	_update_status("Contraintes appliquées.")


func _on_snap_pressed() -> void:
	if _current_path == null:
		_update_status("Sélectionne un RailPath d'abord.")
		return
	if not _is_rail_path(_current_path):
		_update_status("Le nœud sélectionné n'est pas un RailPath valide.")
		return
	if not _try_call_rail_method(_current_path, "_snap_points_to_ground", "action_snap_now"):
		if not _manual_snap_points_to_ground(_current_path):
			_update_status("Snap impossible: aucun terrain avec _sample_height trouvé.")
			return
	_curve_signature = _curve_points_signature(_current_path.curve)
	_update_status("Points snappés au terrain.")


func _on_straighten_pressed() -> void:
	if _current_path == null:
		_update_status("Sélectionne un RailPath d'abord.")
		return
	if not _is_rail_path(_current_path):
		_update_status("Le nœud sélectionné n'est pas un RailPath valide.")
		return
	if not _try_call_rail_method(_current_path, "_apply_smoothing", "action_apply_smoothing"):
		_update_status("Impossible d'appliquer le lissage: instance placeholder en éditeur.")
		return
	_update_status("Lissage appliqué.")


func _on_preview_enabled_toggled(enabled: bool) -> void:
	if _current_path == null:
		return
	if _has_property(_current_path, "preview_enabled"):
		_current_path.set("preview_enabled", enabled)
		_on_preview_refresh_pressed()


func _on_preview_real_toggled(enabled: bool) -> void:
	if _current_path == null:
		return
	if _has_property(_current_path, "preview_real_rails_enabled"):
		_current_path.set("preview_real_rails_enabled", enabled)
		_on_preview_refresh_pressed()


func _on_preview_refresh_pressed() -> void:
	if _current_path == null:
		return
	if _has_property(_current_path, "_preview_signature"):
		_current_path.set("_preview_signature", "")
	_update_status("Preview marquée pour mise à jour (auto au prochain process).")


func _sync_preview_controls() -> void:
	if _preview_enabled_check == null or _preview_real_check == null:
		return
	if _current_path == null:
		_preview_enabled_check.button_pressed = false
		_preview_real_check.button_pressed = false
		_preview_enabled_check.disabled = true
		_preview_real_check.disabled = true
		return
	_preview_enabled_check.disabled = not _has_property(_current_path, "preview_enabled")
	_preview_real_check.disabled = not _has_property(_current_path, "preview_real_rails_enabled")
	if not _preview_enabled_check.disabled:
		_preview_enabled_check.button_pressed = _get_bool_property(_current_path, "preview_enabled", true)
	if not _preview_real_check.disabled:
		_preview_real_check.button_pressed = _get_bool_property(_current_path, "preview_real_rails_enabled", true)


func _is_rail_path(object: Object) -> bool:
	if not (object is Path3D):
		return false
	if object.has_method("_enforce_constraints") and object.has_method("_validate_constraints") and object.has_method("_snap_points_to_ground"):
		return true
	if _has_property(object, "action_enforce") or _has_property(object, "action_validate") or _has_property(object, "action_snap_now"):
		return true
	if object is Node and (object as Node).name == "RailPath":
		return true
	var script := object.get_script()
	if script is Script:
		var script_path := (script as Script).resource_path
		if script_path.ends_with("/scenes/environment/rail_path.gd"):
			return true
	return false


func _curve_points_signature(c: Curve3D) -> String:
	if c == null:
		return ""
	var out := PackedStringArray()
	out.append(str(c.point_count))
	for i in range(c.point_count):
		var p := c.get_point_position(i)
		out.append("%.3f|%.3f|%.3f" % [p.x, p.y, p.z])
	return "::".join(out)


func _update_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _get_bool_property(object: Object, property_name: String, default_value: bool = false) -> bool:
	if object == null or not _has_property(object, property_name):
		return default_value
	return bool(object.get(property_name))


func _try_call_rail_method(path: Path3D, method_name: String, action_property: String = "") -> bool:
	if path == null:
		return false
	# Placeholder fallback: if an action export exists, toggle it.
	if action_property != "" and _has_property(path, action_property):
		path.set(action_property, true)
		return true
	# Direct method call path (for non-placeholder instances).
	if path.has_method(method_name):
		path.call(method_name)
		return true
	return false


func _has_property(object: Object, property_name: String) -> bool:
	for prop in object.get_property_list():
		if str(prop.get("name", "")) == property_name:
			return true
	return false


func _manual_snap_points_to_ground(path: Path3D) -> bool:
	if path == null or path.curve == null or path.curve.point_count == 0:
		return false
	var terrain := _find_terrain_node(path)
	if terrain == null or not terrain.has_method("_sample_height"):
		return false
	var ground_offset := 0.2
	if _has_property(path, "ground_offset"):
		ground_offset = float(path.get("ground_offset"))
	for i in range(path.curve.point_count):
		var p: Vector3 = path.curve.get_point_position(i)
		var world_p: Vector3 = path.to_global(p)
		var local_t: Vector3 = terrain.to_local(Vector3(world_p.x, 0.0, world_p.z))
		var h: float = terrain._sample_height(local_t.x, local_t.z) + ground_offset
		world_p.y = h
		path.curve.set_point_position(i, path.to_local(world_p))
	return true


func _find_terrain_node(path: Path3D) -> Node:
	var root := get_tree().edited_scene_root
	if root == null and path.get_tree() != null:
		root = path.get_tree().current_scene
	if root == null:
		return null
	return _search_terrain_node(root, path)


func _search_terrain_node(node: Node, excluded: Node) -> Node:
	if node == null:
		return null
	if node != excluded and node.has_method("_sample_height"):
		return node
	for child in node.get_children():
		var found := _search_terrain_node(child, excluded)
		if found != null:
			return found
	return null
