extends EnemyBase

func _ready() -> void:
	max_health = 30.0
	move_speed = 7.0
	damage = 8.0
	attack_range = 1.8
	attack_cooldown = 0.6
	loot_value = 15
	super._ready()
