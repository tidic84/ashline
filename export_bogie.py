"""
Export one bogie (Z >= -0.02 half of the chassis GLB) to chassis_bogie.glb.
Run: blender --background --python export_bogie.py
"""
import bpy
import bmesh
import os

SRC  = r"C:\Users\tidic\Documents\ashline\assets\models\train\chassis.glb"
DST  = r"C:\Users\tidic\Documents\ashline\assets\models\train\chassis_bogie.glb"

# ---- import ----
bpy.ops.import_scene.gltf(filepath=SRC)

# Find the mesh object
obj = None
for o in bpy.context.scene.objects:
    if o.type == 'MESH':
        obj = o
        break

if obj is None:
    raise RuntimeError("No mesh found in GLB")

print(f"Mesh: {obj.name}  verts: {len(obj.data.vertices)}")

# ---- bmesh face-filter: keep Z >= -0.02 ----
bpy.context.view_layer.objects.active = obj
bpy.ops.object.mode_set(mode='EDIT')
bm = bmesh.from_edit_mesh(obj.data)
bm.faces.ensure_lookup_table()

# GLTF Z (depth/forward) = Blender -Y.
# GLTF Z > 0 (front half) = Blender Y < 0.
# Delete faces where Blender Y > 0.02  (i.e. GLTF Z < -0.02, the rear half).
BLEND_Y_THRESHOLD = 0.02

faces_to_delete = []
for f in bm.faces:
    cy = sum(v.co.y for v in f.verts) / len(f.verts)   # Blender Y = -GLTF_Z
    if cy > BLEND_Y_THRESHOLD:
        faces_to_delete.append(f)

print(f"Deleting {len(faces_to_delete)} / {len(bm.faces)} faces (BlenderY > {BLEND_Y_THRESHOLD} → GLTF_Z < -{BLEND_Y_THRESHOLD})")
bmesh.ops.delete(bm, geom=faces_to_delete, context='FACES')
bmesh.update_edit_mesh(obj.data)
bpy.ops.object.mode_set(mode='OBJECT')

# ---- export ----
bpy.ops.object.select_all(action='DESELECT')
obj.select_set(True)
bpy.ops.export_scene.gltf(
    filepath=DST,
    use_selection=True,
    export_format='GLB',
    export_materials='EXPORT',
    export_texcoords=True,
    export_normals=True,
)
print(f"Exported: {DST}")
print(f"File size: {os.path.getsize(DST):,} bytes")
