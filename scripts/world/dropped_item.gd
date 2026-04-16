extends StaticBody3D

var item_id: String = ""
var amount: int = 0
var net_id: int = 0

const PICKUP_SFX: String = "pickup_item"

@onready var label: Label3D = $NameLabel
@onready var mesh_holder: Node3D = $MeshHolder

func _ready() -> void:
	add_to_group("dropped_item")
	collision_layer = 32
	collision_mask = 0

func setup(p_item_id: String, p_amount: int) -> void:
	item_id = p_item_id
	amount = p_amount
	set_meta("item_id", item_id)
	set_meta("amount", amount)
	if label:
		var display_name := Inventory.get_item_name(item_id)
		label.text = "%s x%d" % [display_name, amount] if amount > 1 else display_name
	_build_visual()

func _build_visual() -> void:
	if mesh_holder == null:
		return
	var model_path: String = Inventory.ITEM_MODELS.get(item_id, "")
	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		var box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.3, 0.3, 0.3)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Inventory.ITEM_ICON_COLORS.get(item_id, Color(0.5, 0.5, 0.5))
		bm.surface_set_material(0, mat)
		box.mesh = bm
		mesh_holder.add_child(box)
		return
	var res := ResourceLoader.load(model_path)
	if res == null:
		return
	var inst: Node3D = null
	if res is PackedScene:
		inst = (res as PackedScene).instantiate() as Node3D
	elif res is Mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = res as Mesh
		inst = mi
	if inst:
		inst.scale = Vector3(0.4, 0.4, 0.4)
		mesh_holder.add_child(inst)

func interact(_player: CharacterBody3D) -> void:
	if WorldSync.should_request_host():
		var nid := int(get_meta(WorldSync.NET_ID_META, 0))
		if nid > 0:
			WorldSync.request_pickup_drop(nid)
			_play_pickup_sfx()
		return
	server_pickup(0)

func server_pickup(peer_id: int) -> void:
	if not WorldSync.is_host():
		return
	if item_id.is_empty() or amount <= 0:
		return
	if peer_id > 0:
		Inventory.server_add_item(peer_id, item_id, amount)
	else:
		Inventory.add_item(item_id, amount)
	if peer_id <= 0 or peer_id == Inventory.get_local_peer_id():
		_play_pickup_sfx()
	var nid := int(get_meta(WorldSync.NET_ID_META, 0))
	if nid > 0:
		WorldSync.replicate_despawn(nid)
	queue_free()

func _play_pickup_sfx() -> void:
	AudioManager.play_sfx(PICKUP_SFX, 0.0, randf_range(0.96, 1.04))
