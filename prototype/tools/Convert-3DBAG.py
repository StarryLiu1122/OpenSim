"""Convert a bounded 3DBAG CityJSONFeature response into Region Lab GLBs.

The input is a downloaded 3DBAG API response, not an arbitrary CityJSON file.
Only LoD 2.2 solid exteriors without polygon holes are accepted. No network or
third-party Python packages are needed during conversion.
"""
import argparse
import hashlib
import json
import math
import struct
from pathlib import Path


COLORS = {
    "GroundSurface": [0.31, 0.31, 0.29, 1],
    "WallSurface": [0.77, 0.72, 0.63, 1],
    "RoofSurface": [0.45, 0.27, 0.22, 1],
}


def cross(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def triangulate(points):
    """Ear-clip one simple planar 3D ring; preserve its source winding."""
    cleaned = []
    for point in points:
        if not cleaned or math.dist(point, cleaned[-1]) > 1e-6:
            cleaned.append(point)
    if len(cleaned) > 2 and math.dist(cleaned[0], cleaned[-1]) < 1e-6:
        cleaned.pop()
    if len(cleaned) < 3:
        raise ValueError("polygon has fewer than three distinct vertices")
    normal = [0.0, 0.0, 0.0]
    for a, b in zip(cleaned, cleaned[1:] + cleaned[:1]):
        normal[0] += (a[1] - b[1]) * (a[2] + b[2])
        normal[1] += (a[2] - b[2]) * (a[0] + b[0])
        normal[2] += (a[0] - b[0]) * (a[1] + b[1])
    drop = max(range(3), key=lambda axis: abs(normal[axis]))
    projected = [tuple(value for axis, value in enumerate(point) if axis != drop) for point in cleaned]
    indices = list(range(len(cleaned)))
    area = sum(projected[a][0] * projected[b][1] - projected[b][0] * projected[a][1]
               for a, b in zip(indices, indices[1:] + indices[:1]))
    if abs(area) < 1e-9:
        raise ValueError("polygon has zero projected area")
    sign = 1 if area > 0 else -1
    triangles = []
    while len(indices) > 3:
        for offset in range(len(indices)):
            a, b, c = [indices[(offset + shift) % len(indices)] for shift in (-1, 0, 1)]
            turn = cross(projected[a], projected[b], projected[c]) * sign
            if turn <= 1e-10:
                if abs(turn) <= 1e-10:
                    indices.remove(b)
                    break
                continue
            if any(cross(projected[a], projected[b], projected[p]) * sign >= -1e-10
                   and cross(projected[b], projected[c], projected[p]) * sign >= -1e-10
                   and cross(projected[c], projected[a], projected[p]) * sign >= -1e-10
                   for p in indices if p not in (a, b, c)):
                continue
            triangles.append((cleaned[a], cleaned[b], cleaned[c]))
            indices.remove(b)
            break
        else:
            raise ValueError("polygon cannot be triangulated without changing its outline")
    if len(indices) == 3:
        triangles.append(tuple(cleaned[index] for index in indices))
    return triangles


def glb_for_building(surface_triangles, center):
    binary = bytearray()
    views, accessors, primitives = [], [], []
    for material, triangles in enumerate(surface_triangles):
        if not triangles:
            continue
        binary.extend(b"\0" * (-len(binary) % 4))
        start = len(binary)
        for triangle in triangles:
            for x, y, z in triangle:
                binary.extend(struct.pack("<3f", x - center[0], z - center[2], center[1] - y))
        views.append({"buffer": 0, "byteOffset": start, "byteLength": len(binary) - start})
        accessors.append({"bufferView": len(views) - 1, "componentType": 5126,
                          "count": len(triangles) * 3, "type": "VEC3"})
        primitives.append({"attributes": {"POSITION": len(accessors) - 1}, "material": material})
    document = {
        "asset": {"version": "2.0", "generator": "Region Lab 3DBAG LoD2.2 converter"},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": primitives}],
        "materials": [{"doubleSided": True, "pbrMetallicRoughness": {
            "baseColorFactor": COLORS[kind], "metallicFactor": 0, "roughnessFactor": 0.95}}
            for kind in COLORS],
        "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(binary)}],
    }
    encoded = json.dumps(document, separators=(",", ":")).encode("utf-8")
    encoded += b" " * (-len(encoded) % 4)
    binary.extend(b"\0" * (-len(binary) % 4))
    return (struct.pack("<5I", 0x46546C67, 2, 28 + len(encoded) + len(binary),
                        len(encoded), 0x4E4F534A) + encoded
            + struct.pack("<2I", len(binary), 0x004E4942) + binary)


def convert(source, destination, limit=12, origin=(85000.0, 446700.0), offset=(128.0, 120.0)):
    raw = source.read_bytes()
    response = json.loads(raw)
    metadata = response["metadata"]
    if metadata["metadata"]["referenceSystem"] != "https://www.opengis.net/def/crs/EPSG/0/7415":
        raise ValueError("expected 3DBAG EPSG:7415 coordinates")
    if not 1 <= limit <= 16:
        raise ValueError("at most 16 imported assets fit one Region Lab region")
    if not all(math.isfinite(value) for value in (*origin, *offset)):
        raise ValueError("origin and region offset must be finite metre coordinates")
    transform = metadata["transform"]
    selected, skipped = [], []
    for feature in response["features"]:
        identifier = feature["id"]
        try:
            part = next(obj for obj in feature["CityObjects"].values() if obj["type"] == "BuildingPart")
            geometry = next(item for item in part["geometry"] if item["lod"] == "2.2" and item["type"] == "Solid")
            faces = geometry["boundaries"][0]
            labels = geometry["semantics"]["values"][0]
            semantics = geometry["semantics"]["surfaces"]
            if len(faces) != len(labels) or any(len(face) != 1 for face in faces):
                raise ValueError("unsupported polygon holes or surface labels")
            vertices = [tuple(value[axis] * transform["scale"][axis] + transform["translate"][axis]
                              for axis in range(3)) for value in feature["vertices"]]
            used = [vertices[index] for face in faces for index in face[0]]
            lower = [min(point[axis] for point in used) for axis in range(3)]
            upper = [max(point[axis] for point in used) for axis in range(3)]
            bounds = [upper[axis] - lower[axis] for axis in range(3)]
            if any(width < 0.2 or width > 32 for width in bounds):
                raise ValueError("outside 0.2–32 m per-axis asset bounds")
            center = [(lower[axis] + upper[axis]) * 0.5 for axis in range(3)]
            world_xy = [offset[0] + center[0] - origin[0], offset[1] + center[1] - origin[1]]
            if (world_xy[0] - bounds[0]/2 < 1 or world_xy[0] + bounds[0]/2 > 255
                    or world_xy[1] - bounds[1]/2 < 1 or world_xy[1] + bounds[1]/2 > 255):
                raise ValueError("building would cross the Region Lab boundary")
            surfaces = [[], [], []]
            for face, label in zip(faces, labels):
                kind = semantics[label]["type"]
                if kind not in COLORS:
                    raise ValueError("unsupported CityJSON surface type")
                surfaces[list(COLORS).index(kind)].extend(triangulate([vertices[index] for index in face[0]]))
            if sum(map(len, surfaces)) > 20000:
                raise ValueError("exceeds triangle budget")
            selected.append({"id": identifier, "center": center, "bounds": bounds,
                             "world_xy": world_xy, "surfaces": surfaces,
                             "triangles": sum(map(len, surfaces))})
        except (KeyError, IndexError, StopIteration, ValueError) as exc:
            skipped.append({"id": identifier, "reason": str(exc)})
    omitted = [item["id"] for item in selected[limit:]]
    selected = selected[:limit]
    if not selected:
        raise ValueError("no supported buildings in this response")
    baseline = min(item["center"][2] - item["bounds"][2] * .5 for item in selected)
    destination.mkdir(parents=True, exist_ok=True)
    manifest = {"source_url": response["links"][0]["href"], "source_sha256": hashlib.sha256(raw).hexdigest(),
                "source_crs": "EPSG:7415", "origin_rd": list(origin), "region_offset": list(offset),
                "height_baseline_nap": baseline, "license": "CC-BY-4.0",
                "attribution": "© 3DBAG by tudelft3d and 3DGI",
                "changes": "LoD2.2 triangulated, centered, recolored, and NAP elevation shifted to local ground",
                "buildings": [], "skipped": skipped, "omitted_by_limit": omitted}
    for item in selected:
        output = destination / (item["id"].split(".")[-1] + ".glb")
        content = glb_for_building(item["surfaces"], item["center"])
        if len(content) > 2 * 1024 * 1024:
            raise ValueError(f"{item['id']} exceeds the 2 MiB asset limit")
        output.write_bytes(content)
        manifest["buildings"].append({"id": item["id"], "file": output.name,
                                       "position": [*item["world_xy"], item["center"][2] - baseline],
                                       "bounds": [item["bounds"][0], item["bounds"][1], item["bounds"][2]],
                                       "triangles": item["triangles"], "sha256": hashlib.sha256(content).hexdigest()})
    (destination / "manifest.json").write_bytes((json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--limit", type=int, default=12)
    parser.add_argument("--origin-east", type=float, default=85000.0)
    parser.add_argument("--origin-north", type=float, default=446700.0)
    parser.add_argument("--offset-east", type=float, default=128.0)
    parser.add_argument("--offset-north", type=float, default=120.0)
    args = parser.parse_args()
    result = convert(args.source, args.destination, args.limit,
                     (args.origin_east, args.origin_north),
                     (args.offset_east, args.offset_north))
    print(f"Converted {len(result['buildings'])} real buildings; skipped {len(result['skipped'])} unsupported buildings.")
