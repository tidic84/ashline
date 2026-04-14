extends Node

signal resource_changed(resource_id: String, amount: int)
signal inventory_updated
signal item_changed(item_id: String, amount: int)
signal hotbar_updated
signal selected_hotbar_changed(index: int, item_id: String)
signal survival_changed(health: float, hunger: float, thirst: float)
signal inventory_capacity_changed(used_slots: int, max_slots: int)

enum ResourceType { WOOD, METAL, COMPONENTS, FUEL }

const HOTBAR_SIZE: int = 9
const INVENTORY_SLOT_COUNT: int = 27
const MAX_STAT: float = 100.0
const MAX_INVENTORY_SLOTS: int = HOTBAR_SIZE + INVENTORY_SLOT_COUNT

const TOOL_ITEMS: Array[String] = ["axe", "pickaxe", "hammer"]

const ITEM_NAMES: Dictionary = {
	"wood": "Wood",
	"metal": "Metal",
	"components": "Components",
	"fuel": "Fuel",
	"branch": "Branch",
	"log": "Log",
	"stone": "Stone",
	"metal_scrap": "Metal Scrap",
	"axe": "Axe",
	"pickaxe": "Pickaxe",
	"hammer": "Hammer",
}

const ITEM_STACK_SIZES: Dictionary = {
	"wood": 200,
	"metal": 200,
	"components": 100,
	"fuel": 200,
	"branch": 100,
	"log": 100,
	"stone": 150,
	"metal_scrap": 100,
	"axe": 1,
	"pickaxe": 1,
	"hammer": 1,
}

const ITEM_ICON_COLORS: Dictionary = {
	"wood": Color(0.57, 0.36, 0.22, 1.0),
	"metal": Color(0.53, 0.56, 0.60, 1.0),
	"components": Color(0.76, 0.67, 0.39, 1.0),
	"fuel": Color(0.95, 0.53, 0.18, 1.0),
	"branch": Color(0.48, 0.30, 0.16, 1.0),
	"log": Color(0.40, 0.25, 0.14, 1.0),
	"stone": Color(0.52, 0.52, 0.56, 1.0),
	"metal_scrap": Color(0.45, 0.46, 0.49, 1.0),
	"axe": Color(0.74, 0.38, 0.28, 1.0),
	"pickaxe": Color(0.42, 0.62, 0.74, 1.0),
	"hammer": Color(0.84, 0.70, 0.30, 1.0),
}

# 3D model paths for inventory icon rendering. If missing, falls back to a flat colored tile.
const ITEM_MODELS: Dictionary = {
	"wood": "res://assets/models/survival/resource-wood.glb",
	"log": "res://assets/models/survival/resource-wood.glb",
	"branch": "res://assets/fab/tree_branch_b/glb/dry_tree_branch_beach01.glb",
	"stone": "res://assets/fab/stone_pack_a/obj/source/Stone_extracted/stone.obj",
	"metal": "res://assets/models/survival/metal-panel.glb",
	"metal_scrap": "res://assets/models/survival/metal-panel-screws.glb",
	"fuel": "res://assets/models/survival/barrel.glb",
	"components": "res://assets/models/survival/box.glb",
	"axe": "res://assets/fab/axe/fbx/AXE_01.fbx",
	"hammer": "res://assets/fab/hammer/fbx/source/Sledge Hammer_extracted/Sledge Hammer/SledgeHammer.fbx",
	"pickaxe": "res://assets/fab/pickaxe/SM_BasicPickaxe.fbx",
}

const ICON_TEXTURE_SIZE: Vector2i = Vector2i(96, 96)


const HARVEST_TO_ITEM: Dictionary = {
	"branch": {"wood": 1},
	"log": {"wood": 3},
	"metal_scrap": {"metal": 2},
}

var _slots: Array[Dictionary] = []
var _item_icons: Dictionary = {}

var selected_hotbar_index: int = 0

var health: float = MAX_STAT
var hunger: float = MAX_STAT
var thirst: float = MAX_STAT

var hunger_decay_per_second: float = 0.55
var thirst_decay_per_second: float = 0.8
var starvation_damage_per_second: float = 1.6
var dehydration_damage_per_second: float = 2.0
var health_regen_per_second: float = 0.3

func _ready() -> void:
	var total: int = get_total_slot_count()
	_slots.resize(total)
	for i in range(total):
		_slots[i] = _empty_slot()
	set_process(true)
	hotbar_updated.emit()
	selected_hotbar_changed.emit(selected_hotbar_index, get_selected_item())
	survival_changed.emit(health, hunger, thirst)
	inventory_capacity_changed.emit(get_used_slots(), MAX_INVENTORY_SLOTS)

func _process(delta: float) -> void:
	var old_health: float = health
	var old_hunger: float = hunger
	var old_thirst: float = thirst

	hunger = maxf(0.0, hunger - hunger_decay_per_second * delta)
	thirst = maxf(0.0, thirst - thirst_decay_per_second * delta)

	if hunger <= 0.0:
		health = maxf(0.0, health - starvation_damage_per_second * delta)
	if thirst <= 0.0:
		health = maxf(0.0, health - dehydration_damage_per_second * delta)
	if hunger > 40.0 and thirst > 40.0:
		health = minf(MAX_STAT, health + health_regen_per_second * delta)

	if not is_equal_approx(old_health, health) or not is_equal_approx(old_hunger, hunger) or not is_equal_approx(old_thirst, thirst):
		survival_changed.emit(health, hunger, thirst)

# Compatibility wrappers used by existing systems.
func add_resource(resource_id: String, amount: int) -> void:
	add_item(resource_id, amount)

func remove_resource(resource_id: String, amount: int) -> bool:
	return remove_item(resource_id, amount)

func has_resources(cost: Dictionary) -> bool:
	return has_items(cost)

func spend_resources(cost: Dictionary) -> bool:
	return spend_items(cost)

func get_amount(resource_id: String) -> int:
	return get_item_amount(resource_id)

func add_item(item_id: String, amount: int) -> void:
	if amount <= 0:
		return
	if not ITEM_NAMES.has(item_id):
		return

	var remaining: int = amount
	remaining = _fill_existing_stacks(item_id, remaining)
	remaining = _fill_empty_slots(item_id, remaining)

	var added: int = amount - remaining
	if added <= 0:
		return

	if HARVEST_TO_ITEM.has(item_id):
		var conversion: Dictionary = HARVEST_TO_ITEM[item_id]
		for converted_id in conversion:
			var converted_amount: int = int(conversion[converted_id]) * added
			if converted_amount > 0:
				add_item(converted_id, converted_amount)

	_auto_assign_tool_to_hotbar(item_id)
	_notify_inventory_changed()

func remove_item(item_id: String, amount: int) -> bool:
	if amount <= 0:
		return true
	if not has_item(item_id, amount):
		return false

	var remaining: int = amount
	for i in range(_slots.size() - 1, -1, -1):
		var slot := _slots[i]
		if slot.item_id != item_id:
			continue
		var take: int = mini(slot.amount, remaining)
		slot.amount -= take
		remaining -= take
		if slot.amount <= 0:
			_slots[i] = _empty_slot()
		else:
			_slots[i] = slot
		if remaining <= 0:
			break

	_notify_inventory_changed()
	return true

func has_item(item_id: String, amount: int = 1) -> bool:
	if amount <= 0:
		return true
	return get_item_amount(item_id) >= amount

func has_items(cost: Dictionary) -> bool:
	for item_id in cost:
		if not has_item(item_id, int(cost[item_id])):
			return false
	return true

func spend_items(cost: Dictionary) -> bool:
	if not has_items(cost):
		return false
	for item_id in cost:
		remove_item(item_id, int(cost[item_id]))
	_notify_inventory_changed()
	return true

func get_item_amount(item_id: String) -> int:
	var total: int = 0
	for slot in _slots:
		if slot.item_id == item_id:
			total += int(slot.amount)
	return total

func get_item_name(item_id: String) -> String:
	return ITEM_NAMES.get(item_id, item_id)

func get_stack_size(item_id: String) -> int:
	return int(ITEM_STACK_SIZES.get(item_id, 99))

func get_used_slots() -> int:
	var used: int = 0
	for slot in _slots:
		if not _is_slot_empty(slot):
			used += 1
	return used

func get_free_slots() -> int:
	return maxi(0, MAX_INVENTORY_SLOTS - get_used_slots())

func has_inventory_space_for(item_id: String, amount: int = 1) -> bool:
	if amount <= 0:
		return true
	return _max_addable_amount(item_id) >= amount

func get_total_slot_count() -> int:
	return HOTBAR_SIZE + INVENTORY_SLOT_COUNT

func get_inventory_slot_count() -> int:
	return INVENTORY_SLOT_COUNT

func get_slot_data(index: int) -> Dictionary:
	if index < 0 or index >= _slots.size():
		return _empty_slot()
	return _slots[index].duplicate(true)

func get_hotbar_slot_data(index: int) -> Dictionary:
	return get_slot_data(index)

func move_slot(source_index: int, target_index: int) -> bool:
	if not _is_valid_slot_index(source_index) or not _is_valid_slot_index(target_index):
		return false
	if source_index == target_index:
		return false

	var src := _slots[source_index]
	if _is_slot_empty(src):
		return false

	var dst := _slots[target_index]
	if _is_slot_empty(dst):
		_slots[target_index] = src
		_slots[source_index] = _empty_slot()
	elif dst.item_id == src.item_id:
		var stack_max: int = get_stack_size(dst.item_id)
		var room: int = maxi(0, stack_max - int(dst.amount))
		if room > 0:
			var transfer: int = mini(room, int(src.amount))
			dst.amount += transfer
			src.amount -= transfer
			_slots[target_index] = dst
			if src.amount <= 0:
				_slots[source_index] = _empty_slot()
			else:
				_slots[source_index] = src
		else:
			_slots[source_index] = dst
			_slots[target_index] = src
	else:
		_slots[source_index] = dst
		_slots[target_index] = src

	_notify_inventory_changed()
	return true

func get_hotbar_slots() -> Array[String]:
	var out: Array[String] = []
	for i in range(HOTBAR_SIZE):
		out.append(_slots[i].item_id)
	return out

func set_hotbar_slot(index: int, item_id: String) -> bool:
	if index < 0 or index >= HOTBAR_SIZE:
		return false
	if item_id == "":
		return false
	var src: int = _find_any_slot_with_item(item_id)
	if src < 0:
		return false
	if src == index:
		return true
	return move_slot(src, index)

func select_hotbar_slot(index: int) -> void:
	if index < 0 or index >= HOTBAR_SIZE:
		return
	selected_hotbar_index = index
	selected_hotbar_changed.emit(selected_hotbar_index, get_selected_item())
	hotbar_updated.emit()

func cycle_hotbar(delta: int) -> void:
	var next: int = posmod(selected_hotbar_index + delta, HOTBAR_SIZE)
	select_hotbar_slot(next)

func get_selected_item() -> String:
	if selected_hotbar_index < 0 or selected_hotbar_index >= HOTBAR_SIZE:
		return ""
	var slot := _slots[selected_hotbar_index]
	if _is_slot_empty(slot):
		return ""
	return String(slot.item_id)

func find_hotbar_slot(item_id: String) -> int:
	for i in range(HOTBAR_SIZE):
		var slot := _slots[i]
		if slot.item_id == item_id and int(slot.amount) > 0:
			return i
	return -1

func select_hotbar_item(item_id: String) -> bool:
	var idx: int = find_hotbar_slot(item_id)
	if idx < 0:
		var source: int = _find_any_slot_with_item(item_id)
		if source < 0:
			return false
		var dest: int = _find_first_empty_hotbar_slot()
		if dest < 0:
			dest = selected_hotbar_index
		move_slot(source, dest)
		idx = dest
	select_hotbar_slot(idx)
	return true

var _icon_viewport: SubViewport = null
var _icon_camera: Camera3D = null
var _icon_stage: Node3D = null

func get_item_icon(item_id: String) -> Texture2D:
	if _item_icons.has(item_id):
		return _item_icons[item_id]
	# Return fallback immediately; actual 3D render is queued.
	var fb := _fallback_icon(item_id)
	_item_icons[item_id] = fb
	_queue_item_render(item_id)
	return fb

var _render_queue: Array[String] = []
var _render_busy: bool = false

func _queue_item_render(item_id: String) -> void:
	if item_id in _render_queue:
		return
	_render_queue.append(item_id)
	if not _render_busy:
		_process_render_queue()

func _process_render_queue() -> void:
	if _render_busy:
		return
	_render_busy = true
	while _render_queue.size() > 0:
		var id: String = _render_queue.pop_front()
		var tex: Texture2D = await _render_item_icon(id)
		if tex != null:
			_item_icons[id] = tex
			inventory_updated.emit()
			hotbar_updated.emit()
	_render_busy = false

func _ensure_icon_renderer() -> void:
	if _icon_viewport != null and is_instance_valid(_icon_viewport):
		return
	_icon_viewport = SubViewport.new()
	_icon_viewport.size = ICON_TEXTURE_SIZE
	_icon_viewport.transparent_bg = true
	_icon_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_icon_viewport.own_world_3d = true
	_icon_viewport.world_3d = World3D.new()
	_icon_viewport.msaa_3d = Viewport.MSAA_4X

	var light := DirectionalLight3D.new()
	light.transform = Transform3D(Basis().rotated(Vector3.RIGHT, -0.9).rotated(Vector3.UP, 0.7), Vector3.ZERO)
	light.light_energy = 1.3
	_icon_viewport.add_child(light)

	var fill := DirectionalLight3D.new()
	fill.transform = Transform3D(Basis().rotated(Vector3.RIGHT, -0.5).rotated(Vector3.UP, -2.3), Vector3.ZERO)
	fill.light_energy = 0.45
	_icon_viewport.add_child(fill)

	_icon_camera = Camera3D.new()
	_icon_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_icon_camera.size = 1.6
	_icon_camera.near = 0.05
	_icon_camera.far = 20.0
	# Slightly tilted 3/4 view.
	_icon_camera.transform = Transform3D(
		Basis().rotated(Vector3.RIGHT, -0.55).rotated(Vector3.UP, 0.55),
		Vector3(2.0, 1.8, 2.0)
	)
	_icon_camera.look_at(Vector3.ZERO, Vector3.UP)
	_icon_viewport.add_child(_icon_camera)

	_icon_stage = Node3D.new()
	_icon_viewport.add_child(_icon_stage)

	# Parent under scene tree root so it renders.
	var tree := get_tree()
	if tree and tree.root:
		tree.root.add_child.call_deferred(_icon_viewport)

func _render_item_icon(item_id: String) -> Texture2D:
	_ensure_icon_renderer()
	var model_path: String = ITEM_MODELS.get(item_id, "")
	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		return _fallback_icon(item_id)
	var packed: PackedScene = load(model_path) as PackedScene
	if packed == null:
		return _fallback_icon(item_id)
	var inst: Node3D = packed.instantiate() as Node3D
	if inst == null:
		return _fallback_icon(item_id)
	# Clear stage, add instance
	for c in _icon_stage.get_children():
		c.queue_free()
	_icon_stage.add_child(inst)

	# Center + scale to fit camera ortho size.
	var aabb := _compute_aabb(inst)
	if aabb.size.length() > 0.0001:
		var max_dim: float = maxf(maxf(aabb.size.x, aabb.size.y), aabb.size.z)
		var target: float = 1.2
		var scale_factor: float = target / max_dim
		inst.scale = Vector3(scale_factor, scale_factor, scale_factor)
		inst.position = -aabb.get_center() * scale_factor

	# Wait for viewport to be in tree, then let it render a frame.
	while not _icon_viewport.is_inside_tree():
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img: Image = _icon_viewport.get_texture().get_image()
	if img == null:
		return _fallback_icon(item_id)
	var tex := ImageTexture.create_from_image(img)
	# Remove the rendered instance to free memory.
	inst.queue_free()
	return tex

func _fallback_icon(item_id: String) -> Texture2D:
	var img := Image.create(ICON_TEXTURE_SIZE.x, ICON_TEXTURE_SIZE.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c: Color = ITEM_ICON_COLORS.get(item_id, Color(0.55, 0.55, 0.55))
	var pad: int = 10
	img.fill_rect(Rect2i(pad, pad, ICON_TEXTURE_SIZE.x - pad * 2, ICON_TEXTURE_SIZE.y - pad * 2), c)
	# Subtle gradient highlight (non pixel-art).
	for y in range(pad, ICON_TEXTURE_SIZE.y / 2):
		var a: float = 1.0 - float(y - pad) / float(ICON_TEXTURE_SIZE.y / 2 - pad)
		var shade := Color(1, 1, 1, 0.15 * a)
		img.fill_rect(Rect2i(pad, y, ICON_TEXTURE_SIZE.x - pad * 2, 1), Color(
			minf(c.r + shade.a, 1.0),
			minf(c.g + shade.a, 1.0),
			minf(c.b + shade.a, 1.0),
			1.0
		))
	return ImageTexture.create_from_image(img)

func _compute_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var has_any := false
	for child in _gather_visual_instances(node):
		var vis := child as VisualInstance3D
		var a: AABB = vis.get_aabb()
		# Transform AABB from vis local → node local
		var xform: Transform3D = node.global_transform.affine_inverse() * vis.global_transform
		a = xform * a
		if not has_any:
			aabb = a
			has_any = true
		else:
			aabb = aabb.merge(a)
	return aabb

func _gather_visual_instances(node: Node) -> Array[VisualInstance3D]:
	var out: Array[VisualInstance3D] = []
	if node is VisualInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_gather_visual_instances(c))
	return out

# ---- Icon painters (legacy pixel-art, unused — replaced by 3D preview renderer) ----

func _icon_wood(img: Image) -> void:
	var b := Color(0.55, 0.32, 0.13)
	var d := Color(0.35, 0.20, 0.07)
	var l := Color(0.72, 0.48, 0.24)
	img.fill_rect(Rect2i(2, 7, 28, 18), b)
	img.fill_rect(Rect2i(2, 7, 28, 3), l)   # top face
	for y in [11, 15, 19, 23]:
		img.fill_rect(Rect2i(2, y, 28, 1), d)
	img.fill_rect(Rect2i(16, 7, 1, 18), d)  # center split

func _icon_log(img: Image) -> void:
	var b := Color(0.38, 0.22, 0.10)
	var l := Color(0.55, 0.34, 0.16)
	var r := Color(0.50, 0.30, 0.13)
	img.fill_rect(Rect2i(4, 5, 24, 22), b)
	img.fill_rect(Rect2i(6, 7, 6, 18), r)   # left ring
	img.fill_rect(Rect2i(10, 9, 12, 14), l) # inner
	img.fill_rect(Rect2i(13, 11, 6, 10), b) # core

func _icon_branch(img: Image) -> void:
	var b := Color(0.45, 0.26, 0.10)
	var d := Color(0.28, 0.15, 0.05)
	# diagonal stick
	for i in range(22):
		img.set_pixel(4 + i, 26 - i, b)
		if i > 0: img.set_pixel(5 + i, 26 - i, b)
		if i > 0: img.set_pixel(4 + i, 27 - i, d)
	# side twig
	for j in range(8):
		img.set_pixel(14 + j, 16 - j, b)

func _icon_stone(img: Image) -> void:
	var g := Color(0.53, 0.53, 0.55)
	var l := Color(0.70, 0.70, 0.72)
	var d := Color(0.33, 0.33, 0.35)
	img.fill_rect(Rect2i(4, 6, 24, 20), g)
	img.fill_rect(Rect2i(4, 6, 14, 6), l)   # top highlight
	img.fill_rect(Rect2i(18, 20, 10, 6), d) # shadow
	# rough top edge
	img.fill_rect(Rect2i(4, 4, 6, 2), g)
	img.fill_rect(Rect2i(12, 3, 8, 3), g)
	img.fill_rect(Rect2i(22, 5, 6, 1), g)

func _icon_metal(img: Image) -> void:
	var s := Color(0.52, 0.55, 0.60)
	var l := Color(0.75, 0.78, 0.82)
	var d := Color(0.30, 0.32, 0.36)
	img.fill_rect(Rect2i(3, 5, 26, 22), s)
	img.fill_rect(Rect2i(3, 5, 26, 5), l)    # top shine
	img.fill_rect(Rect2i(3, 22, 26, 5), d)   # bottom shadow
	img.fill_rect(Rect2i(20, 5, 4, 22), l)   # right highlight strip
	# rivet details
	for pos in [Vector2i(7, 9), Vector2i(7, 21), Vector2i(24, 9), Vector2i(24, 21)]:
		img.fill_rect(Rect2i(pos.x, pos.y, 2, 2), d)

func _icon_scrap(img: Image) -> void:
	var s := Color(0.44, 0.44, 0.48)
	var r := Color(0.58, 0.28, 0.14)  # rust
	var l := Color(0.60, 0.62, 0.66)
	img.fill_rect(Rect2i(3, 8, 16, 14), s)
	img.fill_rect(Rect2i(15, 12, 14, 12), s)
	img.fill_rect(Rect2i(14, 4, 10, 8), s)
	# rust patches
	img.fill_rect(Rect2i(5, 10, 5, 4), r)
	img.fill_rect(Rect2i(18, 14, 4, 4), r)
	# shine
	img.fill_rect(Rect2i(3, 8, 10, 2), l)
	img.fill_rect(Rect2i(14, 4, 10, 2), l)

func _icon_fuel(img: Image) -> void:
	# Flame shape
	var o := Color(0.95, 0.55, 0.10)
	var y := Color(1.00, 0.90, 0.20)
	var r := Color(0.80, 0.20, 0.05)
	img.fill_rect(Rect2i(12, 18, 8, 10), o)  # base
	img.fill_rect(Rect2i(9,  12, 14, 8), o)
	img.fill_rect(Rect2i(11, 7,  10, 7), o)
	img.fill_rect(Rect2i(13, 4,  6,  5), y)  # core bright
	img.fill_rect(Rect2i(10, 10, 4,  8), r)  # dark side
	img.fill_rect(Rect2i(18, 14, 3,  6), r)

func _icon_components(img: Image) -> void:
	# Small cog/gear shape
	var g := Color(0.74, 0.65, 0.36)
	var d := Color(0.50, 0.43, 0.22)
	var l := Color(0.88, 0.80, 0.55)
	img.fill_rect(Rect2i(8, 8, 16, 16), g)
	img.fill_rect(Rect2i(12, 4, 8, 4), g)   # top tooth
	img.fill_rect(Rect2i(12, 24, 8, 4), g)  # bottom
	img.fill_rect(Rect2i(4, 12, 4, 8), g)   # left
	img.fill_rect(Rect2i(24, 12, 4, 8), g)  # right
	img.fill_rect(Rect2i(12, 12, 8, 8), d)  # center hole
	img.fill_rect(Rect2i(8, 8, 8, 4), l)    # shine

func _icon_hammer(img: Image) -> void:
	var h := Color(0.30, 0.18, 0.08)  # handle
	var m := Color(0.55, 0.57, 0.60)  # metal head
	var l := Color(0.78, 0.80, 0.83)  # metal shine
	# head
	img.fill_rect(Rect2i(4, 3, 20, 12), m)
	img.fill_rect(Rect2i(4, 3, 20, 4), l)  # top shine
	# handle
	img.fill_rect(Rect2i(13, 14, 5, 16), h)
	img.fill_rect(Rect2i(14, 14, 2, 16), Color(h.r + 0.15, h.g + 0.08, h.b + 0.03))

func _icon_axe(img: Image) -> void:
	var h := Color(0.30, 0.18, 0.08)
	var m := Color(0.58, 0.60, 0.62)
	var l := Color(0.80, 0.82, 0.85)
	# blade
	img.fill_rect(Rect2i(4, 4, 18, 18), m)
	img.fill_rect(Rect2i(4, 4, 18, 4), l)
	# cutout (axe shape)
	img.fill_rect(Rect2i(4, 14, 10, 8), Color(0, 0, 0, 0))  # hollow
	# handle
	img.fill_rect(Rect2i(18, 14, 5, 16), h)
	img.fill_rect(Rect2i(19, 14, 2, 16), Color(h.r+0.12, h.g+0.07, h.b+0.02))

func _icon_pickaxe(img: Image) -> void:
	var h := Color(0.30, 0.18, 0.08)
	var m := Color(0.52, 0.55, 0.58)
	var l := Color(0.76, 0.79, 0.82)
	# left pick tip
	img.fill_rect(Rect2i(2, 5, 12, 6), m)
	img.fill_rect(Rect2i(2, 5, 10, 2), l)
	# right pick tip
	img.fill_rect(Rect2i(18, 5, 12, 6), m)
	img.fill_rect(Rect2i(18, 5, 12, 2), l)
	# center band
	img.fill_rect(Rect2i(10, 2, 12, 12), m)
	img.fill_rect(Rect2i(10, 2, 12, 3), l)
	# handle
	img.fill_rect(Rect2i(14, 13, 5, 18), h)
	img.fill_rect(Rect2i(15, 13, 2, 18), Color(h.r+0.12, h.g+0.07, h.b+0.02))

func _fill_existing_stacks(item_id: String, remaining: int) -> int:
	var stack_max: int = get_stack_size(item_id)
	for i in range(_slots.size()):
		if remaining <= 0:
			return 0
		var slot := _slots[i]
		if slot.item_id != item_id:
			continue
		var room: int = maxi(0, stack_max - int(slot.amount))
		if room <= 0:
			continue
		var add: int = mini(room, remaining)
		slot.amount += add
		_slots[i] = slot
		remaining -= add
	return remaining

func _fill_empty_slots(item_id: String, remaining: int) -> int:
	var stack_max: int = get_stack_size(item_id)
	for i in range(_slots.size()):
		if remaining <= 0:
			return 0
		if not _is_slot_empty(_slots[i]):
			continue
		var add: int = mini(stack_max, remaining)
		_slots[i] = {"item_id": item_id, "amount": add}
		remaining -= add
	return remaining

func _notify_inventory_changed() -> void:
	for item_id in ITEM_NAMES.keys():
		var amount: int = get_item_amount(item_id)
		item_changed.emit(item_id, amount)
		resource_changed.emit(item_id, amount)
	inventory_capacity_changed.emit(get_used_slots(), MAX_INVENTORY_SLOTS)
	hotbar_updated.emit()
	selected_hotbar_changed.emit(selected_hotbar_index, get_selected_item())
	inventory_updated.emit()

func _max_addable_amount(item_id: String) -> int:
	var stack_max: int = get_stack_size(item_id)
	var total_room: int = 0
	for slot in _slots:
		if _is_slot_empty(slot):
			total_room += stack_max
		elif slot.item_id == item_id:
			total_room += maxi(0, stack_max - int(slot.amount))
	return total_room

func _empty_slot() -> Dictionary:
	return {"item_id": "", "amount": 0}

func _is_slot_empty(slot: Dictionary) -> bool:
	return String(slot.get("item_id", "")) == "" or int(slot.get("amount", 0)) <= 0

func _is_valid_slot_index(index: int) -> bool:
	return index >= 0 and index < _slots.size()

func _find_first_empty_hotbar_slot() -> int:
	for i in range(HOTBAR_SIZE):
		if _is_slot_empty(_slots[i]):
			return i
	return -1

func _find_any_slot_with_item(item_id: String) -> int:
	for i in range(_slots.size()):
		var slot := _slots[i]
		if slot.item_id == item_id and int(slot.amount) > 0:
			return i
	return -1

func _auto_assign_tool_to_hotbar(item_id: String) -> void:
	if not TOOL_ITEMS.has(item_id):
		return
	if find_hotbar_slot(item_id) >= 0:
		return
	var source: int = _find_any_slot_with_item(item_id)
	if source < 0:
		return
	var target: int = _find_first_empty_hotbar_slot()
	if target >= 0:
		move_slot(source, target)
