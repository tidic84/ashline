extends Node

## Crée une jonction Y de test au démarrage pour valider le système d'aiguillage.
## Supprimer ce nœud de la scène une fois les tests terminés.
##
## Layout (vue de dessus) :
##
##        [départ train]
##             |
##       RailPath_TestMain
##             |
##          [jonction]  ← RailSwitch ici (appuyer E)
##          /       \
##  BranchA          BranchB
##  (gauche)         (droite)

const JUNCTION_POS := Vector3(0.0, 0.0, 25.0)
const SWITCH_OFFSET := Vector3(2.5, 0.5, 0.0)

func _ready() -> void:
	# Attendre que le terrain et les autoloads soient prêts
	await get_tree().process_frame
	await get_tree().process_frame
	_build_junction()


func _build_junction() -> void:
	var root := get_tree().current_scene

	# --- 3 chemins de rail ---
	var main_path := _make_path("RailPath_TestMain", [
		JUNCTION_POS + Vector3(0, 0, 50),  # début (le train vient de là)
		JUNCTION_POS,                       # fin = jonction
	])
	var branch_a := _make_path("RailPath_TestBranchA", [
		JUNCTION_POS,                        # début = jonction
		JUNCTION_POS + Vector3(-35, 0, -40), # part vers la gauche
	])
	var branch_b := _make_path("RailPath_TestBranchB", [
		JUNCTION_POS,                        # début = jonction
		JUNCTION_POS + Vector3(35, 0, -40),  # part vers la droite
	])

	for path in [main_path, branch_a, branch_b]:
		path.snap_to_ground = true
		root.add_child(path)

	# Laisser _ready() des RailPath s'exécuter (register_path, snap_to_ground)
	await get_tree().process_frame

	# --- Connexions manuelles à la jonction ---
	# End (1) de Main → Start (0) de BranchA et BranchB
	RailNetwork.add_connection(main_path, 1, branch_a, 0)
	RailNetwork.add_connection(main_path, 1, branch_b, 0)

	# --- Aiguillage interactif ---
	var switch_scene: PackedScene = load("res://scenes/rail/rail_switch.tscn")
	var rail_switch := switch_scene.instantiate()
	rail_switch.name = "RailSwitch_TestJunction"
	rail_switch.endpoint = 1  # Contrôle le bout (end) de main_path
	# rail_path sera défini après add_child via _path_node direct
	root.add_child(rail_switch)
	rail_switch.global_position = JUNCTION_POS + SWITCH_OFFSET
	rail_switch._path_node = main_path

	# --- Régénérer les meshes de rails ---
	for node in get_tree().get_nodes_in_group("terrain"):
		if node.has_method("rebuild_rail_meshes"):
			node.rebuild_rail_meshes()
			break

	print("[TestRailJunction] Jonction créée à ", JUNCTION_POS)
	print("  → Approcher la position Z=25, appuyer [E] sur le levier pour changer de voie.")
	print("  → Voie active par défaut : BranchA (gauche). [E] → BranchB (droite).")


func _make_path(path_name: String, points: Array[Vector3]) -> Node:
	var rail_scene: PackedScene = load("res://scenes/environment/rail_path.tscn")
	var path: Node = rail_scene.instantiate()
	path.name = path_name
	var curve := Curve3D.new()
	curve.bake_interval = 0.2
	for p in points:
		curve.add_point(p)
	path.curve = curve
	return path
