"""Real SQLite, native Godot schema, process races, interruption and portable restore."""
import argparse
import concurrent.futures
import copy
import hashlib
import json
import os
import shutil
import sqlite3
import struct
import subprocess
import time
import uuid
import zipfile
from pathlib import Path


def glb_variant(source, index):
    """Keep valid geometry while giving each inventory entry distinct content."""
    if source[:4] != b"glTF" or struct.unpack_from("<I", source, 4)[0] != 2:
        raise ValueError("Inventory fixture must be GLB 2.0")
    json_length = struct.unpack_from("<I", source, 12)[0]
    document = json.loads(source[20:20 + json_length])
    document["asset"]["generator"] = f"Region Lab inventory bundle probe {index}"
    chunk = json.dumps(document, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    chunk += b" " * (-len(chunk) % 4)
    tail = source[20 + json_length:]
    return b"glTF" + struct.pack("<II", 2, 20 + len(chunk) + len(tail)) + struct.pack("<II", len(chunk), 0x4E4F534A) + chunk + tail


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
        self.check(init["ok"] and init["schema_version"] == 7, "empty database initialized and migrated")
        (self.output / "runtime.json").write_text(json.dumps(init, indent=2) + "\n")
        self.check(self.call("init")["ok"], "repeated migration is idempotent")
        save = self.request("save", input=str(fixture), expected_commit=-1, request_id=str(uuid.uuid4()))
        first = self.invoke(save)
        self.check(first["ok"] and first["commit_revision"] == 0, "initial atomic database commit")
        loaded = self.call("load")
        self.check(loaded["ok"] and loaded["world"] == world, "database preserves complete world semantics and array order")
        self.check(all("glb" not in asset for asset in loaded["world"]["assets"]), "database load transfers references rather than embedded mesh bytes")
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
            c.execute("DROP TABLE inventory_items")
            c.execute("DROP TABLE inventory_folders")
            c.execute("DROP TABLE grants")
            c.execute("DROP TABLE restrictions")
            c.execute("DROP TABLE audit_log")
            c.execute("DROP TABLE sessions")
            c.execute("DROP TABLE accounts")
            c.execute("DROP TABLE network_receipts")
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
        # V5 success receipts and world rows must have the same commit boundary.
        network_root = self.output / "network receipts"
        receipt_id, principal_id = str(uuid.uuid4()), str(uuid.uuid4())
        receipt = dict(request_id=receipt_id, principal_id=principal_id, fingerprint="a" * 64,
                       result=dict(ok=True, revision=world["revision"], request_id=receipt_id, world_epoch=str(uuid.uuid4())))
        network_save = self.request("save", input=str(fixture), expected_commit=-1, request_id=receipt_id, network_receipt=receipt)
        network_save["root"] = str(network_root)
        failed_save = dict(network_save, fault="before_commit")
        self.check(self.invoke(failed_save).get("error") == "INJECTED_BEFORE_COMMIT", "network transaction fails before publication")
        receipts = self.request("receipts"); receipts["root"] = str(network_root)
        self.check(self.invoke(receipts)["receipts"] == [], "rolled-back world never leaves a success receipt")
        committed = self.invoke(dict(network_save, fault="crash_after_commit"))
        self.check(not committed["ok"] and self.invoke(receipts)["receipts"] == [receipt], "success receipt survives writer death after commit")
        self.check(self.invoke(network_save).get("replayed") is True and len(self.invoke(receipts)["receipts"]) == 1, "network retry replays exactly one durable receipt")
        changed_receipt = copy.deepcopy(network_save); changed_receipt["network_receipt"]["principal_id"] = str(uuid.uuid4())
        self.check(self.invoke(changed_receipt).get("error") == "REQUEST_REUSED", "durable request fingerprint binds authenticated principal")
        invalid_receipt = copy.deepcopy(network_save); invalid_receipt["request_id"] = str(uuid.uuid4())
        self.check(self.invoke(invalid_receipt).get("error") == "INVALID_NETWORK_RECEIPT", "mismatched receipt and transaction identity rejected")
        with sqlite3.connect(network_root / "worlds.sqlite3") as c:
            c.execute("DROP TABLE inventory_items"); c.execute("DROP TABLE inventory_folders"); c.execute("DROP TABLE grants"); c.execute("DROP TABLE restrictions")
            c.execute("DROP TABLE audit_log"); c.execute("DROP TABLE sessions"); c.execute("DROP TABLE accounts")
            c.execute("DROP TABLE network_receipts"); c.execute("PRAGMA user_version=2")
        migrate2 = self.request("init", fault="migration_receipts"); migrate2["root"] = str(network_root)
        self.check(self.invoke(migrate2).get("error") == "INJECTED_MIGRATION_RECEIPTS", "v2 to v3 migration failure is explicit")
        with sqlite3.connect(network_root / "worlds.sqlite3") as c:
            self.check(c.execute("PRAGMA user_version").fetchone()[0] == 2 and not c.execute("SELECT name FROM sqlite_master WHERE name='network_receipts'").fetchall(), "v3 migration rolls back DDL and version together")
        migrate2.pop("fault")
        network_load = self.request("load"); network_load["root"] = str(network_root)
        self.check(self.invoke(migrate2)["ok"] and self.invoke(network_load)["world"] == world, "v2 database retries migration and preserves committed world")
        # V6 identity lifecycle: accounts, hashed sessions, atomic revocation and audit.
        identity_root = self.output / "identity database"
        init_id = self.request("init"); init_id["root"] = str(identity_root)
        self.check(self.invoke(init_id)["ok"], "identity database initialized at current schema")
        now = 1_760_000_000_000
        def identity(op, **values):
            request = self.request(op, **values); request["root"] = str(identity_root); return self.invoke(request)
        owner = identity("account_create", name="owner", role="owner", now_ms=now)
        self.check(owner["ok"] and owner["account"]["role"] == "owner" and not owner["account"]["disabled"], "owner account created with generated identifiers")
        owner_id = owner["account"]["id"]
        self.check(identity("account_create", name="owner", role="editor", now_ms=now).get("error") == "ACCOUNT_NAME_TAKEN", "duplicate account name rejected")
        self.check(identity("account_create", name="bad", role="admin", now_ms=now).get("error") == "INVALID_ACCOUNT_ROLE", "unknown role rejected")
        self.check(identity("account_create", name=" ", role="editor", now_ms=now).get("error") == "INVALID_ACCOUNT_NAME", "blank account name rejected")
        token = "secret-token-one"
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        issued = identity("session_issue", account_id=owner_id, token_hash=token_hash, now_ms=now, ttl_ms=3_600_000)
        self.check(issued["ok"] and issued["expires_at_ms"] == now + 3_600_000, "session issued with bounded ttl")
        valid = identity("session_validate", token_hash=token_hash, now_ms=now + 1000)
        self.check(valid["ok"] and valid["valid"] and valid["account"]["id"] == owner_id and valid["account"]["role"] == "owner", "hashed token validates to account")
        self.check(identity("session_validate", token_hash="b" * 64, now_ms=now).get("code") == "UNKNOWN_TOKEN", "unknown token refused without account detail")
        self.check(identity("session_issue", account_id=owner_id, token_hash=token_hash, now_ms=now, ttl_ms=3_600_000).get("error") == "SESSION_EXISTS", "duplicate token hash rejected")
        self.check(identity("session_issue", account_id=owner_id, token_hash="not-a-hash", now_ms=now, ttl_ms=3_600_000).get("error") == "INVALID_TOKEN_HASH", "malformed token hash rejected")
        self.check(identity("session_issue", account_id=owner_id, token_hash="c" * 64, now_ms=now, ttl_ms=1000).get("error") == "INVALID_SESSION_TTL", "ttl below floor rejected")
        short_hash = "d" * 64
        self.check(identity("session_issue", account_id=owner_id, token_hash=short_hash, now_ms=now, ttl_ms=60_000)["ok"], "minimum ttl session issued")
        self.check(identity("session_validate", token_hash=short_hash, now_ms=now + 61_000).get("code") == "SESSION_EXPIRED", "expired session refused at server time")
        revoked = identity("session_revoke", token_hash=token_hash, now_ms=now + 2000)
        self.check(revoked["ok"] and revoked["revoked"] == 1, "session revoked by token hash")
        self.check(identity("session_validate", token_hash=token_hash, now_ms=now + 3000).get("code") == "SESSION_REVOKED", "revoked session stays revoked")
        self.check(identity("session_revoke", now_ms=now).get("error") == "REVOKE_TARGET_REQUIRED", "revoke without target rejected")
        self.check(identity("session_revoke", token_hash=token_hash, account_id=owner_id, now_ms=now).get("error") == "REVOKE_TARGET_REQUIRED", "revoke with two targets rejected")
        editor = identity("account_create", name="editor", role="editor", now_ms=now)
        editor_id = editor["account"]["id"]
        editor_hash = "e" * 64
        self.check(identity("session_issue", account_id=editor_id, token_hash=editor_hash, now_ms=now, ttl_ms=3_600_000)["ok"], "second account session issued")
        disabled = identity("account_disable", account_id=editor_id, disabled=True, now_ms=now + 4000)
        self.check(disabled["ok"] and disabled["disabled"], "account disabled")
        self.check(identity("session_validate", token_hash=editor_hash, now_ms=now + 5000).get("code") == "SESSION_REVOKED", "disabling revokes live sessions atomically")
        self.check(identity("session_issue", account_id=editor_id, token_hash="f" * 64, now_ms=now, ttl_ms=3_600_000).get("error") == "ACCOUNT_DISABLED", "disabled account cannot receive sessions")
        enabled = identity("account_disable", account_id=editor_id, disabled=False, now_ms=now + 6000)
        self.check(enabled["ok"] and not enabled["disabled"], "account re-enabled")
        self.check(identity("session_validate", token_hash=editor_hash, now_ms=now + 7000).get("code") == "SESSION_REVOKED", "re-enable does not resurrect revoked sessions")
        new_editor_hash = "1" * 64
        self.check(identity("session_issue", account_id=editor_id, token_hash=new_editor_hash, now_ms=now + 8000, ttl_ms=3_600_000)["ok"], "re-enabled account receives new session")
        self.check(identity("session_validate", token_hash=new_editor_hash, now_ms=now + 9000)["valid"], "new session valid after re-enable")
        by_account = identity("session_revoke", account_id=editor_id, now_ms=now + 10000)
        self.check(by_account["ok"] and by_account["revoked"] == 1, "all account sessions revoked by account id")
        self.check(identity("account_disable", account_id=str(uuid.uuid4()), disabled=True, now_ms=now).get("error") == "ACCOUNT_NOT_FOUND", "disabling unknown account rejected")
        listing = identity("account_list")
        self.check(listing["ok"] and len(listing["accounts"]) == 2 and len(listing["sessions"]) >= 3, "account list exposes accounts and sessions")
        audit = identity("audit_list", limit=200)
        actions = [row[2] for row in audit["audit"]]
        self.check(audit["ok"] and "account_create" in actions and "session_revoke" in actions and "account_disable" in actions, "audit log records identity actions")
        self.check(audit["audit"][0][2] == "session_revoke" and audit["audit"][0][4] == "revoked_sessions=1", "audit log returned newest entry first")
        with sqlite3.connect(identity_root / "worlds.sqlite3") as c:
            self.check(c.execute("SELECT COUNT(*) FROM sessions WHERE token_hash=$h", (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()[0] == 1, "sessions persist only token hashes")
        # v3 to v4 migration rolls back DDL and version together.
        with sqlite3.connect(identity_root / "worlds.sqlite3") as c:
            c.execute("DROP TABLE inventory_items"); c.execute("DROP TABLE inventory_folders"); c.execute("DROP TABLE grants"); c.execute("DROP TABLE restrictions")
            c.execute("DROP TABLE audit_log"); c.execute("DROP TABLE sessions"); c.execute("DROP TABLE accounts"); c.execute("PRAGMA user_version=3")
        migrate3 = dict(init_id, fault="migration_identity")
        self.check(self.invoke(migrate3).get("error") == "INJECTED_MIGRATION_IDENTITY", "v3 to v4 migration failure is explicit")
        with sqlite3.connect(identity_root / "worlds.sqlite3") as c:
            self.check(c.execute("PRAGMA user_version").fetchone()[0] == 3 and not c.execute("SELECT name FROM sqlite_master WHERE name='accounts'").fetchall(), "v4 migration rolls back DDL and version together")
        migrate3.pop("fault")
        self.check(self.invoke(migrate3)["ok"], "v4 migration retries after rollback")
        # V6 permits: restrictions and per-account grants over the same database.
        permit_owner = identity("account_create", name="permit-owner", role="owner", now_ms=now)["account"]["id"]
        permit_guest = identity("account_create", name="permit-guest", role="observer", now_ms=now)["account"]["id"]
        thing = str(uuid.uuid4())
        applied = identity("object_restrict", object_id=thing, restricted=True, actor_id=permit_owner, now_ms=now)
        self.check(applied["ok"] and applied["restricted"], "object restriction registered")
        self.check(identity("object_restrict", object_id=str(uuid.uuid4()), restricted=True, actor_id=str(uuid.uuid4()), now_ms=now).get("error") == "ACCOUNT_NOT_FOUND", "restriction by unknown actor rejected")
        self.check(identity("grant_update", object_id=str(uuid.uuid4()), account_id=permit_guest, granted=True, actor_id=permit_owner, now_ms=now).get("error") == "OBJECT_NOT_RESTRICTED", "grant without restriction rejected")
        self.check(identity("grant_update", object_id=thing, account_id=str(uuid.uuid4()), granted=True, actor_id=permit_owner, now_ms=now).get("error") == "ACCOUNT_NOT_FOUND", "grant to unknown account rejected")
        granted = identity("grant_update", object_id=thing, account_id=permit_guest, granted=True, actor_id=permit_owner, now_ms=now)
        self.check(granted["ok"] and granted["granted"], "grant recorded for restricted object")
        listing = identity("grant_list")
        self.check(listing["ok"] and [r["object_id"] for r in listing["restrictions"]] == [thing] and [g["account_id"] for g in listing["grants"]] == [permit_guest], "grant list exposes restriction and grant")
        revoked = identity("grant_update", object_id=thing, account_id=permit_guest, granted=False, actor_id=permit_owner, now_ms=now)
        self.check(revoked["ok"] and not revoked["granted"] and identity("grant_list")["grants"] == [], "grant revoked")
        lifted = identity("object_restrict", object_id=thing, restricted=False, actor_id=permit_owner, now_ms=now)
        self.check(lifted["ok"] and not lifted["restricted"], "restriction lifted")
        cleared = identity("grant_list")
        self.check(cleared["restrictions"] == [] and cleared["grants"] == [], "lifting restriction retires its grants")
        audit = identity("audit_list", limit=50)
        actions = [row[2] for row in audit["audit"]]
        self.check("object_restrict" in actions and "grant_revoke" in actions and "object_unrestrict" in actions, "audit log records permit actions")
        # v4 to v5 migration rolls back DDL and version together.
        with sqlite3.connect(identity_root / "worlds.sqlite3") as c:
            c.execute("DROP TABLE inventory_items"); c.execute("DROP TABLE inventory_folders"); c.execute("DROP TABLE grants"); c.execute("DROP TABLE restrictions"); c.execute("PRAGMA user_version=4")
        migrate4 = dict(init_id, fault="migration_permits")
        self.check(self.invoke(migrate4).get("error") == "INJECTED_MIGRATION_PERMITS", "v4 to v5 migration failure is explicit")
        with sqlite3.connect(identity_root / "worlds.sqlite3") as c:
            self.check(c.execute("PRAGMA user_version").fetchone()[0] == 4 and not c.execute("SELECT name FROM sqlite_master WHERE name='grants'").fetchall(), "v5 migration rolls back DDL and version together")
        migrate4.pop("fault")
        self.check(self.invoke(migrate4)["ok"], "v5 migration retries after rollback")
        # V6 inventory: folders and items reference content by hash, independent of
        # world assets and scene instances.
        holder = self.call("account_create", name="inventory-holder", role="editor", now_ms=now)["account"]["id"]
        friend = self.call("account_create", name="inventory-friend", role="editor", now_ms=now)["account"]["id"]
        folder = self.call("inventory_folder_create", account_id=holder, name="props", now_ms=now)
        self.check(folder["ok"] and folder["folder"]["parent_id"] is None, "root inventory folder created")
        child = self.call("inventory_folder_create", account_id=holder, name="nested", parent_id=folder["folder"]["id"], now_ms=now)
        self.check(child["ok"] and child["folder"]["parent_id"] == folder["folder"]["id"], "nested folder created")
        self.check(self.call("inventory_folder_create", account_id=holder, name="bad", parent_id=str(uuid.uuid4()), now_ms=now).get("error") == "FOLDER_NOT_FOUND", "folder under unknown parent rejected")
        self.check(self.call("inventory_folder_create", account_id=holder, name="bad", parent_id=folder["folder"]["id"].replace(folder["folder"]["id"][0], "a" if folder["folder"]["id"][0] != "a" else "b"), now_ms=now).get("error") == "FOLDER_NOT_FOUND", "folder id from another tree rejected")
        self.check(self.call("inventory_folder_create", account_id=str(uuid.uuid4()), name="x", now_ms=now).get("error") == "ACCOUNT_NOT_FOUND", "folder for unknown account rejected")
        added = self.call("inventory_add", account_id=holder, name="Cabin kit", sha256=mesh["sha256"], license="CC0-1.0", attribution="test", now_ms=now)
        self.check(added["ok"] and added["item"]["asset_sha256"] == mesh["sha256"], "inventory item references content by hash")
        item_id = added["item"]["id"]
        self.check(self.call("inventory_add", account_id=holder, name="ghost", sha256="0" * 64, now_ms=now).get("error") == "CONTENT_UNKNOWN", "item for unknown content rejected")
        self.check(self.call("inventory_add", account_id=holder, name=" ", sha256=mesh["sha256"], now_ms=now).get("error") == "INVALID_ITEM_NAME", "blank item name rejected")
        self.check(self.call("inventory_add", account_id=friend, name="stolen", sha256=mesh["sha256"], folder_id=folder["folder"]["id"], now_ms=now).get("error") == "FOLDER_NOT_FOUND", "item into another account folder rejected")
        moved_item = self.call("inventory_move", item_id=item_id, folder_id=child["folder"]["id"], now_ms=now)
        self.check(moved_item["ok"] and moved_item["folder_id"] == child["folder"]["id"], "item moved into nested folder")
        self.check(self.call("inventory_move", item_id=item_id, folder_id=str(uuid.uuid4()), now_ms=now).get("error") == "FOLDER_NOT_FOUND", "move to unknown folder rejected")
        listing = self.call("inventory_list", account_id=holder)
        self.check(listing["ok"] and len(listing["folders"]) == 2 and len(listing["items"]) == 1, "inventory list shows folders and items")
        # Inventory keeps content alive for garbage collection even without world assets.
        with sqlite3.connect(db) as c:
            orphan_hash = "9" * 64
            c.execute("INSERT INTO contents(sha256,bytes) VALUES($h,4)", {"h": orphan_hash})
            c.execute("INSERT INTO inventory_items(id,account_id,folder_id,asset_sha256,name,license,attribution,created_at_ms) VALUES($i,$a,NULL,$h,'held','','',0)", {"i": str(uuid.uuid4()), "a": holder, "h": orphan_hash})
        (self.root / "objects" / (orphan_hash + ".glb")).write_bytes(b"held")
        self.check(self.call("gc")["removed"] == [], "garbage collection preserves inventory-referenced content")
        self.check((self.root / "objects" / (orphan_hash + ".glb")).exists(), "inventory-only content file survives collection")
        with sqlite3.connect(db) as c:
            c.execute("DELETE FROM inventory_items WHERE asset_sha256=$h", {"h": orphan_hash})
        self.check(orphan_hash + ".glb" in self.call("gc")["removed"], "content collected once inventory reference removed")
        # Give transfers the item; disabled recipients refused.
        self.call("account_disable", account_id=friend, disabled=True, now_ms=now)
        self.check(self.call("inventory_give", item_id=item_id, to_account_id=friend, now_ms=now).get("error") == "ACCOUNT_DISABLED", "give to disabled account rejected")
        self.call("account_disable", account_id=friend, disabled=False, now_ms=now)
        given = self.call("inventory_give", item_id=item_id, to_account_id=friend, now_ms=now)
        self.check(given["ok"] and given["account_id"] == friend, "item given to another account")
        self.check(self.call("inventory_list", account_id=holder)["items"] == [], "giver inventory empty after give")
        friend_listing = self.call("inventory_list", account_id=friend)
        self.check(len(friend_listing["items"]) == 1 and friend_listing["items"][0]["folder_id"] is None, "recipient finds item at inventory root")
        self.check(self.call("inventory_give", item_id=str(uuid.uuid4()), to_account_id=friend, now_ms=now).get("error") == "ITEM_NOT_FOUND", "give of unknown item rejected")
        removed_item = self.call("inventory_remove", item_id=item_id, now_ms=now)
        self.check(removed_item["ok"] and self.call("inventory_list", account_id=friend)["items"] == [], "item removed from inventory")
        self.check(self.call("inventory_remove", item_id=item_id, now_ms=now).get("error") == "ITEM_NOT_FOUND", "removing twice rejected")
        audit = self.call("audit_list", limit=200)
        actions = [row[2] for row in audit["audit"]]
        self.check("inventory_add" in actions and "inventory_give" in actions and "inventory_remove" in actions, "audit log records inventory actions")
        # Bundle v2 carries accounts, permits and inventory with their content.
        permit_item = self.call("inventory_add", account_id=holder, name="Roundtrip kit", sha256=mesh["sha256"], folder_id=folder["folder"]["id"], now_ms=now)["item"]["id"]
        self.call("object_restrict", object_id=world["objects"][0]["id"], restricted=True, actor_id=holder, now_ms=now)
        self.call("grant_update", object_id=world["objects"][0]["id"], account_id=friend, granted=True, actor_id=holder, now_ms=now)
        package2 = self.output / "v2.bundle.zip"
        exported2 = self.call("backup", output=str(package2))
        self.check(exported2["ok"], "v2 bundle exported with service data")
        service_root = self.output / "restored service"
        restore2 = self.request("import", input=str(package2), expected_commit=-1, request_id=str(uuid.uuid4())); restore2["root"] = str(service_root)
        self.check(self.invoke(restore2)["ok"], "v2 bundle restores into a fresh root")
        def restored(op, **values):
            request = self.request(op, **values); request["root"] = str(service_root); return self.invoke(request)
        r_accounts = restored("account_list")
        self.check(any(a["name"] == "inventory-holder" for a in r_accounts["accounts"]), "restored bundle preserves accounts")
        r_permits = restored("grant_list")
        self.check(len(r_permits["restrictions"]) == 1 and len(r_permits["grants"]) == 1, "restored bundle preserves restrictions and grants")
        holder_id = next(a["id"] for a in r_accounts["accounts"] if a["name"] == "inventory-holder")
        r_items = restored("inventory_list", account_id=holder_id)
        self.check(len(r_items["items"]) == 1 and r_items["items"][0]["id"] == permit_item and len(r_items["folders"]) == 2, "restored bundle preserves inventory folders and items")
        self.check(len(list((service_root / "objects").glob("*.glb"))) == 1, "restored bundle republishes referenced content")
        # A version 1 bundle without service data still imports (world only).
        v1_package = self.output / "v1.bundle.zip"
        with zipfile.ZipFile(package2) as source, zipfile.ZipFile(v1_package, "w") as target_zip:
            for info in source.infolist():
                if info.filename == "service.json": continue
                data = source.read(info)
                if info.filename == "manifest.json":
                    manifest = json.loads(data); manifest["version"] = 1
                    manifest["entries"] = [e for e in manifest["entries"] if e["path"] != "service.json"]
                    data = json.dumps(manifest).encode()
                target_zip.writestr(info.filename, data)
        v1_root = self.output / "restored v1"
        restore_v1 = self.request("import", input=str(v1_package), expected_commit=-1, request_id=str(uuid.uuid4())); restore_v1["root"] = str(v1_root)
        self.check(self.invoke(restore_v1)["ok"], "version 1 bundle imports without service data")
        # Inventory libraries can outnumber the world's 96 registered mesh assets.
        # Populate many unique valid content rows directly so this exercises the
        # backup format rather than hundreds of short-lived Store processes.
        source_glb = (Path(self.args.project).resolve().parent / "fixtures" / "meshes" / "bench.glb").read_bytes()
        library_hashes = []
        with sqlite3.connect(db) as c:
            for index in range(260):
                content = glb_variant(source_glb, index)
                digest = hashlib.sha256(content).hexdigest()
                library_hashes.append(digest)
                (self.root / "objects" / (digest + ".glb")).write_bytes(content)
                c.execute("INSERT INTO contents(sha256,bytes) VALUES(?,?)", (digest, len(content)))
                c.execute("INSERT INTO inventory_items(id,account_id,folder_id,asset_sha256,name,license,attribution,created_at_ms) VALUES(?,?,NULL,?,?,?, ?,?)",
                          (str(uuid.uuid4()), holder, digest, f"Library bench {index}", "CC0-1.0", "Region Lab fixture", now))
        self.check(len(set(library_hashes)) == 260, "inventory fixture contains 260 unique valid GLBs")
        library_bundle = self.output / "large-inventory.bundle.zip"
        library_backup = self.call("backup", output=str(library_bundle))
        self.check(library_backup["ok"] and library_bundle.exists(), "bundle exports a library exceeding the former 259-entry limit")
        with zipfile.ZipFile(library_bundle) as archive:
            names = archive.namelist()
            self.check(len(names) > 259 and all("objects/" + digest + ".glb" in names for digest in library_hashes), "bundle includes every inventory-only content file")
        library_root = self.output / "restored large inventory"
        restore_library = self.request("import", input=str(library_bundle), expected_commit=-1, request_id=str(uuid.uuid4())); restore_library["root"] = str(library_root)
        self.check(self.invoke(restore_library)["ok"], "large inventory bundle passes self-verification and restores")
        library_list = self.request("inventory_list", account_id=holder); library_list["root"] = str(library_root)
        restored_library = self.invoke(library_list)
        restored_hashes = {item["asset_sha256"] for item in restored_library.get("items", [])}
        self.check(restored_library["ok"] and len(restored_library["items"]) == 261 and set(library_hashes) <= restored_hashes,
                   "restored library retains all 260 inventory-only assets and the original item")
        self.check(all(hashlib.sha256((library_root / "objects" / (digest + ".glb")).read_bytes()).hexdigest() == digest for digest in library_hashes),
                   "restored library content hashes match its inventory records")
        # A live store refuses the next distinct blob before it can create a
        # library that its bounded backup format cannot represent.
        with sqlite3.connect(library_root / "worlds.sqlite3") as c:
            for index in range(260, 1023):
                content = glb_variant(source_glb, index)
                digest = hashlib.sha256(content).hexdigest()
                (library_root / "objects" / (digest + ".glb")).write_bytes(content)
                c.execute("INSERT INTO contents(sha256,bytes) VALUES(?,?)", (digest, len(content)))
                c.execute("INSERT INTO inventory_items(id,account_id,folder_id,asset_sha256,name,license,attribution,created_at_ms) VALUES(?,?,NULL,?,?,?, ?,?)",
                          (str(uuid.uuid4()), holder, digest, f"Capacity bench {index}", "CC0-1.0", "Region Lab fixture", now))
            next_content = glb_variant(source_glb, 1023)
            next_hash = hashlib.sha256(next_content).hexdigest()
            (library_root / "objects" / (next_hash + ".glb")).write_bytes(next_content)
            c.execute("INSERT INTO contents(sha256,bytes) VALUES(?,?)", (next_hash, len(next_content)))
        add_at_limit = self.request("inventory_add", account_id=holder, name="over content limit", sha256=next_hash, now_ms=now)
        add_at_limit["root"] = str(library_root)
        self.check(self.invoke(add_at_limit).get("error") == "CONTENT_LIBRARY_LIMIT", "new inventory content is rejected at the live library cap")
        kept_items = self.invoke(library_list)
        self.check(kept_items["ok"] and len(kept_items["items"]) == 1024, "capacity rejection leaves inventory unchanged")
        # A duplicate item needs no new content and remains usable at the blob cap.
        duplicate_at_limit = self.request("inventory_add", account_id=holder, name="shared content", sha256=library_hashes[0], now_ms=now)
        duplicate_at_limit["root"] = str(library_root)
        self.check(self.invoke(duplicate_at_limit)["ok"], "inventory may reuse existing content at the distinct-blob cap")
        # Simulate a pre-limit database whose retained-byte metadata already
        # exceeds the safe bundle budget; export must explain the failure.
        with sqlite3.connect(library_root / "worlds.sqlite3") as c:
            c.executemany("UPDATE contents SET bytes=? WHERE sha256=?", ((2 * 1024 * 1024, digest) for digest in library_hashes[:129]))
        legacy_over_limit = self.request("backup", output=str(self.output / "legacy-over-limit.bundle.zip")); legacy_over_limit["root"] = str(library_root)
        self.check(self.invoke(legacy_over_limit).get("error") == "CONTENT_LIBRARY_LIMIT", "existing over-budget library reports an explicit export error")
        over_limit = self.output / "too-many-entries.bundle.zip"
        with zipfile.ZipFile(library_bundle) as source, zipfile.ZipFile(over_limit, "w", compression=zipfile.ZIP_DEFLATED) as target_zip:
            for info in source.infolist(): target_zip.writestr(info, source.read(info))
            for index in range(4097 - len(names)):
                target_zip.writestr(f"objects/{index:064x}.glb", b"x")
        reject_many = self.request("import", input=str(over_limit), expected_commit=-1, request_id=str(uuid.uuid4())); reject_many["root"] = str(self.output / "reject many entries")
        self.check(self.invoke(reject_many).get("error") == "BUNDLE_ENTRY_LIMIT", "bundle still rejects archives over the bounded entry cap")
        # V6 agents: the widened role CHECK accepts agent; rebuild migration is atomic.
        self.check(identity("account_create", name="agent-7", role="agent", now_ms=now)["ok"], "agent role accepted after rebuild")
        self.check(identity("account_create", name="agent-bad", role="superuser", now_ms=now).get("error") == "INVALID_ACCOUNT_ROLE", "unknown role still rejected")
        with sqlite3.connect(identity_root / "worlds.sqlite3") as c:
            c.execute("UPDATE accounts SET role='editor' WHERE name='agent-7'"); c.execute("PRAGMA user_version=6")
        migrate5 = dict(init_id, fault="migration_agent_role")
        self.check(self.invoke(migrate5).get("error") == "INJECTED_MIGRATION_AGENT_ROLE", "v6 to v7 migration failure is explicit")
        with sqlite3.connect(identity_root / "worlds.sqlite3") as c:
            self.check(c.execute("PRAGMA user_version").fetchone()[0] == 6 and "accounts_v7" not in [x[0] for x in c.execute("SELECT name FROM sqlite_master")], "v7 migration rolls back rebuild and version together")
        migrate5.pop("fault")
        self.check(self.invoke(migrate5)["ok"], "v7 migration retries after rollback")
        with sqlite3.connect(identity_root / "worlds.sqlite3") as c:
            self.check(c.execute("PRAGMA foreign_key_check").fetchall() == [] and c.execute("SELECT COUNT(*) FROM accounts WHERE name='permit-owner'").fetchone()[0] == 1, "rebuild preserves accounts and referential integrity")
        self.check(identity("account_create", name="agent-7b", role="agent", now_ms=now)["ok"], "agent role accepted on migrated database")
        self.report()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("store", "godot", "project", "output"): parser.add_argument("--" + name, required=True)
    suite = Suite(parser.parse_args())
    try: suite.run()
    except BaseException as error:
        suite.checks.append(dict(name="suite completion", passed=False, error=type(error).__name__ + ": " + str(error))); suite.report(); raise
