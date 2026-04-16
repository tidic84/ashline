extends PanelContainer
class_name InventorySlotUI

signal slot_pressed(slot_index: int, button_index: int)
signal slot_dropped(source_index: int, target_index: int)
signal slot_hovered(slot_index: int, item_id: String)
signal slot_unhovered(slot_index: int)

var slot_index: int = -1
var _has_item: bool = false
var _item_id: String = ""
var _content: Control
var _icon: TextureRect
var _amount_label: Label
var _key_label: Label

func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if get_child_count() == 0:
		_build_ui()

func setup(index: int, key_text: String = "") -> void:
	slot_index = index
	if _icon == null:
		_build_ui()
	_key_label.text = key_text

func set_slot_visual(icon: Texture2D, amount: int, selected: bool, has_item: bool, key_text: String = "", item_id: String = "") -> void:
	if _icon == null:
		_build_ui()
	_has_item = has_item
	_item_id = item_id if has_item else ""
	_key_label.text = key_text
	_icon.texture = icon
	_icon.modulate = Color(1, 1, 1, 1.0 if has_item else 0.0)
	_amount_label.text = str(amount) if amount > 1 else ""
	add_theme_stylebox_override("panel", _slot_style(selected))

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		slot_pressed.emit(slot_index, event.button_index)

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		if _has_item and not _item_id.is_empty():
			slot_hovered.emit(slot_index, _item_id)
	elif what == NOTIFICATION_MOUSE_EXIT:
		slot_unhovered.emit(slot_index)

func _get_drag_data(_at_position: Vector2) -> Variant:
	if not _has_item or _icon == null or _icon.texture == null:
		return null
	set_drag_preview(_make_icon_preview(_icon.texture, Vector2(48, 48), Vector2(40, 40), Color(1, 1, 1, 0.85)))
	return {"source_index": slot_index}

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not (data is Dictionary):
		return false
	return data.has("source_index") and int(data["source_index"]) != slot_index

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if data is Dictionary and data.has("source_index"):
		slot_dropped.emit(int(data["source_index"]), slot_index)

func _build_ui() -> void:
	custom_minimum_size = Vector2(48, 48)
	add_theme_stylebox_override("panel", _slot_style(false))
	clip_contents = true

	_content = Control.new()
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.clip_contents = true
	add_child(_content)

	var icon_margin := MarginContainer.new()
	icon_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon_margin.add_theme_constant_override("margin_left", 4)
	icon_margin.add_theme_constant_override("margin_top", 4)
	icon_margin.add_theme_constant_override("margin_right", 4)
	icon_margin.add_theme_constant_override("margin_bottom", 4)
	icon_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(icon_margin)

	var icon_center := CenterContainer.new()
	icon_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_margin.add_child(icon_center)

	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(36, 36)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_center.add_child(_icon)

	# Key label — top-left, tiny
	_key_label = Label.new()
	_key_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_key_label.offset_right = 16
	_key_label.offset_bottom = 14
	_key_label.add_theme_font_size_override("font_size", 9)
	_key_label.add_theme_color_override("font_color", Color(0.70, 0.70, 0.70, 1.0))
	_key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_key_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_key_label)

	# Amount label — bottom-right, Minecraft style
	_amount_label = Label.new()
	_amount_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_amount_label.offset_left = -26
	_amount_label.offset_top = -14
	_amount_label.add_theme_font_size_override("font_size", 9)
	_amount_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	_amount_label.add_theme_color_override("font_shadow_color", Color(0.1, 0.1, 0.1, 1.0))
	_amount_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_amount_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_amount_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_amount_label)

func _make_icon_preview(texture: Texture2D, panel_size: Vector2, icon_size: Vector2, modulate_color: Color = Color.WHITE) -> Control:
	var wrapper := Control.new()
	wrapper.custom_minimum_size = panel_size
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.add_child(center)

	var preview := TextureRect.new()
	preview.custom_minimum_size = icon_size
	preview.texture = texture
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.modulate = modulate_color
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(preview)

	return wrapper

func _slot_style(selected: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.12, 0.12, 0.12, 0.90)
	if selected:
		s.border_width_top = 2
		s.border_width_left = 2
		s.border_width_right = 2
		s.border_width_bottom = 2
		s.border_color = Color(0.95, 0.86, 0.18, 1.0)
	else:
		s.border_width_top = 1
		s.border_width_left = 1
		s.border_width_right = 1
		s.border_width_bottom = 1
		s.border_color = Color(0.42, 0.42, 0.42, 0.85)
	return s
