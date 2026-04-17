extends StaticBody3D

@export var data: BuildableData
@export var max_health: float = 50.0
@export var disable_self_shading: bool = false
@export var debug_force_unshaded: bool = false

var current_health: float

func _ready() -> void:
	if data:
		max_health = data.health
	current_health = max_health
	add_to_group("placeable")
	if not has_meta(WorldSync.NET_ID_META) and WorldSync.is_host():
		WorldSync.register_entity(self)
	if disable_self_shading or debug_force_unshaded:
		call_deferred("_apply_lighting_tweaks")

func _apply_lighting_tweaks() -> void:
	var model := get_node_or_null("Model") as Node3D
	if model == null:
		return
	var count := 0
	count = _walk_meshes(model, count)
	print("[placeable] ", name, " touched ", count, " MeshInstance3D")

func _walk_meshes(node: Node, count: int) -> int:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if disable_self_shading:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if debug_force_unshaded:
			var surf_count := mi.mesh.get_surface_count() if mi.mesh else 0
			for i in surf_count:
				var src := mi.get_active_material(i)
				var mat := StandardMaterial3D.new()
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				if src is BaseMaterial3D and (src as BaseMaterial3D).albedo_texture:
					mat.albedo_texture = (src as BaseMaterial3D).albedo_texture
				mi.set_surface_override_material(i, mat)
		count += 1
	for c in node.get_children():
		count = _walk_meshes(c, count)
	return count

func take_damage(amount: float) -> void:
	if WorldSync.should_request_host():
		WorldSync.request_damage(WorldSync.get_net_id(self), amount)
		return
	current_health -= amount
	if current_health <= 0:
		_on_destroyed()

func repair(amount: float) -> void:
	current_health = minf(current_health + amount, max_health)

func _on_destroyed() -> void:
	var wagon := _find_wagon()
	if wagon and wagon.has_method("unregister_built_item"):
		wagon.unregister_built_item(self)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		WorldSync.replicate_despawn(WorldSync.get_net_id(self))
	queue_free()

func _find_wagon() -> Node3D:
	var parent := get_parent()
	while parent:
		if parent.is_in_group("wagon"):
			return parent as Node3D
		parent = parent.get_parent()
	return null
