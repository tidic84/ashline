extends StaticBody3D
class_name Harvestable

@export var resource_id: String = "wood"
@export var drop_item_id: String = ""
@export var amount: int = 5
@export var hits_to_harvest: int = 3
@export var respawn_time: float = 0.0 # 0 = no respawn
@export var required_tool_id: String = ""
@export var interact_label: String = "Harvest"

const PICKUP_SFX: String = "pickup_item"

var hits_remaining: int
var is_depleted: bool = false

func _ready() -> void:
	hits_remaining = hits_to_harvest
	collision_layer = 32 # Interactable
	collision_mask = 0
	add_to_group("harvestable")
	if not has_meta(WorldSync.NET_ID_META):
		WorldSync.register_entity(self, 300000 + absi(String(get_path()).hash() % 500000))

func interact(_player: CharacterBody3D) -> void:
	if WorldSync.should_request_host():
		WorldSync.request_harvest(WorldSync.get_net_id(self))
		if _is_pickup_collectible():
			_play_pickup_sfx()
		return
	server_harvest(Inventory.get_local_peer_id())

func server_harvest(peer_id: int) -> void:
	if is_depleted:
		return
	var selected_item: String
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server() and peer_id != Inventory.get_local_peer_id():
		selected_item = Inventory.server_get_selected_item(peer_id)
	else:
		selected_item = Inventory.get_selected_item()
	if required_tool_id != "" and selected_item != required_tool_id:
		AudioManager.play_sfx("metal_hit", 0.0, 0.85)
		return
	hits_remaining -= 1
	if _is_pickup_collectible():
		_play_pickup_sfx()
	else:
		_play_hit_sfx()
	_on_hit()
	if hits_remaining <= 0:
		_harvest(peer_id)

func get_interact_text() -> String:
	if required_tool_id == "":
		return "[E] %s" % interact_label
	var tool_name: String = Inventory.get_item_name(required_tool_id)
	return "[E] %s (%s required)" % [interact_label, tool_name]

func _play_hit_sfx() -> void:
	var kind: String = resource_id if drop_item_id == "" else drop_item_id
	match kind:
		"wood", "branch", "log":
			var idx: int = randi_range(1, 9)
			AudioManager.play_sfx("cutting_wood0%d" % idx, 0.0, randf_range(0.95, 1.05))
		"stone":
			var idx: int = randi_range(1, 4)
			AudioManager.play_sfx("mining_stone0%d" % idx, 0.0, randf_range(0.9, 1.1))
		"metal", "metal_scrap": AudioManager.play_sfx("metal_hit", 0.0, randf_range(0.9, 1.1))
		_: AudioManager.play_sfx("harvest", 0.0, randf_range(0.9, 1.1))

func _is_pickup_collectible() -> bool:
	return required_tool_id.is_empty() and hits_to_harvest <= 1

func _play_pickup_sfx() -> void:
	AudioManager.play_sfx(PICKUP_SFX, 0.0, randf_range(0.96, 1.04))

func _on_hit() -> void:
	# Shake effect
	var tween := create_tween()
	tween.tween_property(self, "rotation:y", rotation.y + 0.1, 0.05)
	tween.tween_property(self, "rotation:y", rotation.y - 0.1, 0.05)
	tween.tween_property(self, "rotation:y", rotation.y, 0.05)

func _harvest(peer_id: int = 1) -> void:
	is_depleted = true
	if drop_item_id != "":
		if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
			Inventory.server_add_item(peer_id, drop_item_id, amount)
		else:
			Inventory.add_item(drop_item_id, amount)
	elif resource_id != "":
		if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
			Inventory.server_add_item(peer_id, resource_id, amount)
		else:
			Inventory.add_resource(resource_id, amount)
	if respawn_time > 0:
		visible = false
		var col: Node = get_node_or_null("CollisionShape3D")
		if col:
			col.disabled = true
		await get_tree().create_timer(respawn_time).timeout
		_respawn()
	else:
		if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
			WorldSync.replicate_despawn(WorldSync.get_net_id(self))
		queue_free()

func _respawn() -> void:
	is_depleted = false
	hits_remaining = hits_to_harvest
	visible = true
	var col: Node = get_node_or_null("CollisionShape3D")
	if col:
		col.disabled = false
