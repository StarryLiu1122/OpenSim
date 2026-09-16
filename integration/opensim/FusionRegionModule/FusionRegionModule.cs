using System.Collections.Concurrent;
using System.Net;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Mono.Addins;
using Nini.Config;
using OpenMetaverse;
using OpenSim.Framework;
using OpenSim.Framework.Servers;
using OpenSim.Framework.Servers.HttpServer;
using OpenSim.Region.Framework.Interfaces;
using OpenSim.Region.Framework.Scenes;

[assembly: Addin("RegionLab.Fusion", "0.4.1")]
[assembly: AddinDependency("OpenSim.Region.Framework", "0.9.3.0")]

namespace RegionLab.Fusion;

/// <summary>Experimental, local operator adapter for one isolated reference region.</summary>
[Extension(Path = "/OpenSim/RegionModules", NodeName = "RegionModule", Id = "FusionRegionModule")]
public sealed partial class FusionRegionModule : INonSharedRegionModule
{
    private const int MaxBody = 65536, MaxReceipts = 1024, MaxParts = 128;
    private static readonly string[] Operations = { "GetCapabilities", "GetSnapshot", "GetReceipt", "CreateBox", "Link", "Move", "Rotate", "MoveMember", "Scale", "Duplicate", "Unlink", "Delete", "Backup" };
    private readonly ConcurrentQueue<Work> queue = new();
    private readonly Dictionary<string, Receipt> receipts = new(); // Accessed only on OnFrame.
    private readonly string epoch = Guid.NewGuid().ToString();
    private Scene scene;
    private UUID owner;
    private byte[] token;
    private string path, journalDirectory;
    private bool enabled;
    private volatile bool closing;
    private long tick, sequence;
    private int pending;
    private sealed record Work(JsonElement Command, TaskCompletionSource<object> Completion);
    private sealed record Receipt(string Fingerprint, object Result);
    private sealed class Rejected(string code) : Exception(code) { }

    public string Name => "Region Lab Fusion Reference Adapter";
    public Type ReplaceableInterface => null;

    public void Initialise(IConfigSource source)
    {
        var config = source.Configs["Fusion"];
        enabled = config?.GetBoolean("Enabled", false) == true;
        if (!enabled) return;
        var secret = config.GetString("Token", "");
        if (secret.Length < 64 || !UUID.TryParse(config.GetString("Owner", ""), out owner) || owner == UUID.Zero)
            throw new InvalidOperationException("Fusion requires a generated token and an explicit owner.");
        token = Encoding.UTF8.GetBytes("Bearer " + secret);
        journalDirectory = Path.GetFullPath(config.GetString("DataDirectory", "fusion-data"));
        Directory.CreateDirectory(journalDirectory);
        ConfigureFp(config);
    }

    public void PostInitialise() { }
    public void AddRegion(Scene value) { if (enabled) scene = value; }
    public void RegionLoaded(Scene value)
    {
        if (!enabled || path != null) return;
        path = "/fusion/v0/regions/" + scene.RegionInfo.RegionID + "/commands";
        scene.EventManager.OnFrame += OnFrame;
        MainServer.Instance.AddSimpleStreamHandler(new SimpleStreamHandler(path, Handle));
        StartFp();
        Console.WriteLine("[FUSION]: Local reference endpoint ready; epoch=" + epoch);
    }
    public void RemoveRegion(Scene value) => Close();
    public void Close()
    {
        closing = true;
        CloseFp();
        if (path != null)
        {
            MainServer.Instance.RemoveSimpleStreamHandler(path);
            scene.EventManager.OnFrame -= OnFrame;
            path = null;
        }
        while (queue.TryDequeue(out var item))
        {
            Interlocked.Decrement(ref pending);
            item.Completion.TrySetResult(Reply(item.Command, "rejected", "STOPPING"));
        }
    }

    private void Handle(IOSHttpRequest request, IOSHttpResponse response)
    {
        response.ContentType = "application/json; charset=utf-8";
        response.AddHeader("Cache-Control", "no-store");
        object result;
        try
        {
            var supplied = Encoding.UTF8.GetBytes(request.Headers["Authorization"] ?? "");
            if (!IPAddress.IsLoopback(request.RemoteIPEndPoint.Address) || !CryptographicOperations.FixedTimeEquals(supplied, token) || principals[0].Expires <= DateTimeOffset.UtcNow)
            { response.StatusCode = 401; result = new { error = "UNAUTHORIZED" }; }
            else if (request.HttpMethod != "POST")
            { response.StatusCode = 405; result = new { error = "METHOD_NOT_ALLOWED" }; }
            else if (request.ContentLength64 < 1 || request.ContentLength64 > MaxBody)
            { response.StatusCode = 413; result = new { error = "BODY_LIMIT" }; }
            else
            {
                byte[] bytes = new byte[(int)request.ContentLength64];
                request.InputStream.ReadExactly(bytes);
                using var doc = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 12 });
                var command = doc.RootElement.Clone();
                ValidateEnvelope(command);
                if (closing) throw new Rejected("STOPPING");
                if (Interlocked.Increment(ref pending) > 64)
                { Interlocked.Decrement(ref pending); throw new Rejected("QUEUE_FULL"); }
                var completion = new TaskCompletionSource<object>(TaskCreationOptions.RunContinuationsAsynchronously);
                queue.Enqueue(new Work(command, completion));
                if (completion.Task.Wait(TimeSpan.FromSeconds(5))) result = completion.Task.Result;
                else { response.StatusCode = 202; result = Reply(command, "pending", "QUERY_RECEIPT"); }
            }
        }
        catch (Exception e) when (e is JsonException or Rejected or InvalidOperationException or EndOfStreamException)
        { response.StatusCode = 400; result = new { error = e is Rejected ? e.Message : "INVALID_JSON" }; }
        response.RawBuffer = JsonSerializer.SerializeToUtf8Bytes(result);
    }

    private static void ValidateEnvelope(JsonElement c)
    {
        Keys(c, "fp_version", "request_id", "trace_id", "world_epoch", "operation", "expires_at", "payload");
        if (Text(c, "fp_version") != "0.1" || !CanonicalId(Text(c, "request_id")) ||
            !CanonicalId(Text(c, "trace_id")) || !ValidDeadline(Text(c, "expires_at")) ||
            c.GetProperty("payload").ValueKind != JsonValueKind.Object) throw new Rejected("INVALID_ENVELOPE");
        Text(c, "world_epoch"); Text(c, "operation");
        NoDuplicateKeys(c);
    }
    private static void NoDuplicateKeys(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>();
            foreach (var p in value.EnumerateObject())
            { if (!names.Add(p.Name)) throw new Rejected("DUPLICATE_KEY"); NoDuplicateKeys(p.Value); }
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var p in value.EnumerateArray()) NoDuplicateKeys(p);
    }
    private static void Keys(JsonElement value, params string[] keys)
    {
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Count() != keys.Length ||
            value.EnumerateObject().Any(p => !keys.Contains(p.Name))) throw new Rejected("INVALID_FIELDS");
    }
    private static string Text(JsonElement value, string key)
    {
        if (!value.TryGetProperty(key, out var p) || p.ValueKind != JsonValueKind.String || p.GetString().Length > 200)
            throw new Rejected("INVALID_STRING");
        return p.GetString();
    }
    private static UUID Id(JsonElement value, string key)
    {
        if (!CanonicalId(Text(value, key)) || !UUID.TryParse(Text(value, key), out var id) || id == UUID.Zero) throw new Rejected("INVALID_ID");
        return id;
    }
    private static bool CanonicalId(string value) => Guid.TryParseExact(value, "D", out var id) && id != Guid.Empty && id.ToString() == value;
    private static bool ValidDeadline(string value) =>
        Regex.IsMatch(value, @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$") &&
        DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out _);
    private static float[] Numbers(JsonElement value, string key, int length)
    {
        if (!value.TryGetProperty(key, out var p) || p.ValueKind != JsonValueKind.Array || p.GetArrayLength() != length)
            throw new Rejected("INVALID_VECTOR");
        var values = new List<float>();
        foreach (var v in p.EnumerateArray())
        {
            if (v.ValueKind != JsonValueKind.Number || !v.TryGetSingle(out float n) || !float.IsFinite(n)) throw new Rejected("INVALID_VECTOR");
            values.Add(n);
        }
        return values.ToArray();
    }
    private static Vector3 Vector(JsonElement value, string key)
    { var v = Numbers(value, key, 3); return new Vector3(v[0], v[1], v[2]); }
    private static Quaternion Rotation(JsonElement value)
    {
        var q = Numbers(value, "rotation", 4);
        if (q.Any(v => v < -1 || v > 1) || Math.Abs(q.Sum(v => v * v) - 1) > 0.0001) throw new Rejected("INVALID_ROTATION");
        return new Quaternion(q[0], q[1], q[2], q[3]);
    }
    private static void Bounds(Vector3 p)
    {
        if (!float.IsFinite(p.X) || !float.IsFinite(p.Y) || !float.IsFinite(p.Z) || p.X < 1 || p.X > 255 || p.Y < 1 || p.Y > 255 || p.Z < 0.5 || p.Z > 100)
            throw new Rejected("OUT_OF_BOUNDS");
    }
    private static void Size(Vector3 v)
    { if (v.X < 0.1 || v.X > 16 || v.Y < 0.1 || v.Y > 16 || v.Z < 0.1 || v.Z > 16) throw new Rejected("INVALID_SIZE"); }
    private static string Fingerprint(JsonElement value)
    {
        // Canonicalize property order; numeric spellings remain distinct by design.
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream)) WriteCanonical(writer, value);
        return Convert.ToHexString(SHA256.HashData(stream.ToArray()));
    }
    private static void WriteCanonical(Utf8JsonWriter writer, JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            writer.WriteStartObject();
            foreach (var p in value.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
            { writer.WritePropertyName(p.Name); WriteCanonical(writer, p.Value); }
            writer.WriteEndObject();
        }
        else if (value.ValueKind == JsonValueKind.Array)
        { writer.WriteStartArray(); foreach (var p in value.EnumerateArray()) WriteCanonical(writer, p); writer.WriteEndArray(); }
        else value.WriteTo(writer);
    }

    private void OnFrame()
    {
        tick++;
        FpFrame();
        for (int i = 0; i < 8 && queue.TryDequeue(out var work); i++)
        {
            Interlocked.Decrement(ref pending);
            try { work.Completion.TrySetResult(Execute(work.Command)); }
            catch { work.Completion.TrySetResult(Reply(work.Command, "result_unknown", "INTERNAL_ERROR")); }
        }
    }
    private object Reply(JsonElement c, string state, string error = "", object data = null) => new
    {
        fp_version = "0.1", request_id = Text(c, "request_id"), trace_id = Text(c, "trace_id"), world_epoch = epoch,
        operation = Text(c, "operation"), state, error, tick, adapter_sequence = sequence, data
    };

    private object Execute(JsonElement c)
    {
        string operation = Text(c, "operation"), id = Text(c, "request_id");
        var p = c.GetProperty("payload");
        if (operation != "GetCapabilities" && Text(c, "world_epoch") != epoch) return Reply(c, "rejected", "EPOCH_MISMATCH");
        bool mutation = !new[] { "GetCapabilities", "GetSnapshot", "GetReceipt" }.Contains(operation);
        string fingerprint = Fingerprint(c);
        if (mutation && receipts.TryGetValue(id, out var previous))
            return previous.Fingerprint == fingerprint ? previous.Result : Reply(c, "rejected", "REQUEST_REUSED");
        var expires = DateTimeOffset.Parse(Text(c, "expires_at"), CultureInfo.InvariantCulture);
        if (expires < DateTimeOffset.UtcNow || expires > DateTimeOffset.UtcNow.AddSeconds(60)) return Reply(c, "rejected", "INVALID_DEADLINE");
        if (!Operations.Contains(operation)) return Reply(c, "rejected", "UNSUPPORTED_OPERATION");
        if (mutation && receipts.Count >= MaxReceipts) return Reply(c, "rejected", "RECEIPT_LIMIT");
        bool prepared = false;
        object result;
        try
        {
            if (mutation)
            {
                // Reserve before touching the world. Never retry a potentially applied mutation.
                receipts.Add(id, new Receipt(fingerprint, Reply(c, "result_unknown", "INCOMPLETE")));
                Audit(c, "prepared", fingerprint);
                prepared = true;
            }
            var data = Apply(operation, p);
            if (mutation) sequence++;
            result = Reply(c, "completed", data: data);
        }
        catch (Rejected e) { result = Reply(c, "rejected", e.Message); }
        catch { result = Reply(c, prepared ? "result_unknown" : "rejected", "EXECUTION_OR_STORAGE_ERROR"); }
        if (mutation)
        {
            try { Audit(c, "terminal", fingerprint, result); }
            catch { result = Reply(c, "result_unknown", "AUDIT_UNAVAILABLE"); }
            receipts[id] = new Receipt(fingerprint, result);
        }
        return result;
    }
    private void Audit(JsonElement c, string phase, string fingerprint, object result = null)
    {
        var line = JsonSerializer.SerializeToUtf8Bytes(new { utc = DateTimeOffset.UtcNow, world_epoch = epoch, request_id = Text(c, "request_id"), trace_id = Text(c, "trace_id"), operation = Text(c, "operation"), phase, fingerprint, state = result == null ? null : JsonSerializer.SerializeToElement(result).GetProperty("state").GetString() });
        using var file = new FileStream(Path.Combine(journalDirectory, epoch + ".jsonl"), FileMode.Append, FileAccess.Write, FileShare.Read);
        file.Write(line); file.WriteByte(10); file.Flush(true);
    }
    private SceneObjectGroup Group(JsonElement p, string key = "group_id")
    {
        var part = scene.GetSceneObjectPart(Id(p, key));
        if (part == null) throw new Rejected("NOT_FOUND");
        if (part.ParentGroup.OwnerID != (operationOwner ?? owner)) throw new Rejected("FORBIDDEN");
        if (part != part.ParentGroup.RootPart) throw new Rejected("ROOT_REQUIRED");
        return part.ParentGroup;
    }
    private int PartCount() => scene.GetSceneObjectGroups().Sum(g => g.PrimCount);
    private static float[] V(Vector3 v) => new[] { v.X, v.Y, v.Z };
    private static float[] Q(Quaternion q) => new[] { q.X, q.Y, q.Z, q.W };
    private object Snapshot() => new
    {
        region_id = scene.RegionInfo.RegionID.ToString(), coordinate_system = "X-east,Y-north,Z-up;metres",
        scope = "configured-owner-objects-and-avatar",
        avatars = scene.GetScenePresences().Where(p => p.UUID == owner && !p.IsChildAgent && !p.IsDeleted).Select(p => new { id = p.UUID.ToString(), position = V(p.AbsolutePosition), rotation = Q(p.Rotation) }).ToArray(),
        groups = scene.GetSceneObjectGroups().Where(g => g.OwnerID == owner && !g.IsAttachment).OrderBy(g => g.UUID.ToString()).Select(g => new
        {
            group_id = g.UUID.ToString(), root_id = g.RootPart.UUID.ToString(), position = V(g.AbsolutePosition), rotation = Q(g.GroupRotation),
            parts = g.Parts.OrderBy(part => part.LinkNum).Select(part => new
            {
                id = part.UUID.ToString(), name = part.Name, owner_id = part.OwnerID.ToString(), link_number = part.LinkNum,
                local_position = V(part.OffsetPosition), stored_rotation_offset = Q(part.RotationOffset),
                world_position = V(part.GetWorldPosition()), world_rotation = Q(part.GetWorldRotation()), size = V(part.Scale)
            }).ToArray()
        }).ToArray()
    };
    private object Apply(string operation, JsonElement p)
    {
        if (operation == "GetCapabilities")
        {
            Keys(p);
            return new { adapter = "opensim-reference/0.4.0-dev", operations = Operations, max_body_bytes = MaxBody, max_parts = MaxParts,
                max_mutation_receipts_per_epoch = MaxReceipts, persistent_receipt_replay = false, owner_id = owner.ToString(),
                snapshot_scope = "configured-owner-objects-and-avatar", authority = "OpenSim", event_stream = false,
                adapter_sequence_semantics = "successful adapter mutations only; not a world revision" };
        }
        if (operation == "GetSnapshot") { Keys(p); return Snapshot(); }
        if (operation == "GetReceipt")
        {
            Keys(p, "request_id"); string requestId = Id(p, "request_id").ToString();
            return receipts.TryGetValue(requestId, out var r) ? r.Result : throw new Rejected("RECEIPT_NOT_FOUND");
        }
        if (operation == "Backup") { Keys(p); scene.Backup(true); return new { requested = true, durability = "verify by clean shutdown and restart" }; }
        if (operation == "CreateBox")
        {
            Keys(p, "name", "position", "size");
            var position = Vector(p, "position"); var size = Vector(p, "size"); Bounds(position); Size(size);
            string name = Text(p, "name");
            if (name.Length == 0 || name.Length > 64) throw new Rejected("INVALID_NAME");
            if (PartCount() >= MaxParts) throw new Rejected("PART_LIMIT");
            var shape = PrimitiveBaseShape.CreateBox(); shape.Scale = size;
            var group = new SceneObjectGroup(operationOwner ?? owner, position, Quaternion.Identity, shape);
            group.RootPart.Name = name;
            if (!scene.AddNewSceneObject(group, true)) throw new InvalidOperationException();
            return new { group_id = group.UUID.ToString(), root_id = group.RootPart.UUID.ToString() };
        }
        if (operation == "Link")
        {
            Keys(p, "root_id", "child_id");
            var root = Group(p, "root_id"); var child = Group(p, "child_id");
            if (root == child || root.PrimCount != 1 || child.PrimCount != 1) throw new Rejected("TWO_DISTINCT_SINGLE_PARTS_REQUIRED");
            scene.LinkObjects(operationOwner ?? owner, root.LocalId, new List<uint> { child.LocalId });
            if (root.PrimCount != 2) throw new InvalidOperationException();
            return Snapshot();
        }
        // All fields and proposed transforms are validated before framework mutations.
        var target = Group(p);
        switch (operation)
        {
            case "Move":
                Keys(p, "group_id", "position"); var pos = Vector(p, "position"); Bounds(pos);
                foreach (var part in target.Parts) Bounds(part.GetWorldPosition() + pos - target.AbsolutePosition);
                target.UpdateGroupPosition(pos); break;
            case "Rotate":
                Keys(p, "group_id", "rotation"); var rot = Rotation(p);
                foreach (var part in target.Parts) Bounds(target.AbsolutePosition + part.OffsetPosition * rot);
                target.UpdateGroupRotationR(rot); break;
            case "MoveMember":
                Keys(p, "group_id", "member_id", "local_position"); var member = scene.GetSceneObjectPart(Id(p, "member_id"));
                if (member == null || member.ParentGroup != target || member == target.RootPart) throw new Rejected("CHILD_REQUIRED");
                var local = Vector(p, "local_position"); Bounds(target.AbsolutePosition + local * target.GroupRotation);
                target.UpdateSinglePosition(local, member.LocalId); break;
            case "Scale":
                Keys(p, "group_id", "factor");
                if (p.GetProperty("factor").ValueKind != JsonValueKind.Number || !p.GetProperty("factor").TryGetSingle(out float factor) || !float.IsFinite(factor) || factor < 0.25 || factor > 4) throw new Rejected("INVALID_SCALE");
                foreach (var part in target.Parts) { Size(part.Scale * factor); Bounds(target.AbsolutePosition + part.OffsetPosition * factor * target.GroupRotation); }
                if (!target.GroupResize(factor)) throw new InvalidOperationException(); break;
            case "Duplicate":
                Keys(p, "group_id", "offset"); var offset = Vector(p, "offset");
                foreach (var part in target.Parts) Bounds(part.GetWorldPosition() + offset);
                if (PartCount() + target.PrimCount > MaxParts) throw new Rejected("PART_LIMIT");
                var actor = operationOwner ?? owner;
                if (scene.GetScenePresence(actor) == null) throw new Rejected("OPERATOR_OFFLINE");
                if (!scene.Permissions.CanDuplicateObject(target, actor)) throw new Rejected("FORBIDDEN");
                var copy = scene.SceneGraph.DuplicateObject(target.LocalId, offset, actor, UUID.Zero, Quaternion.Identity, false);
                if (copy == null) throw new InvalidOperationException();
                return new { group_id = copy.UUID.ToString(), snapshot = Snapshot() };
            case "Unlink":
                Keys(p, "group_id");
                if (target.PrimCount != 2) throw new Rejected("TWO_PART_GROUP_REQUIRED");
                target.DelinkFromGroup(target.Parts.Single(part => part != target.RootPart), true); break;
            case "Delete":
                Keys(p, "group_id"); scene.DeleteSceneObject(target, false); break;
            default: throw new Rejected("UNSUPPORTED_OPERATION");
        }
        return Snapshot();
    }
}
