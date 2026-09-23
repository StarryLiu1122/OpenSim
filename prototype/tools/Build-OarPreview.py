"""Build a bounded Region Lab preview from a locally owned OpenSim OAR.

This is a geometry approximation: linked prims are sampled and mapped to the
six built-in shapes. It does not transfer textures, scripts, inventory or mesh.
The OAR and generated world are local data; do not publish either without
checking the source's redistribution rights.
"""

import argparse
import base64
import hashlib
import json
import math
import struct
import tarfile
import uuid
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

OWNER = "11111111-1111-4111-8111-111111111111"
REGION = "33333333-3333-4333-8333-333333333333"
KINDS = ("box", "cylinder", "sphere", "door", "tree", "lamp")


def vec(element, keys="XYZ"):
    return tuple(float(element.findtext(key, "0")) for key in keys)


def multiply(a, b):
    x, y, z, w = a
    u, v, t, s = b
    return (w*u+x*s+y*t-z*v, w*v-x*t+y*s+z*u,
            w*t+x*v-y*u+z*s, w*s-x*u-y*v-z*t)


def rotate(q, v):
    x, y, z, w = q
    u, t, s = v
    cross = (y*s-z*t, z*u-x*s, x*t-y*u)
    return (u+2*(w*cross[0]+y*cross[2]-z*cross[1]),
            t+2*(w*cross[1]+z*cross[0]-x*cross[2]),
            s+2*(w*cross[2]+x*cross[1]-y*cross[0]))


def stable_uuid(key):
    value = bytearray(hashlib.sha256(key.encode()).digest()[:16])
    value[6] = (value[6] & 15) | 64
    value[8] = (value[8] & 63) | 128
    return str(uuid.UUID(bytes=bytes(value)))


def tint(part, kind):
    name = part.findtext("Name", "").lower()
    if any(word in name for word in ("tree", "grass", "fern", "leaf")):
        return "#5C7749"
    if any(word in name for word in ("roof", "tile")):
        return "#766B61"
    encoded = part.findtext("Shape/TextureEntry", "")
    try:
        values = base64.b64decode(encoded, validate=True)[16:20]
        if len(values) == 4 and values[3] >= 80:
            rgb = tuple(255 - v for v in values[:3])
            if max(rgb) - min(rgb) < 12 and sum(rgb) > 690:
                return "#C9C5B8" if kind == "box" else "#B8B4A6"
            return "#%02X%02X%02X" % rgb
    except (ValueError, base64.binascii.Error):
        pass
    return "#B8B4A6"


def part_record(part, origin, root_rotation, source_key, is_root):
    scale = vec(part.find("Scale"))
    if any(not math.isfinite(n) or n <= 0 for n in scale):
        return None
    if any(n > 32 for n in scale):
        return None
    local = vec(part.find("OffsetPosition"))
    offset = rotate(root_rotation, local)
    position = tuple(origin[i] + offset[i] for i in range(3))
    if not (2 < position[0] < 254 and 2 < position[1] < 254 and 15 < position[2] < 90):
        return None
    local_rotation = vec(part.find("RotationOffset"), "XYZW")
    q = root_rotation if is_root else multiply(root_rotation, local_rotation)
    length = math.sqrt(sum(n*n for n in q))
    if length < 1e-6:
        return None
    q = tuple(n / length for n in q)
    # The domain validator checks the rotated footprint and minimum dimensions.
    dims = tuple(max(0.2, n) for n in scale)
    x, y, z, w = q
    basis = ((1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)),
             (2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)))
    ex = sum(abs(basis[0][i])*dims[i]*0.5 for i in range(3))
    ey = sum(abs(basis[1][i])*dims[i]*0.5 for i in range(3))
    if position[0]-ex < 0 or position[0]+ex > 256 or position[1]-ey < 0 or position[1]+ey > 256:
        return None
    shape = part.findtext("Shape/ProfileShape", "Square")
    path = part.findtext("Shape/PathCurve", "16")
    kind = "sphere" if path == "32" else "cylinder" if shape == "Circle" else "box"
    # Large curved and vegetation prims in this archive are texture/sculpt
    # carriers. Plain builtin cylinders turn them into misleading solid drums.
    if kind != "box" and (max(scale[:2]) > 7 or scale[2] > 14):
        return None
    if part.findtext("Name", "").strip().lower() in ("grass", "fern"):
        return None
    area = dims[0]*dims[1] + dims[0]*dims[2] + dims[1]*dims[2]
    return dict(key=source_key, position=position, rotation=q, size=dims,
                kind=kind, color=tint(part, kind), area=area,
                name=part.findtext("Name", "Primitive"))


def build(source, focus, limit):
    groups = []
    terrain = None
    with tarfile.open(source) as archive:
        for entry in archive:
            if entry.name.startswith("terrains/") and entry.name.endswith(".r32"):
                raw = archive.extractfile(entry).read()
                if len(raw) == 256*256*4:
                    terrain = [struct.unpack_from("<f", raw, (y*256+x)*4)[0]
                               for y in range(0, 256, 4) for x in range(0, 256, 4)]
            if not entry.name.startswith("objects/") or not entry.name.endswith(".xml"):
                continue
            if entry.size > 2 * 1024 * 1024:
                continue
            root = ET.fromstring(archive.extractfile(entry).read())
            first = root.find("SceneObjectPart")
            if first is None:
                continue
            origin = vec(first.find("GroupPosition"))
            if not (focus[0]-110 <= origin[0] <= focus[0]+145 and
                    focus[1]-85 <= origin[1] <= focus[1]+80 and 15 <= origin[2] < 90):
                continue
            rotation = vec(first.find("RotationOffset"), "XYZW")
            if sum(n*n for n in rotation) < 1e-6:
                continue
            linked = root.find("OtherParts")
            elements = [first] + (list(linked) if linked is not None else [])
            records = [part_record(part, origin, rotation, entry.name+":"+str(i), i == 0)
                       for i, part in enumerate(elements)]
            records = [r for r in records if r is not None]
            if records:
                groups.append((first.findtext("Name", "Primitive"), origin, records))
    if terrain is None:
        raise ValueError("OAR has no 256 x 256 float32 terrain")
    # 65th sample is the nearest edge height; this makes 256 m coverage.
    heights = []
    for y in range(65):
        for x in range(65):
            if y < 64 and x < 64:
                value = terrain[y*64+x]
            else:
                # The source samples are at 4 m intervals; duplicate the edge.
                value = terrain[min(y, 63)*64+min(x, 63)]
            heights.append(round(max(-40, min(80, value)), 3))
    score_groups = []
    for name, origin, records in groups:
        distance = math.hypot(origin[0]-focus[0], origin[1]-focus[1])
        largest = max(record["area"] for record in records)
        named = name.lower() not in ("primitive", "xsg-1")
        score = math.sqrt(largest)*1.6 + math.log1p(len(records))*7 + (18 if named else 0) - distance*0.22
        score_groups.append((score, name, origin, records))
    score_groups.sort(key=lambda g: (-g[0], g[1], g[2]))
    selected = []
    # Reserve breadth first, then add the largest visible components from each group.
    picked = score_groups[:min(105, limit//3)]
    seen = set()
    for _, _, _, records in picked:
        record = max(records, key=lambda r: (r["area"], r["key"]))
        selected.append(record)
        seen.add(record["key"])
    pool = []
    for group_index, (_, _, origin, records) in enumerate(picked):
        for record in records:
            if record["key"] in seen:
                continue
            distance = math.hypot(record["position"][0]-focus[0], record["position"][1]-focus[1])
            score = math.sqrt(record["area"])*2 - distance*0.08 + (4 if record["name"].lower() != "primitive" else 0)
            pool.append((score, group_index, record))
    pool.sort(key=lambda row: (-row[0], row[1], row[2]["key"]))
    per_group = defaultdict(int)
    for _, group_index, record in pool:
        if len(selected) >= limit:
            break
        if per_group[group_index] >= 12:
            continue
        selected.append(record)
        per_group[group_index] += 1
    # Avoid exact duplicate geometry from duplicate linked groups in old archives.
    unique = []
    footprints = set()
    for record in selected:
        key = (record["kind"], *(round(v, 2) for v in record["position"]),
               *(round(v, 2) for v in record["size"]))
        if key not in footprints:
            unique.append(record)
            footprints.add(key)
    catalog = []
    for i, kind in enumerate(KINDS):
        asset_id = "22222222-2222-4222-8222-222222222222" if i == 0 else "22222222-2222-4222-8222-%012d" % (i+1)
        catalog.append(dict(id=asset_id, kind=kind, uri="builtin://unit-"+kind))
    objects = []
    for i, r in enumerate(unique):
        name = f"{r['name'].strip() or 'Primitive'} {i+1:03d}"[:80]
        objects.append(dict(id=stable_uuid(r["key"]), name=name,
                            asset_id=catalog[KINDS.index(r["kind"])]["id"], owner_id=OWNER,
                            position=[round(v, 5) for v in r["position"]],
                            rotation=[round(v, 8) for v in r["rotation"]],
                            size=[round(v, 5) for v in r["size"]], color=r["color"],
                            material="plain", state={}, group_id=""))
    spawn_height = heights[round(focus[1]/4)*65+round(focus[0]/4)]
    world = dict(schema_version=3, revision=0,
                 region=dict(id=REGION, name="北大课程校园·西门预览", size=[256.0, 256.0],
                             spawn=[focus[0], focus[1], round(spawn_height+2.5, 3)], owner_id=OWNER),
                 terrain=dict(columns=65, rows=65, spacing=4.0, heights=heights),
                 assets=catalog, objects=objects, groups=[],
                 environment=dict(sun_hour=14.0, water_enabled=False, water_height=-1.0,
                                  fog_density=0.001, terrain_grid=False))
    return world, dict(source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                       focus=focus, groups_examined=len(groups), objects=len(objects),
                       terrain_min=min(heights), terrain_max=max(heights),
                       note="Approximate geometry-only sample from the local course OAR; no textures, scripts or inventory.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("oar", type=Path)
    parser.add_argument("world_json", type=Path)
    parser.add_argument("--focus", nargs=2, type=float, default=[34.0, 160.0], metavar=("X", "Y"))
    parser.add_argument("--limit", type=int, default=450)
    args = parser.parse_args()
    if not (1 <= args.limit <= 500):
        parser.error("--limit must be 1..500")
    if args.world_json.exists():
        parser.error("output must be a new file")
    world, manifest = build(args.oar, args.focus, args.limit)
    args.world_json.parent.mkdir(parents=True, exist_ok=True)
    args.world_json.write_text(json.dumps(world, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    args.world_json.with_suffix(".manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == "__main__":
    main()
