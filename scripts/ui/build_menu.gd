extends PanelContainer
class_name BuildMenu

signal item_selected(buildable_id: String)
signal mode_selected(mode: int)
signal close_requested
signal exit_build_requested

@onready var list_container: VBoxContainer = $Margin/VBox/Scroll/ItemList
@onready var exit_button: Button = $Margin/VBox/ExitButton
@onready var close_button: Button = $Margin/VBox/TitleBar/CloseButton

func _ready() -> void:
	visible = false
	exit_button.pressed.connect(func(): exit_build_requested.emit())
	close_button.pressed.connect(func(): close_requested.emit())

func _populate() -> void:
	# Always rebuild so affordability (red tint) reflects current resources
	for child in list_container.get_children():
		child.queue_free()

	# Structure section (special modes)
	_add_section("Structure")
	_add_mode_button("Chassis", BuildSystem.CHASSIS_COST, BuildSystem.BuildMode.CHASSIS)
	_add_mode_button("Floor", BuildSystem.FLOOR_COST, BuildSystem.BuildMode.FLOOR)

	# Demolish
	_add_section("Tools")
	var demolish_btn := Button.new()
	demolish_btn.text = "Demolish   [refunds 50%]"
	demolish_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	demolish_btn.modulate = Color(1.0, 0.5, 0.2)
	demolish_btn.pressed.connect(func(): mode_selected.emit(BuildSystem.BuildMode.DEMOLISH))
	list_container.add_child(demolish_btn)

	# Items from catalog, grouped by category
	var by_category: Dictionary = {}
	for id in BuildSystem.buildable_catalog:
		var data: BuildableData = BuildSystem.buildable_catalog[id]
		var cat: int = data.category
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(data)

	var cat_names: Dictionary = {
		BuildableData.Category.WALL: "Walls",
		BuildableData.Category.BARRICADE: "Barricades",
		BuildableData.Category.TURRET: "Defenses",
		BuildableData.Category.FURNITURE: "Furniture",
		BuildableData.Category.UTILITY: "Utilities",
	}

	var ordered_cats: Array = [
		BuildableData.Category.WALL,
		BuildableData.Category.BARRICADE,
		BuildableData.Category.TURRET,
		BuildableData.Category.UTILITY,
		BuildableData.Category.FURNITURE,
	]

	for cat in ordered_cats:
		if not by_category.has(cat):
			continue
		_add_section(cat_names.get(cat, "Items"))
		for data in by_category[cat]:
			_add_item_button(data)

func _add_section(section_name: String) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	list_container.add_child(spacer)
	var label := Label.new()
	label.text = section_name.to_upper()
	label.add_theme_font_size_override("font_size", 16)
	label.modulate = Color(1, 0.85, 0.5)
	list_container.add_child(label)
	var sep := HSeparator.new()
	list_container.add_child(sep)

func _add_mode_button(item_name: String, cost: Dictionary, mode: int) -> void:
	var btn := Button.new()
	btn.text = "%s   [%s]  [hammer]" % [item_name, _format_cost(cost)]
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.pressed.connect(func(): mode_selected.emit(mode))
	if not Inventory.has_resources(cost):
		btn.modulate = Color(1, 0.5, 0.5, 0.7)
	list_container.add_child(btn)

func _add_item_button(data: BuildableData) -> void:
	var btn := Button.new()
	btn.text = "%s   [%s]" % [data.display_name, _format_cost(data.cost)]
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if data.icon != null:
		btn.icon = data.icon
	var id: String = data.id
	btn.pressed.connect(func(): item_selected.emit(id))
	if not Inventory.has_resources(data.cost):
		btn.modulate = Color(1, 0.5, 0.5, 0.7)
	list_container.add_child(btn)

func _format_cost(cost: Dictionary) -> String:
	if cost.is_empty():
		return "free"
	var parts: Array[String] = []
	for k in cost:
		parts.append("%d %s" % [cost[k], k])
	return ", ".join(parts)

func show_menu() -> void:
	_populate()
	visible = true

func hide_menu() -> void:
	visible = false
