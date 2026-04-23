@tool
extends Node3D

@export var character_scene: PackedScene:
	set(v): character_scene = v; _rebuild_preview()
@export var item_scene: PackedScene:
	set(v): item_scene = v; _rebuild_preview()
@export var idle_anim_source: PackedScene:
	set(v): idle_anim_source = v; _rebuild_preview()
@export var hand_bone_name: String = "mixamorig:RightHand":
	set(v): hand_bone_name = v; _rebuild_preview()
@export var item_offset: Transform3D = Transform3D.IDENTITY:
	set(v): item_offset = v; _update_item_transform()
@export var character_offset: Transform3D = Transform3D.IDENTITY:
	set(v): character_offset = v; _update_character_transform()
@export var idle_animation: String = "mixamorig_Idle":
	set(v): idle_animation = v; _play_idle()
@export var character_texture: Texture2D:
	set(v): character_texture = v; _apply_character_texture()
@export var item_follow_path: NodePath
@export var item_albedo: Texture2D:
	set(v): item_albedo = v; _apply_item_material()
@export var item_normal: Texture2D:
	set(v): item_normal = v; _apply_item_material()
@export var item_metallic_roughness: Texture2D:
	set(v): item_metallic_roughness = v; _apply_item_material()
@export var swing_bone_name: String = "RightArm"
@export var swing_axis: Vector3 = Vector3(1, 0, 0)
@export var swing_angle_deg: float = -75.0
@export var swing_down_time: float = 0.12
@export var swing_return_time: float = 0.25
@export var attack_animation: String = ""

var _character_root: Node3D = null
var _item_root: Node3D = null
var _skeleton: Skeleton3D = null
var _bone_attachment: BoneAttachment3D = null
var _anim_player: AnimationPlayer = null
var _swing_tween: Tween = null
var _swing_bone_idx: int = -1
var _swing_rest_rotation: Quaternion = Quaternion.IDENTITY

func _ready() -> void:
	call_deferred("_rebuild_preview")

func _enter_tree() -> void:
	set_process(true)
	if Engine.is_editor_hint():
		call_deferred("_rebuild_preview")

func _process(_delta: float) -> void:
	_update_follow()

func _update_follow() -> void:
	if item_follow_path.is_empty():
		return
	var node := get_node_or_null(item_follow_path) as Node3D
	if node == null or _skeleton == null:
		return
	var bone_name_resolved := _resolve_bone_name(hand_bone_name)
	if bone_name_resolved.is_empty():
		return
	var idx := _skeleton.find_bone(bone_name_resolved)
	if idx < 0:
		return
	node.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(idx)

func _rebuild_preview() -> void:
	if not is_inside_tree():
		return
	_clear_children()
	if character_scene != null:
		_character_root = character_scene.instantiate() as Node3D
		if _character_root:
			add_child(_character_root)
			_character_root.transform = character_offset
			_skeleton = _find_skeleton(_character_root)
			_anim_player = _find_anim_player(_character_root)
			print("[HeldItemViewModel] Skeleton: ", _skeleton, " AnimPlayer: ", _anim_player)
			if _anim_player != null:
				print("[HeldItemViewModel] Anims embarquees: ", _anim_player.get_animation_list())
	if _skeleton == null:
		return
	if _anim_player == null and _character_root != null:
		print("[HeldItemViewModel] Aucun AnimationPlayer trouve, creation vide")
		_anim_player = AnimationPlayer.new()
		_anim_player.name = "AnimationPlayer"
		_character_root.add_child(_anim_player)
	if item_scene != null and item_follow_path.is_empty():
		_bone_attachment = BoneAttachment3D.new()
		var resolved_bone := _resolve_bone_name(hand_bone_name)
		if not resolved_bone.is_empty():
			_bone_attachment.bone_name = resolved_bone
		_skeleton.add_child(_bone_attachment)
		_item_root = item_scene.instantiate() as Node3D
		if _item_root:
			_bone_attachment.add_child(_item_root)
			_item_root.transform = item_offset
	if idle_anim_source != null:
		_inject_idle_from_source()
	_apply_character_texture()
	_apply_item_material()
	_play_idle()

func _clear_children() -> void:
	if _character_root and is_instance_valid(_character_root):
		_character_root.queue_free()
	if _bone_attachment and is_instance_valid(_bone_attachment):
		_bone_attachment.queue_free()
	if _item_root and is_instance_valid(_item_root):
		_item_root.queue_free()
	_character_root = null
	_item_root = null
	_skeleton = null
	_bone_attachment = null
	_anim_player = null

func _update_item_transform() -> void:
	if _item_root and is_instance_valid(_item_root):
		_item_root.transform = item_offset

func _update_character_transform() -> void:
	if _character_root and is_instance_valid(_character_root):
		_character_root.transform = character_offset

func _inject_idle_from_source() -> void:
	if _anim_player == null:
		return
	var source := idle_anim_source.instantiate()
	var src_player := _find_anim_player(source)
	if src_player == null:
		source.queue_free()
		return
	var names := src_player.get_animation_list()
	if names.is_empty():
		source.queue_free()
		return
	var src_anim := src_player.get_animation(names[0])
	if src_anim == null:
		source.queue_free()
		return
	var anim := src_anim.duplicate(true) as Animation
	anim.loop_mode = Animation.LOOP_LINEAR
	var lib := _get_or_create_library()
	if lib.has_animation("idle_override"):
		lib.remove_animation("idle_override")
	lib.add_animation("idle_override", anim)
	idle_animation = "idle_override"
	source.queue_free()

func _get_or_create_library() -> AnimationLibrary:
	var key := StringName("")
	if _anim_player.has_animation_library(key):
		return _anim_player.get_animation_library(key)
	var lib := AnimationLibrary.new()
	_anim_player.add_animation_library(key, lib)
	return lib

func _play_idle() -> void:
	if _anim_player == null:
		return
	var target := idle_animation
	if not _anim_player.has_animation(target):
		var names := _anim_player.get_animation_list()
		print("[HeldItemViewModel] Animations dispo: ", names)
		if names.is_empty():
			return
		target = names[0]
	var anim := _anim_player.get_animation(target)
	if anim:
		anim.loop_mode = Animation.LOOP_LINEAR
	_anim_player.play(target)

func shoot() -> void:
	if _anim_player != null and not attack_animation.is_empty() and _anim_player.has_animation(attack_animation):
		_play_attack_animation()
		return
	if _skeleton == null:
		return
	if _swing_tween != null and _swing_tween.is_running():
		return
	var resolved := _resolve_bone_name(swing_bone_name)
	if resolved.is_empty():
		return
	var idx := _skeleton.find_bone(resolved)
	if idx < 0:
		return
	_swing_bone_idx = idx
	_swing_rest_rotation = _skeleton.get_bone_pose_rotation(idx)
	if _anim_player != null and _anim_player.is_playing():
		_anim_player.pause()
	var swung := _swing_rest_rotation * Quaternion(swing_axis.normalized(), deg_to_rad(swing_angle_deg))
	_swing_tween = create_tween()
	_swing_tween.tween_method(_set_swing_slerp.bind(_swing_rest_rotation, swung), 0.0, 1.0, swing_down_time)
	_swing_tween.tween_method(_set_swing_slerp.bind(swung, _swing_rest_rotation), 0.0, 1.0, swing_return_time)
	_swing_tween.tween_callback(_finish_swing)

func _play_attack_animation() -> void:
	if _anim_player.current_animation == attack_animation and _anim_player.is_playing():
		return
	var anim := _anim_player.get_animation(attack_animation)
	if anim:
		anim.loop_mode = Animation.LOOP_NONE
	if not _anim_player.animation_finished.is_connected(_on_attack_finished):
		_anim_player.animation_finished.connect(_on_attack_finished, CONNECT_ONE_SHOT)
	_anim_player.play(attack_animation)

func _on_attack_finished(anim_name: StringName) -> void:
	if String(anim_name) == attack_animation:
		_play_idle()

func _set_swing_slerp(t: float, from: Quaternion, to: Quaternion) -> void:
	if _skeleton == null or _swing_bone_idx < 0:
		return
	_skeleton.set_bone_pose_rotation(_swing_bone_idx, from.slerp(to, t))

func _finish_swing() -> void:
	_swing_bone_idx = -1
	if _anim_player != null:
		_play_idle()

func _resolve_bone_name(requested: String) -> String:
	if _skeleton == null:
		return ""
	if _skeleton.find_bone(requested) >= 0:
		return requested
	var alt := requested.replace(":", "_") if requested.contains(":") else requested.replace("_", ":")
	if _skeleton.find_bone(alt) >= 0:
		return alt
	var lower_target := requested.to_lower().replace(":", "").replace("_", "")
	for i in range(_skeleton.get_bone_count()):
		var name := _skeleton.get_bone_name(i)
		var normalized := name.to_lower().replace(":", "").replace("_", "")
		if normalized.ends_with(lower_target):
			return name
	return ""

func _apply_item_material() -> void:
	if item_follow_path.is_empty():
		return
	var node := get_node_or_null(item_follow_path)
	if node == null:
		return
	if item_albedo == null and item_normal == null and item_metallic_roughness == null:
		return
	var mat := StandardMaterial3D.new()
	if item_albedo != null:
		mat.albedo_texture = item_albedo
	if item_normal != null:
		mat.normal_enabled = true
		mat.normal_texture = item_normal
	if item_metallic_roughness != null:
		mat.metallic_texture = item_metallic_roughness
		mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		mat.roughness_texture = item_metallic_roughness
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	_assign_material_recursive(node, mat)

func _apply_character_texture() -> void:
	if _character_root == null or not is_instance_valid(_character_root):
		return
	if character_texture == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = character_texture
	_assign_material_recursive(_character_root, mat)

func _assign_material_recursive(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var surface_count := mi.get_surface_override_material_count()
		for i in range(surface_count):
			mi.set_surface_override_material(i, mat)
	for child in node.get_children():
		_assign_material_recursive(child, mat)

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found
	return null

func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_anim_player(child)
		if found:
			return found
	return null
