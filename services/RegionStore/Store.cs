using System.Diagnostics;
using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace RegionLab.Storage;

internal sealed class StoreError(string code) : Exception(code);

internal sealed class Store : IDisposable
{
    internal const int MaxWorldBytes = 8 * 1024 * 1024;
    private const int SchemaVersion = 5;
    private static readonly HashSet<string> IdentityOperations = new(StringComparer.Ordinal)
    { "account_create", "account_list", "account_disable", "session_issue", "session_revoke", "session_validate", "audit_list" };
    private static readonly HashSet<string> PermitOperations = new(StringComparer.Ordinal)
    { "object_restrict", "grant_update", "grant_list" };
    private readonly string root, database, content;
    private readonly JsonObject configuration;
    private SqliteConnection? connection;
    private SqliteTransaction? transaction;
    private string? fault;
    internal Store(JsonObject request)
    {
        configuration = request;
        root = Path.GetFullPath(S(request, "root")); database = Path.Combine(root, "worlds.sqlite3"); content = Path.Combine(root, "objects");
        if (request.ContainsKey("fault"))
        {
            if (Environment.GetEnvironmentVariable("REGIONSTORE_TEST_FAULTS") != "1") throw new StoreError("FAULT_INJECTION_DISABLED");
            fault = S(request, "fault");
        }
    }
    internal object Execute(JsonObject request)
    {
        string operation = S(request, "operation");
        if (operation is "init" or "save" or "import" or "account_create" or "account_disable" or "session_issue" or "session_revoke" or "object_restrict" or "grant_update") Open(true); else Open(false);
        string id = operation is "init" or "status" or "gc" || IdentityOperations.Contains(operation) || PermitOperations.Contains(operation) ? "" : Id(S(request, "region_id"));
        return operation switch
        {
            "init" => new { ok = true, schema_version = SchemaVersion, sqlite_version = Scalar("SELECT sqlite_version()"), path = database },
            "status" => new { ok = true, schema_version = SchemaVersion, regions = Rows("SELECT id,commit_revision,epoch FROM regions"), sqlite_version = Scalar("SELECT sqlite_version()") },
            "load" => Load(id),
            "receipts" => new { ok = true, receipts = Rows("SELECT record_json FROM network_receipts WHERE region_id=$r ORDER BY rowid", ("$r", id)).Select(r => JsonNode.Parse((string)r[0]!)).ToArray() },
            "save" => Save(Validate(ReadBounded(S(request, "input"))), id, Long(request, "expected_commit"), Id(S(request, "request_id")), false),
            "export" or "backup" => Export(id, S(request, "output")),
            "import" => Save(Validate(ReadBundle(S(request, "input"))), id, Long(request, "expected_commit"), Id(S(request, "request_id")), true),
            "gc" => CollectOrphans(),
            "account_create" => AccountCreate(request),
            "account_list" => AccountList(),
            "account_disable" => AccountDisable(request),
            "session_issue" => SessionIssue(request),
            "session_revoke" => SessionRevoke(request),
            "session_validate" => SessionValidate(request),
            "audit_list" => new { ok = true, audit = Rows("SELECT at_ms,account_id,action,outcome,detail FROM audit_log ORDER BY rowid DESC LIMIT $n", ("$n", Math.Clamp((int)Long(request, "limit"), 1, 200))) },
            "object_restrict" => ObjectRestrict(request),
            "grant_update" => GrantUpdate(request),
            "grant_list" => new
            {
                ok = true,
                restrictions = Rows("SELECT object_id,set_by,at_ms FROM restrictions ORDER BY rowid")
                    .Select(r => new { object_id = r[0], set_by = r[1], at_ms = r[2] }).ToArray(),
                grants = Rows("SELECT object_id,account_id,granted_by,granted_at_ms FROM grants ORDER BY rowid")
                    .Select(r => new { object_id = r[0], account_id = r[1], granted_by = r[2], granted_at_ms = r[3] }).ToArray()
            },
            _ => throw new StoreError("UNKNOWN_OPERATION")
        };
    }
    private void Open(bool create)
    {
        if (!create && !File.Exists(database)) throw new StoreError("DATABASE_NOT_FOUND");
        if (create) Directory.CreateDirectory(root);
        connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = database, Mode = create ? SqliteOpenMode.ReadWriteCreate : SqliteOpenMode.ReadWrite, Pooling = false, DefaultTimeout = 3 }.ToString());
        connection.Open();
        long version = Convert.ToInt64(Scalar("PRAGMA user_version"), CultureInfo.InvariantCulture);
        if (version > SchemaVersion || version < 0) throw new StoreError("UNSUPPORTED_DATABASE_VERSION");
        if (version != SchemaVersion && !create) throw new StoreError("MIGRATION_REQUIRED");
        Exec("PRAGMA foreign_keys=ON"); Exec("PRAGMA busy_timeout=3000");
        if (version < SchemaVersion)
        {
            transaction = connection.BeginTransaction(deferred: false);
            try
            {
                if (version == 0)
                {
                    Exec("""
                    CREATE TABLE regions(id TEXT PRIMARY KEY CHECK(length(id)=36), owner_id TEXT NOT NULL CHECK(length(owner_id)=36), commit_revision INTEGER NOT NULL CHECK(commit_revision>=0), world_revision INTEGER NOT NULL CHECK(world_revision>=0), root_json TEXT NOT NULL);
                    CREATE TABLE contents(sha256 TEXT PRIMARY KEY CHECK(length(sha256)=64), bytes INTEGER NOT NULL CHECK(bytes>0 AND bytes<=2097152));
                    CREATE TABLE assets(region_id TEXT NOT NULL REFERENCES regions(id) ON DELETE CASCADE, id TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0), sha256 TEXT REFERENCES contents(sha256), record_json TEXT NOT NULL, PRIMARY KEY(region_id,id), UNIQUE(region_id,ordinal));
                    CREATE TABLE groups(region_id TEXT NOT NULL REFERENCES regions(id) ON DELETE CASCADE, id TEXT NOT NULL, root_id TEXT NOT NULL, owner_id TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0), record_json TEXT NOT NULL, PRIMARY KEY(region_id,id), UNIQUE(region_id,ordinal), FOREIGN KEY(region_id,root_id) REFERENCES objects(region_id,id) DEFERRABLE INITIALLY DEFERRED);
                    CREATE TABLE objects(region_id TEXT NOT NULL REFERENCES regions(id) ON DELETE CASCADE, id TEXT NOT NULL, group_id TEXT, asset_id TEXT NOT NULL, owner_id TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0), record_json TEXT NOT NULL, PRIMARY KEY(region_id,id), UNIQUE(region_id,ordinal), FOREIGN KEY(region_id,group_id) REFERENCES groups(region_id,id) DEFERRABLE INITIALLY DEFERRED, FOREIGN KEY(region_id,asset_id) REFERENCES assets(region_id,id) DEFERRABLE INITIALLY DEFERRED);
                    PRAGMA user_version=1;
                    """);
                }
                if (version < 2)
                {
                Exec("ALTER TABLE regions ADD COLUMN epoch TEXT NOT NULL DEFAULT ''");
                Exec("UPDATE regions SET epoch=$epoch WHERE epoch=''", ("$epoch", Guid.NewGuid().ToString()));
                Inject("migration");
                Exec("CREATE TABLE commits(region_id TEXT NOT NULL REFERENCES regions(id), request_id TEXT NOT NULL, fingerprint TEXT NOT NULL, commit_revision INTEGER NOT NULL, epoch TEXT NOT NULL, PRIMARY KEY(region_id,request_id))");
                Exec("PRAGMA user_version=2");
                }
                if (version < 3)
                {
                    Exec("CREATE TABLE network_receipts(region_id TEXT NOT NULL, request_id TEXT NOT NULL, principal_id TEXT NOT NULL CHECK(length(principal_id)=36), record_json TEXT NOT NULL CHECK(length(record_json)<=65536), PRIMARY KEY(region_id,request_id), FOREIGN KEY(region_id,request_id) REFERENCES commits(region_id,request_id))");
                    Inject("migration_receipts");
                    Exec("PRAGMA user_version=3");
                }
                if (version < 4)
                {
                    // V6 identity: accounts, hashed sessions and an append-only audit log.
                    // Tokens are stored only as SHA-256 hashes; cleartext never persists.
                    Exec("""
                    CREATE TABLE accounts(id TEXT PRIMARY KEY CHECK(length(id)=36), name TEXT NOT NULL UNIQUE CHECK(length(name) BETWEEN 1 AND 64), actor_id TEXT NOT NULL CHECK(length(actor_id)=36), role TEXT NOT NULL CHECK(role IN ('owner','editor','observer')), disabled INTEGER NOT NULL DEFAULT 0 CHECK(disabled IN (0,1)), created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);
                    CREATE TABLE sessions(token_hash TEXT PRIMARY KEY CHECK(length(token_hash)=64), account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, issued_at_ms INTEGER NOT NULL, expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms>issued_at_ms), revoked INTEGER NOT NULL DEFAULT 0 CHECK(revoked IN (0,1)), revoked_at_ms INTEGER);
                    CREATE TABLE audit_log(at_ms INTEGER NOT NULL, account_id TEXT, action TEXT NOT NULL, outcome TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '' CHECK(length(detail)<=2048));
                    """);
                    Inject("migration_identity");
                    Exec("PRAGMA user_version=4");
                }
                if (version < 5)
                {
                    // V6 permits: restricted objects and per-account grants. These are
                    // soft references to world objects (objects are rewritten per
                    // commit), so no foreign key into the world tables.
                    Exec("""
                    CREATE TABLE restrictions(object_id TEXT PRIMARY KEY CHECK(length(object_id)=36), set_by TEXT NOT NULL, at_ms INTEGER NOT NULL);
                    CREATE TABLE grants(object_id TEXT NOT NULL CHECK(length(object_id)=36), account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, granted_by TEXT NOT NULL, granted_at_ms INTEGER NOT NULL, PRIMARY KEY(object_id,account_id));
                    """);
                    Inject("migration_permits");
                    Exec("PRAGMA user_version=5");
                }
                transaction.Commit();
            }
            catch { transaction.Rollback(); throw; }
            finally { transaction.Dispose(); transaction = null; }
        }
        Scalar("PRAGMA journal_mode=WAL"); Exec("PRAGMA synchronous=FULL");
    }
    private JsonObject Validate(byte[] input)
    {
        if (input.Length > MaxWorldBytes) throw new StoreError("WORLD_SIZE_LIMIT");
        NoDuplicateKeys(input);
        string engine = Path.GetFullPath(S(configuration, "godot")), project = Path.GetFullPath(S(configuration, "project"));
        if (!File.Exists(engine) || !File.Exists(Path.Combine(project, "domain", "world_schema.gd"))) throw new StoreError("VALIDATOR_UNAVAILABLE");
        string scratch = Path.Combine(root, "validation", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(scratch);
        string file = Path.Combine(scratch, "input.json"), output = Path.Combine(scratch, "output.json");
        File.WriteAllBytes(file, input);
        try
        {
            var start = new ProcessStartInfo(engine) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var arg in new[] { "--headless", "--path", project, "--log-file", Path.Combine(scratch, "engine.log"), "--script", "res://tools/validate_world.gd", "--", "--input=" + file, "--output=" + output }) start.ArgumentList.Add(arg);
            using var process = Process.Start(start) ?? throw new StoreError("VALIDATOR_UNAVAILABLE");
            var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(30000)) { process.Kill(true); throw new StoreError("VALIDATOR_TIMEOUT"); }
            Task.WaitAll(stdout, stderr);
            if (!File.Exists(output) || new FileInfo(output).Length > MaxWorldBytes) throw new StoreError("VALIDATOR_OUTPUT_INVALID");
            var result = JsonNode.Parse(File.ReadAllBytes(output))!.AsObject();
            if (process.ExitCode != 0 || result.ContainsKey("error")) throw new StoreError("WORLD_VALIDATION_FAILED");
            if (result["migrated"]?.GetValue<bool>() == false)
            {
                // Validation must not introduce another float parse/serialization
                // cycle into an already-current world. Preserve its original JSON
                // numeric values; only an actual legacy migration uses Godot output.
                var original = JsonNode.Parse(input)!.AsObject();
                if (original["format"]?.GetValue<string>() == "region-lab.snapshot")
                {
                    var payload = Encoding.UTF8.GetBytes(S(original, "world_json")); NoDuplicateKeys(payload);
                    return JsonNode.Parse(payload)!.AsObject();
                }
                return original;
            }
            return result["world"]!.DeepClone().AsObject();
        }
        finally
        {
            // Only files created in this unique validation directory are removed.
            foreach (string name in new[] { "input.json", "output.json", "engine.log" }) { string p = Path.Combine(scratch, name); if (File.Exists(p)) File.Delete(p); }
            if (!Directory.EnumerateFileSystemEntries(scratch).Any()) Directory.Delete(scratch);
        }
    }
    private object Save(JsonObject world, string id, long expected, string requestId, bool newEpoch)
    {
        if (S(world["region"]!.AsObject(), "id") != id) throw new StoreError("REGION_ID_MISMATCH");
        if (expected < -1) throw new StoreError("INVALID_EXPECTED_COMMIT");
        JsonObject? receipt = configuration["network_receipt"]?.AsObject();
        if (receipt != null)
        {
            if (receipt.ToJsonString().Length > 65536 || Id(S(receipt, "request_id")) != requestId ||
                !Regex.IsMatch(S(receipt, "fingerprint"), "^[a-f0-9]{64}$") || receipt["result"] is not JsonObject result ||
                result["ok"]?.GetValue<bool>() != true || Long(result, "revision") != Long(world, "revision")) throw new StoreError("INVALID_NETWORK_RECEIPT");
            Id(S(receipt, "principal_id"));
        }
        string fingerprint = Hash(Encoding.UTF8.GetBytes(world.ToJsonString() + "|" + expected + "|" + newEpoch + (receipt == null ? "" : "|" + receipt.ToJsonString())));
        transaction = connection!.BeginTransaction(deferred: false);
        try
        {
            var prior = Rows("SELECT fingerprint,commit_revision,epoch FROM commits WHERE region_id=$r AND request_id=$q", ("$r", id), ("$q", requestId));
            if (prior.Count > 0)
            {
                if ((string)prior[0][0]! != fingerprint) throw new StoreError("REQUEST_REUSED");
                transaction.Rollback(); return new { ok = true, commit_revision = prior[0][1], epoch = prior[0][2], replayed = true, path = database };
            }
            var row = Rows("SELECT commit_revision,epoch FROM regions WHERE id=$r", ("$r", id));
            long current = row.Count == 0 ? -1 : Convert.ToInt64(row[0][0]);
            if (expected != current) throw new StoreError("COMMIT_CONFLICT");
            string epoch = newEpoch || row.Count == 0 ? Guid.NewGuid().ToString() : (string)row[0][1]!;
            long revision = current + 1;
            var assets = world["assets"]!.AsArray();
            foreach (var assetNode in assets)
            {
                var asset = assetNode!.AsObject();
                if (asset["kind"]!.GetValue<string>() != "mesh") continue;
                var bytes = Convert.FromBase64String(S(asset, "glb")); string hash = S(asset, "sha256");
                if (bytes.Length > 2097152 || Hash(bytes) != hash) throw new StoreError("ASSET_HASH_MISMATCH");
                Publish(hash, bytes);
            }
            Inject("after_assets");
            var rootRecord = world.DeepClone().AsObject(); rootRecord.Remove("assets"); rootRecord.Remove("groups"); rootRecord.Remove("objects");
            Exec("INSERT INTO regions(id,owner_id,commit_revision,world_revision,root_json,epoch) VALUES($r,$o,$c,$w,$j,$e) ON CONFLICT(id) DO UPDATE SET owner_id=excluded.owner_id,commit_revision=excluded.commit_revision,world_revision=excluded.world_revision,root_json=excluded.root_json,epoch=excluded.epoch",
                ("$r", id), ("$o", S(world["region"]!.AsObject(), "owner_id")), ("$c", revision), ("$w", Long(world, "revision")), ("$j", rootRecord.ToJsonString()), ("$e", epoch));
            Exec("DELETE FROM objects WHERE region_id=$r", ("$r", id)); Exec("DELETE FROM groups WHERE region_id=$r", ("$r", id)); Exec("DELETE FROM assets WHERE region_id=$r", ("$r", id));
            int ordinal = 0;
            foreach (var node in assets)
            {
                var asset = node!.DeepClone().AsObject(); string? hash = null;
                if (S(asset, "kind") == "mesh")
                {
                    hash = S(asset, "sha256"); var bytes = Convert.FromBase64String(S(asset, "glb")); asset.Remove("glb");
                    Exec("INSERT INTO contents(sha256,bytes) VALUES($h,$n) ON CONFLICT(sha256) DO NOTHING", ("$h", hash), ("$n", bytes.Length));
                }
                Exec("INSERT INTO assets(region_id,id,ordinal,sha256,record_json) VALUES($r,$i,$n,$h,$j)", ("$r", id), ("$i", S(asset, "id")), ("$n", ordinal++), ("$h", hash), ("$j", asset.ToJsonString()));
            }
            ordinal = 0;
            foreach (var node in world["groups"]!.AsArray())
            {
                var group = node!.AsObject();
                Exec("INSERT INTO groups(region_id,id,root_id,owner_id,ordinal,record_json) VALUES($r,$i,$root,$o,$n,$j)", ("$r", id), ("$i", S(group, "id")), ("$root", S(group, "root_id")), ("$o", S(group, "owner_id")), ("$n", ordinal++), ("$j", group.ToJsonString()));
            }
            Inject("after_groups"); ordinal = 0;
            foreach (var node in world["objects"]!.AsArray())
            {
                var item = node!.AsObject(); string group = S(item, "group_id");
                Exec("INSERT INTO objects(region_id,id,group_id,asset_id,owner_id,ordinal,record_json) VALUES($r,$i,$g,$a,$o,$n,$j)", ("$r", id), ("$i", S(item, "id")), ("$g", group.Length == 0 ? null : group), ("$a", S(item, "asset_id")), ("$o", S(item, "owner_id")), ("$n", ordinal++), ("$j", item.ToJsonString()));
            }
            Exec("INSERT INTO commits(region_id,request_id,fingerprint,commit_revision,epoch) VALUES($r,$q,$f,$c,$e)", ("$r", id), ("$q", requestId), ("$f", fingerprint), ("$c", revision), ("$e", epoch));
            if (receipt != null)
                Exec("INSERT INTO network_receipts(region_id,request_id,principal_id,record_json) VALUES($r,$q,$p,$j)", ("$r", id), ("$q", requestId), ("$p", S(receipt, "principal_id")), ("$j", receipt.ToJsonString()));
            Inject("before_commit");
            if (fault == "hold_before_commit") { File.WriteAllText(Path.Combine(root, "fault-ready.txt"), requestId); Thread.Sleep(30000); }
            transaction.Commit();
            if (fault == "crash_after_commit") Environment.FailFast("Test process termination after commit");
            return new { ok = true, commit_revision = revision, epoch, replayed = false, path = database, world_revision = Long(world, "revision") };
        }
        catch { try { transaction.Rollback(); } catch (InvalidOperationException) { } throw; }
        finally { transaction.Dispose(); transaction = null; }
    }
    private void Publish(string hash, byte[] bytes)
    {
        string target = ContentPath(hash); Directory.CreateDirectory(content);
        if (File.Exists(target)) { ReadContent(hash); return; }
        string temporary = Path.Combine(content, hash + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(bytes); file.Flush(true); }
            if (Hash(File.ReadAllBytes(temporary)) != hash) throw new StoreError("ASSET_PUBLISH_VERIFY_FAILED");
            File.Move(temporary, target, false);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private JsonObject ReadWorld(string id, bool hydrate)
    {
        var roots = Rows("SELECT root_json FROM regions WHERE id=$r", ("$r", id));
        if (roots.Count != 1) throw new StoreError("REGION_NOT_FOUND");
        var world = JsonNode.Parse((string)roots[0][0]!)!.AsObject();
        foreach (string table in new[] { "assets", "groups", "objects" })
        {
            var array = new JsonArray();
            foreach (var row in Rows($"SELECT record_json FROM {table} WHERE region_id=$r ORDER BY ordinal", ("$r", id)))
            {
                var item = JsonNode.Parse((string)row[0]!)!.AsObject();
                if (hydrate && table == "assets" && S(item, "kind") == "mesh") item["glb"] = Convert.ToBase64String(ReadContent(S(item, "sha256")));
                array.Add(item);
            }
            world[table] = array;
        }
        return world;
    }
    private object Load(string id)
    {
        JsonObject world; object?[] row;
        transaction = connection!.BeginTransaction(deferred: false);
        try { world = ReadWorld(id, true); row = Rows("SELECT commit_revision,epoch FROM regions WHERE id=$r", ("$r", id))[0]; transaction.Commit(); }
        finally { transaction.Dispose(); transaction = null; }
        world = Validate(Encoding.UTF8.GetBytes(world.ToJsonString()));
        return new { ok = true, world, commit_revision = row[0], epoch = row[1], recovered = false, migrated = false, path = database };
    }
    private object Export(string id, string output)
    {
        output = Path.GetFullPath(output);
        if (File.Exists(output) || output == database || output.StartsWith(content + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new StoreError("EXPORT_TARGET_EXISTS_OR_PROTECTED");
        var files = new SortedDictionary<string, byte[]>(StringComparer.Ordinal);
        object?[] row;
        transaction = connection!.BeginTransaction(deferred: false);
        try
        {
            var world = ReadWorld(id, false);
            // Validate the complete candidate before describing this as a usable backup.
            var hydrated = world.DeepClone().AsObject();
            foreach (var asset in hydrated["assets"]!.AsArray().Select(n => n!.AsObject()).Where(a => S(a, "kind") == "mesh"))
            {
                string hash = S(asset, "sha256"); var bytes = ReadContent(hash); files["objects/" + hash + ".glb"] = bytes; asset["glb"] = Convert.ToBase64String(bytes);
            }
            Validate(Encoding.UTF8.GetBytes(hydrated.ToJsonString()));
            files["world.json"] = Encoding.UTF8.GetBytes(world.ToJsonString());
            row = Rows("SELECT commit_revision,epoch FROM regions WHERE id=$r", ("$r", id))[0];
            transaction.Commit();
        }
        finally { transaction.Dispose(); transaction = null; }
        var manifest = new { format = "region-lab.bundle", version = 1, tool_version = "0.5.1", region_id = id, source_commit_revision = row[0], source_epoch = row[1], entries = files.Select(p => new { path = p.Key, bytes = p.Value.Length, sha256 = Hash(p.Value) }).ToArray() };
        Directory.CreateDirectory(Path.GetDirectoryName(output)!); string temporary = output + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
            {
                using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, true))
                {
                    files["manifest.json"] = JsonSerializer.SerializeToUtf8Bytes(manifest);
                    foreach (var pair in files) { using var entry = archive.CreateEntry(pair.Key, CompressionLevel.Optimal).Open(); entry.Write(pair.Value); }
                }
                stream.Flush(true);
            }
            ReadBundle(temporary); File.Move(temporary, output, false);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        return new { ok = true, path = output, sha256 = Hash(File.ReadAllBytes(output)), source_commit_revision = row[0], scope = "one complete region, including all registered mesh assets" };
    }
    private byte[] ReadBundle(string path)
    {
        if (new FileInfo(path).Length > 16 * 1024 * 1024) throw new StoreError("BUNDLE_SIZE_LIMIT");
        using var archive = ZipFile.OpenRead(path);
        if (archive.Entries.Count < 2 || archive.Entries.Count > 18) throw new StoreError("BUNDLE_ENTRY_LIMIT");
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        long total = 0;
        foreach (var entry in archive.Entries)
        {
            if (!Regex.IsMatch(entry.FullName, @"^(manifest\.json|world\.json|objects/[a-f0-9]{64}\.glb)$") || files.ContainsKey(entry.FullName)) throw new StoreError("BUNDLE_PATH_OR_DUPLICATE");
            if (entry.Length < 1 || entry.Length > MaxWorldBytes || (total += entry.Length) > 16 * 1024 * 1024) throw new StoreError("BUNDLE_INFLATED_LIMIT");
            using var stream = entry.Open(); using var buffer = new MemoryStream();
            var chunk = new byte[8192]; int read;
            while ((read = stream.Read(chunk)) > 0) { if (buffer.Length + read > entry.Length) throw new StoreError("BUNDLE_LENGTH_MISMATCH"); buffer.Write(chunk, 0, read); }
            if (buffer.Length != entry.Length) throw new StoreError("BUNDLE_LENGTH_MISMATCH");
            files.Add(entry.FullName, buffer.ToArray());
        }
        if (!files.TryGetValue("manifest.json", out var manifestBytes) || manifestBytes.Length > 65536 || !files.ContainsKey("world.json")) throw new StoreError("BUNDLE_MANIFEST_MISSING");
        NoDuplicateKeys(manifestBytes); NoDuplicateKeys(files["world.json"]);
        var manifest = JsonNode.Parse(manifestBytes)!.AsObject();
        if (S(manifest, "format") != "region-lab.bundle" || Long(manifest, "version") != 1) throw new StoreError("UNSUPPORTED_BUNDLE");
        var listed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in manifest["entries"]!.AsArray())
        {
            var item = node!.AsObject(); string name = S(item, "path");
            if (name == "manifest.json" || !listed.Add(name) || !files.TryGetValue(name, out var bytes) || Long(item, "bytes") != bytes.Length || S(item, "sha256") != Hash(bytes)) throw new StoreError("BUNDLE_CHECKSUM_OR_MANIFEST");
        }
        if (listed.Count != files.Count - 1) throw new StoreError("BUNDLE_UNLISTED_ENTRY");
        var world = JsonNode.Parse(files["world.json"])!.AsObject();
        if (S(world["region"]!.AsObject(), "id") != S(manifest, "region_id")) throw new StoreError("BUNDLE_REGION_MISMATCH");
        var used = new HashSet<string>(StringComparer.Ordinal) { "world.json" };
        foreach (var asset in world["assets"]!.AsArray().Select(n => n!.AsObject()).Where(a => S(a, "kind") == "mesh"))
        {
            string hash = S(asset, "sha256"); string name = "objects/" + hash + ".glb";
            used.Add(name);
            if (!files.TryGetValue(name, out var bytes) || Hash(bytes) != hash || bytes.Length > 2097152 || asset.ContainsKey("glb")) throw new StoreError("BUNDLE_ASSET_MISSING_OR_INVALID");
            asset["glb"] = Convert.ToBase64String(bytes);
        }
        if (!used.SetEquals(listed)) throw new StoreError("BUNDLE_UNREFERENCED_CONTENT");
        var result = Encoding.UTF8.GetBytes(world.ToJsonString()); if (result.Length > MaxWorldBytes) throw new StoreError("WORLD_SIZE_LIMIT"); return result;
    }
    private object CollectOrphans()
    {
        var removed = new List<string>();
        transaction = connection!.BeginTransaction(deferred: false);
        try
        {
            var live = Rows("SELECT DISTINCT sha256 FROM assets WHERE sha256 IS NOT NULL").Select(r => (string)r[0]!).ToHashSet(StringComparer.Ordinal);
            // Publication and GC share the SQLite write lock. No uncommitted asset
            // can be collected while a save is between file publication and commit.
            foreach (var file in Directory.Exists(content) ? Directory.EnumerateFiles(content) : Array.Empty<string>())
            {
                string name = Path.GetFileName(file);
                if (Regex.IsMatch(name, @"^[a-f0-9]{64}\.glb$") && !live.Contains(name[..64])) { File.Delete(file); removed.Add(name); }
                else if (Regex.IsMatch(name, @"^[a-f0-9]{64}\.[a-f0-9]{32}\.tmp$")) { File.Delete(file); removed.Add(name); }
            }
            Exec("DELETE FROM contents WHERE sha256 NOT IN (SELECT sha256 FROM assets WHERE sha256 IS NOT NULL)"); transaction.Commit();
        }
        finally { transaction.Dispose(); transaction = null; }
        return new { ok = true, removed };
    }
    private static readonly HashSet<string> AccountRoles = new(StringComparer.Ordinal) { "owner", "editor", "observer" };
    private void Audit(long nowMs, string? accountId, string action, string outcome, string detail = "")
    {
        Exec("INSERT INTO audit_log(at_ms,account_id,action,outcome,detail) VALUES($t,$a,$c,$o,$d)",
            ("$t", nowMs), ("$a", accountId), ("$c", action), ("$o", outcome), ("$d", detail.Length <= 2048 ? detail : detail[..2048]));
    }
    private object AccountList() => new
    {
        ok = true,
        accounts = Rows("SELECT id,name,actor_id,role,disabled,created_at_ms,updated_at_ms FROM accounts ORDER BY created_at_ms,rowid")
            .Select(r => new { id = r[0], name = r[1], actor_id = r[2], role = r[3], disabled = Convert.ToInt64(r[4]) == 1, created_at_ms = r[5], updated_at_ms = r[6] }).ToArray(),
        sessions = Rows("SELECT token_hash,account_id,issued_at_ms,expires_at_ms,revoked,revoked_at_ms FROM sessions ORDER BY issued_at_ms,rowid")
            .Select(r => new { token_hash = r[0], account_id = r[1], issued_at_ms = r[2], expires_at_ms = r[3], revoked = Convert.ToInt64(r[4]) == 1, revoked_at_ms = r[5] }).ToArray()
    };
    private object AccountCreate(JsonObject request)
    {
        string name = S(request, "name"); string role = S(request, "role");
        if (name.Trim().Length is < 1 or > 64) throw new StoreError("INVALID_ACCOUNT_NAME");
        if (!AccountRoles.Contains(role)) throw new StoreError("INVALID_ACCOUNT_ROLE");
        long now = Long(request, "now_ms");
        string id = request["id"] is JsonNode givenId ? Id(givenId.GetValue<string>()) : Guid.NewGuid().ToString();
        string actor = request["actor_id"] is JsonNode givenActor ? Id(givenActor.GetValue<string>()) : Guid.NewGuid().ToString();
        transaction = connection!.BeginTransaction(deferred: false);
        try
        {
            if (Scalar("SELECT COUNT(*) FROM accounts WHERE name=$n", ("$n", name)) is long taken && taken > 0) throw new StoreError("ACCOUNT_NAME_TAKEN");
            if (Scalar("SELECT COUNT(*) FROM accounts WHERE id=$i", ("$i", id)) is long clash && clash > 0) throw new StoreError("ACCOUNT_ID_TAKEN");
            Exec("INSERT INTO accounts(id,name,actor_id,role,disabled,created_at_ms,updated_at_ms) VALUES($i,$n,$a,$r,0,$t,$t)",
                ("$i", id), ("$n", name), ("$a", actor), ("$r", role), ("$t", now));
            Audit(now, id, "account_create", "ok", role);
            transaction.Commit();
        }
        catch { try { transaction.Rollback(); } catch (InvalidOperationException) { } throw; }
        finally { transaction.Dispose(); transaction = null; }
        return new { ok = true, account = new { id, name, actor_id = actor, role, disabled = false, created_at_ms = now, updated_at_ms = now } };
    }
    private object AccountDisable(JsonObject request)
    {
        string accountId = Id(S(request, "account_id"));
        bool disabled = request["disabled"]?.GetValue<bool>() ?? throw new StoreError("MISSING_DISABLED");
        long now = Long(request, "now_ms");
        transaction = connection!.BeginTransaction(deferred: false);
        try
        {
            var rows = Rows("SELECT disabled FROM accounts WHERE id=$i", ("$i", accountId));
            if (rows.Count == 0) throw new StoreError("ACCOUNT_NOT_FOUND");
            Exec("UPDATE accounts SET disabled=$d,updated_at_ms=$t WHERE id=$i", ("$d", disabled ? 1 : 0), ("$t", now), ("$i", accountId));
            int revoked = 0;
            if (disabled)
            {
                // Disabling an account revokes every live session in the same transaction.
                revoked = (int)(long)Scalar("SELECT COUNT(*) FROM sessions WHERE account_id=$i AND revoked=0", ("$i", accountId))!;
                Exec("UPDATE sessions SET revoked=1,revoked_at_ms=$t WHERE account_id=$i AND revoked=0", ("$t", now), ("$i", accountId));
            }
            Audit(now, accountId, disabled ? "account_disable" : "account_enable", "ok", disabled ? $"revoked_sessions={revoked}" : "");
            transaction.Commit();
        }
        catch { try { transaction.Rollback(); } catch (InvalidOperationException) { } throw; }
        finally { transaction.Dispose(); transaction = null; }
        return new { ok = true, account_id = accountId, disabled };
    }
    private object SessionIssue(JsonObject request)
    {
        string accountId = Id(S(request, "account_id"));
        string tokenHash = S(request, "token_hash");
        if (!Regex.IsMatch(tokenHash, "^[a-f0-9]{64}$")) throw new StoreError("INVALID_TOKEN_HASH");
        long now = Long(request, "now_ms"), ttl = Long(request, "ttl_ms");
        if (ttl < 60_000 || ttl > 30L * 24 * 3600 * 1000) throw new StoreError("INVALID_SESSION_TTL");
        transaction = connection!.BeginTransaction(deferred: false);
        try
        {
            var rows = Rows("SELECT disabled FROM accounts WHERE id=$i", ("$i", accountId));
            if (rows.Count == 0) throw new StoreError("ACCOUNT_NOT_FOUND");
            if (Convert.ToInt64(rows[0][0]) == 1) throw new StoreError("ACCOUNT_DISABLED");
            if (Scalar("SELECT COUNT(*) FROM sessions WHERE token_hash=$h", ("$h", tokenHash)) is long clash && clash > 0) throw new StoreError("SESSION_EXISTS");
            Exec("INSERT INTO sessions(token_hash,account_id,issued_at_ms,expires_at_ms,revoked) VALUES($h,$i,$t,$e,0)",
                ("$h", tokenHash), ("$i", accountId), ("$t", now), ("$e", now + ttl));
            Audit(now, accountId, "session_issue", "ok");
            transaction.Commit();
            return new { ok = true, account_id = accountId, token_hash = tokenHash, issued_at_ms = now, expires_at_ms = now + ttl };
        }
        catch { try { transaction.Rollback(); } catch (InvalidOperationException) { } throw; }
        finally { transaction.Dispose(); transaction = null; }
    }
    private object SessionRevoke(JsonObject request)
    {
        long now = Long(request, "now_ms");
        string? tokenHash = request["token_hash"]?.GetValue<string>();
        string? accountId = request["account_id"]?.GetValue<string>();
        if ((tokenHash == null) == (accountId == null)) throw new StoreError("REVOKE_TARGET_REQUIRED");
        if (tokenHash != null && !Regex.IsMatch(tokenHash, "^[a-f0-9]{64}$")) throw new StoreError("INVALID_TOKEN_HASH");
        if (accountId != null) accountId = Id(accountId);
        transaction = connection!.BeginTransaction(deferred: false);
        int count;
        try
        {
            if (tokenHash != null)
            {
                count = (int)(long)Scalar("SELECT COUNT(*) FROM sessions WHERE token_hash=$h AND revoked=0", ("$h", tokenHash))!;
                Exec("UPDATE sessions SET revoked=1,revoked_at_ms=$t WHERE token_hash=$h AND revoked=0", ("$t", now), ("$h", tokenHash));
                Audit(now, null, "session_revoke", count > 0 ? "ok" : "unknown", "by_token");
            }
            else
            {
                if (Scalar("SELECT COUNT(*) FROM accounts WHERE id=$i", ("$i", accountId)) is long missing && missing == 0) throw new StoreError("ACCOUNT_NOT_FOUND");
                count = (int)(long)Scalar("SELECT COUNT(*) FROM sessions WHERE account_id=$i AND revoked=0", ("$i", accountId))!;
                Exec("UPDATE sessions SET revoked=1,revoked_at_ms=$t WHERE account_id=$i AND revoked=0", ("$t", now), ("$i", accountId));
                Audit(now, accountId, "session_revoke", "ok", $"revoked_sessions={count}");
            }
            transaction.Commit();
        }
        catch { try { transaction.Rollback(); } catch (InvalidOperationException) { } throw; }
        finally { transaction.Dispose(); transaction = null; }
        return new { ok = true, revoked = count };
    }
    private object SessionValidate(JsonObject request)
    {
        string tokenHash = S(request, "token_hash");
        if (!Regex.IsMatch(tokenHash, "^[a-f0-9]{64}$")) throw new StoreError("INVALID_TOKEN_HASH");
        long now = Long(request, "now_ms");
        var rows = Rows("SELECT s.account_id,s.expires_at_ms,s.revoked,a.name,a.actor_id,a.role,a.disabled FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.token_hash=$h", ("$h", tokenHash));
        if (rows.Count == 0) { Audit(now, null, "session_validate", "unknown_token"); return new { ok = true, valid = false, code = "UNKNOWN_TOKEN" }; }
        var row = rows[0];
        string accountId = (string)row[0]!;
        string code = Convert.ToInt64(row[2]) == 1 ? "SESSION_REVOKED" : Convert.ToInt64(row[6]) == 1 ? "ACCOUNT_DISABLED" : now >= Convert.ToInt64(row[1]) ? "SESSION_EXPIRED" : "";
        Audit(now, accountId, "session_validate", code.Length == 0 ? "ok" : code.ToLowerInvariant());
        if (code.Length > 0) return new { ok = true, valid = false, code };
        return new { ok = true, valid = true, account = new { id = accountId, name = (string)row[3]!, actor_id = (string)row[4]!, role = (string)row[5]! }, expires_at_ms = row[1] };
    }
    private object ObjectRestrict(JsonObject request)
    {
        string objectId = Id(S(request, "object_id"));
        bool restricted = request["restricted"]?.GetValue<bool>() ?? throw new StoreError("MISSING_RESTRICTED");
        string by = Id(S(request, "actor_id"));
        long now = Long(request, "now_ms");
        transaction = connection!.BeginTransaction(deferred: false);
        try
        {
            if (Scalar("SELECT COUNT(*) FROM accounts WHERE id=$i", ("$i", by)) is long missing && missing == 0) throw new StoreError("ACCOUNT_NOT_FOUND");
            if (restricted)
                Exec("INSERT INTO restrictions(object_id,set_by,at_ms) VALUES($o,$b,$t) ON CONFLICT(object_id) DO NOTHING", ("$o", objectId), ("$b", by), ("$t", now));
            else
            {
                // Lifting a restriction retires every grant on the object with it.
                Exec("DELETE FROM restrictions WHERE object_id=$o", ("$o", objectId));
                Exec("DELETE FROM grants WHERE object_id=$o", ("$o", objectId));
            }
            Audit(now, by, restricted ? "object_restrict" : "object_unrestrict", "ok", $"object={objectId}");
            transaction.Commit();
        }
        catch { try { transaction.Rollback(); } catch (InvalidOperationException) { } throw; }
        finally { transaction.Dispose(); transaction = null; }
        return new { ok = true, object_id = objectId, restricted };
    }
    private object GrantUpdate(JsonObject request)
    {
        string objectId = Id(S(request, "object_id"));
        string accountId = Id(S(request, "account_id"));
        bool granted = request["granted"]?.GetValue<bool>() ?? throw new StoreError("MISSING_GRANTED");
        string by = Id(S(request, "actor_id"));
        long now = Long(request, "now_ms");
        transaction = connection!.BeginTransaction(deferred: false);
        try
        {
            if (Scalar("SELECT COUNT(*) FROM restrictions WHERE object_id=$o", ("$o", objectId)) is long open && open == 0) throw new StoreError("OBJECT_NOT_RESTRICTED");
            if (Scalar("SELECT COUNT(*) FROM accounts WHERE id=$i", ("$i", accountId)) is long missing && missing == 0) throw new StoreError("ACCOUNT_NOT_FOUND");
            if (granted)
                Exec("INSERT INTO grants(object_id,account_id,granted_by,granted_at_ms) VALUES($o,$a,$b,$t) ON CONFLICT(object_id,account_id) DO NOTHING", ("$o", objectId), ("$a", accountId), ("$b", by), ("$t", now));
            else
                Exec("DELETE FROM grants WHERE object_id=$o AND account_id=$a", ("$o", objectId), ("$a", accountId));
            Audit(now, by, granted ? "grant_update" : "grant_revoke", "ok", $"object={objectId} account={accountId}");
            transaction.Commit();
        }
        catch { try { transaction.Rollback(); } catch (InvalidOperationException) { } throw; }
        finally { transaction.Dispose(); transaction = null; }
        return new { ok = true, object_id = objectId, account_id = accountId, granted };
    }
    private string ContentPath(string hash)
    {
        if (!Regex.IsMatch(hash, "^[a-f0-9]{64}$")) throw new StoreError("INVALID_CONTENT_ID");
        return Path.Combine(content, hash + ".glb");
    }
    private byte[] ReadContent(string hash)
    {
        string path = ContentPath(hash);
        if (!File.Exists(path) || new FileInfo(path).Length > 2097152) throw new StoreError("CONTENT_MISSING_OR_OVERSIZED");
        var bytes = File.ReadAllBytes(path); if (Hash(bytes) != hash) throw new StoreError("CONTENT_CHECKSUM_MISMATCH"); return bytes;
    }
    private SqliteCommand Command(string sql, params (string, object?)[] parameters)
    {
        var command = connection!.CreateCommand(); command.Transaction = transaction; command.CommandText = sql;
        foreach (var p in parameters) command.Parameters.AddWithValue(p.Item1, p.Item2 ?? DBNull.Value); return command;
    }
    private void Exec(string sql, params (string, object?)[] parameters) { using var command = Command(sql, parameters); command.ExecuteNonQuery(); }
    private object? Scalar(string sql, params (string, object?)[] parameters) { using var command = Command(sql, parameters); return command.ExecuteScalar(); }
    private List<object?[]> Rows(string sql, params (string, object?)[] parameters)
    {
        using var command = Command(sql, parameters); using var reader = command.ExecuteReader(); var result = new List<object?[]>();
        while (reader.Read()) { var values = new object[reader.FieldCount]; reader.GetValues(values); result.Add(values.Select(v => v is DBNull ? null : v).ToArray()); }
        return result;
    }
    private void Inject(string stage) { if (fault == stage) throw new StoreError("INJECTED_" + stage.ToUpperInvariant()); }
    private static string S(JsonObject o, string key) => o[key]?.GetValue<string>() ?? throw new StoreError("MISSING_" + key.ToUpperInvariant());
    private static long Long(JsonObject o, string key)
    {
        // Godot represents parsed JSON numbers as doubles, including integral revisions.
        double value = o[key]?.GetValue<double>() ?? double.NaN;
        return double.IsFinite(value) && value == Math.Floor(value) && Math.Abs(value) <= 9007199254740991 ? (long)value : throw new StoreError("INVALID_" + key.ToUpperInvariant());
    }
    private static string Id(string value) => Guid.TryParseExact(value, "D", out var id) && id != Guid.Empty && id.ToString() == value ? value : throw new StoreError("INVALID_ID");
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    internal static byte[] ReadBounded(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length > MaxWorldBytes) throw new StoreError("INPUT_LIMIT");
        var bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
        if (file.ReadByte() != -1) throw new StoreError("INPUT_CHANGED");
        return bytes;
    }
    internal static void NoDuplicateKeys(byte[] bytes)
    {
        using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32 });
        void Walk(JsonElement element)
        {
            if (element.ValueKind == JsonValueKind.Object) { var keys = new HashSet<string>(StringComparer.Ordinal); foreach (var p in element.EnumerateObject()) { if (!keys.Add(p.Name)) throw new StoreError("DUPLICATE_JSON_KEY"); Walk(p.Value); } }
            else if (element.ValueKind == JsonValueKind.Array) foreach (var value in element.EnumerateArray()) Walk(value);
        }
        Walk(document.RootElement);
    }
    public void Dispose() { transaction?.Dispose(); connection?.Dispose(); }
}
