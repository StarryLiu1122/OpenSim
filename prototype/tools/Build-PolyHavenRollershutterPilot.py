"""Pack Poly Haven's CC0 Rollershutter Window 01 into a bounded static GLB.

The --download-source option fetches the official 1K glTF and dependencies from
https://polyhaven.com/a/rollershutter_window_01 and verifies their published MD5
digests. The source glTF contains two copies of the window, one plain and one
graffiti-covered, 3 m apart. This script selects one copy and embeds its original
1K PBR textures in a single GLB.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import struct
from pathlib import Path
from urllib.request import Request, urlopen

from PIL import Image


MAX_BYTES = 2 * 1024 * 1024
SOURCE_FILES = {
    "rollershutter_window_01_1k.gltf": (
        "https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/rollershutter_window_01/rollershutter_window_01_1k.gltf",
        "5228a7253b40de720ad8247757d218f1",
    ),
    "rollershutter_window_01.bin": (
        "https://dl.polyhaven.org/file/ph-assets/Models/gltf/8k/rollershutter_window_01/rollershutter_window_01.bin",
        "54837c166c34e1a1ca7f6495a82ab6d9",
    ),
    "textures/rollershutter_window_01_arm_1k.jpg": (
        "https://dl.polyhaven.org/file/ph-assets/Models/jpg/1k/rollershutter_window_01/rollershutter_window_01_arm_1k.jpg",
        "4ab04fd28873a76e2d84e47147eae6b0",
    ),
    "textures/rollershutter_window_01_diff_1k.jpg": (
        "https://dl.polyhaven.org/file/ph-assets/Models/jpg/1k/rollershutter_window_01/rollershutter_window_01_diff_1k.jpg",
        "0800d21822ec7199c825caafda90427a",
    ),
    "textures/rollershutter_window_01_graffiti_diff_1k.jpg": (
        "https://dl.polyhaven.org/file/ph-assets/Models/jpg/1k/rollershutter_window_01/rollershutter_window_01_graffiti_diff_1k.jpg",
        "10d15a7029c107af920b8f758e96a384",
    ),
    "textures/rollershutter_window_01_nor_gl_1k.jpg": (
        "https://dl.polyhaven.org/file/ph-assets/Models/jpg/1k/rollershutter_window_01/rollershutter_window_01_nor_gl_1k.jpg",
        "ce48690b51f8e17ab3567878158055f1",
    ),
}


def download_source(source: Path) -> None:
    if source.name != "rollershutter_window_01_1k.gltf":
        raise ValueError("--download-source requires the official glTF filename")
    for relative_path, (url, expected_md5) in SOURCE_FILES.items():
        destination = source.parent / relative_path
        if destination.exists() and hashlib.md5(destination.read_bytes()).hexdigest() == expected_md5:
            continue
        request = Request(url, headers={"User-Agent": "OpenSimulatorAssetPilot/1.0"})
        with urlopen(request, timeout=90) as response:
            blob = response.read()
        if hashlib.md5(blob).hexdigest() != expected_md5:
            raise ValueError(f"Poly Haven source checksum changed: {url}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(blob)


def build(source: Path, output: Path, variant: str = "graffiti") -> dict:
    if variant not in {"plain", "graffiti"}:
        raise ValueError("variant must be plain or graffiti")
    gltf = json.loads(source.read_text(encoding="utf-8"))
    if gltf["asset"]["version"] != "2.0" or gltf.get("extensionsRequired"):
        raise ValueError("Expected an unextended glTF 2.0 source")
    source_buffer = (source.parent / gltf["buffers"][0]["uri"]).read_bytes()
    if len(source_buffer) != gltf["buffers"][0]["byteLength"]:
        raise ValueError("Source binary length does not match glTF")

    chosen_name = (
        "rollershutter_window_01_graffiti"
        if variant == "graffiti"
        else "rollershutter_window_01"
    )
    node = next(n for n in gltf["nodes"] if n["name"] == chosen_name)
    source_mesh = gltf["meshes"][node["mesh"]]
    if len(source_mesh["primitives"]) != 1:
        raise ValueError("Expected one primitive in selected window")
    source_primitive = source_mesh["primitives"][0]
    if set(source_primitive["attributes"]) != {"POSITION", "NORMAL", "TEXCOORD_0"}:
        raise ValueError("Unexpected source vertex attributes")

    payload = bytearray()
    views: list[dict] = []
    accessors: list[dict] = []

    def add_view(blob: bytes, target: int | None = None) -> int:
        payload.extend(b"\0" * (-len(payload) % 4))
        view = {"buffer": 0, "byteOffset": len(payload), "byteLength": len(blob)}
        if target is not None:
            view["target"] = target
        views.append(view)
        payload.extend(blob)
        return len(views) - 1

    def add_accessor(index: int) -> int:
        accessor = copy.deepcopy(gltf["accessors"][index])
        if "sparse" in accessor:
            raise ValueError("Sparse source accessors are unsupported")
        old_view = gltf["bufferViews"][accessor["bufferView"]]
        offset = old_view.get("byteOffset", 0)
        blob = source_buffer[offset : offset + old_view["byteLength"]]
        accessor["bufferView"] = add_view(blob, old_view.get("target"))
        accessors.append(accessor)
        return len(accessors) - 1

    primitive = {
        "attributes": {
            key: add_accessor(source_primitive["attributes"][key])
            for key in ("POSITION", "NORMAL", "TEXCOORD_0")
        },
        "indices": add_accessor(source_primitive["indices"]),
        "material": 0,
        "mode": 4,
    }
    source_material = gltf["materials"][source_primitive["material"]]
    material = copy.deepcopy(source_material)
    material["alphaMode"] = "OPAQUE"
    images: list[dict] = []
    textures: list[dict] = []
    texture_map: dict[int, int] = {}

    def map_texture(old_index: int) -> int:
        if old_index not in texture_map:
            old_texture = gltf["textures"][old_index]
            old_image = gltf["images"][old_texture["source"]]
            if old_image["mimeType"] != "image/jpeg":
                raise ValueError("Expected Poly Haven JPEG texture")
            image_file = source.parent / old_image["uri"]
            with Image.open(image_file) as image:
                if image.format != "JPEG" or image.size != (1024, 1024):
                    raise ValueError(f"Expected 1K JPEG: {image_file}")
            blob = image_file.read_bytes()
            if len(blob) > 1024 * 1024:
                raise ValueError(f"Texture exceeds importer limit: {image_file}")
            images.append({
                "bufferView": add_view(blob),
                "mimeType": "image/jpeg",
                "name": old_image["name"],
            })
            textures.append({"source": len(images) - 1, "sampler": 0})
            texture_map[old_index] = len(textures) - 1
        return texture_map[old_index]

    material["normalTexture"]["index"] = map_texture(
        source_material["normalTexture"]["index"]
    )
    pbr = material["pbrMetallicRoughness"]
    source_pbr = source_material["pbrMetallicRoughness"]
    for role in ("baseColorTexture", "metallicRoughnessTexture"):
        pbr[role]["index"] = map_texture(source_pbr[role]["index"])

    minimum = gltf["accessors"][source_primitive["attributes"]["POSITION"]]["min"]
    maximum = gltf["accessors"][source_primitive["attributes"]["POSITION"]]["max"]
    dimensions = [maximum[i] - minimum[i] for i in range(3)]
    if not all(0.2 <= extent <= 32 for extent in dimensions):
        raise ValueError(f"Asset dimensions exceed importer limits: {dimensions}")
    triangles = gltf["accessors"][source_primitive["indices"]]["count"] // 3
    if triangles > 20_000:
        raise ValueError("Asset exceeds triangle limit")

    document = {
        "asset": {"version": "2.0", "generator": "Build-PolyHavenRollershutterPilot.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        # The source graffiti copy is translated +3 m beside the plain copy.
        # Omit that showcase translation so either variant is centred identically.
        "nodes": [{"name": chosen_name, "mesh": 0}],
        "meshes": [{"name": source_mesh["name"], "primitives": [primitive]}],
        "materials": [material],
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "images": images,
        "textures": textures,
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(payload)}],
    }
    json_bytes = json.dumps(document, separators=(",", ":")).encode("utf-8")
    json_bytes += b" " * (-len(json_bytes) % 4)
    payload.extend(b"\0" * (-len(payload) % 4))
    glb = struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(json_bytes) + 8 + len(payload))
    glb += struct.pack("<I4s", len(json_bytes), b"JSON") + json_bytes
    glb += struct.pack("<I4s", len(payload), b"BIN\0") + payload
    if len(glb) > MAX_BYTES:
        raise ValueError(f"GLB exceeds 2 MiB importer limit: {len(glb)} bytes")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(glb)
    return {
        "variant": variant,
        "bytes": len(glb),
        "sha256": hashlib.sha256(glb).hexdigest(),
        "triangles": triangles,
        "dimensions_xyz_m": dimensions,
        "embedded_jpeg_textures": len(images),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="official 1K glTF with .bin and textures beside it")
    parser.add_argument("output", type=Path, help="self-contained bounded GLB")
    parser.add_argument("--variant", choices=("plain", "graffiti"), default="graffiti")
    parser.add_argument("--download-source", action="store_true", help="fetch and MD5-check official source files")
    args = parser.parse_args()
    if args.download_source:
        download_source(args.source)
    print(json.dumps(build(args.source, args.output, args.variant)))
