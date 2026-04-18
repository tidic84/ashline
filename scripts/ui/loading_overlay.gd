extends Control

const SKY_TOP: Color = Color(0.79, 0.43, 0.22, 1.0)
const SKY_MID: Color = Color(0.44, 0.18, 0.09, 1.0)
const SKY_BOTTOM: Color = Color(0.10, 0.07, 0.05, 1.0)
const FOG_COLOR: Color = Color(0.91, 0.74, 0.52, 0.10)
const SILHOUETTE: Color = Color(0.02, 0.02, 0.02, 1.0)
const SILHOUETTE_SOFT: Color = Color(0.08, 0.08, 0.08, 0.82)
const EMBER: Color = Color(0.95, 0.70, 0.32, 0.92)

@onready var message_label: Label = $OverlayMargin/BottomStack/MessageLabel
@onready var progress_label: Label = $OverlayMargin/BottomStack/ProgressLabel

var _time: float = 0.0
var _progress_ratio: float = 0.0
var _show_progress: bool = false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
	queue_redraw()

func _process(delta: float) -> void:
	_time += delta
	queue_redraw()

func set_status(message: String, show_progress: bool = false, progress_ratio: float = 0.0) -> void:
	_show_progress = show_progress
	_progress_ratio = clampf(progress_ratio, 0.0, 1.0)
	message_label.text = message
	progress_label.visible = show_progress
	progress_label.text = "Chargement %d%%" % int(round(_progress_ratio * 100.0))

func _draw() -> void:
	var viewport_size := size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var track_y := viewport_size.y * 0.76
	var horizon_y := viewport_size.y * 0.48
	_draw_sky(viewport_size, horizon_y)
	_draw_moon(viewport_size)
	_draw_hills(viewport_size, track_y)
	_draw_fog(viewport_size, horizon_y, track_y)
	_draw_track(viewport_size, track_y)
	_draw_train(viewport_size, track_y)
	_draw_foreground(viewport_size, track_y)
	if _show_progress:
		_draw_progress(viewport_size)

func _draw_sky(viewport_size: Vector2, horizon_y: float) -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(viewport_size.x, horizon_y * 0.45)), SKY_TOP)
	draw_rect(Rect2(Vector2(0.0, horizon_y * 0.45), Vector2(viewport_size.x, horizon_y * 0.35)), SKY_MID)
	draw_rect(Rect2(Vector2(0.0, horizon_y * 0.80), Vector2(viewport_size.x, viewport_size.y - horizon_y * 0.80)), SKY_BOTTOM)

func _draw_moon(viewport_size: Vector2) -> void:
	var moon_center := Vector2(viewport_size.x * 0.82, viewport_size.y * 0.18)
	draw_circle(moon_center, viewport_size.y * 0.065, Color(0.99, 0.87, 0.66, 0.75))
	draw_circle(moon_center + Vector2(viewport_size.y * 0.018, -viewport_size.y * 0.008), viewport_size.y * 0.055, SKY_TOP)

func _draw_hills(viewport_size: Vector2, track_y: float) -> void:
	var back_hills := PackedVector2Array([
		Vector2(0.0, track_y - 110.0),
		Vector2(viewport_size.x * 0.12, track_y - 150.0),
		Vector2(viewport_size.x * 0.30, track_y - 132.0),
		Vector2(viewport_size.x * 0.48, track_y - 172.0),
		Vector2(viewport_size.x * 0.68, track_y - 142.0),
		Vector2(viewport_size.x * 0.86, track_y - 162.0),
		Vector2(viewport_size.x, track_y - 126.0),
		Vector2(viewport_size.x, viewport_size.y),
		Vector2(0.0, viewport_size.y),
	])
	draw_colored_polygon(back_hills, Color(0.11, 0.08, 0.07, 0.85))
	var front_hills := PackedVector2Array([
		Vector2(0.0, track_y - 54.0),
		Vector2(viewport_size.x * 0.14, track_y - 80.0),
		Vector2(viewport_size.x * 0.34, track_y - 60.0),
		Vector2(viewport_size.x * 0.56, track_y - 92.0),
		Vector2(viewport_size.x * 0.76, track_y - 72.0),
		Vector2(viewport_size.x, track_y - 48.0),
		Vector2(viewport_size.x, viewport_size.y),
		Vector2(0.0, viewport_size.y),
	])
	draw_colored_polygon(front_hills, Color(0.06, 0.05, 0.04, 0.96))

func _draw_fog(viewport_size: Vector2, horizon_y: float, track_y: float) -> void:
	draw_rect(
		Rect2(Vector2(0.0, horizon_y + 12.0), Vector2(viewport_size.x, track_y - horizon_y)),
		FOG_COLOR
	)

func _draw_track(viewport_size: Vector2, track_y: float) -> void:
	var base_offset := fposmod(_time * 310.0, 74.0)
	draw_rect(Rect2(0.0, track_y + 12.0, viewport_size.x, viewport_size.y - track_y), SILHOUETTE)
	for i in range(-2, int(ceil(viewport_size.x / 74.0)) + 3):
		var sleeper_x := i * 74.0 - base_offset
		draw_rect(Rect2(sleeper_x, track_y + 6.0, 48.0, 10.0), SILHOUETTE_SOFT)
	draw_line(Vector2(0.0, track_y + 4.0), Vector2(viewport_size.x, track_y + 4.0), SILHOUETTE_SOFT, 4.0)
	draw_line(Vector2(0.0, track_y + 15.0), Vector2(viewport_size.x, track_y + 15.0), SILHOUETTE_SOFT, 4.0)

func _draw_train(viewport_size: Vector2, track_y: float) -> void:
	var bob := sin(_time * 6.0) * 1.8
	var train_x := viewport_size.x * 0.24
	var body_y := track_y - 64.0 + bob
	draw_rect(Rect2(train_x, body_y + 18.0, 168.0, 34.0), SILHOUETTE)
	draw_rect(Rect2(train_x + 112.0, body_y - 18.0, 42.0, 42.0), SILHOUETTE)
	draw_rect(Rect2(train_x + 24.0, body_y - 2.0, 92.0, 20.0), SILHOUETTE)
	draw_rect(Rect2(train_x + 38.0, body_y - 18.0, 12.0, 18.0), SILHOUETTE)
	draw_rect(Rect2(train_x + 46.0, body_y - 28.0, 14.0, 14.0), SILHOUETTE)
	draw_rect(Rect2(train_x + 182.0, body_y + 12.0, 126.0, 40.0), SILHOUETTE)
	draw_rect(Rect2(train_x + 316.0, body_y + 12.0, 126.0, 40.0), SILHOUETTE)
	draw_line(Vector2(train_x + 210.0, body_y + 12.0), Vector2(train_x + 210.0, body_y - 8.0), SILHOUETTE, 4.0)
	draw_line(Vector2(train_x + 344.0, body_y + 12.0), Vector2(train_x + 344.0, body_y - 8.0), SILHOUETTE, 4.0)
	_draw_wheels(train_x, track_y + bob)
	_draw_smoke(Vector2(train_x + 54.0, body_y - 28.0))

func _draw_wheels(train_x: float, track_y: float) -> void:
	var wheel_centers := [
		Vector2(train_x + 30.0, track_y + 9.0),
		Vector2(train_x + 88.0, track_y + 9.0),
		Vector2(train_x + 148.0, track_y + 9.0),
		Vector2(train_x + 206.0, track_y + 9.0),
		Vector2(train_x + 284.0, track_y + 9.0),
		Vector2(train_x + 340.0, track_y + 9.0),
		Vector2(train_x + 418.0, track_y + 9.0),
	]
	var spoke_angle := _time * 8.0
	for wheel_center in wheel_centers:
		draw_circle(wheel_center, 18.0, SILHOUETTE)
		draw_circle(wheel_center, 6.0, SILHOUETTE_SOFT)
		var spoke_dir := Vector2(cos(spoke_angle), sin(spoke_angle)) * 12.0
		draw_line(wheel_center - spoke_dir, wheel_center + spoke_dir, SILHOUETTE_SOFT, 2.0)
		var cross_dir := Vector2(-spoke_dir.y, spoke_dir.x)
		draw_line(wheel_center - cross_dir, wheel_center + cross_dir, SILHOUETTE_SOFT, 2.0)
	draw_line(
		Vector2(train_x + 30.0, track_y + 9.0),
		Vector2(train_x + 148.0, track_y + 9.0 + sin(_time * 10.0) * 2.0),
		SILHOUETTE_SOFT,
		4.0
	)

func _draw_smoke(origin: Vector2) -> void:
	for i in range(5):
		var puff_time := _time * 0.85 + float(i) * 0.46
		var drift := fposmod(puff_time, 1.8)
		var puff_center := origin + Vector2(drift * 26.0, -drift * 34.0 - float(i) * 6.0)
		var radius := 10.0 + drift * 11.0
		draw_circle(puff_center, radius, Color(0.04, 0.04, 0.04, 0.34))

func _draw_foreground(viewport_size: Vector2, track_y: float) -> void:
	var post_offset := fposmod(_time * 220.0, 260.0)
	for i in range(-1, int(ceil(viewport_size.x / 260.0)) + 2):
		var post_x := i * 260.0 - post_offset
		draw_rect(Rect2(post_x, track_y - 120.0, 8.0, 120.0), SILHOUETTE)
		draw_line(Vector2(post_x, track_y - 112.0), Vector2(post_x + 68.0, track_y - 122.0), SILHOUETTE, 3.0)
	var bush_offset := fposmod(_time * 170.0, 160.0)
	for i in range(-2, int(ceil(viewport_size.x / 160.0)) + 3):
		var bush_x := i * 160.0 - bush_offset
		var bush := PackedVector2Array([
			Vector2(bush_x, track_y + 18.0),
			Vector2(bush_x + 16.0, track_y - 2.0),
			Vector2(bush_x + 34.0, track_y + 10.0),
			Vector2(bush_x + 56.0, track_y - 14.0),
			Vector2(bush_x + 86.0, track_y + 18.0),
		])
		draw_polyline(bush, SILHOUETTE, 4.0, true)

func _draw_progress(viewport_size: Vector2) -> void:
	var bar_width: float = minf(viewport_size.x * 0.32, 420.0)
	var bar_height := 10.0
	var bar_position := Vector2((viewport_size.x - bar_width) * 0.5, viewport_size.y - 72.0)
	draw_rect(Rect2(bar_position, Vector2(bar_width, bar_height)), Color(1, 1, 1, 0.08), true)
	draw_rect(Rect2(bar_position, Vector2(bar_width * _progress_ratio, bar_height)), EMBER, true)
