"""Write a reproducible, bounded 80 m streetscape manifest from CC0 models.

This is an assembled demonstration, not a surveyed or georeferenced street.
The source meshes live in fixtures/geodata/polyhaven-urban-apartment/ and
retain their embedded 1K PBR images. The Godot builder imports each distinct
GLB once and places multiple world objects that reference it.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ASSET_DIR = Path(__file__).resolve().parents[1] / "fixtures/geodata/polyhaven-urban-apartment"
OUT = ASSET_DIR / "street-manifest.json"

ASSETS = {
    "apartment": {"file": "urban-apartment.glb", "bounds": [6.0, 3.2, 6.2], "front": "south", "name": "灰泥公寓"},
    "terracotta": {"file": "terracotta-residence.glb", "bounds": [6.0, 4.66, 6.75], "front": "south", "name": "陶土色住宅"},
    "sage": {"file": "sage-shopfront.glb", "bounds": [9.0, 5.6, 6.2], "front": "south", "name": "鼠尾草绿店铺"},
}


def primitive(name: str, position: list[float], bounds: list[float], color: str,
              material: str = "plain", kind: str = "box") -> dict:
    return {"name": name, "kind": kind, "position": position, "bounds": bounds,
            "color": color, "material": material}


def main() -> None:
    buildings: list[dict] = []
    blocks = [
        (96, "apartment", "sage"),
        (105, "terracotta", "apartment"),
        (115, "sage", "terracotta"),
        (125, "apartment", "sage"),
        (136, "sage", "apartment"),
        (147, "terracotta", "terracotta"),
        (157, "apartment", "sage"),
        (166, "sage", "apartment"),
    ]
    for side in ("north", "south"):
        for index, (east, northern, southern) in enumerate(blocks, 1):
            asset = ASSETS[northern if side == "north" else southern]
            bounds = asset["bounds"]
            # Building front is flush with the outer edge of a 3 m sidewalk.
            # All three source facades look south in the portable world axes.
            front_north = 117.0 if side == "north" else 103.0
            center_north = front_north + bounds[1] / 2 if side == "north" else front_north - bounds[1] / 2
            faces_wrong_way = (asset["front"] == "north") != (side == "south")
            entry = {
                "id": f"{side}-{index:02d}",
                "name": f"{side.title()} {index:02d} · {asset['name']}",
                "file": asset["file"],
                "sha256": hashlib.sha256((ASSET_DIR / asset["file"]).read_bytes()).hexdigest(),
                "position": [float(east), round(center_north, 3), round(bounds[2] / 2, 3)],
                "bounds": bounds,
            }
            if faces_wrong_way:
                entry["rotation"] = [0.0, 0.0, 1.0, 0.0]
            buildings.append(entry)

    street: list[dict] = []
    for number, east in enumerate((100, 120, 140, 160), 1):
        street.append(primitive(f"沥青色路面 {number}", [east, 110, -0.06], [20, 8, 0.2], "#333A3D", "concrete"))
        for side, north in (("南", 104.5), ("北", 115.5)):
            street.append(primitive(f"{side}侧人行道 {number}", [east, north, 0.04], [20, 3, 0.2], "#BDBBB1", "concrete"))
    for number, east in enumerate(range(97, 165, 9), 1):
        street.append(primitive(f"中心虚线 {number}", [east, 110, -0.04], [3, 0.2, 0.2], "#E7DDC0"))
    for side, base in (("西", 92), ("东", 165)):
        for index in range(5):
            street.append(primitive(f"{side}端斑马线 {index + 1}", [base + index, 110, -0.04], [0.5, 7.5, 0.2], "#E8E8DB"))
    for index, east in enumerate((95, 119, 143, 168), 1):
        street.append(primitive(f"北侧街灯 {index}", [east, 115.5, 2.25], [0.6, 0.6, 4.5], "#3F4B4D", "metal", "lamp"))
    for index, east in enumerate((107, 132, 156), 1):
        street.append(primitive(f"南侧街灯 {index}", [east, 104.5, 2.25], [0.6, 0.6, 4.5], "#3F4B4D", "metal", "lamp"))
    # The licensed facade kit is detailed only on the street-facing wall.
    # Simple rear window/door panels make the aerial view legible from either
    # side without pretending to be a second surveyed facade.
    for building in buildings:
        side = building["id"].split("-", 1)[0]
        east, _, _ = building["position"]
        width, depth, height = building["bounds"]
        rear_north = (117 + depth + 0.11) if side == "north" else (103 - depth - 0.11)
        columns = (-3.0, 0.0, 3.0) if width > 8 else (-1.5, 1.5)
        for floor, high in enumerate((1.65, min(4.7, height - 1.55)), 1):
            for column, offset in enumerate(columns, 1):
                street.append(primitive(f"{building['id']} 后窗 {floor}-{column}",
                                        [east + offset, rear_north, high], [1.25, 0.2, 1.4],
                                        "#3F5760", "metal"))
        if width <= 8:
            street.append(primitive(f"{building['id']} 后门", [east, rear_north, 1.05],
                                    [1.2, 0.2, 2.1], "#725A4A", "wood"))

    centers = [[east, north] for north in (104, 120) for east in (88, 104, 120, 136, 152, 168)]
    manifest = {
        "source_url": "https://polyhaven.com/a/modular_urban_apartments_facade",
        "source_crs": "LOCAL_METRES",
        "region_name": "高清街区体验区 · 80 米街道",
        "spawn": [94, 110, 1.8],
        "region_size": 256,
        "license": "CC0-1.0",
        "attribution": "Poly Haven; Modular Urban Apartments Facade by James Ray Cock; assembled street demonstration",
        "description": "80 m assembled demonstration street; not a real location or surveyed model",
        "terrain_flatten": {"centers": centers, "radius": 32, "passes": 2, "target_height": 0},
        "primitives": street,
        "buildings": buildings,
    }
    with OUT.open("w", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"{OUT}: {len(buildings)} buildings, {len(street)} street objects")


if __name__ == "__main__":
    main()
