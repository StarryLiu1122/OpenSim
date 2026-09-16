"""Deterministic low-poly derivative of HABS WIS-18, sheet 1 (public domain).

Not a scan: dimensioned structure plus explicitly estimated openings. The source
sheet and dimension/provenance manifest are distributed beside the generated GLB.
Python is required only for optional regeneration, not for import or rendering.
"""
import hashlib
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fixtures", HERE / "Generate-SampleAssets.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
DEST = HERE.parent / "fixtures" / "buildings" / "pioneer-log-cabin"
FOOT = 0.3048


class Building(fixtures.Asset):
    def __init__(self):
        super().__init__()
        self.vertices = []
        self.doc["asset"]["generator"] = "Region Lab HABS WIS-18 documented derivative v1"

    def mesh(self, name, faces, material):
        self.vertices.extend(v for face in faces for v in face)
        super().mesh(name, faces, material)

    def solid(self, name, position, size, material=3):
        self.box(name, position, size, material)
        self.box("COL_" + name, position, size, material)


def generate():
    DEST.mkdir(parents=True, exist_ok=True)
    b = Building()
    width = (15 + 1.5 / 12) * FOOT
    depth = (18 + 4 / 12) * FOOT
    porch = (6 + 5 / 12) * FOOT
    loft = (7 + 5 / 12) * FOOT
    eave = loft + (2 + 3 / 12) * FOOT
    ridge = loft + 6.5 * FOOT
    wall = 0.22  # Simplified average; logs are not individually surveyed in the model.
    floor = 0.12
    door_width, door_height = 0.84, 1.90  # Scale-derived estimates, not written dimensions.
    b.solid("Floor", (0, floor / 2, 0), (width, floor, depth), 3)
    b.solid("PorchFloor", (0, floor / 2, depth / 2 + porch / 2), (width - 0.45, floor, porch), 0)
    # Entrance faces local +Z. Thin opaque low walls preserve the documented porch outline.
    b.solid("PorchLeft", (-width / 2 + 0.25, 0.43, depth / 2 + porch / 2), (0.12, 0.62, porch), 3)
    b.solid("PorchRight", (width / 2 - 0.25, 0.43, depth / 2 + porch / 2), (0.12, 0.62, porch), 3)
    side_width = (width - door_width) / 2
    for sign, name in [(-1, "Left"), (1, "Right")]:
        b.solid("Front" + name, (sign * (door_width / 2 + side_width / 2), (eave + floor) / 2, depth / 2 - wall / 2), (side_width, eave - floor, wall))
    b.solid("EntranceLintel", (0, (floor + door_height + eave) / 2, depth / 2 - wall / 2), (door_width, eave - floor - door_height, wall))
    b.solid("Back", (0, (floor + eave) / 2, -depth / 2 + wall / 2), (width, eave - floor, wall))
    # Side window openings follow the 6-foot longitudinal dimension on the plan.
    window_z = -depth / 2 + 6 * FOOT
    window_width, window_bottom, window_top = 0.70, 0.90, 1.90
    for sign, name in [(-1, "South"), (1, "North")]:
        x = sign * (width / 2 - wall / 2)
        for suffix, a, c in [("Back", -depth / 2, window_z - window_width / 2), ("Front", window_z + window_width / 2, depth / 2)]:
            b.solid(name + suffix, (x, (floor + eave) / 2, (a + c) / 2), (wall, eave - floor, c - a))
        b.solid(name + "Sill", (x, (floor + window_bottom) / 2, window_z), (wall, window_bottom - floor, window_width))
        b.solid(name + "Header", (x, (window_top + eave) / 2, window_z), (wall, eave - window_top, window_width))
    b.solid("Loft", (0, loft, 0), (width - 2 * wall, 0.10, depth - 2 * wall), 3)
    # Gable and roof faces retain the measured section envelope. COL_ triangles
    # deliberately match these surfaces; the accessible ground-floor shell is closed.
    roof_faces = [
        [(-width / 2 - .12, eave, -depth / 2 - .12), (-width / 2 - .12, eave, depth / 2 + .12), (0, ridge, depth / 2 + .12), (0, ridge, -depth / 2 - .12)],
        [(0, ridge, -depth / 2 - .12), (0, ridge, depth / 2 + .12), (width / 2 + .12, eave, depth / 2 + .12), (width / 2 + .12, eave, -depth / 2 - .12)],
        [(-width / 2, eave, depth / 2), (width / 2, eave, depth / 2), (0, ridge, depth / 2)],
        [(width / 2, eave, -depth / 2), (-width / 2, eave, -depth / 2), (0, ridge, -depth / 2)],
    ]
    b.mesh("RoofAndGables", roof_faces, 0)
    b.mesh("COL_RoofAndGables", roof_faces, 0)
    chimney_x = -width / 2 + (10 + 7.5 / 12) * FOOT
    b.solid("Chimney", (chimney_x, 2.05, -depth / 2 - .25), (.90, 4.10, .65), 0)
    b.solid("Fireplace", (chimney_x, .72, -depth / 2 + .36), (1.25, 1.20, .50), 0)
    target = DEST / "pioneer-log-cabin.glb"
    b.save(target)
    minimum = [min(p[a] for p in b.vertices) for a in range(3)]
    maximum = [max(p[a] for p in b.vertices) for a in range(3)]
    manifest = {
        "name": "Pioneer Log Cabin, Milton, Wisconsin", "survey": "HABS WIS-18 / WIS,53-MILT,1-; sheet 1 of 1",
        "source_url": "https://www.loc.gov/pictures/resource/hhh.wi0107.sheet.00001a/",
        "source_tiff_url": "https://cdn.loc.gov/master/pnp/habshaer/wi/wi0100/wi0107/sheet/00001a.tif",
        "source_sha256": "dd439b12afb0364a7f0202e04136bf5f0c19389cf68d8b07b2ee75df6b7c7272",
        "rights_url": "https://www.loc.gov/rr/print/res/114_habs.html",
        "source_rights": "Public domain, original US Government HABS measured drawing; Herbert W. Bradley, delineator",
        "derivative_license": "CC0-1.0", "representation": "Simplified measured-drawing derivative, not a scan or certified building model",
        "measured_metres": {"main_width": width, "main_depth": depth, "porch_depth": porch, "loft_floor": loft, "eave": eave, "ridge": ridge},
        "estimated_metres": {"door_clear_width": door_width, "door_clear_height": door_height, "wall": wall, "floor": floor, "window_width": window_width},
        "estimated_opening_uncertainty_metres": 0.08,
        "simplifications": ["Untextured block walls instead of individual logs", "Door leaf shown open and omitted", "No underground tunnel, trapdoor or usable loft access", "Opening sizes scaled from drawing; no claimed field measurement", "Chimney and fireplace simplified; no fire simulation"],
        "axes": "GLB +Y up, +Z toward the entrance (historical east), +X historical north; no georeferencing",
        "bounds_min_glb": minimum, "bounds_max_glb": maximum,
        "center_glb": [(a + c) / 2 for a, c in zip(minimum, maximum)],
        "avatar": {"height": 1.8, "diameter": .7, "door_height_margin": door_height - 1.8, "door_width_margin": door_width - .7},
        "output_sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "bytes": target.stat().st_size,
        "visible_triangles": sum(m["primitives"][0]["attributes"]["POSITION"] >= 0 and b.doc["accessors"][m["primitives"][0]["attributes"]["POSITION"]]["count"] // 3 for i, m in enumerate(b.doc["meshes"]) if not b.doc["nodes"][i]["name"].startswith("COL_")),
    }
    (DEST / "provenance.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    generate()
