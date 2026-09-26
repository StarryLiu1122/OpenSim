"""Exercise ten additional mesh imports on a full, disposable city snapshot."""
import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import uuid
from pathlib import Path


def variant(source: bytes, index: int) -> bytes:
    if source[:4] != b"glTF" or struct.unpack_from("<I", source, 4)[0] != 2:
        raise ValueError("The probe fixture must be GLB 2.0")
    length = struct.unpack_from("<I", source, 12)[0]
    document = json.loads(source[20:20 + length])
    document["asset"]["generator"] = f"Region Lab capacity probe {index}"
    chunk = json.dumps(document, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    chunk += b" " * (-len(chunk) % 4)
    tail = source[20 + length:]
    return b"glTF" + struct.pack("<II", 2, 20 + len(chunk) + len(tail)) + struct.pack("<II", len(chunk), 0x4E4F534A) + chunk + tail


def godot_batch(engine: Path, project: Path, directory: Path, world: Path, commands: list, phase: str):
    command_file = directory / f"{phase}-commands.json"
    report_file = directory / f"{phase}-report.json"
    command_file.write_text(json.dumps(commands, ensure_ascii=False), encoding="utf-8")
    invocation = [str(engine), "--headless", "--path", str(project), "--log-file", str(directory / f"{phase}.log"),
                  "--script", "res://tools/world_cli.gd", "--", f"--world-file={world}",
                  f"--commands={command_file}", f"--output={report_file}"]
    result = subprocess.run(invocation, capture_output=True, text=True, timeout=240)
    if result.returncode or not report_file.exists():
        raise RuntimeError(f"{phase}: Godot failed ({result.returncode}): {result.stdout[-2000:]} {result.stderr[-2000:]}")
    report = json.loads(report_file.read_text(encoding="utf-8"))
    if not report.get("ok"):
        raise RuntimeError(f"{phase}: {report_file}: {str(report.get('results', []))[:1200]}")
    return report


def store_call(store: Path, engine: Path, project: Path, directory: Path, root: Path, operation: str, **values):
    request = directory / f"store-{uuid.uuid4()}.json"
    response = directory / f"store-{uuid.uuid4()}.response.json"
    request.write_text(json.dumps({"operation": operation, "root": str(root), "region_id": "33333333-3333-4333-8333-333333333333",
                                   "godot": str(engine), "project": str(project), **values}), encoding="utf-8")
    run = subprocess.run([str(store), str(request), str(response)], capture_output=True, text=True, timeout=120)
    result = json.loads(response.read_text(encoding="utf-8")) if response.exists() else {}
    if run.returncode or not result.get("ok"):
        raise RuntimeError(f"RegionStore {operation}: {result or run.stderr[-1000:]}")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--seed", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--store", type=Path, help="Also verify SQLite save, bundle backup and restore")
    args = parser.parse_args()
    engine, project, seed, output = (p.resolve() for p in (args.godot, args.project, args.seed, args.output))
    if output.exists() or not seed.is_file() or not engine.is_file():
        raise ValueError("Use an existing engine and seed, and a new isolated output directory")
    original = json.loads(seed.read_text(encoding="utf-8"))
    source_world = json.loads(original["world_json"])
    original_count = sum(asset.get("kind") == "mesh" for asset in source_world["assets"])
    if original_count != 64:
        raise ValueError(f"The acceptance seed needs exactly 64 mesh assets; got {original_count}")
    output.mkdir(parents=True)
    world = output / "world.json"
    shutil.copy2(seed, world)
    if (Path(str(seed) + ".assets")).is_dir():
        shutil.copytree(Path(str(seed) + ".assets"), Path(str(world) + ".assets"))
    source_glb = (project / "../fixtures/meshes/bench.glb").resolve().read_bytes()
    commands = []
    for index in range(10):
        mesh = output / f"capacity-{index + 1}.glb"
        mesh.write_bytes(variant(source_glb, index + 1))
        commands.append({"operation": "ImportGlb", "payload": {"path": str(mesh), "name": f"Capacity probe {index + 1}",
                                                              "license": "CC0-1.0", "attribution": "Region Lab bench fixture"}})
    commands.append({"operation": "SaveRegion", "payload": {}})
    imported = godot_batch(engine, project, output, world, commands, "import")
    new_ids = [entry["payload"]["id"] for entry in imported["results"][:10]]
    stored = json.loads(world.read_text(encoding="utf-8"))
    compact = json.loads(stored["world_json"])
    assert stored["version"] == 2 and len(world.read_bytes()) < 8 * 1024 * 1024
    assert len(compact["assets"]) == len(source_world["assets"]) + 10
    assert all("glb" not in asset for asset in compact["assets"])
    assert [item["id"] for item in compact["objects"]] == [item["id"] for item in source_world["objects"]]
    for asset in compact["assets"]:
        if asset.get("kind") == "mesh":
            blob = Path(str(world) + ".assets") / (asset["sha256"] + ".glb")
            assert hashlib.sha256(blob.read_bytes()).hexdigest() == asset["sha256"]
    restarted = godot_batch(engine, project, output, world, [{"operation": "GetRegionSnapshot", "payload": {}}], "restart")
    hydrated = restarted["results"][0]["payload"]["world"]
    assert all(any(asset["id"] == id_ for asset in hydrated["assets"]) for id_ in new_ids)
    assert len(hydrated["assets"]) == len(compact["assets"])
    if args.store:
        store = args.store.resolve()
        source_root, restored_root = output / "sqlite-source", output / "sqlite-restored"
        store_call(store, engine, project, output, source_root, "save", input=str(world), expected_commit=-1, request_id=str(uuid.uuid4()))
        database_world = store_call(store, engine, project, output, source_root, "load")["world"]
        assert len(database_world["assets"]) == len(compact["assets"])
        assert all("glb" not in asset for asset in database_world["assets"])
        bundle = output / "sqlite-backup.zip"
        store_call(store, engine, project, output, source_root, "backup", output=str(bundle))
        store_call(store, engine, project, output, restored_root, "import", input=str(bundle), expected_commit=-1, request_id=str(uuid.uuid4()))
        restored_world = store_call(store, engine, project, output, restored_root, "load")["world"]
        assert restored_world == database_world
    godot_batch(engine, project, output, world, [{"operation": "SaveRegion", "payload": {}}], "backup")
    world.write_text("corrupt primary", encoding="utf-8")
    recovered = godot_batch(engine, project, output, world,
                            [{"operation": "LoadRegion", "payload": {}}, {"operation": "GetRegionSnapshot", "payload": {}}], "recover")
    assert recovered["results"][0]["payload"]["recovered"]
    assert len(recovered["results"][1]["payload"]["world"]["assets"]) == len(compact["assets"])
    result = {"ok": True, "seed_meshes": original_count, "added_meshes": 10,
              "persisted_meshes": len(compact["assets"]) - 6, "snapshot_version": 2,
              "snapshot_bytes": len(stored["world_json"].encode("utf-8")), "restart": True, "backup_recovery": True,
              "sqlite_backup_restore": bool(args.store)}
    (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
