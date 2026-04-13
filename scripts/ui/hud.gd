extends Control

signal inventory_toggle_requested

const HOTBAR_KEY_LABELS: Array[String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

@onready var build_panel: PanelContainer = $BuildPanel
@onready var build_label: Label = $BuildPanel/BuildLabel
@onready var crosshair: ColorRect = $Crosshair
@onready var interact_hint: Label = $InteractHint
@onready var speed_label: Label = $SpeedLabel
@onready var distance_label: Label = $DistanceLabel
@onready var time_label: Label = $TimeLabel
@onready var build_menu: BuildMenu = $BuildMenu
@onready var settings_menu: SettingsMenu = $SettingsMenu
@onready var stats_display: Control = $StatsDisplay
@onready var hotbar_slots: HBoxContainer = $HotbarPanel/HotbarSlots
@onready var inventory_panel: PanelContainer = $InventoryPanel
@onready var inventory_items_grid: GridContainer = $InventoryPanel/Margin/VBox/InventoryItemsGrid
@onready var inventory_recipes_label: Label = $InventoryPanel/Margin/VBox/Right/RecipeList
@onready var craft_preview_label: Label = $InventoryPanel/Margin/VBox/Right/CraftInfo

var tracked_chassis: TrainChassis = null
var _hud_refresh_accum: float = 0.0
const HUD_REFRESH_INTERVAL: float = 0.1

var _recipe_ids: Array[String] = []
var _selected_recipe_index: int = 0
var _crafting_system: Node = null

var _hotbar_ui: Array[InventorySlotUI] = []
var _inventory_ui: Array[InventorySlotUI] = []

func _ready() -> void:
	BuildSystem.build_mode_entered.connect(_on_build_entered)
	BuildSystem.build_mode_exited.connect(_on_build_exited)
	Inventory.inventory_updated.connect(_on_inventory_updated)
	Inventory.hotbar_updated.connect(_refresh_hotbar_slots)
	Inventory.selected_hotbar_changed.connect(_on_hotbar_selected)
	Inventory.survival_changed.connect(_on_survival_changed)

	_crafting_system = get_node_or_null("/root/CraftingSystem")
	if _crafting_system and _crafting_system.has_signal("crafted"):
		_crafting_system.connect("crafted", _on_recipe_crafted)

	build_panel.visible = false
	interact_hint.visible = false
	speed_label.visible = false
	inventory_panel.visible = false

	_build_hotbar_ui()
	_build_inventory_slots_ui()

	_recipe_ids = _crafting_get_recipe_ids()
	_on_inventory_updated()
	_on_survival_changed(Inventory.health, Inventory.hunger, Inventory.thirst)


func _process(delta: float) -> void:
	_hud_refresh_accum += delta
	if _hud_refresh_accum < HUD_REFRESH_INTERVAL:
		return
	_hud_refresh_accum = 0.0

	if BuildSystem.is_building:
		var cost_text := _current_build_cost_text()
		build_label.text = "%s%s\n[B] Menu  [R] Rotation  [Clic] Placer  [X] Retirer  [Clic droit] Annuler" % [BuildSystem.get_mode_name(), cost_text]
		if BuildSystem.mode == BuildSystem.BuildMode.OFF:
			crosshair.color = Color(1, 1, 1, 0.8)
		elif BuildSystem.can_place:
			crosshair.color = Color(0.3, 1.0, 0.3, 0.9)
		else:
			crosshair.color = Color(1.0, 0.3, 0.3, 0.9)

	if tracked_chassis == null or not is_instance_valid(tracked_chassis):
		tracked_chassis = _find_nearest_chassis()
	if tracked_chassis and is_instance_valid(tracked_chassis) and tracked_chassis.is_on_rails:
		speed_label.visible = true
		distance_label.visible = true
		var spd: float = absf(tracked_chassis.speed)
		speed_label.text = "%.1f m/s" % spd
		distance_label.text = "%d m" % int(tracked_chassis.distance_traveled)
	else:
		speed_label.visible = false
		distance_label.visible = false

	var main: Node = get_tree().current_scene
	if main and "is_night" in main:
		var night: bool = main.get("is_night")
		time_label.text = "Nuit" if night else "Jour"
		time_label.modulate = Color(0.6, 0.7, 1.0) if night else Color(1, 0.95, 0.7)


func _find_nearest_chassis() -> TrainChassis:
	var nodes := get_tree().get_nodes_in_group("chassis")
	return nodes[0] as TrainChassis if not nodes.is_empty() else null


func _on_inventory_updated() -> void:
	_refresh_hotbar_slots()
	if inventory_panel.visible:
		_update_inventory_panel()

func _on_survival_changed(health: float, hunger: float, thirst: float) -> void:
	if stats_display and stats_display.has_method("set_stats"):
		stats_display.call("set_stats", health, hunger, thirst)

func _on_hotbar_selected(_index: int, _item_id: String) -> void:
	_refresh_hotbar_slots()

func _on_recipe_crafted(_item_id: String) -> void:
	_update_inventory_panel()

func _on_build_entered() -> void:
	build_panel.visible = true

func _on_build_exited() -> void:
	build_panel.visible = false
	crosshair.color = Color.WHITE


func show_interact_hint(text: String) -> void:
	interact_hint.text = text
	interact_hint.visible = true

func hide_interact_hint() -> void:
	interact_hint.visible = false


func _current_build_cost_text() -> String:
	var cost: Dictionary = {}
	match BuildSystem.mode:
		BuildSystem.BuildMode.CHASSIS: cost = BuildSystem.CHASSIS_COST
		BuildSystem.BuildMode.FLOOR:   cost = BuildSystem.FLOOR_COST
		BuildSystem.BuildMode.ITEM:
			if BuildSystem.current_buildable_data:
				cost = BuildSystem.current_buildable_data.cost
	if cost.is_empty():
		return ""
	var parts: Array[String] = []
	for k in cost:
		parts.append("%d %s" % [cost[k], k])
	var txt := "  (" + ", ".join(parts) + ")"
	if Inventory.get_selected_item() != "hammer":
		txt += "  [marteau requis]"
	return txt


func is_inventory_open() -> bool:
	return inventory_panel.visible

func toggle_inventory_panel(force_state: Variant = null) -> bool:
	var new_state: bool = not inventory_panel.visible
	if force_state is bool:
		new_state = force_state
	inventory_panel.visible = new_state
	if new_state:
		_update_inventory_panel()
	return inventory_panel.visible


func select_next_recipe() -> void:
	if _recipe_ids.is_empty(): return
	_selected_recipe_index = (_selected_recipe_index + 1) % _recipe_ids.size()
	_update_inventory_panel()

func select_previous_recipe() -> void:
	if _recipe_ids.is_empty(): return
	_selected_recipe_index = posmod(_selected_recipe_index - 1, _recipe_ids.size())
	_update_inventory_panel()

func craft_selected_recipe() -> void:
	if _recipe_ids.is_empty(): return
	_crafting_craft(_recipe_ids[_selected_recipe_index])
	_update_inventory_panel()


func _update_inventory_panel() -> void:
	_refresh_inventory_slots()
	_update_recipe_panel()

func _update_recipe_panel() -> void:
	if _recipe_ids.is_empty():
		inventory_recipes_label.text = "Aucune recette"
		craft_preview_label.text = ""
		return

	_selected_recipe_index = clampi(_selected_recipe_index, 0, _recipe_ids.size() - 1)

	var lines: Array[String] = []
	for i in range(_recipe_ids.size()):
		var recipe: Dictionary = _crafting_get_recipe(_recipe_ids[i])
		var ok: bool = _crafting_can_craft(_recipe_ids[i])
		var sel: String = "▶ " if i == _selected_recipe_index else "  "
		var status: String = "✓" if ok else "✗"
		lines.append("%s%s  [%s]" % [sel, recipe.get("display_name", _recipe_ids[i]), status])
	inventory_recipes_label.text = "\n".join(lines)

	var rid: String = _recipe_ids[_selected_recipe_index]
	var recipe: Dictionary = _crafting_get_recipe(rid)
	var ingredients: Dictionary = recipe.get("ingredients", {})
	var ingr_lines: Array[String] = []
	for item_id in ingredients:
		var need: int = int(ingredients[item_id])
		var have: int = Inventory.get_item_amount(item_id)
		var ok_c: String = "✓" if have >= need else "✗"
		ingr_lines.append("%s  %s × %d  (/%d)" % [ok_c, Inventory.get_item_name(item_id), need, have])
	craft_preview_label.text = "─── %s ───\n%s\n\n[F] Crafter" % [
		recipe.get("display_name", rid),
		"\n".join(ingr_lines)
	]


func _build_hotbar_ui() -> void:
	for child in hotbar_slots.get_children():
		child.queue_free()
	_hotbar_ui.clear()
	for i in range(Inventory.HOTBAR_SIZE):
		var slot := InventorySlotUI.new()
		slot.setup(i, HOTBAR_KEY_LABELS[i])
		slot.slot_pressed.connect(_on_slot_pressed)
		slot.slot_dropped.connect(_on_slot_dropped)
		hotbar_slots.add_child(slot)
		_hotbar_ui.append(slot)

func _build_inventory_slots_ui() -> void:
	for child in inventory_items_grid.get_children():
		child.queue_free()
	_inventory_ui.clear()
	inventory_items_grid.columns = 9
	for i in range(Inventory.get_inventory_slot_count()):
		var global_index: int = Inventory.HOTBAR_SIZE + i
		var slot := InventorySlotUI.new()
		slot.setup(global_index, "")
		slot.slot_pressed.connect(_on_slot_pressed)
		slot.slot_dropped.connect(_on_slot_dropped)
		inventory_items_grid.add_child(slot)
		_inventory_ui.append(slot)

func _refresh_hotbar_slots() -> void:
	for i in range(_hotbar_ui.size()):
		var data: Dictionary = Inventory.get_hotbar_slot_data(i)
		var has_item: bool = String(data.get("item_id", "")) != "" and int(data.get("amount", 0)) > 0
		var item_id: String = String(data.get("item_id", ""))
		var icon: Texture2D = Inventory.get_item_icon(item_id) if has_item else null
		_hotbar_ui[i].set_slot_visual(icon, int(data.get("amount", 0)), i == Inventory.selected_hotbar_index, has_item, HOTBAR_KEY_LABELS[i])

func _refresh_inventory_slots() -> void:
	for i in range(_inventory_ui.size()):
		var global_index: int = Inventory.HOTBAR_SIZE + i
		var data: Dictionary = Inventory.get_slot_data(global_index)
		var has_item: bool = String(data.get("item_id", "")) != "" and int(data.get("amount", 0)) > 0
		var item_id: String = String(data.get("item_id", ""))
		var icon: Texture2D = Inventory.get_item_icon(item_id) if has_item else null
		_inventory_ui[i].set_slot_visual(icon, int(data.get("amount", 0)), false, has_item, "")


func _on_slot_pressed(slot_index: int, button_index: int) -> void:
	if button_index != MOUSE_BUTTON_LEFT:
		return
	if slot_index < Inventory.HOTBAR_SIZE:
		Inventory.select_hotbar_slot(slot_index)

func _on_slot_dropped(source_index: int, target_index: int) -> void:
	Inventory.move_slot(source_index, target_index)


# Compatibility — build_controller.gd calls these
func select_next_recipe_compat() -> void:   select_next_recipe()
func select_previous_recipe_compat() -> void: select_previous_recipe()
func craft_selected_recipe_compat() -> void: craft_selected_recipe()


func _crafting_get_recipe_ids() -> Array[String]:
	if _crafting_system and _crafting_system.has_method("get_recipe_ids"):
		var ids: Variant = _crafting_system.call("get_recipe_ids")
		if ids is Array:
			return ids
	return []

func _crafting_get_recipe(recipe_id: String) -> Dictionary:
	if _crafting_system and _crafting_system.has_method("get_recipe"):
		var r: Variant = _crafting_system.call("get_recipe", recipe_id)
		if r is Dictionary:
			return r
	return {}

func _crafting_can_craft(recipe_id: String) -> bool:
	if _crafting_system and _crafting_system.has_method("can_craft"):
		return bool(_crafting_system.call("can_craft", recipe_id))
	return false

func _crafting_craft(recipe_id: String) -> bool:
	if _crafting_system and _crafting_system.has_method("craft"):
		return bool(_crafting_system.call("craft", recipe_id))
	return false
