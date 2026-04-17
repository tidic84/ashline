extends StaticBody3D
class_name PumpLever

@export var pump_cooldown: float = 0.22

@export_group("Base Model")
@export var base_position: Vector3 = Vector3(0.0, 0.285, 0.0)
@export var base_rotation_deg: Vector3 = Vector3.ZERO
@export var base_scale: Vector3 = Vector3(0.7, 0.7, 0.7)

@export_group("Handle Pivot")
@export var handle_pivot_position: Vector3 = Vector3(0, 0.9, 0)

@export_group("Handle Model")
@export var handle_model_position: Vector3 = Vector3.ZERO
@export var handle_model_rotation_deg: Vector3 = Vector3.ZERO
@export var handle_model_scale: Vector3 = Vector3.ONE


@export_group("Animation")
@export var pump_angle_deg: float = 20.0
## Axe de rotation du bras. "x" = tangage (penche vers nous / arriere).
## "z" = roulis (penche gauche / droite). Change selon l'orientation du modele.
@export_enum("x", "y", "z") var pump_axis: String = "z"

var can_pump: bool = true
var _pump_target: Node = null  # WagonFrame or TrainChassis

func _ready() -> void:
	collision_layer = 32  # Layer 6 = Interactable
	collision_mask = 0
	add_to_group("interactable")
	_apply_transforms()
	if not has_meta(WorldSync.NET_ID_META):
		WorldSync.register_entity(self, 300000 + absi(String(get_path()).hash() % 500000))
	# Find parent wagon frame or chassis
	var current: Node = get_parent()
	while current:
		if current is WagonFrame:
			_pump_target = current
			current.is_on_rails = true
			break
		if current is TrainChassis:
			_pump_target = current
			current.is_on_rails = true
			break
		current = current.get_parent()

func _apply_transforms() -> void:
	# Les exports de ce script sont la source de verite. Ils ecrasent toujours les
	# transformations stockees dans la .tscn pour que l'inspecteur puisse piloter
	# la taille/position du modele sans conflit.
	var base: Node3D = get_node_or_null("Visuals/Base") as Node3D
	if base:
		base.transform = _make_transform(base_position, base_rotation_deg, base_scale)
	var handle_pivot: Node3D = get_node_or_null("Visuals/Handle") as Node3D
	if handle_pivot:
		handle_pivot.position = handle_pivot_position
	var handle_model: Node3D = get_node_or_null("Visuals/Handle/HandleModel") as Node3D
	if handle_model:
		handle_model.transform = _make_transform(handle_model_position, handle_model_rotation_deg, handle_model_scale)

func _make_transform(pos: Vector3, rot_deg: Vector3, scl: Vector3) -> Transform3D:
	var basis := Basis.from_euler(Vector3(deg_to_rad(rot_deg.x), deg_to_rad(rot_deg.y), deg_to_rad(rot_deg.z)))
	basis = basis.scaled(scl)
	return Transform3D(basis, pos)

func interact(_player: CharacterBody3D) -> void:
	if WorldSync.should_request_host():
		WorldSync.request_interact(WorldSync.get_net_id(self))
		return
	server_interact(Inventory.get_local_peer_id())

func server_interact(_peer_id: int) -> void:
	_perform_pump(true, true)

func apply_network_interact() -> void:
	_perform_pump(false, false)

func _perform_pump(replicate: bool, affect_train: bool) -> void:
	if not can_pump or _pump_target == null:
		return
	can_pump = false
	if affect_train:
		_pump_target.pump()
	if affect_train and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.broadcast_train_entity_snapshots(true)
	AudioManager.play_sfx("pump", 0.0, randf_range(0.95, 1.05))
	_animate_pump()
	if replicate and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_interact(WorldSync.get_net_id(self))
	await get_tree().create_timer(pump_cooldown).timeout
	can_pump = true

var _pump_down: bool = false

func _animate_pump() -> void:
	var handle: Node3D = get_node_or_null("Visuals/Handle") as Node3D
	if handle == null:
		return
	_pump_down = not _pump_down
	var target_angle: float = deg_to_rad(pump_angle_deg) if _pump_down else deg_to_rad(-pump_angle_deg)
	var tween := create_tween()
	tween.tween_property(handle, "rotation:" + pump_axis, target_angle, 0.18).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
