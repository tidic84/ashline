extends EnemyBase

func _ready() -> void:
	max_health = 150.0
	move_speed = 2.0
	damage = 25.0
	attack_range = 2.5
	attack_cooldown = 1.5
	loot_value = 30
	knockback_resistance = 0.5
	super._ready()
