extends Control
class_name StatsDisplay

var health: float = 100.0
var hunger: float = 100.0
var thirst: float = 100.0

const UNITS: int = 10       # icons per stat
const W: int = 9            # icon pixel width (before scale)
const H: int = 8            # icon pixel height
const S: int = 2            # pixel scale
const GAP: int = 1          # gap between icons
const ROW_GAP: int = 3      # gap between rows

func _ready() -> void:
	custom_minimum_size = Vector2(
		(W * S + GAP) * UNITS,
		(H * S + ROW_GAP) * 3
	)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_stats(h: float, food: float, water: float) -> void:
	health = h
	hunger = food
	thirst = water
	queue_redraw()

func _draw() -> void:
	var row_h: int = H * S + ROW_GAP
	_draw_hearts(0)
	_draw_food(row_h)
	_draw_water(row_h * 2)

func _draw_hearts(oy: int) -> void:
	var full := Color(0.93, 0.12, 0.12)
	var empty := Color(0.25, 0.06, 0.06)
	var units: float = health / (100.0 / UNITS)
	for i in range(UNITS):
		var x: int = i * (W * S + GAP)
		var t: float = clampf(units - i, 0.0, 1.0)
		_heart(x, oy, full.lerp(empty, 1.0 - t))

func _draw_food(oy: int) -> void:
	var full := Color(0.91, 0.56, 0.20)
	var empty := Color(0.22, 0.12, 0.04)
	var units: float = hunger / (100.0 / UNITS)
	for i in range(UNITS):
		var x: int = i * (W * S + GAP)
		var t: float = clampf(units - i, 0.0, 1.0)
		_drumstick(x, oy, full.lerp(empty, 1.0 - t))

func _draw_water(oy: int) -> void:
	var full := Color(0.24, 0.60, 0.97)
	var empty := Color(0.05, 0.10, 0.25)
	var units: float = thirst / (100.0 / UNITS)
	for i in range(UNITS):
		var x: int = i * (W * S + GAP)
		var t: float = clampf(units - i, 0.0, 1.0)
		_drop(x, oy, full.lerp(empty, 1.0 - t))

# ----- Shape drawers -----
# Each works on W*S wide × H*S tall canvas offset by (ox, oy)

func _px(ox: int, oy: int, col: int, row: int, c: Color, w: int = 1, h: int = 1) -> void:
	draw_rect(Rect2(ox + col * S, oy + row * S, w * S, h * S), c)

func _heart(ox: int, oy: int, c: Color) -> void:
	# 9 wide × 7 tall heart pattern
	#  .##..##.
	#  ########
	#  ########
	#  .######.
	#  ..####..
	#  ...##...
	#  ........ (empty row)
	var sh := _shine(c)
	_px(ox, oy, 1, 0, c, 2); _px(ox, oy, 5, 0, c, 2)
	_px(ox, oy, 0, 1, c, 8); _px(ox, oy, 0, 2, c, 8)
	_px(ox, oy, 1, 3, c, 6)
	_px(ox, oy, 2, 4, c, 4)
	_px(ox, oy, 3, 5, c, 2)
	# shine
	_px(ox, oy, 1, 1, sh, 2); _px(ox, oy, 5, 1, sh, 2)

func _drumstick(ox: int, oy: int, c: Color) -> void:
	# meat body (top) + handle (bottom)
	var sh := _shine(c)
	var bone := Color(0.84, 0.80, 0.72)
	# Meat
	_px(ox, oy, 2, 0, c, 4)
	_px(ox, oy, 1, 1, c, 6); _px(ox, oy, 1, 2, c, 6)
	_px(ox, oy, 2, 3, c, 4)
	# shine
	_px(ox, oy, 1, 1, sh, 2)
	# bone handle
	_px(ox, oy, 4, 4, bone); _px(ox, oy, 4, 5, bone)
	_px(ox, oy, 3, 6, bone, 2); _px(ox, oy, 4, 7, bone)

func _drop(ox: int, oy: int, c: Color) -> void:
	# teardrop shape, point at top
	var sh := _shine(c)
	_px(ox, oy, 4, 0, c)
	_px(ox, oy, 3, 1, c, 2)
	_px(ox, oy, 2, 2, c, 4)
	_px(ox, oy, 1, 3, c, 6); _px(ox, oy, 1, 4, c, 6); _px(ox, oy, 1, 5, c, 6)
	_px(ox, oy, 2, 6, c, 4)
	_px(ox, oy, 3, 7, c, 2)
	# shine
	_px(ox, oy, 2, 3, sh); _px(ox, oy, 2, 4, sh)

func _shine(c: Color) -> Color:
	return Color(minf(c.r + 0.38, 1.0), minf(c.g + 0.38, 1.0), minf(c.b + 0.38, 1.0), 1.0)
