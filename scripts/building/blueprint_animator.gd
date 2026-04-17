class_name BlueprintAnimator
extends RefCounted

const SHADER: Shader = preload("res://materials/blueprint.gdshader")
const DEFAULT_DURATION: float = 0.75
const ANIM_META: String = "_blueprint_anim"
const MESH_BUSY_META: String = "_blueprint_busy"

var _entries: Array = []

static func animate(root: Node3D, duration: float = DEFAULT_DURATION) -> void:
	if root == null or not is_instance_valid(root):
		return
	if not root.is_inside_tree():
		return
	if root.has_meta(ANIM_META):
		return
	var a := BlueprintAnimator.new()
	a._start(root, duration)

func _start(root: Node3D, duration: float) -> void:
	var all_meshes: Array = []
	_collect_meshes(root, all_meshes)
	var meshes: Array = []
	for m in all_meshes:
		if not m.has_meta(MESH_BUSY_META):
			meshes.append(m)
	if meshes.is_empty():
		return

	# Unified world-space vertical bounds so all sub-meshes reveal together.
	var bounds := AABB()
	var first := true
	for m in meshes:
		var local_aabb: AABB = m.get_aabb()
		var world_aabb: AABB = m.global_transform * local_aabb
		if first:
			bounds = world_aabb
			first = false
		else:
			bounds = bounds.merge(world_aabb)

	var min_y: float = bounds.position.y
	var size_y: float = maxf(bounds.size.y, 0.05)

	for m in meshes:
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		mat.set_shader_parameter("progress", 0.0)
		mat.set_shader_parameter("bounds_min_y", min_y)
		mat.set_shader_parameter("bounds_size_y", size_y)
		mat.set_shader_parameter("pulse_phase", 0.0)
		var count: int = m.get_surface_override_material_count()
		var prev: Array = []
		for i in range(count):
			prev.append(m.get_surface_override_material(i))
			m.set_surface_override_material(i, mat)
		m.set_meta(MESH_BUSY_META, true)
		_entries.append({"mesh": m, "prev": prev, "mat": mat})

	root.set_meta(ANIM_META, self)

	var tween := root.create_tween()
	tween.tween_method(_on_progress, 0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(_on_pulse, 0.0, 1.0, 0.2)
	tween.tween_callback(_finish.bind(root))

func _on_progress(v: float) -> void:
	for e in _entries:
		if is_instance_valid(e.mesh):
			e.mat.set_shader_parameter("progress", v)

func _on_pulse(v: float) -> void:
	for e in _entries:
		if is_instance_valid(e.mesh):
			e.mat.set_shader_parameter("pulse_phase", v)

func _finish(root: Node) -> void:
	for e in _entries:
		if not is_instance_valid(e.mesh):
			continue
		var prev: Array = e.prev
		for i in range(prev.size()):
			e.mesh.set_surface_override_material(i, prev[i])
		if e.mesh.has_meta(MESH_BUSY_META):
			e.mesh.remove_meta(MESH_BUSY_META)
	_entries.clear()
	if root and is_instance_valid(root) and root.has_meta(ANIM_META):
		root.remove_meta(ANIM_META)

func _collect_meshes(node: Node, out: Array) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		_collect_meshes(c, out)
