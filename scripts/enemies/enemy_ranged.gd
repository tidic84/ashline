extends EnemyBase

@export var projectile_speed: float = 20.0

func _ready() -> void:
	max_health = 40.0
	move_speed = 3.0
	damage = 12.0
	attack_range = 15.0
	attack_cooldown = 2.0
	loot_value = 20
	super._ready()

func _move_towards_target(direction: Vector3, _delta: float) -> void:
	# Stop moving when in range
	var dist_to_target := 0.0
	if target and is_instance_valid(target):
		dist_to_target = global_position.distance_to(target.global_position)

	if dist_to_target > attack_range * 0.8:
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
	else:
		velocity.x = 0
		velocity.z = 0

	if direction.length() > 0.01:
		look_at(global_position + direction, Vector3.UP)

func _attack() -> void:
	if target == null or not is_instance_valid(target):
		return
	# Raycast-based ranged attack
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * 1.0
	var to := target.global_position + Vector3.UP * 0.5
	var query := PhysicsRayQueryParameters3D.create(from, to, 23) # World + Player + Train
	query.exclude = [get_rid()]
	var result := space.intersect_ray(query)
	if result and result.collider and result.collider.has_method("take_damage"):
		result.collider.take_damage(damage)
	_attack_effect()
