"""Real SQLite, native Godot schema, process races, interruption and portable restore."""
import argparse
import concurrent.futures
import copy
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import time
import uuid
import zipfile
from pathlib import Path


class Suite:
    def __init__(self, args):
        self.args = args
        self.output = Path(args.output).resolve(); self.output.mkdir(parents=True)
        self.root = self.output / "database with spaces"
        self.checks = []
        self.env = dict(os.environ, REGIONSTORE_TEST_FAULTS="1")
        self.region = "33333333-3333-4333-8333-333333333333"

    def check(self, passed, label):
        self.checks.append(dict(name=label, passed=bool(passed)))
        print(("PASS " if passed else "FAIL ") + label, flush=True)
        self.report()
        if not passed: raise AssertionError(label)

    def report(self):
        (self.output / "report.json").write_text(json.dumps(dict(test="sqlite-storage", passed=bool(self.checks) and all(x["passed"] for x in self.checks), checks=self.checks), indent=2) + "\n")

    def request(self, operation, **values):
        return dict(operation=operation, root=str(self.root), region_id=self.region, godot=str(Path(self.args.godot).resolve()), project=str(Path(self.args.project).resolve()), **values)

    def start(self, request):
        directory = self.output / "requests" / str(uuid.uuid4()); directory.mkdir(parents=True)
        source, target = directory / "request.json", directory / "response.json"
        source.write_text(json.dumps(request), encoding="utf-8")
        log = (directory / "process.txt").open("wb")
        process = subprocess.Popen([self.args.store, str(source), str(target)], stdout=log, stderr=subprocess.STDOUT, env=self.env)
        return process, target, log

    def invoke(self, request):
        process, target, log = self.start(request)
        try: process.wait(timeout=50)
        except subprocess.TimeoutExpired: process.kill(); process.wait(); raise
        finally: log.close()
        if not target.exists(): return dict(ok=False, error="NO_RESPONSE", exit_code=process.returncode)
        reply = json.loads(target.read_text(encoding="utf-8-sig")); reply["process_exit_code"] = process.returncode
        return reply

    def call(self, op, **values): return self.invoke(self.request(op, **values))

    def candidate(self, world, name):
        path = self.output / name; path.write_text(json.dumps(world), encoding="utf-8"); return str(path)

    def run(self):
        fixture = self.output / "fixture.snapshot.json"
        generation = subprocess.run([self.args.godot, "--headless", "--path", self.args.project, "--log-file", str(self.output / "fixture.log"), "--script", "res://tests/storage_fixture.gd", "--", "--output=" + str(fixture)], capture_output=True, timeout=30)
        self.check(generation.returncode == 0 and fixture.exists(), "native WorldService created grouped world with real building and door/lamp state")
        world = json.loads(json.loads(fixture.read_text(encoding="utf-8"))["world_json"])
        init = self.call("init")
        self.check(init["ok"] and init["schema_version"] == 2, "empty database initialized and migrated")
        (self.output / "runtime.json").write_text(json.dumps(init, indent=2) + "\n")
        self.check(self.call("init")["ok"], "repeated migration is idempotent")
        save = self.request("save", input=str(fixture), expected_commit=-1, request_id=str(uuid.uuid4()))
        first = self.invoke(save)
        self.check(first["ok"] and first["commit_revision"] == 0, "initial atomic database commit")
        loaded = self.call("load")
        self.check(loaded["ok"] and loaded["world"] == world, "database preserves complete world semantics and array order")
        self.check(self.invoke(save).get("replayed") is True, "same durable request returns prior commit after process exit")
        changed = copy.deepcopy(world); changed["objects"][0]["name"] += " revision"; changed["revision"] += 1
        new_file = self.candidate(changed, "candidate.json")
        reused = dict(save, input=new_file)
        self.check(self.invoke(reused).get("error") == "REQUEST_REUSED", "persistent request identity rejects altered candidate")
        db = self.root / "worlds.sqlite3"
        with sqlite3.connect(db) as c:
            self.check(c.execute("PRAGMA foreign_key_check").fetchall() == [], "region/group/member/asset foreign keys are valid")
            self.check(c.execute("SELECT count(*) FROM groups").fetchone()[0] == len(world["groups"]), "groups have independent database records")
        mesh = next(a for a in world["assets"] if a["kind"] == "mesh")
        self.check(len(list((self.root / "objects").glob("*.glb"))) == 1, "hash-addressed GLB stored once outside SQLite")
        with sqlite3.connect(db) as c:
            self.check('"glb"' not in c.execute("SELECT record_json FROM assets WHERE sha256 IS NOT NULL").fetchone()[0], "database metadata does not embed binary content")
        invalid = copy.deepcopy(changed); invalid["groups"][0]["root_id"] = str(uuid.uuid4())
        rejected = self.call("save", input=self.candidate(invalid, "invalid.json"), expected_commit=0, request_id=str(uuid.uuid4()))
        self.check(rejected.get("error") == "WORLD_VALIDATION_FAILED" and self.call("load")["world"] == world, "production GDScript rejects invalid candidate before database changes")
        bad_blob = copy.deepcopy(changed); next(a for a in bad_blob["assets"] if a["kind"] == "mesh")["glb"] = "AAAA"
        self.check(self.call("save", input=self.candidate(bad_blob, "invalid-asset.json"), expected_commit=0, request_id=str(uuid.uuid4())).get("error") == "WORLD_VALIDATION_FAILED", "shared mesh validator rejects corrupted embedded asset")
        # Two separate service and Godot processes race on the same expected token.
        race = [self.request("save", input=new_file, expected_commit=0, request_id=str(uuid.uuid4())) for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor: results = list(executor.map(self.invoke, race))
        self.check(sum(r["ok"] for r in results) == 1 and any(r.get("error") == "COMMIT_CONFLICT" for r in results), "two independent writers: exactly one CAS commit succeeds")
        self.check(self.call("load")["world"] == changed, "winning transaction publishes the whole candidate")
        for stage in ("after_groups", "before_commit"):
            rejected = self.call("save", input=str(fixture), expected_commit=1, request_id=str(uuid.uuid4()), fault=stage)
            self.check(rejected.get("error") == "INJECTED_" + stage.upper() and self.call("load")["world"] == changed, stage + " failure rolls back all member and group changes")
        # Publish a different valid GLB, then fail the DB transaction. Reuse a fully
        # validated original fixture (the alternate region stores a different asset).
        orphan_root = self.output / "publication failure"
        pub = self.request("save", input=str(fixture), expected_commit=-1, request_id=str(uuid.uuid4()), fault="after_assets"); pub["root"] = str(orphan_root)
        self.check(self.invoke(pub).get("error") == "INJECTED_AFTER_ASSETS" and len(list((orphan_root / "objects").glob("*.glb"))) == 1, "binary publication preceding DB failure leaves a detectable orphan")
        gc = self.request("gc"); gc["root"] = str(orphan_root)
        self.check(len(self.invoke(gc)["removed"]) == 1, "exclusive maintenance safely collects the unreferenced asset")
        self.check(self.call("gc")["removed"] == [] and self.call("load")["ok"], "garbage collection preserves committed content")
        # Kill the actual writer after uncommitted SQL rows have been changed.
        interrupted = self.request("save", input=str(fixture), expected_commit=1, request_id=str(uuid.uuid4()), fault="hold_before_commit")
        process, target, log = self.start(interrupted)
        try:
            deadline = time.monotonic() + 30
            while not (self.root / "fault-ready.txt").exists() and time.monotonic() < deadline: time.sleep(.05)
            self.check((self.root / "fault-ready.txt").exists() and process.poll() is None, "writer reached the uncommitted interruption barrier")
            process.kill(); process.wait(timeout=10)
        finally: log.close()
        self.check(not target.exists() and self.call("load")["world"] == changed, "process termination preserves the previous committed world")
        uncertain = self.request("save", input=str(fixture), expected_commit=1, request_id=str(uuid.uuid4()), fault="crash_after_commit")
        reply = self.invoke(uncertain)
        retry = dict(uncertain); retry.pop("fault")
        self.check(not reply["ok"] and self.invoke(retry).get("replayed") is True and self.call("load")["world"] == world, "post-commit process death is resolved by durable idempotent retry")
        # A real SQLite write lock makes competing saves fail without corruption.
        with sqlite3.connect(db) as c:
            c.execute("BEGIN IMMEDIATE")
            locked = self.call("save", input=new_file, expected_commit=2, request_id=str(uuid.uuid4()))
            self.check(locked.get("error") == "DATABASE_BUSY", "unavailable database writer lock is reported as failure")
            c.rollback()
        blob = self.root / "objects" / (mesh["sha256"] + ".glb")
        original_bytes = blob.read_bytes(); blob.write_bytes(b"broken")
        self.check(self.call("load").get("error") == "CONTENT_CHECKSUM_MISMATCH", "damaged binary makes the entire load fail explicitly")
        blob.write_bytes(original_bytes)
        missing = blob.with_suffix(".held"); blob.rename(missing)
        self.check(self.call("load").get("error") == "CONTENT_MISSING_OR_OVERSIZED", "missing binary cannot silently delete an object")
        missing.rename(blob)
        package = self.output / "portable.bundle.zip"
        exported = self.call("backup", output=str(package))
        self.check(exported["ok"] and package.exists(), "consistent region backup includes all referenced content")
        # No source GLB path is retained; move only the archive to a fresh location.
        moved_dir = self.output / "another machine path"; moved_dir.mkdir()
        moved = moved_dir / "world.zip"; shutil.move(package, moved)
        restored_root = moved_dir / "empty database"
        restore = self.request("import", input=str(moved), expected_commit=-1, request_id=str(uuid.uuid4())); restore["root"] = str(restored_root)
        restored = self.invoke(restore)
        read = self.request("load"); read["root"] = str(restored_root)
        restored_world = self.invoke(read)
        self.check(restored["ok"] and restored_world["world"] == world and restored["epoch"] != first["epoch"], "moved self-contained bundle restores IDs, groups, terrain, materials, states and a new epoch")
        for variant in ("path", "duplicate", "checksum", "missing", "future"):
            malformed = self.output / (variant + ".zip")
            with zipfile.ZipFile(moved) as source, zipfile.ZipFile(malformed, "w") as target_zip:
                for info in source.infolist():
                    if variant == "missing" and info.filename.startswith("objects/"): continue
                    data = source.read(info)
                    if variant == "checksum" and info.filename == "world.json": data += b" "
                    if variant == "future" and info.filename == "manifest.json":
                        manifest = json.loads(data); manifest["version"] = 999; data = json.dumps(manifest).encode()
                    target_zip.writestr(info.filename, data)
                if variant == "path": target_zip.writestr("../escape.txt", "invalid")
                if variant == "duplicate": target_zip.writestr("world.json", "{}")
            bad = dict(restore, input=str(malformed), request_id=str(uuid.uuid4()), expected_commit=0)
            result = self.invoke(bad)
            self.check(not result["ok"] and self.invoke(read)["world"] == world, "bundle " + variant + " rejected without altering restored database")
        # Fixture versions 1/2/3 traverse the same native upgrader; source bytes do not change.
        for filename in ("v1-region.snapshot.json", "v2-region.snapshot.json", "v3-region.snapshot.json"):
            legacy = Path(self.args.project).parent / "fixtures" / filename
            before = hashlib.sha256(legacy.read_bytes()).hexdigest()
            request = self.request("save", input=str(legacy), expected_commit=-1, request_id=str(uuid.uuid4())); request["root"] = str(self.output / filename)
            migration = self.invoke(request)
            self.check(migration["ok"] and hashlib.sha256(legacy.read_bytes()).hexdigest() == before, "native legacy migration preserves source: " + filename)
        # Roll back v2 migration from a genuine v1 schema, then complete it.
        v1_root = self.output / "migration database"
        setup = self.request("init"); setup["root"] = str(v1_root)
        self.check(self.invoke(setup)["ok"], "migration fixture starts from the complete real database schema")
        populated = self.request("save", input=str(fixture), expected_commit=-1, request_id=str(uuid.uuid4())); populated["root"] = str(v1_root)
        self.check(self.invoke(populated)["ok"], "upgrade fixture contains a complete committed region and asset")
        v1_db = v1_root / "worlds.sqlite3"
        with sqlite3.connect(v1_db) as c:
            c.execute("DROP TABLE commits")
            c.execute("ALTER TABLE regions DROP COLUMN epoch")
            c.execute("PRAGMA user_version=1")
        migrate = self.request("init", fault="migration"); migrate["root"] = str(v1_root)
        self.check(self.invoke(migrate).get("error") == "INJECTED_MIGRATION", "failed schema migration is explicit")
        with sqlite3.connect(v1_db) as c:
            self.check(c.execute("PRAGMA user_version").fetchone()[0] == 1 and "epoch" not in [x[1] for x in c.execute("PRAGMA table_info(regions)")], "failed migration rolls back schema and version atomically")
        migrate.pop("fault")
        self.check(self.invoke(migrate)["ok"], "migration can be retried after rollback")
        upgraded = self.request("load"); upgraded["root"] = str(v1_root)
        self.check(self.invoke(upgraded)["world"] == world, "populated database migration preserves all world records and external assets")
        with sqlite3.connect(v1_db) as c: c.execute("PRAGMA user_version=999")
        self.check(self.invoke(migrate).get("error") == "UNSUPPORTED_DATABASE_VERSION", "future database version refused")
        unavailable = self.output / "unavailable directory"; unavailable.write_text("not a directory")
        request = self.request("init"); request["root"] = str(unavailable)
        self.check(not self.invoke(request)["ok"], "unavailable storage path never reports a successful save")
        self.report()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("store", "godot", "project", "output"): parser.add_argument("--" + name, required=True)
    suite = Suite(parser.parse_args())
    try: suite.run()
    except BaseException as error:
        suite.checks.append(dict(name="suite completion", passed=False, error=type(error).__name__ + ": " + str(error))); suite.report(); raise
