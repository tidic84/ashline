extends Control
class_name StatsDisplay

var health: float = 100.0
var hunger: float = 100.0
var thirst: float = 100.0

const MAX_STAT: float = 100.0

# Subnautica-inspired minimal survival meters.
const METER_RADIUS: float = 24.0
const RING_WIDTH: float = 7.0

const HEALTH_CENTER: Vector2 = Vector2(28.0, 30.0)
const FOOD_CENTER: Vector2 = Vector2(82.0, 30.0)
const WATER_CENTER: Vector2 = Vector2(136.0, 30.0)

const PANEL_SIZE: Vector2 = Vector2(164.0, 60.0)

func _ready() -> void:
	custom_minimum_size = PANEL_SIZE
	if size.x <= 0.0 or size.y <= 0.0:
		size = PANEL_SIZE
	z_index = 4
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

func set_stats(h: float, food: float, water: float) -> void:
	health = clampf(h, 0.0, MAX_STAT)
	hunger = clampf(food, 0.0, MAX_STAT)
	thirst = clampf(water, 0.0, MAX_STAT)
	queue_redraw()

func _draw() -> void:
	_draw_meter(
		HEALTH_CENTER,
		METER_RADIUS,
		health / MAX_STAT,
		Color(0.95, 0.42, 0.35, 1.0),
		Color(0.38, 0.12, 0.11, 1.0),
		RING_WIDTH,
		"health"
	)

	_draw_meter(
		FOOD_CENTER,
		METER_RADIUS,
		hunger / MAX_STAT,
		Color(0.95, 0.73, 0.23, 1.0),
		Color(0.33, 0.24, 0.09, 1.0),
		RING_WIDTH,
		"food"
	)

	_draw_meter(
		WATER_CENTER,
		METER_RADIUS,
		thirst / MAX_STAT,
		Color(0.37, 0.86, 0.97, 1.0),
		Color(0.10, 0.22, 0.32, 1.0),
		RING_WIDTH,
		"water"
	)

func _draw_meter(
	center: Vector2,
	radius: float,
	ratio: float,
	full_color: Color,
	empty_color: Color,
	ring_width: float,
	icon: String
) -> void:
	var r := clampf(ratio, 0.0, 1.0)
	var fill_angle := TAU * r
	var start_angle := -PI * 0.5

	_draw_arc_band(center, radius - ring_width * 0.5, start_angle, TAU, ring_width, empty_color)
	_draw_arc_band(center, radius - ring_width * 0.5, start_angle, fill_angle, ring_width, full_color)

	_draw_small_icon(icon, center)

func _draw_arc_band(center: Vector2, radius: float, start_angle: float, angle_len: float, width: float, color: Color) -> void:
	var segments := maxi(24, int(64.0 * absf(angle_len) / TAU))
	var points := PackedVector2Array()
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var a := start_angle + angle_len * t
		points.append(center + Vector2(cos(a), sin(a)) * radius)
	draw_polyline(points, color, width, true)

func _draw_small_icon(icon: String, center: Vector2) -> void:
	match icon:
		"health":
			_draw_heart(center, 8.0, Color.WHITE)
		"food":
			_draw_apple(center, 8.0, Color.WHITE)
		"water":
			_draw_drop(center, 8.0, Color.WHITE)
		_:
			pass

func _draw_heart(center: Vector2, s: float, color: Color) -> void:
	var pts := PackedVector2Array([
		center + Vector2(0.0, s * 0.65),
		center + Vector2(-s, -s * 0.2),
		center + Vector2(-s * 0.35, -s),
		center + Vector2(0.0, -s * 0.55),
		center + Vector2(s * 0.35, -s),
		center + Vector2(s, -s * 0.2)
	])
	draw_colored_polygon(pts, color)

func _draw_drop(center: Vector2, s: float, color: Color) -> void:
	var pts := PackedVector2Array([
		center + Vector2(0.0, -s),
		center + Vector2(-s * 0.7, -s * 0.1),
		center + Vector2(-s * 0.58, s * 0.72),
		center + Vector2(0.0, s),
		center + Vector2(s * 0.58, s * 0.72),
		center + Vector2(s * 0.7, -s * 0.1)
	])
	draw_colored_polygon(pts, color)

func _draw_apple(center: Vector2, s: float, color: Color) -> void:
	draw_circle(center + Vector2(-s * 0.28, 0.0), s * 0.56, color)
	draw_circle(center + Vector2(s * 0.28, 0.0), s * 0.56, color)
	draw_rect(Rect2(center + Vector2(-s * 0.68, -s * 0.06), Vector2(s * 1.36, s * 0.78)), color)
	draw_line(center + Vector2(0.0, -s * 0.7), center + Vector2(0.0, -s * 1.08), Color(0.60, 0.95, 0.60, 1.0), 2.0)
	draw_circle(center + Vector2(s * 0.42, -s * 0.92), s * 0.24, Color(0.60, 0.95, 0.60, 1.0))
