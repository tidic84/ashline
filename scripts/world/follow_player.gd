extends Node3D
class_name FollowPlayer

@export var target_path: NodePath
@export var follow_y := false
@export var y_offset := 0.0
@export var update_every := 0.1

var _target: Node3D
var _accum := 0.0


func _ready() -> void:
	if not target_path.is_empty():
		_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		_target = _find_player()


func _process(delta: float) -> void:
	_accum += delta
	if _accum < update_every:
		return
	_accum = 0.0
	if _target == null:
		_target = _find_player()
	if _target == null:
		return
	var p := _target.global_position
	if not follow_y:
		p.y = global_position.y + y_offset
	else:
		p.y += y_offset
	global_position = p


func _find_player() -> Node3D:
	var tree := get_tree()
	if tree == null:
		return null
	for group in ["player", "fps_player", "Player"]:
		var nodes := tree.get_nodes_in_group(group)
		for n in nodes:
			if n is Node3D:
				return n as Node3D
	var root := tree.current_scene
	if root == null:
		return null
	return _find_fps_controller(root)


func _find_fps_controller(node: Node) -> Node3D:
	if node.name.begins_with("UP_FPSController"):
		return node as Node3D
	for child in node.get_children():
		var found := _find_fps_controller(child)
		if found != null:
			return found
	return null
