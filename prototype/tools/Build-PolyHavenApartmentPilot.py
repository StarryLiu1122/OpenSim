"""Assemble a compact, textured street facade from Poly Haven's CC0 module kit.

The source glTF and its 1K JPEG dependencies are downloaded separately from
https://polyhaven.com/a/modular_urban_apartments_facade . This script keeps the
source geometry and UVs, reuses meshes across bays, and embeds nine PBR maps in
a self-contained GLB accepted by Region Lab's bounded static importer.
"""

from __future__ import annotations

import argparse
import copy
import io
import json
import struct
from pathlib import Path

from PIL import Image


def build(source: Path, output: Path) -> dict:
    gltf = json.loads(source.read_text(encoding="utf-8"))
    assert gltf["asset"]["version"] == "2.0"
    assert not gltf.get("extensionsRequired")
    raw = (source.parent / gltf["buffers"][0]["uri"]).read_bytes()
    payload = bytearray()
    views: list[dict] = []
    accessors: list[dict] = []
    meshes: list[dict] = []
    nodes: list[dict] = []
    images: list[dict] = []
    textures: list[dict] = []
    view_map: dict[int, int] = {}
    accessor_map: dict[int, int] = {}
    mesh_map: dict[int, int] = {}

    def add_view(data: bytes, target: int | None = None) -> int:
        payload.extend(b"\0" * ((-len(payload)) % 4))
        view = {"buffer": 0, "byteOffset": len(payload), "byteLength": len(data)}
        if target is not None:
            view["target"] = target
        views.append(view)
        payload.extend(data)
        return len(views) - 1

    def source_view(index: int) -> int:
        if index not in view_map:
            old = gltf["bufferViews"][index]
            start = old.get("byteOffset", 0)
            mapped = add_view(raw[start : start + old["byteLength"]], old.get("target"))
            if "byteStride" in old:
                views[mapped]["byteStride"] = old["byteStride"]
            view_map[index] = mapped
        return view_map[index]

    def source_accessor(index: int) -> int:
        if index not in accessor_map:
            item = copy.deepcopy(gltf["accessors"][index])
            assert "sparse" not in item
            item["bufferView"] = source_view(item["bufferView"])
            accessors.append(item)
            accessor_map[index] = len(accessors) - 1
        return accessor_map[index]

    material_map = {0: 0, 1: 1, 2: 2, 4: 3}

    def source_mesh(index: int) -> int:
        if index not in mesh_map:
            source_item = gltf["meshes"][index]
            primitives = []
            for old in source_item["primitives"]:
                primitive = {
                    "attributes": {key: source_accessor(value) for key, value in old["attributes"].items()},
                    "indices": source_accessor(old["indices"]),
                    "material": material_map[old["material"]],
                    "mode": 4,
                }
                assert set(primitive["attributes"]) == {"POSITION", "NORMAL", "TEXCOORD_0"}
                primitives.append(primitive)
            meshes.append({"name": source_item.get("name", "module"), "primitives": primitives})
            mesh_map[index] = len(meshes) - 1
        return mesh_map[index]

    source_nodes = {node["name"]: node for node in gltf["nodes"]}

    def add_module(name: str, x: float, y: float, z: float = 0.0) -> None:
        nodes.append({"name": name, "mesh": source_mesh(source_nodes[name]["mesh"]), "translation": [x, y, z]})

    # Source kit modules are three metres wide, with local X spanning -3..0.
    # A doorway and three windows form a two-bay, two-storey street frontage.
    add_module("wall_door_centered_large_01", 0, 0)
    add_module("door_centered_large_01", 0, 0)
    for x, y in [(3, 0), (0, 3), (3, 3)]:
        add_module("wall_window_centered_large_01", x, y)
        add_module("window_centered_large_01", x, y)
    for x in (0, 3):
        add_module("cornice_standard_standard_01", x, 3)
        add_module("cornice_standard_standard_01", x, 6)

    def add_geometry(name: str, quads: list[list[tuple[float, float, float]]], material: int | None) -> None:
        positions: list[float] = []
        normals: list[float] = []
        uvs: list[float] = []
        indices: list[int] = []
        for quad in quads:
            p0, p1, p2, p3 = quad
            u = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
            v = (p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2])
            cross = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
            length = sum(n * n for n in cross) ** 0.5
            normal = tuple(n / length for n in cross)
            start = len(positions) // 3
            for point, uv in zip(quad, [(0, 0), (1, 0), (1, 1), (0, 1)]):
                positions.extend(point)
                normals.extend(normal)
                uvs.extend(uv)
            indices.extend((start, start + 1, start + 2, start, start + 2, start + 3))
        def float_accessor(values: list[float], kind: str, width: int) -> int:
            view = add_view(struct.pack("<" + "f" * len(values), *values), 34962)
            item = {"bufferView": view, "componentType": 5126, "count": len(values) // width, "type": kind}
            if kind == "VEC3" and values is positions:
                item["min"] = [min(values[i::3]) for i in range(3)]
                item["max"] = [max(values[i::3]) for i in range(3)]
            accessors.append(item)
            return len(accessors) - 1
        attrs = {
            "POSITION": float_accessor(positions, "VEC3", 3),
            "NORMAL": float_accessor(normals, "VEC3", 3),
            "TEXCOORD_0": float_accessor(uvs, "VEC2", 2),
        }
        view = add_view(struct.pack("<" + "H" * len(indices), *indices), 34963)
        accessors.append({"bufferView": view, "componentType": 5123, "count": len(indices), "type": "SCALAR"})
        primitive = {"attributes": attrs, "indices": len(accessors) - 1, "mode": 4}
        if material is not None:
            primitive["material"] = material
        meshes.append({"name": name, "primitives": [primitive]})
        nodes.append({"name": name, "mesh": len(meshes) - 1})

    # The downloaded kit is a set of open facade modules. Complete its simple
    # rear shell while keeping the detailed imported frontage unchanged.
    add_geometry("rear_sides_and_roof", [
        [(-3, 0, 0), (-3, 0, -3), (-3, 6, -3), (-3, 6, 0)],
        [(3, 0, -3), (3, 0, 0), (3, 6, 0), (3, 6, -3)],
        [(-3, 0, -3), (3, 0, -3), (3, 6, -3), (-3, 6, -3)],
        [(-3, 6, 0), (-3, 6, -3), (3, 6, -3), (3, 6, 0)],
    ], 3)
    add_geometry("COL_simple_building", [
        [(-2.99, 0.01, -2.99), (2.99, 0.01, -2.99), (2.99, 5.99, -2.99), (-2.99, 5.99, -2.99)],
        [(-2.99, 0.01, 0.01), (2.99, 0.01, 0.01), (2.99, 5.99, 0.01), (-2.99, 5.99, 0.01)],
        [(-2.99, 0.01, -2.99), (-2.99, 0.01, 0.01), (-2.99, 5.99, 0.01), (-2.99, 5.99, -2.99)],
        [(2.99, 0.01, -2.99), (2.99, 0.01, 0.01), (2.99, 5.99, 0.01), (2.99, 5.99, -2.99)],
        [(-2.99, 5.99, -2.99), (2.99, 5.99, -2.99), (2.99, 5.99, 0.01), (-2.99, 5.99, 0.01)],
        [(-2.99, 0.01, -2.99), (2.99, 0.01, -2.99), (2.99, 0.01, 0.01), (-2.99, 0.01, 0.01)],
    ], None)

    image_slots: dict[tuple[str, str], int] = {}
    for group in ("objects", "trim_01", "plaster"):
        for role, quality in (("diff", 90), ("nor_gl", 80), ("arm", 80)):
            path = source.parent / "textures" / f"modular_urban_apartments_facade_{group}_{role}_1k.jpg"
            with Image.open(path) as original:
                assert original.size == (1024, 1024)
                stream = io.BytesIO()
                original.convert("RGB").save(stream, "JPEG", quality=quality, optimize=True, subsampling=0 if role == "diff" else 2)
            blob = stream.getvalue()
            assert len(blob) <= 1024 * 1024
            images.append({"bufferView": add_view(blob), "mimeType": "image/jpeg", "name": f"{group}_{role}"})
            textures.append({"source": len(images) - 1, "sampler": 0})
            image_slots[(group, role)] = len(textures) - 1

    def pbr(group: str, name: str, roughness: float = 1.0) -> dict:
        return {
            "name": name,
            "doubleSided": True,
            "normalTexture": {"index": image_slots[(group, "nor_gl")]},
            "pbrMetallicRoughness": {
                "baseColorTexture": {"index": image_slots[(group, "diff")]},
                "metallicRoughnessTexture": {"index": image_slots[(group, "arm")]},
                "roughnessFactor": roughness,
            },
        }

    materials = [
        pbr("objects", "Poly Haven doors and window frames"),
        {"name": "Opaque blue-grey window glass", "doubleSided": True,
         "pbrMetallicRoughness": {"baseColorFactor": [0.18, 0.22, 0.27, 1], "metallicFactor": 0.15, "roughnessFactor": 0.24}},
        pbr("trim_01", "Poly Haven stone trim"),
        pbr("plaster", "Poly Haven facade plaster"),
    ]
    document = {
        "asset": {"version": "2.0", "generator": "Build-PolyHavenApartmentPilot.py"},
        "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": materials,
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "images": images,
        "textures": textures,
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(payload)}],
    }
    json_bytes = json.dumps(document, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    json_bytes += b" " * ((-len(json_bytes)) % 4)
    payload.extend(b"\0" * ((-len(payload)) % 4))
    glb = struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(json_bytes) + 8 + len(payload))
    glb += struct.pack("<I4s", len(json_bytes), b"JSON") + json_bytes
    glb += struct.pack("<I4s", len(payload), b"BIN\0") + payload
    assert len(glb) <= 2 * 1024 * 1024, f"GLB exceeds project limit: {len(glb)} bytes"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(glb)
    return {"bytes": len(glb), "nodes": len(nodes), "meshes": len(meshes), "images": len(images)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Poly Haven 1K glTF, with its .bin and textures beside it")
    parser.add_argument("output", type=Path, help="bounded GLB to write")
    args = parser.parse_args()
    print(json.dumps(build(args.source, args.output)))
