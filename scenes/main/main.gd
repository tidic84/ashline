extends Node3D

@onready var players_container: Node3D = $Players
@onready var resources_container: Node3D = $Resources
@onready var sun: DirectionalLight3D = $DirectionalLight3D
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var fps_controller: CharacterBody3D = $UP_FPSController_Prefab
@onready var terrain_node: Node3D = $Terrain

var player_scene: PackedScene = preload("res://scenes/player/player.tscn")

func _ready() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame

	_spawn_rocks()

	if multiplayer.has_multiplayer_peer():
		_spawn_multiplayer_players()

	Inventory.add_resource("wood", 1000)
	Inventory.add_resource("metal", 800)
	Inventory.add_resource("components", 400)
	Inventory.add_resource("fuel", 600)

	GraphicsSettings.apply_all()
	GameManager.start_game()


func _spawn_rocks() -> void:
	# Single MultiMeshInstance3D for all rocks — drastically reduces draw calls.
	# No physics bodies (terrain collision is enough).
	var rng := RandomNumberGenerator.new()
	rng.seed = 8877

	var half_size := 100.0
	var rock_count := 180

	# Build one shared low-poly rock mesh
	var rock_mesh := SphereMesh.new()
	rock_mesh.radius = 0.5
	rock_mesh.height = 0.7
	rock_mesh.radial_segments = 6
	rock_mesh.rings = 3

	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.42, 0.39, 0.35)
	rock_mat.roughness = 0.9
	rock_mat.metallic = 0.0
	rock_mesh.surface_set_material(0, rock_mat)

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = rock_mesh
	multimesh.instance_count = rock_count

	# terrain_node can be either TerrainPatch3D or TerrainStreamer — both
	# expose _sample_height(world_x, world_z).
	for i in range(rock_count):
		var x := rng.randf_range(-half_size, half_size)
		var z := rng.randf_range(-half_size, half_size)
		var y: float = 0.0
		if terrain_node != null and terrain_node.has_method("_sample_height"):
			y = terrain_node._sample_height(x, z)

		var is_boulder := rng.randf() < 0.18
		var sx: float
		var sy: float
		var sz: float
		if is_boulder:
			sx = rng.randf_range(2.0, 4.5)
			sy = rng.randf_range(1.5, 3.0)
			sz = rng.randf_range(2.0, 4.5)
		else:
			sx = rng.randf_range(0.5, 1.4)
			sy = rng.randf_range(0.3, 0.9)
			sz = rng.randf_range(0.5, 1.4)

		var basis := Basis().rotated(Vector3.UP, rng.randf_range(0.0, TAU))
		basis = basis.rotated(Vector3.RIGHT, rng.randf_range(-0.2, 0.2))
		basis = basis.rotated(Vector3.FORWARD, rng.randf_range(-0.15, 0.15))
		basis = basis.scaled(Vector3(sx, sy, sz))

		var pos := Vector3(x, y - sy * 0.2, z)
		multimesh.set_instance_transform(i, Transform3D(basis, pos))

		# Per-instance color variation: grey / dark / mossy tints
		var tint_roll := rng.randf()
		var col: Color
		if tint_roll < 0.5:
			col = Color(1.0, 1.0, 1.0)  # base grey
		elif tint_roll < 0.8:
			col = Color(0.75, 0.72, 0.68)  # darker
		else:
			col = Color(0.85, 0.95, 0.75)  # mossy
		multimesh.set_instance_color(i, col)

	var rocks_mmi := MultiMeshInstance3D.new()
	rocks_mmi.name = "Rocks"
	rocks_mmi.multimesh = multimesh
	rocks_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(rocks_mmi)


func _spawn_multiplayer_players() -> void:
	var spawn_offsets: Array[Vector3] = [
		Vector3(4, 0, 0),
		Vector3(-4, 0, 0),
		Vector3(4, 0, 3),
		Vector3(-4, 0, 3),
	]
	var idx: int = 0
	var base: Vector3 = fps_controller.global_position
	for peer_id in NetworkManager.players_info:
		var player: Node3D = player_scene.instantiate()
		player.name = str(peer_id)
		player.set_multiplayer_authority(peer_id)
		players_container.add_child(player)
		if idx < spawn_offsets.size():
			player.global_position = base + spawn_offsets[idx]
		idx += 1
