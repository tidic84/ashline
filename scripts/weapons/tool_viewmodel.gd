extends Node3D
## Viewmodel premiere personne "item seul" : affiche le modele 3D de l'item
## tenu en bas a droite de l'ecran, sans bras visible, avec une animation
## d'equipement, un leger balancement idle et un coup (swing) declenchable.

const BASE_ITEM_SIZE: float = 0.42
const VIEW_POSITION: Vector3 = Vector3(0.48, -0.42, -0.85)
const EQUIP_RISE: float = 0.45
const EQUIP_TIME: float = 0.22
const SWING_ANGLE_DEG: float = -68.0
const SWING_PUSH: Vector3 = Vector3(-0.08, -0.05, -0.18)
const SWING_DOWN_TIME: float = 0.11
const SWING_RETURN_TIME: float = 0.22
const IDLE_BOB_AMPLITUDE: float = 0.005
const IDLE_BOB_FREQ: float = 1.4
# Position de la camera d'icones d'inventaire (inventory.gd). L'item est
# oriente pour apparaitre a l'ecran exactement comme sur son icone, dont
# l'orientation par item est deja reglee dans ITEM_ICON_SETTINGS.
const ICON_CAMERA_POSITION: Vector3 = Vector3(2.0, 1.8, 2.0)

# Surcharges par item : { "position": Vector3, "rotation_deg": Vector3, "scale_mult": float }
# rotation_deg / scale_mult remplacent les valeurs issues des icones.
const VIEW_OVERRIDES: Dictionary = {}

@export var item_id: String = ""

var _swing_pivot: Node3D = null
var _orient_pivot: Node3D = null
var _model: Node3D = null
var _swing_tween: Tween = null
var _equip_offset: float = 0.0
var _bob_time: float = 0.0

func _ready() -> void:
	if not item_id.is_empty():
		_rebuild()

func setup(id: String) -> void:
	item_id = id
	if is_inside_tree():
		_rebuild()

func _process(delta: float) -> void:
	_bob_time += delta * IDLE_BOB_FREQ
	var bob := Vector3(
		cos(_bob_time * 0.5) * IDLE_BOB_AMPLITUDE * 0.5,
		sin(_bob_time) * IDLE_BOB_AMPLITUDE,
		0.0
	)
	position = bob + Vector3(0.0, _equip_offset, 0.0)

func shoot() -> void:
	play_swing()

func play_swing() -> void:
	if _swing_pivot == null or not is_instance_valid(_swing_pivot):
		return
	if _swing_tween != null and _swing_tween.is_running():
		return
	_swing_tween = create_tween()
	_swing_tween.set_parallel(true)
	_swing_tween.tween_property(_swing_pivot, "rotation:x", deg_to_rad(SWING_ANGLE_DEG), SWING_DOWN_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_swing_tween.tween_property(_swing_pivot, "position", _view_position() + SWING_PUSH, SWING_DOWN_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_swing_tween.chain().tween_property(_swing_pivot, "rotation:x", 0.0, SWING_RETURN_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	_swing_tween.tween_property(_swing_pivot, "position", _view_position(), SWING_RETURN_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)

func _rebuild() -> void:
	if _swing_pivot != null and is_instance_valid(_swing_pivot):
		_swing_pivot.queue_free()
	_swing_pivot = null
	_orient_pivot = null
	_model = null
	var model_path: String = Inventory.ITEM_MODELS.get(item_id, "")
	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		return
	_model = Inventory._instantiate_icon_model(model_path)
	if _model == null:
		return
	_swing_pivot = Node3D.new()
	_swing_pivot.name = "SwingPivot"
	add_child(_swing_pivot)
	_swing_pivot.position = _view_position()
	_orient_pivot = Node3D.new()
	_orient_pivot.name = "OrientPivot"
	_swing_pivot.add_child(_orient_pivot)
	_orient_pivot.basis = _compute_orientation()
	_orient_pivot.add_child(_model)
	Inventory._fix_tool_textures(item_id, _model)
	# Une frame pour que les transforms se propagent avant le calcul d'AABB.
	await get_tree().process_frame
	if _model == null or not is_instance_valid(_model) or not is_inside_tree():
		return
	var aabb: AABB = Inventory._compute_aabb(_model)
	if aabb.size.length() > 0.0001:
		var max_dim: float = maxf(maxf(aabb.size.x, aabb.size.y), aabb.size.z)
		var scale_factor: float = BASE_ITEM_SIZE * _view_scale_mult() / max_dim
		_model.scale = Vector3.ONE * scale_factor
		_model.position = -aabb.get_center() * scale_factor
	_play_equip()

func _compute_orientation() -> Basis:
	var override: Dictionary = VIEW_OVERRIDES.get(item_id, {})
	var icon_settings: Dictionary = Inventory.get_item_icon_settings(item_id)
	var rot_deg: Vector3 = override.get("rotation_deg", icon_settings.get("rotation_deg", Vector3.ZERO))
	var item_basis := Basis.from_euler(Vector3(
		deg_to_rad(rot_deg.x),
		deg_to_rad(rot_deg.y),
		deg_to_rad(rot_deg.z)
	))
	# Reproduit le point de vue de la camera d'icones : meme orientation
	# apparente que sur l'icone d'inventaire, mais vue par la camera FPS (-Z).
	var icon_cam_basis := Basis.looking_at(-ICON_CAMERA_POSITION.normalized(), Vector3.UP)
	return icon_cam_basis.transposed() * item_basis

func _view_position() -> Vector3:
	var override: Dictionary = VIEW_OVERRIDES.get(item_id, {})
	return override.get("position", VIEW_POSITION)

func _view_scale_mult() -> float:
	var override: Dictionary = VIEW_OVERRIDES.get(item_id, {})
	var icon_settings: Dictionary = Inventory.get_item_icon_settings(item_id)
	return float(override.get("scale_mult", icon_settings.get("scale_mult", 1.0)))

func _play_equip() -> void:
	_equip_offset = -EQUIP_RISE
	var tween := create_tween()
	tween.tween_property(self, "_equip_offset", 0.0, EQUIP_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
