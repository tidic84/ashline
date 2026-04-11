extends Node

signal resource_changed(resource_id: String, amount: int)
signal inventory_updated

enum ResourceType { WOOD, METAL, COMPONENTS, FUEL }

# Resource names for display
const RESOURCE_NAMES: Dictionary = {
	"wood": "Wood",
	"metal": "Metal",
	"components": "Components",
	"fuel": "Fuel",
}

var resources: Dictionary = {
	"wood": 0,
	"metal": 0,
	"components": 0,
	"fuel": 0,
}

func add_resource(resource_id: String, amount: int) -> void:
	if not resources.has(resource_id):
		return
	resources[resource_id] += amount
	resource_changed.emit(resource_id, resources[resource_id])
	inventory_updated.emit()

func remove_resource(resource_id: String, amount: int) -> bool:
	if not resources.has(resource_id):
		return false
	if resources[resource_id] < amount:
		return false
	resources[resource_id] -= amount
	resource_changed.emit(resource_id, resources[resource_id])
	inventory_updated.emit()
	return true

func has_resources(cost: Dictionary) -> bool:
	for res_id in cost:
		if not resources.has(res_id):
			return false
		if resources[res_id] < cost[res_id]:
			return false
	return true

func spend_resources(cost: Dictionary) -> bool:
	if not has_resources(cost):
		return false
	for res_id in cost:
		resources[res_id] -= cost[res_id]
		resource_changed.emit(res_id, resources[res_id])
	inventory_updated.emit()
	return true

func get_amount(resource_id: String) -> int:
	if resources.has(resource_id):
		return resources[resource_id]
	return 0
