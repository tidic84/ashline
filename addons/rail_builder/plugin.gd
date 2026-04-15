@tool
extends EditorPlugin

const PANEL_TITLE := "Rail Builder"

# --- UI references ---
var _panel: VBoxContainer
var _scroll: ScrollContainer
var _inner: VBoxContainer
var _status_label: RichTextLabel
var _segment_len_spin: SpinBox
var _yaw_spin: SpinBox
var _pitch_spin: SpinBox
var _auto_enforce_check: CheckBox
var _preview_enabled_check: CheckBox
var _preview_real_check: CheckBox
var _current_path: Path3D = null
var _curve_signature := ""

# --- Pop-out window ---
var _popup_window: Window = null
var _is_popped_out := false
var _is_vertical := false

# --- Section fold states ---
var _section_bodies: Dictionary = {}  # String -> Control


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
	_close_popup_window()
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
		_update_status("[color=#8bc34a]Contraintes appliquees automatiquement.[/color]")


# ============================================================
#  PANEL CONSTRUCTION
# ============================================================

func _build_panel() -> void:
	_panel = VBoxContainer.new()
	_panel.name = PANEL_TITLE
	_panel.custom_minimum_size = Vector2(340, 0)

	# --- Top bar: title + window controls ---
	var top_bar := HBoxContainer.new()
	top_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var title := Label.new()
	title.text = "Rail Builder"
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(title)

	var vertical_btn := Button.new()
	vertical_btn.text = "Vertical"
	vertical_btn.tooltip_text = "Basculer entre disposition horizontale et verticale"
	vertical_btn.pressed.connect(_on_toggle_vertical)
	top_bar.add_child(vertical_btn)

	var popout_btn := Button.new()
	popout_btn.text = "Detacher"
	popout_btn.tooltip_text = "Ouvrir dans une fenetre flottante"
	popout_btn.pressed.connect(_on_popout_pressed)
	top_bar.add_child(popout_btn)

	_panel.add_child(top_bar)

	# --- Scrollable content ---
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(_scroll)

	_inner = VBoxContainer.new()
	_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_inner)

	# ---- SECTION: Construction ----
	var build_body := _add_section("Construction", "Ajouter et configurer des segments de rail")

	var len_row := _make_spin_row("Longueur (m)", 1.0, 200.0, 0.5, 12.0,
		"Longueur du prochain segment en metres")
	_segment_len_spin = len_row.get_child(1) as SpinBox
	build_body.add_child(len_row)

	var yaw_row := _make_spin_row("Virage (deg)", -90.0, 90.0, 0.5, 0.0,
		"Angle horizontal du virage. Negatif = gauche, positif = droite")
	_yaw_spin = yaw_row.get_child(1) as SpinBox
	build_body.add_child(yaw_row)

	var pitch_row := _make_spin_row("Pente (deg)", -30.0, 30.0, 0.25, 0.0,
		"Inclinaison verticale. Negatif = descente, positif = montee")
	_pitch_spin = pitch_row.get_child(1) as SpinBox
	build_body.add_child(pitch_row)

	var add_btn := Button.new()
	add_btn.text = "Ajouter un segment"
	add_btn.tooltip_text = "Ajoute un nouveau point a la fin du rail avec les parametres ci-dessus"
	add_btn.pressed.connect(_on_add_point_pressed)
	build_body.add_child(add_btn)

	var remove_last_btn := Button.new()
	remove_last_btn.text = "Supprimer le dernier point"
	remove_last_btn.tooltip_text = "Retire le dernier point de la courbe"
	remove_last_btn.pressed.connect(_on_remove_last_point_pressed)
	build_body.add_child(remove_last_btn)

	# ---- SECTION: Boucles & Connexions ----
	var loop_body := _add_section("Boucles & Connexions", "Creer des circuits fermes et connecter des rails")

	var close_loop_btn := Button.new()
	close_loop_btn.text = "Fermer la boucle"
	close_loop_btn.tooltip_text = "Connecte la fin du rail a son debut pour former un circuit ferme"
	close_loop_btn.pressed.connect(_on_close_loop_pressed)
	loop_body.add_child(close_loop_btn)

	var connect_start_btn := Button.new()
	connect_start_btn.text = "Connecter DEBUT -> autre rail"
	connect_start_btn.tooltip_text = "Connecte le debut de ce rail au rail le plus proche"
	connect_start_btn.pressed.connect(_on_connect_start_pressed)
	loop_body.add_child(connect_start_btn)

	var connect_end_btn := Button.new()
	connect_end_btn.text = "Connecter FIN -> autre rail"
	connect_end_btn.tooltip_text = "Connecte la fin de ce rail au rail le plus proche"
	connect_end_btn.pressed.connect(_on_connect_end_pressed)
	loop_body.add_child(connect_end_btn)

	var show_connections_btn := Button.new()
	show_connections_btn.text = "Afficher les connexions"
	show_connections_btn.tooltip_text = "Liste toutes les connexions de ce rail dans la console"
	show_connections_btn.pressed.connect(_on_show_connections_pressed)
	loop_body.add_child(show_connections_btn)

	var clear_connections_btn := Button.new()
	clear_connections_btn.text = "Supprimer toutes les connexions"
	clear_connections_btn.tooltip_text = "Retire toutes les connexions de ce rail"
	clear_connections_btn.pressed.connect(_on_clear_connections_pressed)
	loop_body.add_child(clear_connections_btn)

	# ---- SECTION: Aiguillages ----
	var switch_body := _add_section("Aiguillages", "Placer et gerer les aiguillages aux jonctions")

	var add_switch_start_btn := Button.new()
	add_switch_start_btn.text = "Aiguillage au DEBUT"
	add_switch_start_btn.tooltip_text = "Place un aiguillage au debut du rail"
	add_switch_start_btn.pressed.connect(_on_add_switch_start_pressed)
	switch_body.add_child(add_switch_start_btn)

	var add_switch_end_btn := Button.new()
	add_switch_end_btn.text = "Aiguillage a la FIN"
	add_switch_end_btn.tooltip_text = "Place un aiguillage a la fin du rail"
	add_switch_end_btn.pressed.connect(_on_add_switch_end_pressed)
	switch_body.add_child(add_switch_end_btn)

	# ---- SECTION: Contraintes & Lissage ----
	var constraint_body := _add_section("Contraintes & Lissage", "Valider, appliquer et lisser les contraintes du rail")

	var row_a := HBoxContainer.new()
	var validate_btn := Button.new()
	validate_btn.text = "Valider"
	validate_btn.tooltip_text = "Verifie que tous les segments respectent les contraintes (voir console)"
	validate_btn.pressed.connect(_on_validate_pressed)
	validate_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var enforce_btn := Button.new()
	enforce_btn.text = "Appliquer"
	enforce_btn.tooltip_text = "Force tous les segments a respecter les contraintes de virage et pente"
	enforce_btn.pressed.connect(_on_enforce_pressed)
	enforce_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_a.add_child(validate_btn)
	row_a.add_child(enforce_btn)
	constraint_body.add_child(row_a)

	var row_b := HBoxContainer.new()
	var snap_btn := Button.new()
	snap_btn.text = "Snap au sol"
	snap_btn.tooltip_text = "Colle tous les points du rail a la hauteur du terrain"
	snap_btn.pressed.connect(_on_snap_pressed)
	snap_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var straighten_btn := Button.new()
	straighten_btn.text = "Lisser"
	straighten_btn.tooltip_text = "Applique le lissage des tangentes selon le mode choisi dans l'inspecteur"
	straighten_btn.pressed.connect(_on_straighten_pressed)
	straighten_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_b.add_child(snap_btn)
	row_b.add_child(straighten_btn)
	constraint_body.add_child(row_b)

	_auto_enforce_check = CheckBox.new()
	_auto_enforce_check.text = "Auto-contraintes a chaque modification"
	_auto_enforce_check.tooltip_text = "Applique automatiquement les contraintes quand la courbe change"
	_auto_enforce_check.button_pressed = false
	constraint_body.add_child(_auto_enforce_check)

	# ---- SECTION: Preview ----
	var preview_body := _add_section("Preview", "Controles de l'apercu en temps reel dans l'editeur")

	_preview_enabled_check = CheckBox.new()
	_preview_enabled_check.text = "Apercu active"
	_preview_enabled_check.tooltip_text = "Active/desactive l'apercu des rails dans la vue 3D"
	_preview_enabled_check.toggled.connect(_on_preview_enabled_toggled)
	preview_body.add_child(_preview_enabled_check)

	_preview_real_check = CheckBox.new()
	_preview_real_check.text = "Modele realiste"
	_preview_real_check.tooltip_text = "Utilise le vrai modele 3D des rails pour l'apercu"
	_preview_real_check.toggled.connect(_on_preview_real_toggled)
	preview_body.add_child(_preview_real_check)

	var preview_refresh_btn := Button.new()
	preview_refresh_btn.text = "Rafraichir"
	preview_refresh_btn.tooltip_text = "Force la mise a jour de l'apercu"
	preview_refresh_btn.pressed.connect(_on_preview_refresh_pressed)
	preview_body.add_child(preview_refresh_btn)

	# ---- SECTION: Terrain ----
	var terrain_body := _add_section("Terrain", "Generation du terrain le long des rails")

	var gen_terrain_btn := Button.new()
	gen_terrain_btn.text = "Generer le terrain"
	gen_terrain_btn.tooltip_text = "Lance la generation du terrain et des rails (ne se fait plus automatiquement)"
	gen_terrain_btn.pressed.connect(_on_generate_terrain_pressed)
	terrain_body.add_child(gen_terrain_btn)

	var regen_rails_btn := Button.new()
	regen_rails_btn.text = "Regenerer les rails uniquement"
	regen_rails_btn.tooltip_text = "Regenere les meshes de rails sans toucher au terrain"
	regen_rails_btn.pressed.connect(_on_regenerate_rails_pressed)
	terrain_body.add_child(regen_rails_btn)

	# ---- STATUS ----
	_inner.add_child(_make_separator())
	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.scroll_active = false
	_status_label.custom_minimum_size = Vector2(0, 24)
	_status_label.text = "Aucun RailPath selectionne."
	_inner.add_child(_status_label)

	add_control_to_bottom_panel(_panel, PANEL_TITLE)


# ============================================================
#  UI HELPERS
# ============================================================

func _add_section(title: String, tooltip: String) -> VBoxContainer:
	var header := Button.new()
	header.text = "[ - ]  " + title
	header.tooltip_text = tooltip
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.flat = true
	header.add_theme_font_size_override("font_size", 13)
	_inner.add_child(header)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Indent content slightly
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(body)
	_inner.add_child(margin)

	_inner.add_child(_make_separator())

	_section_bodies[title] = body
	header.pressed.connect(_on_section_toggle.bind(title, header))
	return body


func _on_section_toggle(title: String, header: Button) -> void:
	var body: Control = _section_bodies.get(title)
	if body == null:
		return
	var parent_margin := body.get_parent() as Control
	if parent_margin == null:
		return
	parent_margin.visible = not parent_margin.visible
	if parent_margin.visible:
		header.text = "[ - ]  " + title
	else:
		header.text = "[ + ]  " + title


func _make_spin_row(label_text: String, min_val: float, max_val: float,
		step: float, default_val: float, tooltip: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = tooltip
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var spin := SpinBox.new()
	spin.min_value = min_val
	spin.max_value = max_val
	spin.step = step
	spin.value = default_val
	spin.tooltip_text = tooltip
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	row.add_child(spin)
	return row


func _make_separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return sep


# ============================================================
#  POP-OUT WINDOW
# ============================================================

func _on_popout_pressed() -> void:
	if _is_popped_out:
		_close_popup_window()
		return
	_is_popped_out = true

	_popup_window = Window.new()
	_popup_window.title = "Rail Builder"
	_popup_window.size = Vector2i(400, 700) if _is_vertical else Vector2i(600, 500)
	_popup_window.min_size = Vector2i(300, 300)
	_popup_window.close_requested.connect(_close_popup_window)
	_popup_window.transient = true
	_popup_window.always_on_top = true

	# Reparent the scroll container into the popup
	_panel.remove_child(_scroll)
	_popup_window.add_child(_scroll)

	get_editor_interface().get_base_control().add_child(_popup_window)
	_popup_window.popup_centered()
	_update_status("[color=#64b5f6]Fenetre detachee. Fermez-la pour revenir au panel.[/color]")


func _close_popup_window() -> void:
	if _popup_window == null:
		return
	_popup_window.remove_child(_scroll)
	_panel.add_child(_scroll)
	# Make sure scroll is after the top bar
	_panel.move_child(_scroll, 1)
	_popup_window.queue_free()
	_popup_window = null
	_is_popped_out = false
	_update_status("Panel reintegre.")


func _on_toggle_vertical() -> void:
	_is_vertical = not _is_vertical
	if _is_vertical:
		_panel.custom_minimum_size = Vector2(240, 0)
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_update_status("Mode vertical active.")
	else:
		_panel.custom_minimum_size = Vector2(340, 0)
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_update_status("Mode horizontal active.")
	if _popup_window != null:
		_popup_window.size = Vector2i(400, 700) if _is_vertical else Vector2i(600, 500)


# ============================================================
#  SELECTION
# ============================================================

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
		_update_status("Aucun RailPath selectionne.")
		_curve_signature = ""
		_sync_preview_controls()
		return
	if _current_path.curve == null:
		_current_path.curve = Curve3D.new()
		_current_path.curve.bake_interval = 0.5
	_curve_signature = _curve_points_signature(_current_path.curve)
	_sync_preview_controls()
	var pts := _current_path.curve.point_count
	_update_status("[b]%s[/b] - %d points" % [_current_path.name, pts])


# ============================================================
#  CONSTRUCTION ACTIONS
# ============================================================

func _on_add_point_pressed() -> void:
	if _current_path == null:
		_update_status("[color=#ff9800]Selectionne un RailPath d'abord.[/color]")
		return
	if not _is_rail_path(_current_path):
		_update_status("[color=#f44336]Le noeud selectionne n'est pas un RailPath valide.[/color]")
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
	_update_status("[color=#8bc34a]Point ajoute[/color] (%d points)." % c.point_count)


func _on_remove_last_point_pressed() -> void:
	if _current_path == null or _current_path.curve == null:
		_update_status("[color=#ff9800]Aucun rail selectionne.[/color]")
		return
	var c := _current_path.curve
	if c.point_count <= 1:
		_update_status("[color=#ff9800]Impossible: il faut au moins 1 point.[/color]")
		return
	c.remove_point(c.point_count - 1)
	_try_call_rail_method(_current_path, "_apply_smoothing", "action_apply_smoothing")
	_curve_signature = _curve_points_signature(c)
	_update_status("Dernier point supprime (%d points)." % c.point_count)


# ============================================================
#  LOOP & CONNECTION ACTIONS
# ============================================================

func _on_close_loop_pressed() -> void:
	if _current_path == null:
		_update_status("[color=#ff9800]Selectionne un RailPath d'abord.[/color]")
		return
	if _current_path.curve == null or _current_path.curve.point_count < 3:
		_update_status("[color=#f44336]Il faut au moins 3 points pour fermer une boucle.[/color]")
		return

	var c := _current_path.curve
	var start_pos := c.get_point_position(0)
	var end_pos := c.get_point_position(c.point_count - 1)
	var dist := start_pos.distance_to(end_pos)

	# If endpoints are already close, just connect them
	if dist < 2.0:
		# Snap last point to first
		c.set_point_position(c.point_count - 1, start_pos)
	else:
		# Add intermediate points to smoothly close the loop
		var segments_needed := int(ceil(dist / maxf(_segment_len_spin.value, 4.0)))
		segments_needed = clampi(segments_needed, 1, 10)
		for i in range(1, segments_needed + 1):
			var t := float(i) / float(segments_needed)
			var interp := end_pos.lerp(start_pos, t)
			if i == segments_needed:
				interp = start_pos
			c.add_point(interp, Vector3.ZERO, Vector3.ZERO)

	# Self-connect: end -> start
	var prop_end := "connections_at_end"
	var prop_start := "connections_at_start"
	var self_np: NodePath = NodePath(".")

	if _has_property(_current_path, prop_end):
		var existing: Array = _current_path.get(prop_end)
		var already := false
		for np in existing:
			if str(np) == ".":
				already = true
				break
		if not already:
			existing.append(self_np)
			_current_path.set(prop_end, existing)

	if _has_property(_current_path, prop_start):
		var existing: Array = _current_path.get(prop_start)
		var already := false
		for np in existing:
			if str(np) == ".":
				already = true
				break
		if not already:
			existing.append(self_np)
			_current_path.set(prop_start, existing)

	_try_call_rail_method(_current_path, "_apply_smoothing", "action_apply_smoothing")
	if _auto_enforce_check.button_pressed:
		_try_call_rail_method(_current_path, "_enforce_constraints", "action_enforce")
	_curve_signature = _curve_points_signature(c)
	_update_status("[color=#8bc34a]Boucle fermee![/color] %d points, fin -> debut connectes." % c.point_count)


func _on_connect_start_pressed() -> void:
	_connect_endpoint(0)


func _on_connect_end_pressed() -> void:
	_connect_endpoint(1)


func _connect_endpoint(endpoint: int) -> void:
	if _current_path == null:
		_update_status("[color=#ff9800]Selectionne un RailPath d'abord.[/color]")
		return
	var root := get_tree().edited_scene_root
	if root == null:
		_update_status("[color=#f44336]Pas de scene editee.[/color]")
		return
	var all_paths: Array[Node] = []
	_collect_rail_paths(root, all_paths)
	all_paths.erase(_current_path)
	if all_paths.size() == 0:
		_update_status("[color=#ff9800]Aucun autre RailPath dans la scene.[/color]")
		return

	# Find my endpoint position
	var my_pos: Vector3
	if _current_path.curve != null and _current_path.curve.point_count > 0:
		if endpoint == 0:
			my_pos = _current_path.to_global(_current_path.curve.get_point_position(0))
		else:
			my_pos = _current_path.to_global(_current_path.curve.get_point_position(_current_path.curve.point_count - 1))
	else:
		my_pos = _current_path.global_position

	# Find closest endpoint on any other RailPath
	var best_path: Path3D = null
	var best_end: int = 0
	var best_dist: float = INF
	for other in all_paths:
		var other_path := other as Path3D
		if other_path.curve == null or other_path.curve.point_count == 0:
			continue
		var p_start: Vector3 = other_path.to_global(other_path.curve.get_point_position(0))
		var p_end: Vector3 = other_path.to_global(other_path.curve.get_point_position(other_path.curve.point_count - 1))
		var d_start: float = my_pos.distance_to(p_start)
		var d_end: float = my_pos.distance_to(p_end)
		if d_start < best_dist:
			best_dist = d_start
			best_path = other_path
			best_end = 0
		if d_end < best_dist:
			best_dist = d_end
			best_path = other_path
			best_end = 1

	if best_path == null:
		_update_status("[color=#f44336]Aucun RailPath valide trouve.[/color]")
		return

	# Warn if distance is large
	if best_dist > 20.0:
		_update_status("[color=#ff9800]Attention: distance de %.1fm vers %s (loin).[/color]" % [best_dist, best_path.name])

	# Store connection
	var target_np: NodePath = _current_path.get_path_to(best_path)
	var prop_name: String = "connections_at_start" if endpoint == 0 else "connections_at_end"
	if _has_property(_current_path, prop_name):
		var existing: Array = _current_path.get(prop_name)
		for np in existing:
			if str(np) == str(target_np):
				_update_status("[color=#ff9800]Connexion deja existante vers %s.[/color]" % best_path.name)
				return
		existing.append(target_np)
		_current_path.set(prop_name, existing)

		# Also add reverse connection on the target
		var reverse_prop: String = "connections_at_start" if best_end == 0 else "connections_at_end"
		if _has_property(best_path, reverse_prop):
			var rev_np: NodePath = best_path.get_path_to(_current_path)
			var rev_existing: Array = best_path.get(reverse_prop)
			var has_reverse := false
			for np in rev_existing:
				if str(np) == str(rev_np):
					has_reverse = true
					break
			if not has_reverse:
				rev_existing.append(rev_np)
				best_path.set(reverse_prop, rev_existing)

		var my_label := "debut" if endpoint == 0 else "fin"
		var their_label := "debut" if best_end == 0 else "fin"
		_try_call_rail_method(_current_path, "_apply_smoothing", "action_apply_smoothing")
		_curve_signature = _curve_points_signature(_current_path.curve)
		_update_status("[color=#8bc34a]Connecte[/color] %s (%s) -> %s (%s) [%.1fm]" % [
			_current_path.name, my_label, best_path.name, their_label, best_dist])
	else:
		_update_status("[color=#f44336]Propriete '%s' introuvable sur le RailPath.[/color]" % prop_name)


func _on_show_connections_pressed() -> void:
	if _current_path == null:
		_update_status("[color=#ff9800]Aucun rail selectionne.[/color]")
		return
	var msg := "[b]Connexions de %s:[/b]\n" % _current_path.name
	var has_any := false

	if _has_property(_current_path, "connections_at_start"):
		var conns: Array = _current_path.get("connections_at_start")
		if conns.size() > 0:
			msg += "  DEBUT:\n"
			for np in conns:
				var node := _current_path.get_node_or_null(np)
				var node_name := node.name if node else str(np)
				msg += "    -> %s\n" % node_name
			has_any = true

	if _has_property(_current_path, "connections_at_end"):
		var conns: Array = _current_path.get("connections_at_end")
		if conns.size() > 0:
			msg += "  FIN:\n"
			for np in conns:
				var node := _current_path.get_node_or_null(np)
				var node_name := node.name if node else str(np)
				msg += "    -> %s\n" % node_name
			has_any = true

	if not has_any:
		msg += "  (aucune connexion)"

	print(msg)
	_update_status("Connexions affichees dans la console.")


func _on_clear_connections_pressed() -> void:
	if _current_path == null:
		_update_status("[color=#ff9800]Aucun rail selectionne.[/color]")
		return
	if _has_property(_current_path, "connections_at_start"):
		_current_path.set("connections_at_start", [])
	if _has_property(_current_path, "connections_at_end"):
		_current_path.set("connections_at_end", [])
	_update_status("Toutes les connexions supprimees.")


# ============================================================
#  SWITCH (AIGUILLAGE) ACTIONS
# ============================================================

func _on_add_switch_start_pressed() -> void:
	_add_switch_at_endpoint(0)


func _on_add_switch_end_pressed() -> void:
	_add_switch_at_endpoint(1)


func _add_switch_at_endpoint(endpoint: int) -> void:
	if _current_path == null:
		_update_status("[color=#ff9800]Selectionne un RailPath d'abord.[/color]")
		return
	var scene_root := get_tree().edited_scene_root
	if scene_root == null:
		_update_status("[color=#f44336]Pas de scene editee.[/color]")
		return
	var switch_scene := load("res://scenes/rail/rail_switch.tscn") as PackedScene
	if switch_scene == null:
		_update_status("[color=#f44336]Impossible de charger rail_switch.tscn.[/color]")
		return

	var pos: Vector3 = _current_path.global_position
	if _current_path.curve != null and _current_path.curve.point_count > 0:
		if endpoint == 0:
			pos = _current_path.to_global(_current_path.curve.get_point_position(0))
		else:
			pos = _current_path.to_global(_current_path.curve.get_point_position(_current_path.curve.point_count - 1))

	# Check if connections exist at this endpoint
	var prop_name := "connections_at_start" if endpoint == 0 else "connections_at_end"
	if _has_property(_current_path, prop_name):
		var conns: Array = _current_path.get(prop_name)
		if conns.size() == 0:
			_update_status("[color=#ff9800]Aucune connexion au %s. Connectez d'abord un autre rail.[/color]" % (
				"debut" if endpoint == 0 else "fin"))
			return
		if conns.size() < 2:
			_update_status("[color=#ff9800]Un aiguillage demande au moins 2 connexions au %s. Il n'y en a qu'une ici.[/color]" % (
				"debut" if endpoint == 0 else "fin"))
			return

	var existing_switch := _find_existing_switch_for_endpoint(scene_root, _current_path, endpoint)
	if existing_switch != null:
		existing_switch.global_position = pos
		get_editor_interface().get_selection().clear()
		get_editor_interface().get_selection().add_node(existing_switch)
		_update_status("[color=#64b5f6]Un aiguillage existe deja sur %s (%s). Je l'ai simplement reselectionne.[/color]" % [
			_current_path.name,
			"debut" if endpoint == 0 else "fin"
		])
		return

	var instance := switch_scene.instantiate() as Node3D
	scene_root.add_child(instance)
	instance.owner = scene_root
	instance.name = "RailSwitch_%s_%s" % [
		_current_path.name,
		"Start" if endpoint == 0 else "End"
	]
	instance.global_position = pos
	if _has_property(instance, "rail_path"):
		instance.set("rail_path", instance.get_path_to(_current_path))
	if _has_property(instance, "endpoint"):
		instance.set("endpoint", endpoint)

	var label := "debut" if endpoint == 0 else "fin"
	_update_status("[color=#8bc34a]Aiguillage place au %s de %s.[/color]" % [label, _current_path.name])


func _find_existing_switch_for_endpoint(root: Node, rail_path: Path3D, endpoint: int) -> Node3D:
	if root == null or rail_path == null:
		return null
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var node := stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node == root:
			continue
		if not (node is Node3D):
			continue
		if not _has_property(node, "rail_path") or not _has_property(node, "endpoint"):
			continue
		var node_endpoint := int(node.get("endpoint"))
		if node_endpoint != endpoint:
			continue
		var target_np: Variant = node.get("rail_path")
		if not (target_np is NodePath):
			continue
		var target: Node = node.get_node_or_null(target_np as NodePath)
		if target == rail_path:
			return node as Node3D
	return null


# ============================================================
#  CONSTRAINT ACTIONS
# ============================================================

func _on_validate_pressed() -> void:
	if _current_path == null:
		_update_status("[color=#ff9800]Selectionne un RailPath d'abord.[/color]")
		return
	if not _is_rail_path(_current_path):
		_update_status("[color=#f44336]Noeud invalide.[/color]")
		return
	if _try_call_rail_method(_current_path, "_validate_constraints", "action_validate"):
		_update_status("Validation lancee (voir console).")
	else:
		_update_status("[color=#f44336]Impossible de valider: instance placeholder.[/color]")


func _on_enforce_pressed() -> void:
	if _current_path == null:
		_update_status("[color=#ff9800]Selectionne un RailPath d'abord.[/color]")
		return
	if not _is_rail_path(_current_path):
		_update_status("[color=#f44336]Noeud invalide.[/color]")
		return
	if not _try_call_rail_method(_current_path, "_enforce_constraints", "action_enforce"):
		_update_status("[color=#f44336]Impossible d'appliquer les contraintes.[/color]")
		return
	_try_call_rail_method(_current_path, "_apply_smoothing", "action_apply_smoothing")
	_curve_signature = _curve_points_signature(_current_path.curve)
	_update_status("[color=#8bc34a]Contraintes appliquees.[/color]")


func _on_snap_pressed() -> void:
	if _current_path == null:
		_update_status("[color=#ff9800]Selectionne un RailPath d'abord.[/color]")
		return
	if not _is_rail_path(_current_path):
		_update_status("[color=#f44336]Noeud invalide.[/color]")
		return
	if not _try_call_rail_method(_current_path, "_snap_points_to_ground", "action_snap_now"):
		if not _manual_snap_points_to_ground(_current_path):
			_update_status("[color=#f44336]Snap impossible: aucun terrain avec _sample_height trouve.[/color]")
			return
	_curve_signature = _curve_points_signature(_current_path.curve)
	_update_status("[color=#8bc34a]Points snappes au terrain.[/color]")


func _on_straighten_pressed() -> void:
	if _current_path == null:
		_update_status("[color=#ff9800]Selectionne un RailPath d'abord.[/color]")
		return
	if not _is_rail_path(_current_path):
		_update_status("[color=#f44336]Noeud invalide.[/color]")
		return
	if not _try_call_rail_method(_current_path, "_apply_smoothing", "action_apply_smoothing"):
		_update_status("[color=#f44336]Impossible d'appliquer le lissage.[/color]")
		return
	_update_status("[color=#8bc34a]Lissage applique.[/color]")


# ============================================================
#  PREVIEW ACTIONS
# ============================================================

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
	_update_status("Preview rafraichie.")


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


# ============================================================
#  TERRAIN ACTIONS
# ============================================================

func _on_generate_terrain_pressed() -> void:
	var root := get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
	if root == null:
		_update_status("[color=#f44336]Pas de scene ouverte.[/color]")
		return
	# Prefer class-based lookup — more reliable than method name search.
	var terrain := _find_node_by_class_name(root, "TerrainGenerator")
	if terrain == null:
		terrain = _find_node_with_method(root, "generate_terrain")
	if terrain == null:
		_update_status("[color=#f44336]Aucun TerrainGenerator trouve dans la scene (racine: %s).[/color]" % root.name)
		return
	# Count rail paths visible from the scene tree so the user sees what the generator will find.
	var rail_paths: Array = get_tree().get_nodes_in_group("rail_path")
	# Fallback: recursive scan by script if group is empty (editor timing).
	if rail_paths.is_empty():
		var collected: Array[Node] = []
		_collect_rail_paths(root, collected)
		rail_paths = collected
		# Ensure they're in the group for the generator to find.
		for rp in collected:
			if not rp.is_in_group("rail_path"):
				rp.add_to_group("rail_path")
	if rail_paths.is_empty():
		_update_status("[color=#f44336]TerrainGenerator trouve (%s) mais AUCUN RailPath dans la scene.[/color]" % terrain.name)
		return
	if terrain.has_method("generate_terrain"):
		terrain.call("generate_terrain")
		_update_status("[color=#8bc34a]Terrain genere (%s, %d RailPath).[/color]" % [terrain.name, rail_paths.size()])
	elif terrain.has_method("_load_curve_from_rail_path"):
		terrain.call("_load_curve_from_rail_path")
		_update_status("[color=#8bc34a]Rails regeneres (%d RailPath).[/color]" % rail_paths.size())
	else:
		_update_status("[color=#f44336]TerrainGenerator trouve mais pas de methode de generation.[/color]")


func _on_regenerate_rails_pressed() -> void:
	var root := get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
	if root == null:
		_update_status("[color=#f44336]Pas de scene.[/color]")
		return
	var terrain := _find_node_with_method(root, "rebuild_rail_meshes")
	if terrain != null:
		terrain.call("rebuild_rail_meshes")
		_update_status("[color=#8bc34a]Meshes de rails regeneres.[/color]")
		return
	terrain = _find_node_by_class_name(root, "TerrainGenerator")
	if terrain != null and terrain.has_method("_build_rail_meshes"):
		terrain.call("_build_rail_meshes")
		_update_status("[color=#8bc34a]Rails regeneres.[/color]")
		return
	_update_status("[color=#f44336]Aucun TerrainGenerator trouve.[/color]")


# ============================================================
#  UTILITY
# ============================================================

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
	if action_property != "" and _has_property(path, action_property):
		path.set(action_property, true)
		return true
	if path.has_method(method_name):
		path.call(method_name)
		return true
	return false


func _has_property(object: Object, property_name: String) -> bool:
	for prop in object.get_property_list():
		if str(prop.get("name", "")) == property_name:
			return true
	return false


func _collect_rail_paths(node: Node, result: Array[Node]) -> void:
	if _is_rail_path(node):
		result.append(node)
	for child in node.get_children():
		_collect_rail_paths(child, result)


func _find_node_with_method(node: Node, method: String) -> Node:
	if node.has_method(method):
		return node
	for child in node.get_children():
		var found := _find_node_with_method(child, method)
		if found != null:
			return found
	return null


func _find_node_by_class_name(node: Node, class_name_str: String) -> Node:
	if node.get_class() == class_name_str:
		return node
	# Check script class
	var script := node.get_script()
	if script is Script:
		var sc := script as Script
		if sc.get_global_name() == class_name_str:
			return node
	for child in node.get_children():
		var found := _find_node_by_class_name(child, class_name_str)
		if found != null:
			return found
	return null


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
