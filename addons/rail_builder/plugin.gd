@tool
extends EditorPlugin

const PANEL_TITLE := "Rail Builder"
const RAIL_SWITCH_SCENE_PATH := "res://scenes/rail/rail_switch.tscn"
const RAIL_PATH_SCRIPT_PATH := "res://scenes/environment/rail_path.gd"

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

# --- Draw mode UI refs ---
var _draw_mode_check: CheckBox
var _draw_spacing_spin: SpinBox
var _draw_click_mode_check: CheckBox
var _draw_snap_radius_spin: SpinBox

# --- Draw mode state ---
var _draw_mode_active := false
var _click_mode := false  # false = drag continuous, true = click-by-click
var _draw_spacing := 8.0
var _snap_radius := 2.0
var _junction_merge_radius := 0.8
var _current_stroke: Path3D = null
var _last_stroke_world := Vector3.ZERO
var _stroke_point_count := 0
var _dragging_point_path: Path3D = null
var _dragging_point_index := -1
var _hover_screen := Vector2.ZERO
var _hover_world := Vector3.ZERO
var _hover_valid := false
var _violating_points: Dictionary = {}  # instance_id -> PackedInt32Array
var _junction_hotspots: Array = []  # [{rect: Rect2, path: Path3D, endpoint: int}]
var _last_camera: Camera3D = null

# --- Pop-out window ---
var _popup_window: Window = null
var _is_popped_out := false
var _is_vertical := false

# --- Section fold states ---
var _section_bodies: Dictionary = {}  # String -> Control


func _enter_tree() -> void:
	_build_panel()
	set_input_event_forwarding_always_enabled()
	set_force_draw_over_forwarding_enabled()
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
	# Panel reste toujours accessible (on peut activer mode dessin sans rail selectionne).
	if _panel != null:
		_panel.visible = true


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

	# ---- SECTION: Dessin (Y viewport) ----
	var draw_body := _add_section("Dessin (touche Y dans le viewport)",
			"Mode dessin pour tracer des rails a la souris en vue dessus", false)

	var draw_hint := Label.new()
	draw_hint.text = "1. Numpad 7 pour vue dessus\n2. Touche Y ou bouton ci-dessous pour activer\n3. Glisser ou cliquer pour tracer"
	draw_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	draw_body.add_child(draw_hint)

	_draw_mode_check = CheckBox.new()
	_draw_mode_check.text = "Activer le mode dessin (Y)"
	_draw_mode_check.tooltip_text = "Bascule le mode dessin. Une fois actif, les clics dans le viewport 3D tracent des rails."
	_draw_mode_check.toggled.connect(_on_draw_mode_toggled)
	draw_body.add_child(_draw_mode_check)

	_draw_click_mode_check = CheckBox.new()
	_draw_click_mode_check.text = "Mode clic-a-clic (sinon drag continu)"
	_draw_click_mode_check.tooltip_text = "Decoche: clique-glisse pour tracer. Coche: chaque clic pose un point, clic droit termine."
	_draw_click_mode_check.toggled.connect(func(on: bool): _click_mode = on)
	draw_body.add_child(_draw_click_mode_check)

	var spacing_row := _make_spin_row("Espacement (m)", 1.0, 50.0, 0.5, 8.0,
			"Distance minimum entre deux points en mode drag")
	_draw_spacing_spin = spacing_row.get_child(1) as SpinBox
	_draw_spacing_spin.value_changed.connect(func(v: float): _draw_spacing = v)
	draw_body.add_child(spacing_row)

	var snap_row := _make_spin_row("Rayon auto-connect (m)", 0.5, 10.0, 0.5, 2.0,
			"Distance de detection pour snap / connexion automatique aux rails voisins")
	_draw_snap_radius_spin = snap_row.get_child(1) as SpinBox
	_draw_snap_radius_spin.value_changed.connect(func(v: float): _snap_radius = v)
	draw_body.add_child(snap_row)

	var gen_terrain_top := Button.new()
	gen_terrain_top.text = "Generer le terrain autour des rails"
	gen_terrain_top.tooltip_text = "Sculpte le sol le long de chaque rail et reconstruit les meshes"
	gen_terrain_top.pressed.connect(_on_generate_terrain_pressed)
	draw_body.add_child(gen_terrain_top)

	# ---- SECTION: Construction (avance) ----
	var build_body := _add_section("Construction (avance)", "Ajouter et configurer des segments de rail", true)

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
	var loop_body := _add_section("Boucles & Connexions", "Creer des circuits fermes et connecter des rails", true)

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

	# ---- SECTION: Aiguillages (manuel) ----
	var switch_body := _add_section("Aiguillages (manuel)", "Placer et gerer les aiguillages aux jonctions", true)

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
	var constraint_body := _add_section("Contraintes & Lissage", "Valider, appliquer et lisser les contraintes du rail", true)

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
	var preview_body := _add_section("Preview", "Controles de l'apercu en temps reel dans l'editeur", true)

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
	var terrain_body := _add_section("Terrain", "Generation du terrain le long des rails", true)

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

func _add_section(title: String, tooltip: String, start_collapsed: bool = false) -> VBoxContainer:
	var header := Button.new()
	header.text = ("[ + ]  " if start_collapsed else "[ - ]  ") + title
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
	margin.visible = not start_collapsed
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
		_panel.visible = true
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
#  DRAW MODE (viewport top-down)
# ============================================================

func _on_draw_mode_toggled(on: bool) -> void:
	_draw_mode_active = on
	if not on:
		_cancel_stroke()
		_dragging_point_path = null
		_dragging_point_index = -1
	update_overlays()
	if on:
		_update_status("[color=#64b5f6]Mode dessin ACTIF.[/color] Numpad 7 = vue dessus. Clic = tracer.")
	else:
		_update_status("Mode dessin desactive.")


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	_last_camera = camera
	# Touche Y: toggle mode dessin (meme sans panneau ouvert).
	if event is InputEventKey:
		var ek := event as InputEventKey
		if ek.pressed and not ek.echo:
			if ek.keycode == KEY_Y and not ek.ctrl_pressed and not ek.alt_pressed and not ek.shift_pressed:
				if _draw_mode_check != null:
					_draw_mode_check.button_pressed = not _draw_mode_check.button_pressed
				else:
					_on_draw_mode_toggled(not _draw_mode_active)
				return AFTER_GUI_INPUT_STOP

	if not _draw_mode_active:
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouse:
		_hover_screen = (event as InputEventMouse).position
		var hw: Variant = _raycast_world(camera, _hover_screen)
		if hw != null:
			_hover_world = hw
			_hover_valid = true
		else:
			_hover_valid = false
		update_overlays()

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# 1. Junction [+] button?
				for hs in _junction_hotspots:
					var rect: Rect2 = hs.rect
					if rect.has_point(mb.position):
						_handle_junction_click(hs)
						return AFTER_GUI_INPUT_STOP
				# 2. Drag existing point?
				var hit := _pick_point_at_screen(camera, mb.position)
				if hit.size() > 0:
					_dragging_point_path = hit.path
					_dragging_point_index = int(hit.index)
					return AFTER_GUI_INPUT_STOP
				# 3. Start / continue stroke.
				if _click_mode:
					_click_mode_pose_point(camera, mb.position)
				else:
					_begin_stroke(camera, mb.position)
				return AFTER_GUI_INPUT_STOP
			else:
				if _dragging_point_path != null:
					_dragging_point_path = null
					_dragging_point_index = -1
					return AFTER_GUI_INPUT_STOP
				if not _click_mode and _current_stroke != null:
					_end_stroke()
					return AFTER_GUI_INPUT_STOP
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _click_mode and _current_stroke != null:
				_end_stroke()
				return AFTER_GUI_INPUT_STOP
			if _current_stroke != null:
				_cancel_stroke()
				return AFTER_GUI_INPUT_STOP

	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging_point_path != null and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			var wp: Variant = _raycast_world(camera, mm.position)
			if wp != null:
				_update_dragged_point(wp as Vector3)
			return AFTER_GUI_INPUT_STOP
		if not _click_mode and _current_stroke != null and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			_continue_stroke(camera, mm.position)
			return AFTER_GUI_INPUT_STOP

	if event is InputEventKey:
		var ek2 := event as InputEventKey
		if ek2.pressed and ek2.keycode == KEY_ESCAPE and _current_stroke != null:
			_cancel_stroke()
			return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if not _draw_mode_active:
		return
	var camera := _get_editor_camera()
	if camera == null:
		return

	var root := _get_scene_root()
	var all_paths: Array[Node] = []
	if root != null:
		_collect_rail_paths(root, all_paths)

	# Recompute violations.
	_violating_points.clear()
	for node in all_paths:
		var p := node as Path3D
		if p == null or p.curve == null:
			continue
		var arr := _compute_violations(p)
		if arr.size() > 0:
			_violating_points[p.get_instance_id()] = arr

	# Draw existing points (circles) + path outlines from top.
	for node in all_paths:
		var p := node as Path3D
		if p == null or p.curve == null:
			continue
		var n := p.curve.point_count
		var violations: PackedInt32Array = _violating_points.get(p.get_instance_id(), PackedInt32Array())
		# Segments between points.
		var prev_screen := Vector2.ZERO
		var prev_valid := false
		for i in range(n):
			var w: Vector3 = p.to_global(p.curve.get_point_position(i))
			if camera.is_position_behind(w):
				prev_valid = false
				continue
			var s: Vector2 = camera.unproject_position(w)
			if prev_valid:
				overlay.draw_line(prev_screen, s, Color(0.4, 0.7, 1.0, 0.7), 2.0)
			prev_screen = s
			prev_valid = true
			var col := Color.WHITE
			if i in violations:
				col = Color(1.0, 0.3, 0.3, 1.0)
			overlay.draw_circle(s, 6.0, col)

	# Junction [+] buttons.
	_junction_hotspots.clear()
	var junctions := _scan_junctions(all_paths)
	for j in junctions:
		var world_pos: Vector3 = j.pos
		if camera.is_position_behind(world_pos):
			continue
		var s := camera.unproject_position(world_pos)
		var rect := Rect2(s - Vector2(12, 12), Vector2(24, 24))
		overlay.draw_rect(rect, Color(0.2, 0.9, 0.3, 0.85))
		overlay.draw_rect(rect, Color.BLACK, false, 1.0)
		var font := overlay.get_theme_default_font()
		if font != null:
			overlay.draw_string(font, s + Vector2(-6, 6), "+",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.BLACK)
		# Store all cluster members so the click handler can cross-link them.
		var anchor = j.members[0]
		_junction_hotspots.append({
			"rect": rect,
			"path": anchor.path,
			"endpoint": int(anchor.endpoint),
			"members": j.members,
		})

	# Current stroke preview line (last point -> hover).
	if _current_stroke != null and _current_stroke.curve != null and _current_stroke.curve.point_count > 0 and _hover_valid:
		var last_w: Vector3 = _current_stroke.to_global(
				_current_stroke.curve.get_point_position(_current_stroke.curve.point_count - 1))
		if not camera.is_position_behind(last_w) and not camera.is_position_behind(_hover_world):
			var a := camera.unproject_position(last_w)
			var b := camera.unproject_position(_hover_world)
			overlay.draw_line(a, b, Color(1.0, 0.85, 0.2, 0.9), 2.0)
			overlay.draw_circle(b, 5.0, Color(1.0, 0.85, 0.2, 0.9))

	# HUD.
	var font2 := overlay.get_theme_default_font()
	if font2 != null:
		var mode_str := "CLIC" if _click_mode else "DRAG"
		var hud := "MODE DESSIN ACTIF  |  Y = quitter  |  Numpad 7 = vue dessus  |  Espacement: %.1fm  |  %s" % [_draw_spacing, mode_str]
		overlay.draw_rect(Rect2(Vector2(8, 8), Vector2(640, 26)), Color(0, 0, 0, 0.55))
		overlay.draw_string(font2, Vector2(14, 26), hud, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 0.6, 1))
		if _current_stroke != null:
			var hint := "Clic gauche = pose point  |  Clic droit ou Echap = terminer" if _click_mode else "Relachez pour terminer le trait"
			overlay.draw_string(font2, Vector2(14, 46), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)


# ------------- Stroke lifecycle -------------

func _begin_stroke(camera: Camera3D, screen_pos: Vector2) -> void:
	var wp: Variant = _raycast_world(camera, screen_pos)
	if wp == null:
		return
	var world: Vector3 = wp
	var path := _create_new_rail_path(world)
	if path == null:
		return
	_current_stroke = path
	_last_stroke_world = world
	_stroke_point_count = 1
	_update_status("Trait en cours... (%s)" % path.name)


func _continue_stroke(camera: Camera3D, screen_pos: Vector2) -> void:
	if _current_stroke == null or _current_stroke.curve == null:
		return
	var wp: Variant = _raycast_world(camera, screen_pos)
	if wp == null:
		return
	var world: Vector3 = wp
	if world.distance_to(_last_stroke_world) < _draw_spacing:
		return
	_append_stroke_point(world)


func _click_mode_pose_point(camera: Camera3D, screen_pos: Vector2) -> void:
	var wp: Variant = _raycast_world(camera, screen_pos)
	if wp == null:
		return
	var world: Vector3 = wp
	if _current_stroke == null:
		var path := _create_new_rail_path(world)
		if path == null:
			return
		_current_stroke = path
		_last_stroke_world = world
		_stroke_point_count = 1
		_update_status("Trait en cours (clic)... (%s)" % path.name)
	else:
		_append_stroke_point(world)


func _append_stroke_point(world: Vector3) -> void:
	if _current_stroke == null or _current_stroke.curve == null:
		return
	var c: Curve3D = _current_stroke.curve
	c.add_point(_current_stroke.to_local(world), Vector3.ZERO, Vector3.ZERO)
	_last_stroke_world = world
	_stroke_point_count = c.point_count
	_try_call_rail_method(_current_stroke, "_apply_smoothing", "action_apply_smoothing")
	_update_status("Points: %d" % c.point_count)


func _end_stroke() -> void:
	if _current_stroke == null:
		return
	var path := _current_stroke
	_current_stroke = null
	if path.curve == null or path.curve.point_count < 2:
		# Unusable: remove.
		if path.is_inside_tree():
			path.get_parent().remove_child(path)
		path.queue_free()
		_update_status("[color=#ff9800]Trait annule (trop court).[/color]")
		return
	_try_call_rail_method(path, "_apply_smoothing", "action_apply_smoothing")
	_auto_connect_stroke_endpoints(path)
	_update_status("[color=#8bc34a]Rail cree: %s (%d points).[/color]" % [path.name, path.curve.point_count])
	var sel := get_editor_interface().get_selection()
	if sel != null:
		sel.clear()
		sel.add_node(path)


func _cancel_stroke() -> void:
	if _current_stroke == null:
		return
	var path := _current_stroke
	_current_stroke = null
	if path.is_inside_tree():
		path.get_parent().remove_child(path)
	path.queue_free()
	_update_status("Trait annule.")


# ------------- Point drag -------------

func _pick_point_at_screen(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	var root := _get_scene_root()
	if root == null:
		return {}
	var all_paths: Array[Node] = []
	_collect_rail_paths(root, all_paths)
	var best_dist := 10.0  # pixels
	var best_path: Path3D = null
	var best_idx := -1
	for node in all_paths:
		var p := node as Path3D
		if p == null or p.curve == null:
			continue
		for i in range(p.curve.point_count):
			var w: Vector3 = p.to_global(p.curve.get_point_position(i))
			if camera.is_position_behind(w):
				continue
			var s := camera.unproject_position(w)
			var d := s.distance_to(screen_pos)
			if d < best_dist:
				best_dist = d
				best_path = p
				best_idx = i
	if best_path == null:
		return {}
	return {"path": best_path, "index": best_idx}


func _update_dragged_point(world: Vector3) -> void:
	var path := _dragging_point_path
	if path == null or path.curve == null:
		return
	var idx := _dragging_point_index
	if idx < 0 or idx >= path.curve.point_count:
		return
	var target := world
	# Snap Y to terrain + ground_offset when constraints would allow.
	var tentative_local := path.to_local(target)
	path.curve.set_point_position(idx, tentative_local)
	_try_call_rail_method(path, "_apply_smoothing", "action_apply_smoothing")


# ------------- Rail creation -------------

func _create_new_rail_path(world_origin: Vector3) -> Path3D:
	var scene_root := _get_scene_root()
	if scene_root == null:
		_update_status("[color=#f44336]Pas de scene editee.[/color]")
		return null
	var path := Path3D.new()
	var script := load(RAIL_PATH_SCRIPT_PATH)
	if script != null:
		path.set_script(script)
	path.name = _pick_unique_rail_name(scene_root)
	# Curve is built in WORLD space because path has no offset yet (pos = 0,0,0).
	var curve := Curve3D.new()
	curve.bake_interval = 0.5
	curve.add_point(world_origin, Vector3.ZERO, Vector3.ZERO)
	path.curve = curve
	scene_root.add_child(path)
	path.owner = scene_root
	path.add_to_group("rail_path")
	return path


func _pick_unique_rail_name(scene_root: Node) -> String:
	var i := 1
	while true:
		var n := "RailPath" if i == 1 else "RailPath%d" % i
		if scene_root.get_node_or_null(n) == null:
			return n
		i += 1
	return "RailPath"


# ------------- Auto-connect on stroke end -------------

func _auto_connect_stroke_endpoints(path: Path3D) -> void:
	var root := _get_scene_root()
	if root == null or path.curve == null:
		return
	var others: Array[Node] = []
	_collect_rail_paths(root, others)
	others.erase(path)
	if others.is_empty():
		return
	_try_snap_and_link(path, 0, others)
	_try_snap_and_link(path, 1, others)


func _try_snap_and_link(path: Path3D, endpoint: int, others: Array[Node]) -> void:
	var idx := 0 if endpoint == 0 else path.curve.point_count - 1
	var my_world: Vector3 = path.to_global(path.curve.get_point_position(idx))
	var best_dist := _snap_radius
	var best_path: Path3D = null
	var best_end := 0
	var best_target := my_world
	for o in others:
		var op := o as Path3D
		if op == null or op.curve == null or op.curve.point_count == 0:
			continue
		var s: Vector3 = op.to_global(op.curve.get_point_position(0))
		var e: Vector3 = op.to_global(op.curve.get_point_position(op.curve.point_count - 1))
		var ds := my_world.distance_to(s)
		if ds < best_dist:
			best_dist = ds
			best_path = op
			best_end = 0
			best_target = s
		var de := my_world.distance_to(e)
		if de < best_dist:
			best_dist = de
			best_path = op
			best_end = 1
			best_target = e
	if best_path == null:
		return
	# Snap own endpoint to the target.
	path.curve.set_point_position(idx, path.to_local(best_target))
	# Link both sides.
	_link_endpoints(path, endpoint, best_path, best_end)


func _link_endpoints(a: Path3D, ea: int, b: Path3D, eb: int) -> void:
	var prop_a := "connections_at_start" if ea == 0 else "connections_at_end"
	var prop_b := "connections_at_start" if eb == 0 else "connections_at_end"
	if _has_property(a, prop_a):
		var list_a: Array = a.get(prop_a)
		var np_b: NodePath = a.get_path_to(b)
		var has_a := false
		for np in list_a:
			if str(np) == str(np_b):
				has_a = true
				break
		if not has_a:
			list_a.append(np_b)
			a.set(prop_a, list_a)
	if _has_property(b, prop_b):
		var list_b: Array = b.get(prop_b)
		var np_a: NodePath = b.get_path_to(a)
		var has_b := false
		for np in list_b:
			if str(np) == str(np_a):
				has_b = true
				break
		if not has_b:
			list_b.append(np_a)
			b.set(prop_b, list_b)


# ------------- Junction scan -------------

func _scan_junctions(paths: Array[Node]) -> Array:
	# Collect all endpoints (world pos, path, endpoint).
	var endpoints: Array = []
	for node in paths:
		var p := node as Path3D
		if p == null or p.curve == null or p.curve.point_count < 1:
			continue
		endpoints.append({
			"pos": p.to_global(p.curve.get_point_position(0)),
			"path": p,
			"endpoint": 0,
		})
		if p.curve.point_count >= 2:
			endpoints.append({
				"pos": p.to_global(p.curve.get_point_position(p.curve.point_count - 1)),
				"path": p,
				"endpoint": 1,
			})
	# Cluster by proximity.
	var clusters: Array = []
	var used := PackedInt32Array()
	used.resize(endpoints.size())
	for i in range(endpoints.size()):
		if used[i] == 1:
			continue
		var group: Array = [endpoints[i]]
		used[i] = 1
		for j in range(i + 1, endpoints.size()):
			if used[j] == 1:
				continue
			var d: float = (endpoints[i].pos as Vector3).distance_to(endpoints[j].pos as Vector3)
			if d <= _junction_merge_radius:
				group.append(endpoints[j])
				used[j] = 1
		if group.size() >= 3:
			var sum := Vector3.ZERO
			for g in group:
				sum += g.pos
			var avg: Vector3 = sum / float(group.size())
			if _junction_already_has_switch(group):
				continue
			clusters.append({"pos": avg, "members": group})
	return clusters


func _junction_already_has_switch(group: Array) -> bool:
	var root := _get_scene_root()
	if root == null:
		return false
	for g in group:
		var p: Path3D = g.path
		var ep: int = int(g.endpoint)
		if _find_existing_switch_for_endpoint(root, p, ep) != null:
			return true
	return false


func _handle_junction_click(hotspot: Dictionary) -> void:
	var members: Array = hotspot.get("members", [])
	if members.size() < 2:
		_update_status("[color=#f44336]Jonction invalide.[/color]")
		return
	# 1. Cross-link every member of the cluster so each anchor endpoint has
	#    connections to all the others (required by _add_switch_at_endpoint,
	#    which demands >=2 connections on the target endpoint).
	for i in range(members.size()):
		for k in range(members.size()):
			if i == k:
				continue
			var a: Path3D = members[i].path
			var ea: int = int(members[i].endpoint)
			var b: Path3D = members[k].path
			var eb: int = int(members[k].endpoint)
			if a == b and ea == eb:
				continue
			_link_endpoints(a, ea, b, eb)
	# 2. Pick an anchor that now has >=2 connections.
	var anchor_path: Path3D = members[0].path
	var anchor_end: int = int(members[0].endpoint)
	for m in members:
		var p: Path3D = m.path
		var ep: int = int(m.endpoint)
		var prop := "connections_at_start" if ep == 0 else "connections_at_end"
		if _has_property(p, prop):
			var list: Array = p.get(prop)
			if list.size() >= 2:
				anchor_path = p
				anchor_end = ep
				break
	_current_path = anchor_path
	_add_switch_at_endpoint(anchor_end)


# ------------- Raycast / camera helpers -------------

func _raycast_world(camera: Camera3D, screen_pos: Vector2) -> Variant:
	if camera == null:
		return null
	var origin := camera.project_ray_origin(screen_pos)
	var normal := camera.project_ray_normal(screen_pos)
	# Prefer terrain height lookup.
	var root := _get_scene_root()
	if root != null:
		var terrain := _find_terrain_with_sample(root)
		if terrain != null:
			# Intersect ray with Y=0 plane to find (x,z), then sample height.
			var hit_xz := _ray_plane_intersect(origin, normal, 0.0)
			if hit_xz != null:
				var p: Vector3 = hit_xz
				var local_t: Vector3 = (terrain as Node3D).to_local(Vector3(p.x, 0.0, p.z))
				var h := float(terrain.call("_sample_height", local_t.x, local_t.z))
				return Vector3(p.x, h + 0.2, p.z)
	# Fallback: plane Y=0.
	return _ray_plane_intersect(origin, normal, 0.0)


func _ray_plane_intersect(origin: Vector3, normal: Vector3, plane_y: float) -> Variant:
	if absf(normal.y) < 0.0001:
		return null
	var t := (plane_y - origin.y) / normal.y
	if t < 0.0:
		return null
	return origin + normal * t


func _get_editor_camera() -> Camera3D:
	if _last_camera != null and is_instance_valid(_last_camera):
		return _last_camera
	var ei := get_editor_interface()
	if ei == null:
		return null
	if ei.has_method("get_editor_viewport_3d"):
		var vp = ei.call("get_editor_viewport_3d", 0)
		if vp != null and vp.has_method("get_camera_3d"):
			return vp.call("get_camera_3d") as Camera3D
	return null


func _get_scene_root() -> Node:
	return get_tree().edited_scene_root


func _find_terrain_with_sample(root: Node) -> Node:
	if root == null:
		return null
	if root.has_method("_sample_height"):
		return root
	for c in root.get_children():
		var f := _find_terrain_with_sample(c)
		if f != null:
			return f
	return null


# ------------- Violations -------------

func _compute_violations(path: Path3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	if path.curve == null or path.curve.point_count < 2:
		return out
	var max_yaw: float = 12.0
	var max_abs_pitch: float = 15.0
	var max_pitch_delta: float = 5.0
	var min_seg: float = 4.0
	if _has_property(path, "max_yaw_deg"):
		max_yaw = float(path.get("max_yaw_deg"))
	if _has_property(path, "max_abs_pitch_deg"):
		max_abs_pitch = float(path.get("max_abs_pitch_deg"))
	if _has_property(path, "max_pitch_delta_deg"):
		max_pitch_delta = float(path.get("max_pitch_delta_deg"))
	if _has_property(path, "min_segment_length"):
		min_seg = float(path.get("min_segment_length"))
	var prev_fwd := Vector3.ZERO
	for i in range(path.curve.point_count - 1):
		var a: Vector3 = path.curve.get_point_position(i)
		var b: Vector3 = path.curve.get_point_position(i + 1)
		var seg: Vector3 = b - a
		var seg_len := seg.length()
		var flag := false
		if seg_len < min_seg:
			flag = true
		var h := Vector2(seg.x, seg.z).length()
		var pitch_deg := 0.0 if h < 0.0001 else rad_to_deg(atan2(seg.y, h))
		if absf(pitch_deg) > max_abs_pitch:
			flag = true
		if prev_fwd.length_squared() > 0.0001:
			var ha := Vector3(prev_fwd.x, 0.0, prev_fwd.z)
			var hb := Vector3(seg.x, 0.0, seg.z)
			if ha.length_squared() > 0.0001 and hb.length_squared() > 0.0001:
				var yaw := rad_to_deg(ha.normalized().angle_to(hb.normalized()))
				if yaw > max_yaw:
					flag = true
			var prev_h := Vector2(prev_fwd.x, prev_fwd.z).length()
			var prev_pitch := 0.0 if prev_h < 0.0001 else rad_to_deg(atan2(prev_fwd.y, prev_h))
			if absf(pitch_deg - prev_pitch) > max_pitch_delta:
				flag = true
		if flag:
			if not (i + 1) in out:
				out.append(i + 1)
		prev_fwd = seg
	return out


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
