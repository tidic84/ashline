class_name HarvestableBuilder

# Procedurally builds visual + collision for resource nodes.

static func build_tree(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	var trunk_height: float = rng.randf_range(2.2, 4.0)
	var trunk_radius: float = rng.randf_range(0.18, 0.3)
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.28, 0.18, 0.1)
	trunk_mat.roughness = 0.95

	var trunk := CSGCylinder3D.new()
	trunk.radius = trunk_radius
	trunk.height = trunk_height
	trunk.sides = 8
	trunk.material = trunk_mat
	trunk.position = Vector3(0, trunk_height / 2.0, 0)
	body.add_child(trunk)

	var foliage_mat := StandardMaterial3D.new()
	foliage_mat.albedo_color = Color(0.18, 0.38, 0.12)
	foliage_mat.roughness = 0.9

	# 3 foliage spheres stacked
	for i in range(3):
		var f := CSGSphere3D.new()
		f.radius = rng.randf_range(0.9, 1.4) * (1.0 - float(i) * 0.15)
		f.radial_segments = 10
		f.rings = 6
		f.material = foliage_mat
		f.position = Vector3(
			rng.randf_range(-0.15, 0.15),
			trunk_height + float(i) * 0.7,
			rng.randf_range(-0.15, 0.15)
		)
		body.add_child(f)

	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = trunk_radius + 0.1
	cap.height = trunk_height
	col.shape = cap
	col.position = Vector3(0, trunk_height / 2.0, 0)
	body.add_child(col)

static func build_log(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	var log_length: float = rng.randf_range(1.2, 2.0)
	var log_radius: float = rng.randf_range(0.18, 0.28)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.22, 0.13)
	mat.roughness = 0.95

	var log_mesh := CSGCylinder3D.new()
	log_mesh.radius = log_radius
	log_mesh.height = log_length
	log_mesh.sides = 8
	log_mesh.material = mat
	# Lie horizontally
	log_mesh.rotation.z = PI / 2.0
	log_mesh.position = Vector3(0, log_radius, 0)
	body.add_child(log_mesh)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(log_length, log_radius * 2.0, log_radius * 2.0)
	col.shape = box
	col.position = Vector3(0, log_radius, 0)
	body.add_child(col)

static func build_scrap(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.42, 0.4)
	mat.metallic = 0.85
	mat.roughness = 0.55

	# Stack of bent metal pieces
	var piece_count: int = rng.randi_range(2, 4)
	var max_y: float = 0.0
	for i in range(piece_count):
		var piece := CSGBox3D.new()
		var sx: float = rng.randf_range(0.5, 0.9)
		var sy: float = rng.randf_range(0.06, 0.12)
		var sz: float = rng.randf_range(0.4, 0.7)
		piece.size = Vector3(sx, sy, sz)
		piece.material = mat
		piece.position = Vector3(
			rng.randf_range(-0.1, 0.1),
			float(i) * 0.12 + sy / 2.0,
			rng.randf_range(-0.1, 0.1)
		)
		piece.rotation = Vector3(
			rng.randf_range(-0.2, 0.2),
			rng.randf_range(0.0, TAU),
			rng.randf_range(-0.2, 0.2)
		)
		body.add_child(piece)
		max_y = max(max_y, piece.position.y + sy)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, max_y + 0.1, 0.8)
	col.shape = box
	col.position = Vector3(0, (max_y + 0.1) / 2.0, 0)
	body.add_child(col)

static func build_components(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.45, 0.3)
	mat.metallic = 0.5
	mat.roughness = 0.6

	# A small crate with parts
	var crate := CSGBox3D.new()
	crate.size = Vector3(0.6, 0.5, 0.6)
	crate.material = mat
	crate.position = Vector3(0, 0.25, 0)
	body.add_child(crate)

	var bolt_mat := StandardMaterial3D.new()
	bolt_mat.albedo_color = Color(0.7, 0.65, 0.5)
	bolt_mat.metallic = 0.9
	bolt_mat.roughness = 0.4
	for i in range(3):
		var bolt := CSGCylinder3D.new()
		bolt.radius = 0.07
		bolt.height = 0.15
		bolt.sides = 6
		bolt.material = bolt_mat
		bolt.position = Vector3(
			rng.randf_range(-0.15, 0.15),
			0.55,
			rng.randf_range(-0.15, 0.15)
		)
		body.add_child(bolt)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.7, 0.6, 0.7)
	col.shape = box
	col.position = Vector3(0, 0.3, 0)
	body.add_child(col)

static func build_branch_pile(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.22, 0.12)
	mat.roughness = 0.95

	var branch_count: int = rng.randi_range(4, 7)
	for i in range(branch_count):
		var b := CSGCylinder3D.new()
		b.radius = rng.randf_range(0.02, 0.05)
		b.height = rng.randf_range(0.35, 0.65)
		b.sides = 6
		b.material = mat
		b.rotation = Vector3(
			rng.randf_range(-0.4, 0.4),
			rng.randf_range(0.0, TAU),
			rng.randf_range(-0.4, 0.4)
		)
		b.position = Vector3(
			rng.randf_range(-0.15, 0.15),
			rng.randf_range(0.04, 0.12),
			rng.randf_range(-0.15, 0.15)
		)
		body.add_child(b)

	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.28
	col.shape = sphere
	col.position = Vector3(0, 0.18, 0)
	body.add_child(col)

static func build_stone_small(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.46, 0.46, 0.48)
	mat.roughness = 0.9

	var rock_count: int = rng.randi_range(2, 4)
	for i in range(rock_count):
		var rock := CSGSphere3D.new()
		rock.radius = rng.randf_range(0.12, 0.2)
		rock.radial_segments = 8
		rock.rings = 6
		rock.material = mat
		rock.scale = Vector3(
			rng.randf_range(0.8, 1.3),
			rng.randf_range(0.65, 1.1),
			rng.randf_range(0.8, 1.3)
		)
		rock.position = Vector3(
			rng.randf_range(-0.14, 0.14),
			rng.randf_range(0.1, 0.22),
			rng.randf_range(-0.14, 0.14)
		)
		body.add_child(rock)

	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.3
	col.shape = sphere
	col.position = Vector3(0, 0.2, 0)
	body.add_child(col)

static func build_rock_large(body: StaticBody3D, rng: RandomNumberGenerator) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.38, 0.38, 0.4)
	mat.roughness = 0.92

	var main := CSGSphere3D.new()
	main.radius = rng.randf_range(0.7, 1.0)
	main.radial_segments = 10
	main.rings = 7
	main.material = mat
	main.scale = Vector3(
		rng.randf_range(0.9, 1.3),
		rng.randf_range(0.7, 1.1),
		rng.randf_range(0.9, 1.3)
	)
	main.position = Vector3(0, 0.8, 0)
	body.add_child(main)

	for i in range(3):
		var chunk := CSGSphere3D.new()
		chunk.radius = rng.randf_range(0.2, 0.35)
		chunk.material = mat
		chunk.position = Vector3(
			rng.randf_range(-0.45, 0.45),
			rng.randf_range(0.35, 0.85),
			rng.randf_range(-0.45, 0.45)
		)
		body.add_child(chunk)

	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.8
	capsule.height = 1.4
	col.shape = capsule
	col.position = Vector3(0, 0.9, 0)
	body.add_child(col)
