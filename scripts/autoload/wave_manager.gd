extends Node

signal wave_started(wave_number: int)
signal wave_completed(wave_number: int)
signal all_waves_completed
signal enemy_spawned(enemy: Node3D)
signal enemy_killed(enemy: Node3D)

var current_wave: int = 0
var enemies_alive: int = 0
var is_wave_active: bool = false
var spawn_timer: Timer
var enemies_to_spawn: int = 0
var spawn_interval: float = 2.0
var spawn_points: Array[Node3D] = []
var _enemy_scene_cache: Dictionary = {}

const ENEMY_SCENES: Dictionary = {
	"basic": "res://scenes/enemies/enemy_basic.tscn",
	"fast": "res://scenes/enemies/enemy_fast.tscn",
	"tank": "res://scenes/enemies/enemy_tank.tscn",
	"ranged": "res://scenes/enemies/enemy_ranged.tscn",
}

func _ready() -> void:
	spawn_timer = Timer.new()
	spawn_timer.one_shot = false
	spawn_timer.timeout.connect(_on_spawn_timer)
	add_child(spawn_timer)

func register_spawn_point(point: Node3D) -> void:
	spawn_points.append(point)

func start_wave() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	current_wave += 1
	is_wave_active = true
	enemies_to_spawn = _get_enemy_count_for_wave(current_wave)
	enemies_alive = 0
	spawn_interval = maxf(0.5, 2.0 - current_wave * 0.1)
	spawn_timer.wait_time = spawn_interval
	spawn_timer.start()
	wave_started.emit(current_wave)

func on_enemy_died(enemy: Node3D) -> void:
	enemies_alive -= 1
	enemy_killed.emit(enemy)
	GameManager.add_score(10 * current_wave)
	if enemies_alive <= 0 and enemies_to_spawn <= 0:
		_complete_wave()

func _complete_wave() -> void:
	is_wave_active = false
	spawn_timer.stop()
	wave_completed.emit(current_wave)

func _get_enemy_count_for_wave(wave: int) -> int:
	return 5 + wave * 3

func _get_enemy_types_for_wave(_wave: int) -> Array[String]:
	var types: Array[String] = ["basic"]
	if _wave >= 3:
		types.append("fast")
	if _wave >= 5:
		types.append("tank")
	if _wave >= 8:
		types.append("ranged")
	return types

func _on_spawn_timer() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	if enemies_to_spawn <= 0:
		spawn_timer.stop()
		return
	if spawn_points.is_empty():
		return
	var spawn_point: Node3D = spawn_points.pick_random()
	var enemy_types := _get_enemy_types_for_wave(current_wave)
	var enemy_type: String = enemy_types.pick_random()
	_spawn_enemy(enemy_type, spawn_point.global_position)
	enemies_to_spawn -= 1

func _spawn_enemy(type: String, pos: Vector3) -> void:
	if not ENEMY_SCENES.has(type):
		return
	var enemy_scene: PackedScene = _enemy_scene_cache.get(type)
	if enemy_scene == null:
		var enemy_path: String = ENEMY_SCENES[type]
		if not ResourceLoader.exists(enemy_path):
			return
		enemy_scene = load(enemy_path) as PackedScene
		if enemy_scene == null:
			return
		_enemy_scene_cache[type] = enemy_scene
	var enemy := enemy_scene.instantiate() as Node3D
	get_tree().current_scene.add_child(enemy)
	enemy.global_position = pos
	var net_id := WorldSync.register_entity(enemy)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_spawn_scene(net_id, ENEMY_SCENES[type], enemy.global_transform)
	enemies_alive += 1
	enemy_spawned.emit(enemy)
