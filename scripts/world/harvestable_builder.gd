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


static func _spawn_glb(body: StaticBody3D, path: String, rng: RandomNumberGenerator, scale_range: Vector2 = Vector2(1.0, 1.0), y_offset: float = 0.0, random_rot: bool = true) -> Node3D:
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_warning("HarvestableBuilder: missing model %s" % path)
		return null
	var inst: Node3D = packed.instantiate() as Node3D
	var s: float = rng.randf_range(scale_range.x, scale_range.y)
	inst.scale = Vector3(s, s, s)
	if random_rot:
		inst.rotation.y = rng.randf_range(0.0, TAU)
	inst.position.y = y_offset
	body.add_child(inst)
	return inst


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
