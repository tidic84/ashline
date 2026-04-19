extends StaticBody3D
class_name Harvestable

@export var resource_id: String = "wood"
@export var drop_item_id: String = ""
@export var amount: int = 5
@export var hits_to_harvest: int = 3
@export var respawn_time: float = 0.0 # 0 = no respawn
@export var required_tool_id: String = ""
@export var interact_label: String = "Harvest"
@export var hit_cooldown: float = 0.5

const PICKUP_SFX: String = "pickup_item"

var hits_remaining: int
var is_depleted: bool = false
var _next_harvest_hit_time: float = 0.0

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
		_play_spatial_sfx("metal_hit", 0.0, 0.85)
		return
	if not _consume_hit_cooldown():
		return
	hits_remaining -= 1
	if required_tool_id != "" and Inventory.has_durability(selected_item):
		if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
			Inventory.server_consume_selected_durability(peer_id)
		elif not multiplayer.has_multiplayer_peer():
			Inventory._consume_slot_durability(Inventory.selected_hotbar_index)
	if _is_pickup_collectible():
		if _should_play_pickup_sfx_for_peer(peer_id):
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
			_play_spatial_sfx("cutting_wood0%d" % idx, 0.0, randf_range(0.95, 1.05))
		"stone":
			var idx: int = randi_range(1, 4)
			_play_spatial_sfx("mining_stone0%d" % idx, 0.0, randf_range(0.9, 1.1))
		"metal", "metal_scrap":
			_play_spatial_sfx("metal_hit", 0.0, randf_range(0.9, 1.1))
		_:
			_play_spatial_sfx("harvest", 0.0, randf_range(0.9, 1.1))

func _play_spatial_sfx(name: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	var pos := global_position
	if AudioManager != null and AudioManager.has_method("play_sfx_3d"):
		AudioManager.play_sfx_3d(name, pos, volume_db, pitch)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_spatial_sfx(name, pos, volume_db, pitch)

func _is_pickup_collectible() -> bool:
	return required_tool_id.is_empty() and hits_to_harvest <= 1

func _play_pickup_sfx() -> void:
	AudioManager.play_sfx(PICKUP_SFX, 0.0, randf_range(0.96, 1.04))

func _should_play_pickup_sfx_for_peer(peer_id: int) -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	return peer_id <= 0 or peer_id == Inventory.get_local_peer_id()

func _consume_hit_cooldown() -> bool:
	if hit_cooldown <= 0.0:
		return true
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now < _next_harvest_hit_time:
		return false
	_next_harvest_hit_time = now + hit_cooldown
	return true

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
	_next_harvest_hit_time = 0.0
	visible = true
	var col: Node = get_node_or_null("CollisionShape3D")
	if col:
		col.disabled = false
