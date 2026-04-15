@tool
class_name BiomeScatterEntry
extends Resource


func _emit_if_changed(current_value: Variant, next_value: Variant) -> Variant:
	if current_value == next_value:
		return current_value
	emit_changed()
	return next_value


@export var mesh: Mesh:
	set(value):
		mesh = _emit_if_changed(mesh, value)

@export var mesh_scene: PackedScene:
	set(value):
		mesh_scene = _emit_if_changed(mesh_scene, value)

@export var billboard_mesh: Mesh:
	set(value):
		billboard_mesh = _emit_if_changed(billboard_mesh, value)

@export var billboard_scene: PackedScene:
	set(value):
		billboard_scene = _emit_if_changed(billboard_scene, value)

@export_range(0.0, 1000.0, 0.01, "or_greater") var probability: float = 1.0:
	set(value):
		probability = _emit_if_changed(probability, maxf(value, 0.0))

@export_range(0.0, 100000.0, 0.1, "or_greater") var billboard_lod_distance: float = 60.0:
	set(value):
		billboard_lod_distance = _emit_if_changed(billboard_lod_distance, maxf(value, 0.0))

@export var scale_min: Vector3 = Vector3.ONE:
	set(value):
		scale_min = _emit_if_changed(scale_min, value)

@export var scale_max: Vector3 = Vector3.ONE:
	set(value):
		scale_max = _emit_if_changed(scale_max, value)

@export var harvest_enabled := false:
	set(value):
		harvest_enabled = _emit_if_changed(harvest_enabled, value)

@export var harvest_drop_item_id: String = "":
	set(value):
		harvest_drop_item_id = _emit_if_changed(harvest_drop_item_id, value)

@export_range(1, 999, 1, "or_greater") var harvest_amount_min: int = 1:
	set(value):
		harvest_amount_min = _emit_if_changed(harvest_amount_min, maxi(value, 1))

@export_range(1, 999, 1, "or_greater") var harvest_amount_max: int = 1:
	set(value):
		harvest_amount_max = _emit_if_changed(harvest_amount_max, maxi(value, 1))

@export_range(1, 20, 1, "or_greater") var harvest_hits_to_harvest: int = 1:
	set(value):
		harvest_hits_to_harvest = _emit_if_changed(harvest_hits_to_harvest, maxi(value, 1))

@export var harvest_required_tool_id: String = "":
	set(value):
		harvest_required_tool_id = _emit_if_changed(harvest_required_tool_id, value)

@export var harvest_interact_label: String = "Harvest":
	set(value):
		harvest_interact_label = _emit_if_changed(harvest_interact_label, value)

@export var harvest_target_name: String = "":
	set(value):
		harvest_target_name = _emit_if_changed(harvest_target_name, value)
