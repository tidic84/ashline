class_name HarvestableBuilder

# Instantiates realistic GLB visuals (+ collision) for resource nodes.

const TREE_VARIANTS: Array[String] = [
	"res://assets/models/nature/tree_default.glb",
	"res://assets/models/nature/tree_oak.glb",
	"res://assets/models/nature/tree_thin.glb",
]
const ROCK_SMALL_VARIANTS: Array[String] = [
	"res://assets/fab/stone_pack_a/obj/source/Stone_extracted/stone.obj",
	"res://assets/models/nature/rock_smallA.glb",
	"res://assets/models/nature/rock_smallB.glb",
]
const ROCK_LARGE: String = "res://assets/models/nature/rock_largeA.glb"
const LOG_MODEL: String = "res://assets/models/survival/resource-wood.glb"
const PLANKS_MODEL: String = "res://assets/models/survival/resource-planks.glb"
const STONE_PILE_MODEL: String = "res://assets/fab/stone_pack_b/fbx/source/StonePack001.fbx"
const BRANCH_MODEL: String = "res://assets/fab/tree_branch_b/glb/dry_tree_branch_beach01.glb"
const BRANCH_ALT_MODEL: String = "res://assets/fab/tree_branch_a/fbx/mid/Tree_Branch_pcsvQ_Mid.fbx"
const METAL_PANEL_MODEL: String = "res://assets/models/survival/metal-panel.glb"
const CRATE_MODEL: String = "res://assets/models/survival/box.glb"
const MODEL_ALBEDO_TEXTURES: Dictionary = {
	"res://assets/fab/stone_pack_a/obj/source/Stone_extracted/stone.obj": "res://assets/fab/stone_pack_a/obj/source/Stone_extracted/stone_BaseColor.jpg",
	"res://assets/fab/tree_branch_b/glb/dry_tree_branch_beach01.glb": "res://assets/fab/tree_branch_b/glb/dry_tree_branch_beach01_Dry_Tree_Branch_BeachD.png",
	"res://assets/fab/tree_branch_a/fbx/mid/Tree_Branch_pcsvQ_Mid.fbx": "res://assets/fab/tree_branch_a/fbx/mid/Tree_Branch_pcsvQ_Mid_2K_BaseColor.jpg",
}


static func _spawn_glb(body: StaticBody3D, path: String, rng: RandomNumberGenerator, scale_range: Vector2 = Vector2(1.0, 1.0), y_offset: float = 0.0, random_rot: bool = true) -> Node3D:
	var inst: Node3D = _instantiate_model(path)
	if inst == null:
		return null
	var s: float = rng.randf_range(scale_range.x, scale_range.y)
	inst.scale = Vector3(s, s, s)
	if random_rot:
		inst.rotation.y = rng.randf_range(0.0, TAU)
	body.add_child(inst)
	_apply_model_texture_overrides(path, inst)
	_align_instance_to_ground(inst, y_offset)
	return inst

static func _instantiate_model(path: String) -> Node3D:
	var model_resource: Resource = ResourceLoader.load(path)
	if model_resource == null:
		push_warning("HarvestableBuilder: missing model %s" % path)
		return null
	if model_resource is PackedScene:
		var inst: Node3D = (model_resource as PackedScene).instantiate() as Node3D
		if inst == null:
			push_warning("HarvestableBuilder: scene root is not Node3D for %s" % path)
		return inst
	if model_resource is Mesh:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = model_resource as Mesh
		return mesh_instance
	push_warning("HarvestableBuilder: unsupported model resource %s (%s)" % [path, model_resource.get_class()])
	return null


static func _apply_model_texture_overrides(model_path: String, inst: Node3D) -> void:
	var tex_path: String = MODEL_ALBEDO_TEXTURES.get(model_path, "")
	if tex_path.is_empty() or not ResourceLoader.exists(tex_path):
		return
	var tex: Texture2D = load(tex_path) as Texture2D
	if tex == null:
		return
	for mesh_inst in _gather_mesh_instances(inst):
		var mi := mesh_inst as MeshInstance3D
		if mi.mesh == null:
			continue
		for surf_idx in range(mi.mesh.get_surface_count()):
			var override_mat := StandardMaterial3D.new()
			override_mat.albedo_texture = tex
			override_mat.roughness = 1.0
			mi.set_surface_override_material(surf_idx, override_mat)


static func _align_instance_to_ground(inst: Node3D, y_offset: float = 0.0) -> void:
	var bounds: Variant = _compute_visual_bounds(inst, Transform3D.IDENTITY)
	if bounds == null:
		inst.position.y = y_offset
		return
	var aabb: AABB = bounds as AABB
	inst.position.y = y_offset - aabb.position.y


static func _compute_visual_bounds(node: Node, parent_xf: Transform3D) -> Variant:
	var current_xf := parent_xf
	if node is Node3D:
		current_xf = parent_xf * (node as Node3D).transform

	var merged: Variant = null
	if node is VisualInstance3D:
		var vis := node as VisualInstance3D
		merged = _transform_aabb(vis.get_aabb(), current_xf)

	for child in node.get_children():
		var child_node := child as Node
		if child_node == null:
			continue
		var child_bounds: Variant = _compute_visual_bounds(child_node, current_xf)
		if child_bounds == null:
			continue
		if merged == null:
			merged = child_bounds
		else:
			merged = (merged as AABB).merge(child_bounds as AABB)
	return merged


static func _transform_aabb(aabb: AABB, xf: Transform3D) -> AABB:
	var p: Vector3 = aabb.position
	var s: Vector3 = aabb.size
	var corners: Array[Vector3] = [
		xf * p,
		xf * (p + Vector3(s.x, 0.0, 0.0)),
		xf * (p + Vector3(0.0, s.y, 0.0)),
		xf * (p + Vector3(0.0, 0.0, s.z)),
		xf * (p + Vector3(s.x, s.y, 0.0)),
		xf * (p + Vector3(s.x, 0.0, s.z)),
		xf * (p + Vector3(0.0, s.y, s.z)),
		xf * (p + s),
	]
	var out := AABB(corners[0], Vector3.ZERO)
	for i in range(1, corners.size()):
		out = out.expand(corners[i])
	return out


static func _gather_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		var child_node := child as Node
		if child_node == null:
			continue
		out.append_array(_gather_mesh_instances(child_node))
	return out


static func build_tree(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	var variant: String = TREE_VARIANTS[rng.randi_range(0, TREE_VARIANTS.size() - 1)]
	_spawn_glb(body, variant, rng, Vector2(1.1, 1.7))

	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 3.2
	col.shape = cap
	col.position = Vector3(0, 1.6, 0)
	body.add_child(col)


static func build_log(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	_spawn_glb(body, LOG_MODEL, rng, Vector2(0.9, 1.2))

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.5, 0.45, 0.45)
	col.shape = box
	col.position = Vector3(0, 0.22, 0)
	body.add_child(col)


static func build_scrap(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	_spawn_glb(body, METAL_PANEL_MODEL, rng, Vector2(0.9, 1.15))

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 0.4, 0.8)
	col.shape = box
	col.position = Vector3(0, 0.2, 0)
	body.add_child(col)


static func build_components(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	_spawn_glb(body, CRATE_MODEL, rng, Vector2(0.9, 1.1))

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.7, 0.6, 0.7)
	col.shape = box
	col.position = Vector3(0, 0.3, 0)
	body.add_child(col)


static func build_branch_pile(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	var variant: String = BRANCH_MODEL if rng.randf() < 0.5 else BRANCH_ALT_MODEL
	_spawn_glb(body, variant, rng, Vector2(0.7, 1.0))

	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.35
	col.shape = sphere
	col.position = Vector3(0, 0.2, 0)
	body.add_child(col)


static func build_stone_small(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	var variant: String = ROCK_SMALL_VARIANTS[rng.randi_range(0, ROCK_SMALL_VARIANTS.size() - 1)]
	_spawn_glb(body, variant, rng, Vector2(0.9, 1.4))

	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.35
	col.shape = sphere
	col.position = Vector3(0, 0.2, 0)
	body.add_child(col)


static func build_rock_large(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	_spawn_glb(body, ROCK_LARGE, rng, Vector2(1.0, 1.5))

	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.9
	capsule.height = 1.6
	col.shape = capsule
	col.position = Vector3(0, 0.9, 0)
	body.add_child(col)
