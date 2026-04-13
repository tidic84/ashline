extends StaticBody3D
class_name Harvestable

@export var resource_id: String = "wood"
@export var drop_item_id: String = ""
@export var amount: int = 5
@export var hits_to_harvest: int = 3
@export var respawn_time: float = 0.0 # 0 = no respawn
@export var required_tool_id: String = ""
@export var interact_label: String = "Harvest"

var hits_remaining: int
var is_depleted: bool = false

func _ready() -> void:
	hits_remaining = hits_to_harvest
	collision_layer = 32 # Interactable
	collision_mask = 0
	add_to_group("harvestable")

func interact(_player: CharacterBody3D) -> void:
	if is_depleted:
		return
	if required_tool_id != "" and Inventory.get_selected_item() != required_tool_id:
		AudioManager.play_sfx("metal_hit", 0.0, 0.85)
		return
	hits_remaining -= 1
	_play_hit_sfx()
	_on_hit()
	if hits_remaining <= 0:
		_harvest()

func get_interact_text() -> String:
	if required_tool_id == "":
		return "[E] %s" % interact_label
	var tool_name: String = Inventory.get_item_name(required_tool_id)
	return "[E] %s (%s required)" % [interact_label, tool_name]

func _play_hit_sfx() -> void:
	var kind: String = resource_id if drop_item_id == "" else drop_item_id
	match kind:
		"wood", "branch", "log": AudioManager.play_sfx("chop", 0.0, randf_range(0.95, 1.05))
		"metal", "metal_scrap", "stone": AudioManager.play_sfx("metal_hit", 0.0, randf_range(0.9, 1.1))
		_: AudioManager.play_sfx("harvest", 0.0, randf_range(0.9, 1.1))

func _on_hit() -> void:
	# Shake effect
	var tween := create_tween()
	tween.tween_property(self, "rotation:y", rotation.y + 0.1, 0.05)
	tween.tween_property(self, "rotation:y", rotation.y - 0.1, 0.05)
	tween.tween_property(self, "rotation:y", rotation.y, 0.05)

func _harvest() -> void:
	is_depleted = true
	if drop_item_id != "":
		Inventory.add_item(drop_item_id, amount)
	elif resource_id != "":
		Inventory.add_resource(resource_id, amount)
	if respawn_time > 0:
		visible = false
		var col: Node = get_node_or_null("CollisionShape3D")
		if col:
			col.disabled = true
		await get_tree().create_timer(respawn_time).timeout
		_respawn()
	else:
		queue_free()

func _respawn() -> void:
	is_depleted = false
	hits_remaining = hits_to_harvest
	visible = true
	var col: Node = get_node_or_null("CollisionShape3D")
	if col:
		col.disabled = false
