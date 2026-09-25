"""Convert a 4x4 or 8x8 Helsinki 2017 L19 block into bounded textured GLBs.

Input is a directory of matching OBJ/JPEG files from an official Helsinki OBJ ZIP.
The converter changes coordinates and container format only; textures remain the
city's aerial-photo textures. It does not fetch or execute remote content.
"""

import argparse
import hashlib
import json
import math
import re
import struct
from pathlib import Path


SOURCE_URL = (
    "https://3d.hel.ninja/data/mesh/Helsinki3D-MESH_2017_OBJ_2km-250m_ZIP/"
    "Helsinki3D_2017_OBJ_672494x2.zip"
)
ROOT_EAST = 5250.0
ROOT_NORTH = 4000.0
CELL = 31.25


def add_buffer(binary, views, content):
    binary.extend(b"\0" * (-len(binary) % 4))
    offset = len(binary)
    binary.extend(content)
    views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(content)})
    return len(views) - 1


def encode_glb(vertices, texcoords, groups, jpeg, center):
    binary = bytearray()
    views, accessors, primitives = [], [], []
    for material, faces in enumerate(groups):
        if not faces:
            continue
        unique = {}
        positions = []
        uv = []
        indices = []
        for face in faces:
            for key in face:
                if key not in unique:
                    unique[key] = len(unique)
                    x, north, height = vertices[key[0]]
                    positions.extend((x - center[0], height - center[2], center[1] - north))
                    if material == 0:
                        u, v = texcoords[key[1]]
                        uv.extend((u, 1.0 - v))
                indices.append(unique[key])
        if len(unique) > 60000 or len(indices) > 60000:
            raise ValueError("tile exceeds reader vertex or 20,000-triangle budget")
        position_view = add_buffer(binary, views, struct.pack(f"<{len(positions)}f", *positions))
        accessors.append({"bufferView": position_view, "componentType": 5126,
                          "count": len(unique), "type": "VEC3"})
        attributes = {"POSITION": len(accessors) - 1}
        if material == 0:
            uv_view = add_buffer(binary, views, struct.pack(f"<{len(uv)}f", *uv))
            accessors.append({"bufferView": uv_view, "componentType": 5126,
                              "count": len(unique), "type": "VEC2"})
            attributes["TEXCOORD_0"] = len(accessors) - 1
        index_type = 5123 if len(unique) < 65536 else 5125
        index_format = "H" if index_type == 5123 else "I"
        index_view = add_buffer(binary, views, struct.pack(f"<{len(indices)}{index_format}", *indices))
        accessors.append({"bufferView": index_view, "componentType": index_type,
                          "count": len(indices), "type": "SCALAR"})
        primitives.append({"attributes": attributes, "indices": len(accessors) - 1,
                           "material": material})
    image_view = add_buffer(binary, views, jpeg)
    document = {
        "asset": {"version": "2.0", "generator": "Region Lab Helsinki mesh converter"},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": primitives}],
        "materials": [
            {"doubleSided": True, "pbrMetallicRoughness": {
                "baseColorTexture": {"index": 0}, "metallicFactor": 0, "roughnessFactor": 0.95}},
            {"doubleSided": True, "pbrMetallicRoughness": {
                "baseColorFactor": [0.5, 0.5, 0.5, 1], "metallicFactor": 0,
                "roughnessFactor": 0.95}},
        ],
        "textures": [{"source": 0}],
        "images": [{"bufferView": image_view, "mimeType": "image/jpeg"}],
        "accessors": accessors, "bufferViews": views,
        "buffers": [{"byteLength": len(binary)}],
    }
    encoded = json.dumps(document, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 4)
    binary.extend(b"\0" * (-len(binary) % 4))
    content = (struct.pack("<5I", 0x46546C67, 2, 28 + len(encoded) + len(binary),
                           len(encoded), 0x4E4F534A) + encoded
               + struct.pack("<2I", len(binary), 0x004E4942) + binary)
    if len(content) > 2 * 1024 * 1024:
        raise ValueError("tile exceeds 2 MiB GLB limit")
    return content


def parse_obj(data):
    vertices, uv, groups = [], [], [[], []]
    material = None
    for line in data.decode("ascii").splitlines():
        if line.startswith("v "):
            vertices.append(tuple(map(float, line.split()[1:])))
        elif line.startswith("vt "):
            uv.append(tuple(map(float, line.split()[1:3])))
        elif line.startswith("usemtl "):
            material = 1 if line.endswith("_untextured") else 0
        elif line.startswith("f "):
            if material is None:
                raise ValueError("face without material")
            parts = line.split()[1:]
            if len(parts) != 3:
                raise ValueError("expected triangulated OBJ")
            face = []
            for part in parts:
                refs = part.split("/")
                if len(refs) != 2:
                    raise ValueError("expected vertex/UV face indices")
                a, b = map(int, refs)
                face.append((a - 1, b - 1))
            groups[material].append(face)
    if not vertices or not groups[0] or not uv:
        raise ValueError("tile has no textured geometry")
    used = [vertices[a] for group in groups for face in group for a, _ in face]
    lower = tuple(min(point[i] for point in used) for i in range(3))
    upper = tuple(max(point[i] for point in used) for i in range(3))
    if any(not math.isfinite(v) for point in vertices + uv for v in point):
        raise ValueError("nonfinite geometry")
    return vertices, uv, groups, lower, upper


def convert(source, destination, grid_x=2, grid_y=3, count=4):
    if count not in (4, 8) or not 0 <= grid_x <= 8 - count or not 0 <= grid_y <= 8 - count:
        raise ValueError("selection must be a 4x4 or 8x8 block within one source tile")
    if destination.exists() and any(destination.iterdir()):
        raise ValueError("use a fresh empty output directory")
    selected = {}
    for obj in sorted(source.glob("*_L19_*.obj")):
        match = re.fullmatch(r"Tile_\+\d+_\+\d+_L19_[0-3]{6}\.obj", obj.name)
        if not match:
            continue
        raw = obj.read_bytes()
        vertices, uv, groups, lower, upper = parse_obj(raw)
        gx = round((lower[0] - ROOT_EAST) / CELL)
        gy = round((lower[1] - ROOT_NORTH) / CELL)
        if not (grid_x <= gx < grid_x + count and grid_y <= gy < grid_y + count):
            continue
        if (gx, gy) in selected:
            raise ValueError("duplicate source tile location")
        jpg = obj.with_name(obj.stem + "_0.jpg")
        image = jpg.read_bytes()
        if len(image) > 1024 * 1024 or not image.startswith(b"\xff\xd8"):
            raise ValueError("missing or oversized JPEG texture")
        selected[gx, gy] = (obj, raw, jpg, image, vertices, uv, groups, lower, upper)
    if len(selected) != count * count:
        raise ValueError(f"expected {count * count} contiguous tiles, found {len(selected)}")
    baseline = min(item[7][2] for item in selected.values())
    destination.mkdir(parents=True)
    offset = (64.0, 32.0) if count == 4 else (128.0, 128.0)
    manifest = {
        "source_url": SOURCE_URL, "source_crs": "EPSG:3879+5773",
        "region_name": "赫尔辛基实景街区",
        "spawn": [128.0, 107.0, 5.5] if count == 4 else [253.0, 253.0, 7.5],
        "region_size": 256 if count == 4 else 512,
        "source_tile": source.name, "source_lod": 19,
        "source_bounds": [ROOT_EAST + grid_x * CELL, ROOT_NORTH + grid_y * CELL,
                          ROOT_EAST + (grid_x + count) * CELL,
                          ROOT_NORTH + (grid_y + count) * CELL],
        "region_offset": list(offset), "height_baseline_source": baseline,
        "license": "CC-BY-4.0", "attribution": "City of Helsinki, Helsinki 3D Mesh 2017; hel.fi/3d",
        "changes": f"{count * count} original L19 OBJ/JPEG tiles converted to local-coordinate embedded GLBs; texture pixels unchanged",
        "tiles": [],
    }
    for gy in range(grid_y, grid_y + count):
        for gx in range(grid_x, grid_x + count):
            obj, raw, jpg, image, vertices, uv, groups, lower, upper = selected[gx, gy]
            bounds = [upper[i] - lower[i] for i in range(3)]
            if any(v < 0.2 or v > 32 for v in bounds):
                raise ValueError(f"{obj.name} is outside 0.2–32 metre bounds")
            center = tuple((lower[i] + upper[i]) / 2 for i in range(3))
            content = encode_glb(vertices, uv, groups, image, center)
            output = destination / f"helsinki-{gx}-{gy}.glb"
            output.write_bytes(content)
            manifest["tiles"].append({
                "name": f"赫尔辛基街区 {gx}-{gy}", "file": output.name,
                "position": [offset[0] + center[0] - manifest["source_bounds"][0],
                             offset[1] + center[1] - manifest["source_bounds"][1],
                             center[2] - baseline],
                "bounds": [bounds[0], bounds[1], bounds[2]],
                "triangles": sum(map(len, groups)), "sha256": hashlib.sha256(content).hexdigest(),
                "source_obj": obj.name, "source_obj_sha256": hashlib.sha256(raw).hexdigest(),
                "source_jpeg": jpg.name, "source_jpeg_sha256": hashlib.sha256(image).hexdigest(),
            })
    (destination / "manifest.json").write_bytes((json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--grid-x", type=int, default=2)
    parser.add_argument("--grid-y", type=int, default=3)
    parser.add_argument("--count", type=int, choices=(4, 8), default=4)
    args = parser.parse_args()
    result = convert(args.source, args.destination, args.grid_x, args.grid_y, args.count)
    print(f"Converted {len(result['tiles'])} textured Helsinki tiles; bounds {result['source_bounds']}.")
