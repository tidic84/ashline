extends Control

var nodes_data: Array = []
var connections_data: Array = []


func _draw() -> void:
	if size == Vector2.ZERO:
		return
	for conn in connections_data:
		if not (conn is Array) or conn.size() != 2:
			continue
		var a_idx: int = int(conn[0])
		var b_idx: int = int(conn[1])
		if a_idx >= nodes_data.size() or b_idx >= nodes_data.size():
			continue
		var a: Dictionary = nodes_data[a_idx]
		var b: Dictionary = nodes_data[b_idx]
		var p1: Vector2 = Vector2(a["pos"].x, a["pos"].y) * size
		var p2: Vector2 = Vector2(b["pos"].x, b["pos"].y) * size
		var both_unlocked: bool = bool(a.get("unlocked", false)) and bool(b.get("unlocked", false))
		var col: Color
		if both_unlocked:
			col = Color(0.35, 0.85, 1.0, 0.9)
		else:
			col = Color(0.22, 0.55, 0.72, 0.45)
		draw_line(p1, p2, col, 2.0, true)
		# Small junction dots
		draw_circle(p1, 3.0, col)
		draw_circle(p2, 3.0, col)
