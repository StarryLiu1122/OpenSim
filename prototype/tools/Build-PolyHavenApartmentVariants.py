"""Build two bounded street-building variants from Poly Haven's CC0 facade kit.

Input: the downloaded 1K glTF, BIN and JPEGs from
https://polyhaven.com/a/modular_urban_apartments_facade

Output: self-contained GLBs and a JSON report. The modules retain their source
geometry and UVs. Simple rear shells, a balconette and a shopfront fill the
open sides so these assets can be viewed from all directions in Region Lab.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import struct
from pathlib import Path

from PIL import Image


MAX_BYTES = 2 * 1024 * 1024
MAX_TRIANGLES = 20_000
MAX_VERTICES = 60_000


class Builder:
    def __init__(self, source: Path, variant: str):
        self.source = source
        self.variant = variant
        self.gltf = json.loads(source.read_text(encoding="utf-8"))
        if self.gltf["asset"]["version"] != "2.0" or self.gltf.get("extensionsRequired"):
            raise ValueError("Expected an unextended glTF 2.0 source")
        self.raw = (source.parent / self.gltf["buffers"][0]["uri"]).read_bytes()
        self.source_nodes = {node["name"]: node for node in self.gltf["nodes"]}
        self.payload = bytearray()
        self.views: list[dict] = []
        self.accessors: list[dict] = []
        self.meshes: list[dict] = []
        self.nodes: list[dict] = []
        self.images: list[dict] = []
        self.textures: list[dict] = []
        self.view_map: dict[int, int] = {}
        self.accessor_map: dict[int, int] = {}
        self.mesh_map: dict[int, int] = {}
        self.triangles = 0
        self.vertices = 0
        self.minimum = [float("inf")] * 3
        self.maximum = [float("-inf")] * 3

    def add_view(self, data: bytes, target: int | None = None) -> int:
        self.payload.extend(b"\0" * ((-len(self.payload)) % 4))
        view = {"buffer": 0, "byteOffset": len(self.payload), "byteLength": len(data)}
        if target is not None:
            view["target"] = target
        self.views.append(view)
        self.payload.extend(data)
        return len(self.views) - 1

    def source_view(self, index: int) -> int:
        if index not in self.view_map:
            old = self.gltf["bufferViews"][index]
            start = old.get("byteOffset", 0)
            mapped = self.add_view(self.raw[start : start + old["byteLength"]], old.get("target"))
            if "byteStride" in old:
                self.views[mapped]["byteStride"] = old["byteStride"]
            self.view_map[index] = mapped
        return self.view_map[index]

    def source_accessor(self, index: int) -> int:
        if index not in self.accessor_map:
            item = copy.deepcopy(self.gltf["accessors"][index])
            if "sparse" in item:
                raise ValueError("Sparse accessors are unsupported")
            item["bufferView"] = self.source_view(item["bufferView"])
            self.accessors.append(item)
            self.accessor_map[index] = len(self.accessors) - 1
        return self.accessor_map[index]

    def source_mesh(self, index: int) -> int:
        if index not in self.mesh_map:
            source_item = self.gltf["meshes"][index]
            primitives = []
            for old in source_item["primitives"]:
                if set(old["attributes"]) != {"POSITION", "NORMAL", "TEXCOORD_0"}:
                    raise ValueError("Unexpected source vertex attributes")
                primitives.append({
                    "attributes": {key: self.source_accessor(value) for key, value in old["attributes"].items()},
                    "indices": self.source_accessor(old["indices"]),
                    "material": {0: 0, 1: 1, 2: 2, 3: 4, 4: 3}[old["material"]],
                    "mode": 4,
                })
            self.meshes.append({"name": source_item.get("name", "module"), "primitives": primitives})
            self.mesh_map[index] = len(self.meshes) - 1
        return self.mesh_map[index]

    def record_bounds(self, points: list[tuple[float, float, float]]) -> None:
        for point in points:
            for axis in range(3):
                self.minimum[axis] = min(self.minimum[axis], point[axis])
                self.maximum[axis] = max(self.maximum[axis], point[axis])

    def add_module(self, name: str, x: float, y: float, z: float = 0) -> None:
        source_mesh_index = self.source_nodes[name]["mesh"]
        for primitive in self.gltf["meshes"][source_mesh_index]["primitives"]:
            position = self.gltf["accessors"][primitive["attributes"]["POSITION"]]
            self.record_bounds([tuple(position["min"][i] + (x, y, z)[i] for i in range(3)),
                                tuple(position["max"][i] + (x, y, z)[i] for i in range(3))])
            self.triangles += self.gltf["accessors"][primitive["indices"]]["count"] // 3
            self.vertices += position["count"]
        self.nodes.append({"name": f"{name}_{len(self.nodes)}", "mesh": self.source_mesh(source_mesh_index),
                           "translation": [x, y, z]})

    def add_quads(self, name: str, quads: list[list[tuple[float, float, float]]], material: int | None) -> None:
        if not quads:
            return
        positions: list[float] = []
        normals: list[float] = []
        uvs: list[float] = []
        indices: list[int] = []
        for quad in quads:
            p0, p1, p2, p3 = quad
            u = tuple(p1[i] - p0[i] for i in range(3))
            v = tuple(p2[i] - p0[i] for i in range(3))
            cross = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
            length = sum(value * value for value in cross) ** 0.5
            if length < 1e-9:
                raise ValueError(f"Degenerate quad in {name}")
            normal = tuple(value / length for value in cross)
            first = len(positions) // 3
            for point, uv in zip(quad, ((0, 0), (1, 0), (1, 1), (0, 1))):
                positions.extend(point)
                normals.extend(normal)
                uvs.extend(uv)
            indices.extend((first, first + 1, first + 2, first, first + 2, first + 3))
        if not name.startswith("COL_"):
            self.record_bounds([p for q in quads for p in q])
        self.triangles += len(indices) // 3
        self.vertices += len(positions) // 3

        def float_accessor(values: list[float], kind: str, width: int) -> int:
            view = self.add_view(struct.pack("<" + "f" * len(values), *values), 34962)
            item = {"bufferView": view, "componentType": 5126, "count": len(values) // width, "type": kind}
            if values is positions:
                item["min"] = [min(values[i::3]) for i in range(3)]
                item["max"] = [max(values[i::3]) for i in range(3)]
            self.accessors.append(item)
            return len(self.accessors) - 1

        attrs = {"POSITION": float_accessor(positions, "VEC3", 3),
                 "NORMAL": float_accessor(normals, "VEC3", 3),
                 "TEXCOORD_0": float_accessor(uvs, "VEC2", 2)}
        index_view = self.add_view(struct.pack("<" + "H" * len(indices), *indices), 34963)
        self.accessors.append({"bufferView": index_view, "componentType": 5123,
                               "count": len(indices), "type": "SCALAR"})
        primitive = {"attributes": attrs, "indices": len(self.accessors) - 1, "mode": 4}
        if material is not None:
            primitive["material"] = material
        self.meshes.append({"name": name, "primitives": [primitive]})
        self.nodes.append({"name": name, "mesh": len(self.meshes) - 1})

    @staticmethod
    def box(x0: float, x1: float, y0: float, y1: float, z0: float, z1: float) -> list[list[tuple[float, float, float]]]:
        return [
            [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
            [(x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0)],
            [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)],
            [(x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1)],
            [(x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0)],
            [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        ]

    def shell(self, x0: float, x1: float, height: float, depth: float) -> None:
        self.add_quads("rear_sides_roof", [
            [(x0, 0, 0), (x0, 0, -depth), (x0, height, -depth), (x0, height, 0)],
            [(x1, 0, -depth), (x1, 0, 0), (x1, height, 0), (x1, height, -depth)],
            [(x0, 0, -depth), (x1, 0, -depth), (x1, height, -depth), (x0, height, -depth)],
            [(x0, height, 0), (x0, height, -depth), (x1, height, -depth), (x1, height, 0)],
        ], 3)
        # A closed simple collision volume lives completely inside the visible shell.
        self.add_quads("COL_building", self.box(x0 + 0.01, x1 - 0.01,
                                                 0.01, height - 0.01,
                                                 -depth + 0.01, -0.01), None)

    def embed_textures(self) -> dict[tuple[str, str], int]:
        slots: dict[tuple[str, str], int] = {}
        for group in ("objects", "trim_01", "plaster", "trim_02"):
            roles = (("diff", 90), ("nor_gl", 80), ("arm", 80)) if group != "trim_02" else (("diff", 67),)
            for role, quality in roles:
                path = self.source.parent / "textures" / f"modular_urban_apartments_facade_{group}_{role}_1k.jpg"
                with Image.open(path) as original:
                    if original.size != (1024, 1024):
                        raise ValueError(f"Expected a 1K texture: {path}")
                    stream = io.BytesIO()
                    original.convert("RGB").save(stream, "JPEG", quality=quality, optimize=True,
                                                 subsampling=0 if role == "diff" and group != "trim_02" else 2)
                data = stream.getvalue()
                self.images.append({"bufferView": self.add_view(data), "mimeType": "image/jpeg",
                                    "name": f"{group}_{role}"})
                self.textures.append({"source": len(self.images) - 1, "sampler": 0})
                slots[(group, role)] = len(self.textures) - 1
        return slots

    def materials(self, slots: dict[tuple[str, str], int]) -> list[dict]:
        def textured(group: str, name: str, tint: list[float]) -> dict:
            pbr = {"baseColorTexture": {"index": slots[(group, "diff")]},
                   "baseColorFactor": tint, "roughnessFactor": 1.0}
            item = {"name": name, "doubleSided": True, "pbrMetallicRoughness": pbr}
            if (group, "nor_gl") in slots:
                item["normalTexture"] = {"index": slots[(group, "nor_gl")]}
                pbr["metallicRoughnessTexture"] = {"index": slots[(group, "arm")]}
            return item

        terracotta = self.variant == "terracotta"
        return [
            textured("objects", "Poly Haven timber frames and doors", [0.92, 0.86, 0.78, 1] if terracotta else [0.78, 0.86, 0.82, 1]),
            {"name": "Opaque blue-grey glass", "doubleSided": True,
             "pbrMetallicRoughness": {"baseColorFactor": [0.18, 0.25, 0.29, 1], "metallicFactor": 0.14, "roughnessFactor": 0.25}},
            textured("trim_01", "Poly Haven stone mouldings", [0.94, 0.85, 0.70, 1] if terracotta else [0.93, 0.94, 0.87, 1]),
            textured("plaster", "Poly Haven tinted plaster", [0.92, 0.60, 0.46, 1] if terracotta else [0.61, 0.80, 0.72, 1]),
            textured("trim_02", "Poly Haven crown stone", [0.91, 0.83, 0.72, 1] if terracotta else [0.86, 0.92, 0.84, 1]),
            {"name": "Wrought iron or painted frame", "doubleSided": True,
             "pbrMetallicRoughness": {"baseColorFactor": [0.11, 0.13, 0.14, 1] if terracotta else [0.12, 0.26, 0.29, 1],
                                      "metallicFactor": 0.28, "roughnessFactor": 0.53}},
            {"name": "Warm awning canvas", "doubleSided": True,
             "pbrMetallicRoughness": {"baseColorFactor": [0.72, 0.36, 0.25, 1], "roughnessFactor": 0.94}},
            {"name": "Pale awning canvas", "doubleSided": True,
             "pbrMetallicRoughness": {"baseColorFactor": [0.94, 0.85, 0.67, 1], "roughnessFactor": 0.94}},
        ]

    def finish(self, output: Path) -> dict:
        if self.triangles > MAX_TRIANGLES or self.vertices > MAX_VERTICES or len(self.nodes) > 256:
            raise ValueError(f"Importer budget exceeded: {self.triangles} triangles, {self.vertices} vertices")
        materials = self.materials(self.embed_textures())
        document = {
            "asset": {"version": "2.0", "generator": "Build-PolyHavenApartmentVariants.py"},
            "scene": 0, "scenes": [{"nodes": list(range(len(self.nodes)))}],
            "nodes": self.nodes, "meshes": self.meshes, "materials": materials,
            "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
            "images": self.images, "textures": self.textures,
            "accessors": self.accessors, "bufferViews": self.views,
            "buffers": [{"byteLength": len(self.payload)}],
        }
        json_bytes = json.dumps(document, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        json_bytes += b" " * ((-len(json_bytes)) % 4)
        self.payload.extend(b"\0" * ((-len(self.payload)) % 4))
        glb = struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(json_bytes) + 8 + len(self.payload))
        glb += struct.pack("<I4s", len(json_bytes), b"JSON") + json_bytes
        glb += struct.pack("<I4s", len(self.payload), b"BIN\0") + self.payload
        if len(glb) > MAX_BYTES or len(json_bytes) > 262144:
            raise ValueError(f"Importer byte budget exceeded: {len(glb)} total, {len(json_bytes)} JSON")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(glb)
        return {"file": output.name, "bytes": len(glb), "sha256": hashlib.sha256(glb).hexdigest(),
                "bounds_min_xyz_m": [round(v, 4) for v in self.minimum],
                "bounds_max_xyz_m": [round(v, 4) for v in self.maximum],
                "dimensions_xyz_m": [round(self.maximum[i] - self.minimum[i], 4) for i in range(3)],
                "triangles_including_proxy": self.triangles, "vertices_including_proxy": self.vertices,
                "nodes": len(self.nodes), "surfaces_including_proxy": sum(len(m["primitives"]) for n in self.nodes if "mesh" in n for m in [self.meshes[n["mesh"]]]),
                "textures": len(self.images)}


def terracotta(source: Path, output: Path) -> dict:
    b = Builder(source, "terracotta")
    b.add_module("wall_door_centered_small_01", 0, 0)
    b.add_module("door_centered_small_01", 0, 0)
    for x, y in ((3, 0), (0, 3), (3, 3)):
        b.add_module("wall_window_centered_double_02", x, y)
        b.add_module("window_centered_double_02", x, y)
    for x in (0, 3):
        b.add_module("cornice_standard_standard_01", x, 3)
        b.add_module("crown_standard_standard_01", x, 6)
    # Two shallow wrought-iron Juliet balconies distinguish the upper floor.
    dark: list[list[tuple[float, float, float]]] = []
    for shift in (-3.0, 0.0):
        dark += b.box(shift + 0.28, shift + 2.72, 3.37, 3.43, 0.24, 0.64)
        dark += b.box(shift + 0.30, shift + 2.70, 4.13, 4.19, 0.61, 0.66)
        for i in range(9):
            x = shift + 0.39 + i * 0.275
            dark += b.box(x, x + 0.035, 3.43, 4.15, 0.61, 0.66)
    b.add_quads("juliet_balconies", dark, 5)
    b.shell(-3, 3, 6.0, 4.0)
    return b.finish(output)


def shopfront(source: Path, output: Path) -> dict:
    b = Builder(source, "shopfront")
    # A third, custom middle bay widens this building to nine metres while the
    # two flanking bays keep the detailed Poly Haven door and window modules.
    for x in (0, 6):
        b.add_module("wall_door_window_small_01", x, 0)
        b.add_module("door_window_small_01", x, 0)
        b.add_module("wall_window_centered_large_02", x, 3)
        b.add_module("window_centered_large_02", x, 3)
        b.add_module("cornice_standard_standard_01", x, 3)
        b.add_module("cornice_standard_standard_01", x, 6)
    # The middle bay is a recessed display window below a double upper window.
    wall = []
    frame = []
    glass = []
    for low, high, left, right in ((0, 3, 0.30, 2.70), (3, 6, 0.45, 2.55)):
        sill = low + (0.34 if low == 0 else 0.70)
        head = low + (2.57 if low == 0 else 2.45)
        wall += b.box(0, left, low, high, -0.12, 0.0)
        wall += b.box(right, 3, low, high, -0.12, 0.0)
        wall += b.box(left, right, low, sill, -0.12, 0.0)
        wall += b.box(left, right, head, high, -0.12, 0.0)
        glass += b.box(left + 0.07, right - 0.07, sill + 0.07, head - 0.07, -0.09, -0.075)
        frame += b.box(left, right, sill, sill + 0.09, -0.06, 0.06)
        frame += b.box(left, right, head - 0.09, head, -0.06, 0.06)
        frame += b.box(left, left + 0.09, sill, head, -0.06, 0.06)
        frame += b.box(right - 0.09, right, sill, head, -0.06, 0.06)
        frame += b.box(1.455, 1.545, sill, head, -0.06, 0.06)
    b.add_quads("recessed_central_wall", wall, 3)
    b.add_quads("recessed_shop_glass", glass, 1)
    b.add_quads("painted_shop_frames", frame, 5)
    # Broad striped canvas projects above all three shopfronts.
    warm = []
    pale = []
    for i in range(12):
        x0 = -3 + i * 0.75
        x1 = x0 + 0.75
        quad = [(x0, 2.82, 0.11), (x1, 2.82, 0.11), (x1, 2.44, 1.10), (x0, 2.44, 1.10)]
        (warm if i % 2 else pale).append(quad)
    b.add_quads("ochre_canvas_awning", warm, 6)
    b.add_quads("cream_canvas_awning", pale, 7)
    b.add_quads("awning_frame", b.box(-3, 6, 2.80, 2.86, 0.08, 0.16), 5)
    b.shell(-3, 6, 6.15, 4.5)
    return b.finish(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Poly Haven source.gltf with BIN and 1K textures")
    parser.add_argument("output_dir", type=Path, help="Scratch output directory")
    args = parser.parse_args()
    report = {"source": str(args.source), "license": "Poly Haven CC0", "assets": [
        terracotta(args.source, args.output_dir / "terracotta-residence.glb"),
        shopfront(args.source, args.output_dir / "sage-shopfront.glb"),
    ]}
    (args.output_dir / "build-report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
