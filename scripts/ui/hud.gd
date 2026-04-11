extends Control

@onready var resource_label: Label = $ResourcePanel/ResourceLabel
@onready var build_panel: PanelContainer = $BuildPanel
@onready var build_label: Label = $BuildPanel/BuildLabel
@onready var crosshair: ColorRect = $Crosshair
@onready var interact_hint: Label = $InteractHint
@onready var speed_label: Label = $SpeedLabel
@onready var distance_label: Label = $DistanceLabel
@onready var time_label: Label = $TimeLabel
@onready var build_menu: BuildMenu = $BuildMenu
@onready var settings_menu: SettingsMenu = $SettingsMenu

var tracked_chassis: TrainChassis = null
var _hud_refresh_accum: float = 0.0
const HUD_REFRESH_INTERVAL: float = 0.1

func _ready() -> void:
	BuildSystem.build_mode_entered.connect(_on_build_entered)
	BuildSystem.build_mode_exited.connect(_on_build_exited)
	Inventory.inventory_updated.connect(_update_resources)
	build_panel.visible = false
	interact_hint.visible = false
	speed_label.visible = false
	_update_resources()

func _process(_delta: float) -> void:
	_hud_refresh_accum += _delta
	if _hud_refresh_accum < HUD_REFRESH_INTERVAL:
		return
	_hud_refresh_accum = 0.0

	if BuildSystem.is_building:
		var cost_text := _current_build_cost_text()
		build_label.text = "%s%s\n[B] Menu  [R] Rotate  [LMB] Place  [X] Remove  [RMB] Cancel" % [BuildSystem.get_mode_name(), cost_text]
		# Crosshair feedback based on placement validity
		if BuildSystem.mode == BuildSystem.BuildMode.OFF:
			crosshair.color = Color(1, 1, 1, 0.8)
		elif BuildSystem.can_place:
			crosshair.color = Color(0.3, 1.0, 0.3, 0.9)
		else:
			crosshair.color = Color(1.0, 0.3, 0.3, 0.9)

	# Track nearest chassis speed
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
		time_label.text = "Night" if night else "Day"
		var night_color := Color(0.6, 0.7, 1.0)
		var day_color := Color(1, 0.95, 0.7)
		time_label.modulate = night_color if night else day_color

func _find_nearest_chassis() -> TrainChassis:
	var chassis_nodes := get_tree().get_nodes_in_group("chassis")
	if chassis_nodes.size() > 0:
		return chassis_nodes[0] as TrainChassis
	return null

func _update_resources() -> void:
	resource_label.text = "Wood: %d  |  Metal: %d  |  Parts: %d  |  Fuel: %d" % [
		Inventory.get_amount("wood"),
		Inventory.get_amount("metal"),
		Inventory.get_amount("components"),
		Inventory.get_amount("fuel"),
	]

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
		BuildSystem.BuildMode.CHASSIS:
			cost = BuildSystem.CHASSIS_COST
		BuildSystem.BuildMode.FLOOR:
			cost = BuildSystem.FLOOR_COST
		BuildSystem.BuildMode.ITEM:
			if BuildSystem.current_buildable_data:
				cost = BuildSystem.current_buildable_data.cost
	if cost.is_empty():
		return ""
	var parts: Array[String] = []
	for k in cost:
		parts.append("%d %s" % [cost[k], k])
	return "  (" + ", ".join(parts) + ")"
