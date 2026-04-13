extends Node

signal crafted(item_id: String)
signal craft_failed(item_id: String, reason: String)

const RECIPES: Dictionary = {
	"axe": {
		"display_name": "Axe",
		"ingredients": {"branch": 2, "stone": 3, "metal_scrap": 1},
		"preview_color": Color(0.78, 0.42, 0.20, 1.0),
	},
	"pickaxe": {
		"display_name": "Pickaxe",
		"ingredients": {"branch": 2, "stone": 2, "metal_scrap": 2},
		"preview_color": Color(0.55, 0.60, 0.65, 1.0),
	},
	"hammer": {
		"display_name": "Hammer",
		"ingredients": {"branch": 1, "stone": 2, "metal_scrap": 3},
		"preview_color": Color(0.88, 0.72, 0.32, 1.0),
	},
}

func get_recipe_ids() -> Array[String]:
	var ids: Array[String] = []
	for recipe_id in RECIPES.keys():
		ids.append(recipe_id)
	ids.sort()
	return ids

func get_recipe(recipe_id: String) -> Dictionary:
	if not RECIPES.has(recipe_id):
		return {}
	return RECIPES[recipe_id].duplicate(true)

func can_craft(recipe_id: String) -> bool:
	if not RECIPES.has(recipe_id):
		return false
	var recipe: Dictionary = RECIPES[recipe_id]
	var ingredients: Dictionary = recipe.get("ingredients", {})
	return Inventory.has_items(ingredients)

func craft(recipe_id: String) -> bool:
	if not RECIPES.has(recipe_id):
		craft_failed.emit(recipe_id, "Unknown recipe")
		return false
	if not can_craft(recipe_id):
		craft_failed.emit(recipe_id, "Missing ingredients")
		return false
	var recipe: Dictionary = RECIPES[recipe_id]
	var ingredients: Dictionary = recipe.get("ingredients", {})
	if not Inventory.spend_items(ingredients):
		craft_failed.emit(recipe_id, "Cannot spend ingredients")
		return false
	Inventory.add_item(recipe_id, 1)
	crafted.emit(recipe_id)
	return true
