extends CharacterBody3D
class_name EnemyBase

signal died

@export var max_health: float = 50.0
@export var move_speed: float = 4.0
@export var damage: float = 10.0
@export var attack_range: float = 2.0
@export var attack_cooldown: float = 1.0
@export var loot_value: int = 10
@export var knockback_resistance: float = 0.0

static var _group_cache_frame: int = -1
static var _cached_wagons: Array[Node3D] = []
static var _cached_players: Array[Node3D] = []

var current_health: float
var target: Node3D = null
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var attack_timer: float = 0.0
var is_dead: bool = false
var target_refresh_timer: float = 0.0

const TARGET_REFRESH_INTERVAL: float = 0.5

func _ready() -> void:
	current_health = max_health
	add_to_group("enemy")
	if not has_meta(WorldSync.NET_ID_META) and WorldSync.is_host():
		WorldSync.register_entity(self)
	collision_layer = 4
	collision_mask = 19 # World + Player + Train
	_find_target()

func _physics_process(delta: float) -> void:
	if is_dead:
		return

	if not is_on_floor():
		velocity.y -= gravity * delta

	# Don't find target every frame
	target_refresh_timer -= delta
	if target_refresh_timer <= 0:
		_find_target()
		target_refresh_timer = TARGET_REFRESH_INTERVAL

	if target == null or not is_instance_valid(target):
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return

	var to_target := target.global_position - global_position
	to_target.y = 0
	var distance := to_target.length()

	if distance > attack_range:
		_move_towards_target(to_target.normalized(), delta)
	else:
		velocity.x = 0
		velocity.z = 0
		attack_timer -= delta
		if attack_timer <= 0:
			_attack()
			attack_timer = attack_cooldown

	move_and_slide()

func _move_towards_target(direction: Vector3, _delta: float) -> void:
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	if direction.length_squared() > 0.0001:
		var look_target := global_position + direction
		look_at(look_target, Vector3.UP)

func take_damage(amount: float) -> void:
	if WorldSync.should_request_host():
		WorldSync.request_damage(WorldSync.get_net_id(self), amount)
		return
	if is_dead:
		return
	current_health -= amount
	_on_hit()
	if current_health <= 0:
		die()

func die() -> void:
	is_dead = true
	died.emit()
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		WaveManager.on_enemy_died(self)
		GameManager.add_score(loot_value)
	_drop_loot()
	_death_effect()
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_despawn(WorldSync.get_net_id(self))
	queue_free()

func _attack() -> void:
	if target and target.has_method("take_damage"):
		target.take_damage(damage)
	_attack_effect()

func _on_hit() -> void:
	# Override for hit flash, sounds etc
	pass

func _death_effect() -> void:
	# Override for death particles, sounds
	pass

func _attack_effect() -> void:
	# Override for attack animation, sounds
	pass

func _drop_loot() -> void:
	# Override for loot drops
	pass

func _find_target() -> void:
	_refresh_target_group_cache()
	var min_dist_sq := INF
	target = null

	# Priority: closest wagon or placeable
	for wagon in _cached_wagons:
		var dist_sq := global_position.distance_squared_to(wagon.global_position)
		if dist_sq < min_dist_sq:
			min_dist_sq = dist_sq
			target = wagon

	# Players get priority if much closer
	for player in _cached_players:
		var dist_sq := global_position.distance_squared_to(player.global_position)
		if dist_sq < min_dist_sq * 0.36:
			min_dist_sq = dist_sq
			target = player

func _refresh_target_group_cache() -> void:
	var current_frame: int = Engine.get_physics_frames()
	if _group_cache_frame == current_frame:
		return
	_group_cache_frame = current_frame
	_cached_wagons.clear()
	_cached_players.clear()
	for wagon in get_tree().get_nodes_in_group("wagon"):
		if wagon is Node3D and is_instance_valid(wagon):
			_cached_wagons.append(wagon)
	for player in get_tree().get_nodes_in_group("player"):
		if player is Node3D and is_instance_valid(player):
			_cached_players.append(player)
