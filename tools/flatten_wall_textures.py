"""Flatten baked directional lighting in Meshy AI wall textures.

Rewrites wall-blue.glb / wall-yellow.glb by replacing the baseColor image
with a delit version (low-frequency brightness normalized) so identical
walls placed side by side no longer show the same baked gradient.

Uses manual GLB binary manipulation (JSON chunk + BIN chunk) because
pygltflib cannot repack embedded buffer images.

Run once:  python tools/flatten_wall_textures.py
"""

import io
import json
import os
import shutil
import struct
import sys

import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGETS = [
    os.path.join(ROOT, "assets/models/building/wall-blue.glb"),
    os.path.join(ROOT, "assets/models/building/wall-yellow.glb"),
]


def delight(img: Image.Image) -> Image.Image:
    """Remove low-frequency luminance gradient, keep detail & color."""
    has_alpha = img.mode == "RGBA"
    rgb = img.convert("RGB")
    arr = np.array(rgb).astype(np.float32)

    lum = 0.299 * arr[..., 0] + 0.587 * arr[..., 1] + 0.114 * arr[..., 2]
    lum_img = Image.fromarray(np.clip(lum, 0, 255).astype(np.uint8), "L")

    radius = max(img.size) // 6
    low = np.array(lum_img.filter(ImageFilter.GaussianBlur(radius=radius))).astype(np.float32)

    target = float(low.mean())
    correction = target / np.maximum(low, 1.0)
    correction = np.clip(correction, 0.55, 1.8)

    result = arr * correction[..., None]
    result = np.clip(result, 0, 255).astype(np.uint8)

    out = Image.fromarray(result, "RGB")
    if has_alpha:
        alpha = img.split()[-1]
        out = Image.merge("RGBA", (*out.split(), alpha))
    return out


def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, version, total_len = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67, "not a GLB file"
    off = 12

    json_len, json_type = struct.unpack_from("<II", data, off)
    off += 8
    assert json_type == 0x4E4F534A, "first chunk must be JSON"
    json_bytes = data[off:off + json_len]
    off += json_len

    bin_chunk = b""
    if off < len(data):
        bin_len, bin_type = struct.unpack_from("<II", data, off)
        off += 8
        assert bin_type == 0x004E4942, "second chunk must be BIN"
        bin_chunk = data[off:off + bin_len]

    gltf = json.loads(json_bytes.decode("utf-8"))
    return gltf, bin_chunk


def pad4(b: bytes, pad_byte: bytes = b"\x00") -> bytes:
    n = (4 - (len(b) % 4)) % 4
    return b + pad_byte * n


def write_glb(path, gltf: dict, bin_chunk: bytes) -> None:
    json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    json_padded = pad4(json_bytes, b" ")
    bin_padded = pad4(bin_chunk, b"\x00")

    total_len = 12 + 8 + len(json_padded) + 8 + len(bin_padded)

    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total_len))
        f.write(struct.pack("<II", len(json_padded), 0x4E4F534A))
        f.write(json_padded)
        f.write(struct.pack("<II", len(bin_padded), 0x004E4942))
        f.write(bin_padded)


def replace_image_in_bin(gltf: dict, bin_chunk: bytes, img_idx: int, new_bytes: bytes, new_mime: str):
    """Replace image's buffer-view bytes inside BIN, shifting subsequent views."""
    image = gltf["images"][img_idx]
    bv_idx = image["bufferView"]
    bvs = gltf["bufferViews"]
    old_bv = bvs[bv_idx]
    old_off = old_bv.get("byteOffset", 0)
    old_len = old_bv["byteLength"]

    before = bin_chunk[:old_off]
    after = bin_chunk[old_off + old_len:]

    new_bv_bytes = pad4(new_bytes, b"\x00")
    new_bin = before + new_bv_bytes + after

    delta = len(new_bv_bytes) - old_len
    bvs[bv_idx]["byteLength"] = len(new_bytes)

    for i, bv in enumerate(bvs):
        if i == bv_idx:
            continue
        off = bv.get("byteOffset", 0)
        if off > old_off:
            bv["byteOffset"] = off + delta

    buf_idx = old_bv.get("buffer", 0)
    gltf["buffers"][buf_idx]["byteLength"] = len(new_bin)

    image["mimeType"] = new_mime

    return new_bin


def process_glb(glb_path: str) -> None:
    backup = glb_path + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(glb_path, backup)
        print(f"  backup: {os.path.basename(backup)}")

    gltf, bin_chunk = read_glb(glb_path)

    mats = gltf.get("materials", [])
    if not mats:
        print("  no materials, skip")
        return
    pbr = mats[0].get("pbrMetallicRoughness", {})
    base = pbr.get("baseColorTexture")
    if not base:
        print("  no baseColor, skip")
        return

    tex_idx = base["index"]
    img_idx = gltf["textures"][tex_idx]["source"]
    img = gltf["images"][img_idx]
    print(f"  target image: [{img_idx}] name={img.get('name')} mime={img.get('mimeType')}")

    bv = gltf["bufferViews"][img["bufferView"]]
    off = bv.get("byteOffset", 0)
    length = bv["byteLength"]
    img_bytes = bin_chunk[off:off + length]

    src = Image.open(io.BytesIO(img_bytes))
    print(f"  size={src.size} mode={src.mode}")
    out = delight(src)

    buf = io.BytesIO()
    out.save(buf, format="PNG", optimize=True)
    new_bytes = buf.getvalue()
    print(f"  new PNG size: {len(new_bytes):,} bytes (was {length:,})")

    new_bin = replace_image_in_bin(gltf, bin_chunk, img_idx, new_bytes, "image/png")
    write_glb(glb_path, gltf, new_bin)
    print(f"  repacked: {os.path.basename(glb_path)}")


def main() -> int:
    for path in TARGETS:
        print(f"Processing {os.path.basename(path)}")
        if not os.path.exists(path):
            print("  missing, skip")
            continue
        process_glb(path)
        print()
    print("Done. Re-import the GLBs in Godot (right-click -> Reimport).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
