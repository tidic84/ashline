extends Node3D

@export var weapon_name: String = "Pistol"
@export var damage: float = 20.0
@export var fire_rate: float = 0.3
@export var reload_time: float = 1.5
@export var mag_size: int = 12
@export var max_ammo: int = 60
@export var weapon_range: float = 100.0
@export var spread: float = 0.02

var current_ammo: int
var reserve_ammo: int
var can_shoot: bool = true
var is_reloading: bool = false

@onready var raycast: RayCast3D = $RayCast3D
@onready var muzzle: Marker3D = $Muzzle
@onready var fire_timer: Timer = $FireTimer
@onready var reload_timer: Timer = $ReloadTimer
@onready var anim: AnimationPlayer = get_node_or_null("AnimationPlayer") as AnimationPlayer

func _ready() -> void:
	current_ammo = mag_size
	reserve_ammo = max_ammo
	fire_timer.wait_time = fire_rate
	fire_timer.one_shot = true
	fire_timer.timeout.connect(func(): can_shoot = true)
	reload_timer.wait_time = reload_time
	reload_timer.one_shot = true
	reload_timer.timeout.connect(_finish_reload)
	play_anim("equip")

func play_anim(name: String) -> void:
	if anim == null or not anim.has_animation(name):
		return
	anim.play(name)

func play_idle() -> void:
	if anim == null or not anim.has_animation("idle"):
		return
	if anim.current_animation == "idle" and anim.is_playing():
		return
	anim.play("idle")

func shoot() -> void:
	if not can_shoot or is_reloading or current_ammo <= 0:
		if current_ammo <= 0:
			reload()
		return

	current_ammo -= 1
	can_shoot = false
	fire_timer.start()
	play_anim("fire")

	var ray_origin := raycast.global_position
	var ray_dir := -raycast.global_basis.z
	ray_dir += Vector3(
		randf_range(-spread, spread),
		randf_range(-spread, spread),
		randf_range(-spread, spread)
	)

	raycast.target_position = Vector3(0, 0, -weapon_range)
	raycast.force_raycast_update()

	if raycast.is_colliding():
		var collider: Object = raycast.get_collider()
		var hit_point := raycast.get_collision_point()
		if collider.has_method("take_damage"):
			collider.take_damage(damage)
		_spawn_hit_effect(hit_point)

	_play_shoot_effects()

func reload() -> void:
	if is_reloading or current_ammo == mag_size or reserve_ammo <= 0:
		return
	is_reloading = true
	reload_timer.start()
	play_anim("reload")

func _finish_reload() -> void:
	var needed := mag_size - current_ammo
	var available := mini(needed, reserve_ammo)
	current_ammo += available
	reserve_ammo -= available
	is_reloading = false
	play_idle()

func _process(_delta: float) -> void:
	if anim == null or anim.is_playing():
		return
	play_idle()

func _play_shoot_effects() -> void:
	pass

func _spawn_hit_effect(_position: Vector3) -> void:
	pass
