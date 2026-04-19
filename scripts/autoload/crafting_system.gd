extends Node

signal crafted(item_id: String)
signal craft_failed(item_id: String, reason: String)

const STATION_INVENTORY: String = "inventory"
const STATION_WORKBENCH: String = "workbench"

# Recipes are tagged with a "station" field:
#  - "inventory": craftable in-hand, for emergency & early game
#  - "workbench": requires a workbench, for real tools & upgrades
const RECIPES: Dictionary = {
	# ── Inventory (survival / emergency / bootstrap) ─────────────────────────
	"hammer_crude": {
		"display_name": "Marteau rudimentaire",
		"ingredients": {"branch": 1, "stone": 2, "fiber": 1},
		"preview_color": Color(0.60, 0.48, 0.22, 1.0),
		"craft_time": 2.0,
		"station": STATION_INVENTORY,
	},
	"bandage": {
		"display_name": "Bandage",
		"ingredients": {"fiber": 3},
		"preview_color": Color(0.92, 0.88, 0.78, 1.0),
		"craft_time": 1.5,
		"station": STATION_INVENTORY,
	},
	"primitive_flask": {
		"display_name": "Gourde primitive",
		"ingredients": {"fiber": 2, "metal_scrap": 1},
		"preview_color": Color(0.40, 0.55, 0.62, 1.0),
		"craft_time": 2.5,
		"station": STATION_INVENTORY,
	},
	"repair_wrap": {
		"display_name": "Kit de réparation",
		"ingredients": {"fiber": 2, "metal_scrap": 2},
		"preview_color": Color(0.70, 0.55, 0.30, 1.0),
		"craft_time": 2.0,
		"station": STATION_INVENTORY,
	},
	"torch": {
		"display_name": "Torche",
		"ingredients": {"branch": 1, "fiber": 2},
		"preview_color": Color(0.95, 0.52, 0.18, 1.0),
		"craft_time": 1.5,
		"station": STATION_INVENTORY,
	},

	# ── Workbench (real tools & progression) ────────────────────────────────
	"components": {
		"display_name": "Composants",
		"ingredients": {"metal_scrap": 3, "branch": 1},
		"preview_color": Color(0.76, 0.67, 0.39, 1.0),
		"craft_time": 3.0,
		"station": STATION_WORKBENCH,
	},
	"axe": {
		"display_name": "Hache",
		"ingredients": {"branch": 2, "stone": 3, "metal_scrap": 1},
		"preview_color": Color(0.78, 0.42, 0.20, 1.0),
		"craft_time": 4.0,
		"station": STATION_WORKBENCH,
	},
	"pickaxe": {
		"display_name": "Pioche",
		"ingredients": {"branch": 2, "stone": 2, "metal_scrap": 2},
		"preview_color": Color(0.55, 0.60, 0.65, 1.0),
		"craft_time": 6.0,
		"station": STATION_WORKBENCH,
	},
	"hammer": {
		"display_name": "Marteau renforcé",
		"ingredients": {"branch": 1, "metal_scrap": 3, "components": 1},
		"preview_color": Color(0.88, 0.72, 0.32, 1.0),
		"craft_time": 5.0,
		"station": STATION_WORKBENCH,
	},
}

func get_recipe_ids() -> Array[String]:
	var ids: Array[String] = []
	for recipe_id in RECIPES.keys():
		ids.append(recipe_id)
	ids.sort()
	return ids

func get_recipe_ids_for_station(station: String) -> Array[String]:
	var ids: Array[String] = []
	for recipe_id in RECIPES.keys():
		var recipe: Dictionary = RECIPES[recipe_id]
		if String(recipe.get("station", STATION_INVENTORY)) == station:
			ids.append(recipe_id)
	ids.sort()
	return ids

func get_recipe(recipe_id: String) -> Dictionary:
	if not RECIPES.has(recipe_id):
		return {}
	return RECIPES[recipe_id].duplicate(true)

func get_station(recipe_id: String) -> String:
	if not RECIPES.has(recipe_id):
		return ""
	return String(RECIPES[recipe_id].get("station", STATION_INVENTORY))

func can_craft(recipe_id: String) -> bool:
	if not RECIPES.has(recipe_id):
		return false
	var recipe: Dictionary = RECIPES[recipe_id]
	var ingredients: Dictionary = recipe.get("ingredients", {})
	return Inventory.has_items(ingredients)

func craft(recipe_id: String) -> bool:
	if WorldSync.should_request_host():
		WorldSync.request_craft(recipe_id)
		return false
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

func server_craft(peer_id: int, recipe_id: String) -> bool:
	if not RECIPES.has(recipe_id):
		craft_failed.emit(recipe_id, "Unknown recipe")
		return false
	var recipe: Dictionary = RECIPES[recipe_id]
	var ingredients: Dictionary = recipe.get("ingredients", {})
	if not Inventory.server_spend_items(peer_id, ingredients):
		craft_failed.emit(recipe_id, "Missing ingredients")
		return false
	Inventory.server_add_item(peer_id, recipe_id, 1)
	crafted.emit(recipe_id)
	return true
