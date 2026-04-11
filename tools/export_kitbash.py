"""Blender script: split kitbash FBX into individual GLB files.
- Clears parent hierarchy
- Centers geometry at origin
- Orients walls upright (tallest dim → Blender Z → Godot Y)
- Scales walls to fit 1m grid (1m wide, ~2m tall)
- Assigns PBR textures
- Places walls with base at Y=0 (bottom-centered)
"""
import bpy
import os
import math
from mathutils import Vector

FBX_PATH = r"C:\Users\tidic\AppData\Local\Temp\kitbash_extract\Post_apocalypse_kitbash_free\Fbx\12.fbx"
OUT_DIR = r"C:\Users\tidic\Documents\ashline\assets\models\kitbash"
TEX_DIR = r"C:\Users\tidic\AppData\Local\Temp\kitbash_extract\Post_apocalypse_kitbash_free\Textures"

_tex_cache = {}

def get_texture(name):
    if name not in _tex_cache:
        path = os.path.join(TEX_DIR, name)
        if os.path.exists(path):
            _tex_cache[name] = bpy.data.images.load(path)
        else:
            _tex_cache[name] = None
    return _tex_cache[name]

def setup_pbr_material(obj):
    mat_name = f"M_kitbash_{obj.name}"
    mat = bpy.data.materials.new(name=mat_name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    nodes.clear()

    output = nodes.new('ShaderNodeOutputMaterial')
    output.location = (400, 0)
    bsdf = nodes.new('ShaderNodeBsdfPrincipled')
    bsdf.location = (0, 0)
    links.new(bsdf.outputs['BSDF'], output.inputs['Surface'])

    img = get_texture("Post_apocalypse_city_color_dark.png")
    if img:
        tex = nodes.new('ShaderNodeTexImage')
        tex.image = img
        tex.location = (-400, 200)
        links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])

    img = get_texture("Post_apocalypse_city_normal.png")
    if img:
        tex = nodes.new('ShaderNodeTexImage')
        tex.image = img
        tex.image.colorspace_settings.name = 'Non-Color'
        tex.location = (-400, -200)
        nmap = nodes.new('ShaderNodeNormalMap')
        nmap.location = (-100, -200)
        links.new(tex.outputs['Color'], nmap.inputs['Color'])
        links.new(nmap.outputs['Normal'], bsdf.inputs['Normal'])

    img = get_texture("Post_apocalypse_city_roughness.png")
    if img:
        tex = nodes.new('ShaderNodeTexImage')
        tex.image = img
        tex.image.colorspace_settings.name = 'Non-Color'
        tex.location = (-400, -500)
        links.new(tex.outputs['Color'], bsdf.inputs['Roughness'])

    img = get_texture("Post_apocalypse_city_metalness.png")
    if img:
        tex = nodes.new('ShaderNodeTexImage')
        tex.image = img
        tex.image.colorspace_settings.name = 'Non-Color'
        tex.location = (-400, -800)
        links.new(tex.outputs['Color'], bsdf.inputs['Metallic'])

    if len(obj.material_slots) == 0:
        obj.data.materials.append(mat)
    else:
        for slot in obj.material_slots:
            slot.material = mat

def categorize(name, dx, dy, dz):
    dims = sorted([dx, dy, dz])
    if "Cube" in name:
        return None
    if dims[0] < 0.5 and dims[1] > 1.5 and dims[2] > 1.5:
        return "wall"
    if dims[2] > 2.5 and dims[0] < 0.5 and dims[1] < 0.5:
        return "railing"
    if dims[2] < 2.0:
        return "prop_small"
    if dims[2] < 4.0:
        return "prop_medium"
    return "structure"

def prepare_object(obj):
    """Clear parent, apply transforms, center at origin."""
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

def center_bottom(obj):
    """Center X/Y at origin, place bottom at Z=0 (Blender Z-up → Godot Y-up)."""
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    # Get world-space bounds
    verts = [obj.matrix_world @ v.co for v in obj.data.vertices]
    xs = [v.x for v in verts]; ys = [v.y for v in verts]; zs = [v.z for v in verts]
    cx = (min(xs) + max(xs)) / 2.0
    cy = (min(ys) + max(ys)) / 2.0
    cz_bottom = min(zs)

    # Shift: center X/Y, bottom Z=0 (Z is UP in Blender → Y in Godot)
    obj.location.x -= cx
    obj.location.y -= cy
    obj.location.z -= cz_bottom
    bpy.ops.object.transform_apply(location=True)

def orient_wall_upright(obj):
    """Rotate wall so tallest dim aligns with Blender Z (→ Godot Y = height),
    and thinnest dim aligns with Blender Y (→ Godot Z = depth/thickness).
    Result in Godot: X=face width, Y=height, Z=thickness."""
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    d = obj.dimensions
    dims = [d.x, d.y, d.z]
    max_idx = dims.index(max(dims))

    # Step 1: make Z the tallest axis
    if max_idx == 0:  # X is tallest → rotate 90° around Y
        obj.rotation_euler.y = math.pi / 2.0
        bpy.ops.object.transform_apply(rotation=True)
    elif max_idx == 1:  # Y is tallest → rotate -90° around X
        obj.rotation_euler.x = -math.pi / 2.0
        bpy.ops.object.transform_apply(rotation=True)
    # max_idx == 2: Z already tallest

    # Step 2: make Y the thinnest (thin = wall thickness → Blender Y → Godot Z)
    d = obj.dimensions
    if d.y > d.x:  # Y is wider than X → swap with Z rotation
        obj.rotation_euler.z = math.pi / 2.0
        bpy.ops.object.transform_apply(rotation=True)

def scale_to_fit(obj, category):
    """Scale object to fit the build grid.
    Walls: ~2m tall (uniform scale based on height).
    Props: max dimension ~0.8m / 1.2m.
    Railings: 1m long."""
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    if category == "wall":
        # Orient upright first, then scale
        orient_wall_upright(obj)
        d = obj.dimensions
        # Z is now the tallest (height in Blender → Y in Godot)
        if d.z > 0.01:
            s = 2.0 / d.z
            obj.scale = (s, s, s)
            bpy.ops.object.transform_apply(scale=True)
    elif category in ("prop_small", "prop_medium"):
        d = obj.dimensions
        max_dim = max(d.x, d.y, d.z)
        if max_dim > 0.01:
            target = 0.8 if category == "prop_small" else 1.2
            s = target / max_dim
            obj.scale = (s, s, s)
            bpy.ops.object.transform_apply(scale=True)
    elif category == "railing":
        d = obj.dimensions
        max_dim = max(d.x, d.y, d.z)
        if max_dim > 0.01:
            s = 1.0 / max_dim
            obj.scale = (s, s, s)
            bpy.ops.object.transform_apply(scale=True)

def export_one(obj, category, index):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    cat_dir = os.path.join(OUT_DIR, category)
    os.makedirs(cat_dir, exist_ok=True)
    filepath = os.path.join(cat_dir, f"{category}_{index:03d}.glb")

    bpy.ops.export_scene.gltf(
        filepath=filepath,
        use_selection=True,
        export_format='GLB',
        export_apply=True,
        export_texcoords=True,
        export_normals=True,
        export_materials='EXPORT',
        export_image_format='JPEG',
    )
    obj.select_set(False)
    return os.path.basename(filepath)

# ---- main ----
print("Loading FBX ...")
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
bpy.ops.import_scene.fbx(filepath=FBX_PATH)

meshes = [o for o in bpy.data.objects if o.type == 'MESH']
print(f"Found {len(meshes)} meshes")

CATEGORIES = {"wall": [], "prop_small": [], "prop_medium": [], "railing": [], "structure": []}
for obj in meshes:
    d = obj.dimensions
    cat = categorize(obj.name, d.x, d.y, d.z)
    if cat:
        CATEGORIES[cat].append(obj)

limits = {"wall": 15, "prop_small": 20, "prop_medium": 10, "railing": 8, "structure": 5}

for cat, objects in CATEGORIES.items():
    n = min(len(objects), limits.get(cat, 10))
    print(f"\n--- {cat}: {n}/{len(objects)} ---")
    for i, obj in enumerate(objects[:n]):
        prepare_object(obj)
        scale_to_fit(obj, cat)
        center_bottom(obj)
        setup_pbr_material(obj)
        fname = export_one(obj, cat, i)
        d = obj.dimensions
        print(f"  {fname}  {d.x:.2f} x {d.y:.2f} x {d.z:.2f}")

print("\nDONE")
