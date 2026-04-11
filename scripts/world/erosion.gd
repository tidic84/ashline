class_name HydraulicErosion

# Particle-based hydraulic erosion simulation.
# Drops water particles that carve valleys, deposit sediment, and create natural-looking terrain.

const GRAVITY: float = 4.0
const EVAPORATE_RATE: float = 0.015
const DEPOSIT_RATE: float = 0.12
const ERODE_RATE: float = 0.25
const MIN_SLOPE: float = 0.01
const INERTIA: float = 0.3
const CAPACITY_FACTOR: float = 8.0
const MIN_VOLUME: float = 0.01
const MAX_LIFETIME: int = 90
const ERODE_RADIUS: int = 3

var _width: int
var _heights: PackedFloat32Array

static func erode(heights: PackedFloat32Array, width: int, iterations: int, seed_val: int) -> PackedFloat32Array:
	var e := HydraulicErosion.new()
	e._width = width
	e._heights = heights.duplicate()
	e._run(iterations, seed_val)
	return e._heights

func _run(iterations: int, seed_val: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	for i in range(iterations):
		_drop_particle(rng)

func _drop_particle(rng: RandomNumberGenerator) -> void:
	var px: float = rng.randf_range(2.0, float(_width - 3))
	var pz: float = rng.randf_range(2.0, float(_width - 3))
	var dx: float = 0.0
	var dz: float = 0.0
	var speed: float = 1.0
	var water: float = 1.0
	var sediment: float = 0.0

	for step in range(MAX_LIFETIME):
		var ix: int = int(px)
		var iz: int = int(pz)
		if ix < 1 or ix >= _width - 2 or iz < 1 or iz >= _width - 2:
			break

		var grad: Vector2 = _gradient(px, pz)
		dx = dx * INERTIA - grad.x * (1.0 - INERTIA)
		dz = dz * INERTIA - grad.y * (1.0 - INERTIA)

		var len: float = sqrt(dx * dx + dz * dz)
		if len < 0.0001:
			dx = rng.randf_range(-1.0, 1.0)
			dz = rng.randf_range(-1.0, 1.0)
			len = sqrt(dx * dx + dz * dz)
		dx /= len
		dz /= len

		var new_px: float = px + dx
		var new_pz: float = pz + dz
		var ni: int = int(new_px)
		var nj: int = int(new_pz)
		if ni < 1 or ni >= _width - 2 or nj < 1 or nj >= _width - 2:
			break

		var old_h: float = _interp(px, pz)
		var new_h: float = _interp(new_px, new_pz)
		var delta_h: float = new_h - old_h

		var capacity: float = maxf(-delta_h, MIN_SLOPE) * speed * water * CAPACITY_FACTOR

		if sediment > capacity or delta_h > 0.0:
			var deposit: float = 0.0
			if delta_h > 0.0:
				deposit = minf(sediment, delta_h)
			else:
				deposit = (sediment - capacity) * DEPOSIT_RATE
			sediment -= deposit
			_deposit_at(px, pz, deposit)
		else:
			var erode_amount: float = minf((capacity - sediment) * ERODE_RATE, -delta_h)
			_erode_at(px, pz, erode_amount)
			sediment += erode_amount

		speed = sqrt(maxf(speed * speed + delta_h * GRAVITY, 0.01))
		water *= (1.0 - EVAPORATE_RATE)
		if water < MIN_VOLUME:
			break

		px = new_px
		pz = new_pz

func _gradient(x: float, z: float) -> Vector2:
	var ix: int = int(x)
	var iz: int = int(z)
	var fx: float = x - float(ix)
	var fz: float = z - float(iz)
	var h00: float = _h(ix, iz)
	var h10: float = _h(ix + 1, iz)
	var h01: float = _h(ix, iz + 1)
	var h11: float = _h(ix + 1, iz + 1)
	var gx: float = lerpf(h10 - h00, h11 - h01, fz)
	var gz: float = lerpf(h01 - h00, h11 - h10, fx)
	return Vector2(gx, gz)

func _interp(x: float, z: float) -> float:
	var ix: int = int(x)
	var iz: int = int(z)
	var fx: float = x - float(ix)
	var fz: float = z - float(iz)
	return lerpf(
		lerpf(_h(ix, iz), _h(ix + 1, iz), fx),
		lerpf(_h(ix, iz + 1), _h(ix + 1, iz + 1), fx),
		fz
	)

func _h(i: int, j: int) -> float:
	return _heights[j * _width + i]

func _set_h(i: int, j: int, val: float) -> void:
	_heights[j * _width + i] = val

func _deposit_at(x: float, z: float, amount: float) -> void:
	var ix: int = int(x)
	var iz: int = int(z)
	var fx: float = x - float(ix)
	var fz: float = z - float(iz)
	_set_h(ix, iz, _h(ix, iz) + amount * (1.0 - fx) * (1.0 - fz))
	_set_h(ix + 1, iz, _h(ix + 1, iz) + amount * fx * (1.0 - fz))
	_set_h(ix, iz + 1, _h(ix, iz + 1) + amount * (1.0 - fx) * fz)
	_set_h(ix + 1, iz + 1, _h(ix + 1, iz + 1) + amount * fx * fz)

func _erode_at(x: float, z: float, amount: float) -> void:
	var cx: int = int(x)
	var cz: int = int(z)
	var total_weight: float = 0.0
	var weights: Array[float] = []
	var coords: Array[Vector2i] = []
	for dj in range(-ERODE_RADIUS, ERODE_RADIUS + 1):
		for di in range(-ERODE_RADIUS, ERODE_RADIUS + 1):
			var pi: int = cx + di
			var pj: int = cz + dj
			if pi < 0 or pi >= _width or pj < 0 or pj >= _width:
				continue
			var dist: float = sqrt(float(di * di + dj * dj))
			if dist > float(ERODE_RADIUS):
				continue
			var w: float = maxf(0.0, float(ERODE_RADIUS) - dist)
			weights.append(w)
			coords.append(Vector2i(pi, pj))
			total_weight += w
	if total_weight < 0.001:
		return
	for k in range(coords.size()):
		var frac: float = weights[k] / total_weight
		var idx: int = coords[k].y * _width + coords[k].x
		_heights[idx] = maxf(0.0, _heights[idx] - amount * frac)
