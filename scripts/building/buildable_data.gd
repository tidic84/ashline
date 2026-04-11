class_name BuildableData
extends Resource

@export var id: String = ""
@export var display_name: String = ""
@export var description: String = ""
@export var icon: Texture2D
@export var scene: PackedScene
@export var category: Category = Category.WALL
@export var health: float = 50.0
@export var build_weight: int = 1
@export var cost: Dictionary = {}
@export var can_rotate: bool = true

enum Category {
	WALL,
	FLOOR,
	BARRICADE,
	TURRET,
	FURNITURE,
	UTILITY
}
