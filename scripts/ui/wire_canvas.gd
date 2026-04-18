extends Control

const _C_WIRE := Color(0.45, 0.75, 1.00, 0.38)

var wires: Array = []

func _draw() -> void:
	for w in wires:
		var a: Vector2 = w[0]
		var b: Vector2 = w[1]
		var mid := Vector2(b.x, a.y)
		_draw_dashed(a, mid)
		_draw_dashed(mid, b)
		var seg := b - mid
		if seg.length_squared() > 0.01:
			var dir  := seg.normalized() * 8.0
			var perp := Vector2(-dir.y, dir.x) * 0.4
			draw_line(b, b - dir + perp, _C_WIRE, 1.5)
			draw_line(b, b - dir - perp, _C_WIRE, 1.5)

func _draw_dashed(a: Vector2, b: Vector2) -> void:
	var total := a.distance_to(b)
	if total < 0.5:
		return
	var dir := (b - a) / total
	var t   := 0.0
	while t < total:
		var t_end := minf(t + 6.0, total)
		draw_line(a + dir * t, a + dir * t_end, _C_WIRE, 1.5)
		t += 10.0
