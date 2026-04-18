extends StaticBody3D

@export var max_health: float = 100.0
var current_health: float

func _ready() -> void:
	current_health = max_health
	add_to_group("placeable")
	if not has_meta(WorldSync.NET_ID_META) and WorldSync.is_host():
		WorldSync.register_entity(self)

func interact(player: Node) -> void:
	_open_ui(player)

func secondary_interact(player: Node) -> void:
	_open_ui(player)

func get_interact_text() -> String:
	return "[E] Établi — Crafting"

func _open_ui(player: Node) -> void:
	var hud: Node = player.get_node_or_null("HUD")
	if hud != null and hud.has_method("open_workbench"):
		hud.open_workbench()
