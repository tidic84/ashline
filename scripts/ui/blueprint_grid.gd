extends Control

const _C_GRID  := Color(0.25, 0.50, 0.90, 0.18)
const _C_BKT   := Color(0.50, 0.78, 1.00, 0.55)
const _C_CROSS := Color(0.35, 0.62, 1.00, 0.12)
const _STEP    := 22

func _draw() -> void:
	var sz := size
	var x  := 0.0
	while x <= sz.x:
		draw_line(Vector2(x, 0), Vector2(x, sz.y), _C_GRID, 1.0)
		x += _STEP
	var y := 0.0
	while y <= sz.y:
		draw_line(Vector2(0, y), Vector2(sz.x, y), _C_GRID, 1.0)
		y += _STEP
	var blen := 18.0
	draw_line(Vector2(0, 0),       Vector2(blen, 0),         _C_BKT, 2.0)
	draw_line(Vector2(0, 0),       Vector2(0, blen),         _C_BKT, 2.0)
	draw_line(Vector2(sz.x, 0),    Vector2(sz.x - blen, 0),  _C_BKT, 2.0)
	draw_line(Vector2(sz.x, 0),    Vector2(sz.x, blen),      _C_BKT, 2.0)
	draw_line(Vector2(0, sz.y),    Vector2(blen, sz.y),      _C_BKT, 2.0)
	draw_line(Vector2(0, sz.y),    Vector2(0, sz.y - blen),  _C_BKT, 2.0)
	draw_line(Vector2(sz.x, sz.y), Vector2(sz.x-blen, sz.y), _C_BKT, 2.0)
	draw_line(Vector2(sz.x, sz.y), Vector2(sz.x, sz.y-blen), _C_BKT, 2.0)
	draw_line(Vector2(sz.x*0.5, 0),  Vector2(sz.x*0.5, sz.y), _C_CROSS, 1.0)
	draw_line(Vector2(0, sz.y*0.5),  Vector2(sz.x, sz.y*0.5), _C_CROSS, 1.0)
