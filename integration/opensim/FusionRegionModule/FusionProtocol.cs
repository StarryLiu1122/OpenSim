using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Nini.Config;
using OpenMetaverse;
using OpenSim.Framework.Servers;
using OpenSim.Framework.Servers.HttpServer;

namespace RegionLab.Fusion;

// FP 0.2 is a project contract, independent from the frozen v0 reference endpoint.
// All world reads, action progress and writes run in the region frame callback.
public sealed partial class FusionRegionModule
{
    private int eventLimit = 2048;
    private static readonly string[] FpReads = { "GetCapabilities", "WorldStateSubscribe", "SimEventStream", "ActionReceipt", "AvatarSession" };
    private static readonly string[] FpWrites = { "AgentSpawn", "AgentDespawn", "AgentAction", "CancelAction", "WorldMutation", "ExperimentControl", "TelemetryExport" };
    private readonly object fpGate = new();
    private readonly ConcurrentQueue<FpWork> fpQueue = new();
    private readonly List<Principal> principals = new();
    private readonly Dictionary<string, FpReceipt> fpReceipts = new();
    private readonly Dictionary<string, long> sourceSequences = new();
    private readonly Dictionary<string, JsonElement> observed = new();
    private readonly List<JsonElement> events = new();
    private readonly Dictionary<string, ActionJob> actions = new();
    private UUID? operationOwner;
    private string fpPath, botDll, botConfiguration, dotnetPath, experiment;
    private BotProcess bot;
    private long eventSequence;
    private int fpPending;
    private float botYaw;
    private sealed record Principal(string Subject, UUID Owner, string Role, byte[] Token, DateTimeOffset Expires);
    private sealed record FpWork(JsonElement Command, Principal Principal, TaskCompletionSource<object> Completion);
    private sealed record FpReceipt(string Subject, string Fingerprint, JsonElement Reply);
    private sealed record ActionJob(JsonElement Command, Principal Principal, string Fingerprint, string Kind, Vector3 Target, float Yaw, DateTimeOffset Deadline);

    private void ConfigureFp(IConfig config)
    {
        eventLimit = config.GetInt("EventCapacity", 2048);
        if (eventLimit < 32 || eventLimit > 2048) throw new InvalidOperationException("EventCapacity must be 32..2048.");
        var expires = DateTimeOffset.UtcNow.AddHours(8);
        if (DateTimeOffset.TryParse(config.GetString("SessionExpires", ""), out var configured)) expires = configured;
        principals.Add(new Principal("operator", owner, "operator", token, expires));
        foreach (var pair in new[] { ("Observer", "observer"), ("Secondary", "writer") })
        {
            string secret = config.GetString(pair.Item1 + "Token", "");
            if (secret.Length == 0) continue;
            if (secret.Length < 64) throw new InvalidOperationException("Generated FP tokens must contain at least 64 characters.");
            UUID id = owner;
            if (pair.Item2 == "writer" && (!UUID.TryParse(config.GetString("SecondaryOwner", ""), out id) || id == UUID.Zero)) throw new InvalidOperationException("Secondary owner required.");
            principals.Add(new Principal(pair.Item1.ToLowerInvariant(), id, pair.Item2, Encoding.UTF8.GetBytes("Bearer " + secret), expires));
        }
        botDll = config.GetString("BotDll", "");
        botConfiguration = config.GetString("BotConfiguration", "");
        dotnetPath = config.GetString("DotnetPath", "dotnet");
    }
    private void StartFp()
    {
        fpPath = "/fusion/v1/regions/" + scene.RegionInfo.RegionID + "/commands";
        MainServer.Instance.AddSimpleStreamHandler(new SimpleStreamHandler(fpPath, HandleFp));
    }
    private void CloseFp()
    {
        lock (fpGate)
        {
            if (fpPath != null) { MainServer.Instance.RemoveSimpleStreamHandler(fpPath); fpPath = null; }
            bot?.Dispose(); bot = null;
            // Prepared records remain queryable as result_unknown in the next epoch.
            while (fpQueue.TryDequeue(out var work)) { Interlocked.Decrement(ref fpPending); work.Completion.TrySetResult(FpReply(work.Command, "rejected", "STOPPING")); }
        }
    }
    private void HandleFp(IOSHttpRequest request, IOSHttpResponse response)
    {
        response.ContentType = "application/json; charset=utf-8";
        response.AddHeader("Cache-Control", "no-store");
        object result;
        try
        {
            var supplied = Encoding.UTF8.GetBytes(request.Headers["Authorization"] ?? "");
            var principal = principals.FirstOrDefault(p => CryptographicOperations.FixedTimeEquals(supplied, p.Token));
            if (!IPAddress.IsLoopback(request.RemoteIPEndPoint.Address) || principal == null || principal.Expires <= DateTimeOffset.UtcNow)
            { response.StatusCode = 401; result = new { error = "UNAUTHORIZED_OR_EXPIRED_SESSION" }; }
            else if (request.HttpMethod != "POST") { response.StatusCode = 405; result = new { error = "METHOD_NOT_ALLOWED" }; }
            else if (request.ContentLength64 < 1 || request.ContentLength64 > MaxBody) { response.StatusCode = 413; result = new { error = "BODY_LIMIT" }; }
            else
            {
                var bytes = new byte[(int)request.ContentLength64]; request.InputStream.ReadExactly(bytes);
                using var doc = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 12 });
                var c = doc.RootElement.Clone(); NoDuplicateKeys(c);
                Keys(c, "fp_version", "world_id", "region_id", "request_id", "trace_id", "world_epoch", "origin", "source_seq", "operation", "expires_at", "payload");
                if (Text(c, "fp_version") != "0.2" || !CanonicalId(Text(c, "request_id")) || !CanonicalId(Text(c, "trace_id")) ||
                    !ValidDeadline(Text(c, "expires_at")) || c.GetProperty("payload").ValueKind != JsonValueKind.Object ||
                    !c.GetProperty("source_seq").TryGetInt64(out long seq) || seq < 0) throw new Rejected("INVALID_ENVELOPE");
                if (Text(c, "world_id") != scene.RegionInfo.RegionID.ToString() || Text(c, "region_id") != scene.RegionInfo.RegionID.ToString()) throw new Rejected("WRONG_WORLD");
                Text(c, "operation"); Text(c, "world_epoch");
                if (Text(c, "origin") is not ("mock-platform" or "manual-test")) throw new Rejected("UNTRUSTED_ORIGIN");
                if (closing) throw new Rejected("STOPPING");
                if (Interlocked.Increment(ref fpPending) > 64) { Interlocked.Decrement(ref fpPending); throw new Rejected("QUEUE_FULL"); }
                var completion = new TaskCompletionSource<object>(TaskCreationOptions.RunContinuationsAsynchronously);
                fpQueue.Enqueue(new FpWork(c, principal, completion));
                if (completion.Task.Wait(TimeSpan.FromSeconds(5))) result = completion.Task.Result;
                else { response.StatusCode = 202; result = FpReply(c, "pending", "QUERY_RECEIPT"); }
            }
        }
        catch (Exception e) when (e is JsonException or Rejected or InvalidOperationException or EndOfStreamException)
        { response.StatusCode = 400; result = new { error = e is Rejected ? e.Message : "INVALID_JSON" }; }
        response.RawBuffer = JsonSerializer.SerializeToUtf8Bytes(result);
    }
    private object FpReply(JsonElement c, string state, string error = "", object data = null) => new
    {
        fp_version = "0.2", world_id = scene.RegionInfo.RegionID.ToString(), region_id = scene.RegionInfo.RegionID.ToString(), source_runtime = "opensim-0.9.3.0",
        world_epoch = epoch, request_id = Text(c, "request_id"), trace_id = Text(c, "trace_id"), operation = Text(c, "operation"),
        state, error, tick, event_seq = eventSequence, observed_at = DateTimeOffset.UtcNow, data
    };
    private void FpFrame()
    {
        lock (fpGate)
        {
            if (closing) return;
            Capture("opensim", "");
            for (int i = 0; i < 8 && fpQueue.TryDequeue(out var work); i++)
            {
                Interlocked.Decrement(ref fpPending);
                try { work.Completion.TrySetResult(ExecuteFp(work.Command, work.Principal)); }
                catch { work.Completion.TrySetResult(FpReply(work.Command, "result_unknown", "INTERNAL_ERROR")); }
            }
            AdvanceActions();
            if (bot != null && !bot.Exited && tick % 100 == 0 && !actions.Values.Any(a => a.Kind == "MOVE_TO")) bot.Control(botYaw, false);
        }
    }
    private IEnumerable<JsonElement> Entities()
    {
        foreach (var group in scene.GetSceneObjectGroups().Where(g => !g.IsAttachment).OrderBy(g => g.UUID.ToString()))
            yield return JsonSerializer.SerializeToElement(new
            {
                entity_id = "group/" + group.UUID, source_id = group.UUID.ToString(), kind = "object_group", root_id = group.RootPart.UUID.ToString(), owner_id = group.OwnerID.ToString(),
                position = V(group.AbsolutePosition), rotation = Q(group.GroupRotation),
                members = group.Parts.OrderBy(p => p.LinkNum).Select(p => new { entity_id = "part/" + p.UUID, source_id = p.UUID.ToString(), name = p.Name, link_number = p.LinkNum, local_position = V(p.OffsetPosition), rotation = Q(p.RotationOffset), size = V(p.Scale), state = p.Description.StartsWith("FP_DOOR:") ? p.Description : "" }).ToArray()
            });
        foreach (var p in scene.GetScenePresences().Where(p => !p.IsChildAgent && !p.IsDeleted).OrderBy(p => p.UUID.ToString()))
            yield return JsonSerializer.SerializeToElement(new { entity_id = "avatar/" + p.UUID, source_id = p.UUID.ToString(), kind = "avatar", position = V(p.AbsolutePosition), rotation = Q(p.Rotation) });
    }
    private void Capture(string origin, string trace)
    {
        var next = Entities().ToDictionary(e => Text(e, "entity_id"));
        foreach (var pair in next)
            if (!observed.TryGetValue(pair.Key, out var old) || Fingerprint(old) != Fingerprint(pair.Value)) AddEvent("upsert", pair.Key, pair.Value, origin, trace);
        foreach (var old in observed.Keys)
            if (!next.ContainsKey(old)) AddEvent("delete", old, null, origin, trace);
        observed.Clear(); foreach (var pair in next) observed.Add(pair.Key, pair.Value);
    }
    private void AddEvent(string kind, string entity, object data, string origin, string trace)
    {
        events.Add(JsonSerializer.SerializeToElement(new { fp_version = "0.2", world_epoch = epoch, seq = ++eventSequence, tick, observed_at = DateTimeOffset.UtcNow, kind, entity_id = entity, origin, trace_id = trace, data }));
        if (events.Count > eventLimit) events.RemoveAt(0);
    }
    private static object Visible(object value, Principal principal)
    {
        if (principal.Role != "observer") return value;
        var node = JsonNode.Parse(JsonSerializer.Serialize(value));
        void Remove(JsonNode n)
        {
            if (n is JsonObject obj) { obj.Remove("owner_id"); foreach (var p in obj.ToArray()) if (p.Value != null) Remove(p.Value); }
            else if (n is JsonArray a) foreach (var child in a) if (child != null) Remove(child);
        }
        if (node != null) Remove(node);
        return node;
    }
    private object State(Principal principal) => Visible(new { snapshot_seq = eventSequence, coordinate_system = "X-east,Y-north,Z-up;metres", scope = "non-attachment-region-objects-and-root-avatars", entities = observed.Values.ToArray(), consistency = "immutable frame observation; not a lock over upstream physics or viewer threads" }, principal);
    private object ExecuteFp(JsonElement c, Principal principal)
    {
        var op = Text(c, "operation"); var id = Text(c, "request_id"); var p = c.GetProperty("payload");
        if (principal.Expires <= DateTimeOffset.UtcNow) return FpReply(c, "rejected", "SESSION_EXPIRED");
        if (op != "GetCapabilities" && Text(c, "world_epoch") != epoch) return FpReply(c, "rejected", "EPOCH_MISMATCH");
        bool mutation = FpWrites.Contains(op); string fingerprint = Fingerprint(c);
        if (fpReceipts.TryGetValue(id, out var previous))
            return previous.Subject == principal.Subject && previous.Fingerprint == fingerprint ? previous.Reply : FpReply(c, "rejected", "REQUEST_REUSED");
        var deadline = DateTimeOffset.Parse(Text(c, "expires_at"), CultureInfo.InvariantCulture);
        if (deadline <= DateTimeOffset.UtcNow || deadline > DateTimeOffset.UtcNow.AddSeconds(60)) return FpReply(c, "rejected", "INVALID_DEADLINE");
        if (!mutation && !FpReads.Contains(op)) return FpReply(c, "rejected", "UNSUPPORTED_OPERATION");
        if (mutation && (principal.Role == "observer" || (principal.Role == "writer" && op != "WorldMutation"))) return FpReply(c, "rejected", "FORBIDDEN");
        string sourceKey = principal.Subject + "/" + Text(c, "origin");
        long sourceSeq = c.GetProperty("source_seq").GetInt64();
        if (mutation && sourceSeq <= sourceSequences.GetValueOrDefault(sourceKey)) return FpReply(c, "rejected", "SOURCE_SEQUENCE_REUSED_OR_OUT_OF_ORDER");
        if (mutation && fpReceipts.Count >= MaxReceipts) return FpReply(c, "rejected", "RECEIPT_LIMIT");
        bool prepared = false;
        object result;
        try
        {
            if (mutation)
            {
                PersistFp(c, principal, fingerprint, FpReply(c, "pending", "PREPARED"));
                prepared = true; sourceSequences[sourceKey] = sourceSeq;
            }
            object data = ApplyFp(c, principal, fingerprint, deadline);
            if (actions.ContainsKey(id)) return fpReceipts[id].Reply;
            Capture(Text(c, "origin"), Text(c, "trace_id"));
            result = FpReply(c, "completed", data: data);
        }
        catch (Rejected e) { result = FpReply(c, "rejected", e.Message); }
        catch { result = FpReply(c, prepared ? "result_unknown" : "rejected", "EXECUTION_OR_STORAGE_ERROR"); }
        if (mutation && prepared)
        {
            try { PersistFp(c, principal, fingerprint, result); }
            catch { result = FpReply(c, "result_unknown", "RECEIPT_STORAGE_UNAVAILABLE"); fpReceipts[id] = new FpReceipt(principal.Subject, fingerprint, JsonSerializer.SerializeToElement(result)); }
        }
        return result;
    }
    private void PersistFp(JsonElement c, Principal principal, string fingerprint, object result)
    {
        var reply = JsonSerializer.SerializeToElement(result);
        var id = Text(c, "request_id");
        string target = Path.Combine(journalDirectory, epoch + "-" + id + ".receipt.json");
        string temp = target + ".tmp";
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { subject = principal.Subject, fingerprint, reply });
        using (var file = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None)) { file.Write(bytes); file.Flush(true); }
        File.Move(temp, target, true);
        fpReceipts[id] = new FpReceipt(principal.Subject, fingerprint, reply);
    }
    private object QueryReceipt(JsonElement p, Principal principal)
    {
        Keys(p, "request_id", "receipt_epoch"); string id = Id(p, "request_id").ToString(); string requestedEpoch = Id(p, "receipt_epoch").ToString();
        if (requestedEpoch == epoch && fpReceipts.TryGetValue(id, out var r)) return r.Subject == principal.Subject ? r.Reply : throw new Rejected("FORBIDDEN");
        string file = Path.Combine(journalDirectory, requestedEpoch + "-" + id + ".receipt.json");
        if (!File.Exists(file)) throw new Rejected("RECEIPT_NOT_FOUND_RESULT_UNKNOWN");
        if (new FileInfo(file).Length > 16 * 1024 * 1024) throw new Rejected("CORRUPT_RECEIPT");
        using var doc = JsonDocument.Parse(File.ReadAllText(file));
        if (Text(doc.RootElement, "subject") != principal.Subject) throw new Rejected("FORBIDDEN");
        var reply = JsonNode.Parse(doc.RootElement.GetProperty("reply").GetRawText());
        if ((string)reply["state"] == "pending") { reply["state"] = "result_unknown"; reply["error"] = "PREVIOUS_EPOCH_INTERRUPTED"; }
        return reply;
    }
    private object ApplyFp(JsonElement c, Principal principal, string fingerprint, DateTimeOffset deadline)
    {
        var p = c.GetProperty("payload"); string op = Text(c, "operation"), id = Text(c, "request_id");
        switch (op)
        {
            case "GetCapabilities":
                Keys(p);
                return new { fp_version = "0.2", adapter = "region-lab-fusion/0.4.1", authority = "OpenSim", principal = principal.Subject, role = principal.Role,
                    operations = principal.Role == "observer" ? FpReads : principal.Role == "writer" ? FpReads.Concat(new[] { "WorldMutation" }).ToArray() : FpReads.Concat(FpWrites).ToArray(),
                    actions = new[] { "MOVE_TO", "TURN", "INSPECT", "INTERACT" }, event_capacity = eventLimit, max_commands_per_epoch = MaxReceipts,
                    bot_limit = 1, max_body_bytes = MaxBody, mutation_scope = "owned static boxes and two-part linksets", subscription = "bounded polling with explicit cursor", webgpu = false,
                    unsupported = new[] { "navigation planning", "grabbing", "impulses", "arbitrary scripts", "SSO", "inventory", "real model platform", "whole-scene transaction" } };
            case "AvatarSession":
                Keys(p); return new { subject = principal.Subject, role = principal.Role, expires_at = principal.Expires, authenticated = true };
            case "WorldStateSubscribe": Keys(p); return State(principal);
            case "SimEventStream":
                Keys(p, "after_seq", "limit"); long after = p.GetProperty("after_seq").GetInt64(); int limit = p.GetProperty("limit").GetInt32();
                if (after < 0 || after > eventSequence || limit < 1 || limit > 128) throw new Rejected("INVALID_CURSOR_OR_LIMIT");
                if (events.Count > 0 && after < events[0].GetProperty("seq").GetInt64() - 1) throw new Rejected("RESYNC_REQUIRED");
                var batch = events.Where(e => e.GetProperty("seq").GetInt64() > after).Take(limit).ToArray();
                return Visible(new { events = batch, next_seq = batch.Length > 0 ? batch[^1].GetProperty("seq").GetInt64() : after, head_seq = eventSequence }, principal);
            case "ActionReceipt": return QueryReceipt(p, principal);
            case "CancelAction":
                Keys(p, "request_id"); string cancelId = Id(p, "request_id").ToString();
                if (!actions.TryGetValue(cancelId, out var cancelled)) throw new Rejected("ACTION_NOT_PENDING");
                if (cancelled.Principal.Subject != principal.Subject) throw new Rejected("FORBIDDEN");
                if (cancelled.Kind is not ("MOVE_TO" or "TURN")) throw new Rejected("LIFECYCLE_NOT_CANCELLABLE");
                bot?.Control(botYaw, false); FinishAction(cancelId, cancelled, "cancelled", "CANCELLED_BY_CALLER"); return new { cancelled = cancelId };
            case "AgentSpawn":
                Keys(p);
                if (scene.GetScenePresence(owner) != null || (bot != null && !bot.Exited)) throw new Rejected("BOT_OR_AVATAR_ALREADY_PRESENT");
                if (!File.Exists(botDll) || !File.Exists(botConfiguration)) throw new Rejected("BOT_NOT_CONFIGURED");
                bot?.Dispose(); bot = new BotProcess(dotnetPath, botDll, botConfiguration, Path.Combine(journalDirectory, epoch + "-bot.log"));
                actions.Add(id, new ActionJob(c, principal, fingerprint, "spawn", Vector3.Zero, 0, deadline)); return null;
            case "AgentDespawn":
                Keys(p);
                if (bot == null) throw new Rejected("BOT_NOT_MANAGED");
                foreach (var active in actions.ToArray()) FinishAction(active.Key, active.Value, "cancelled", "BOT_DESPAWNED");
                bot.Control(botYaw, false); bot.Logout(); actions.Add(id, new ActionJob(c, principal, fingerprint, "despawn", Vector3.Zero, 0, deadline)); return null;
            case "AgentAction": return BeginAction(c, principal, fingerprint, deadline);
            case "WorldMutation":
                Keys(p, "expected_seq", "operation", "payload");
                if (p.GetProperty("expected_seq").GetInt64() != eventSequence) throw new Rejected("STATE_CONFLICT");
                string mutation = Text(p, "operation");
                if (!new[] { "CreateBox", "CreateDoor", "Link", "Move", "Rotate", "MoveMember", "Scale", "Duplicate", "Unlink", "Delete" }.Contains(mutation)) throw new Rejected("UNSUPPORTED_MUTATION");
                operationOwner = principal.Owner;
                try
                {
                    var result = Apply(mutation == "CreateDoor" ? "CreateBox" : mutation, p.GetProperty("payload"));
                    if (mutation == "CreateDoor")
                    {
                        var groupId = JsonSerializer.SerializeToElement(result).GetProperty("group_id").GetString();
                        var part = scene.GetSceneObjectPart(UUID.Parse(groupId)); part.Description = "FP_DOOR:closed"; part.ParentGroup.HasGroupChanged = true;
                    }
                    // Avoid leaking the legacy owner-scoped snapshot through a different subject.
                    return mutation is "CreateBox" or "CreateDoor" or "Duplicate" ? new { entity_id = "group/" + JsonSerializer.SerializeToElement(result).GetProperty("group_id").GetString() } : new { applied = mutation };
                }
                finally { operationOwner = null; }
            case "ExperimentControl":
                Keys(p, "action", "experiment_id"); string experimentId = Id(p, "experiment_id").ToString(); string action = Text(p, "action");
                if (action == "start") { if (experiment != null) throw new Rejected("EXPERIMENT_ACTIVE"); experiment = experimentId; AddEvent("experiment_start", experiment, null, Text(c, "origin"), Text(c, "trace_id")); }
                else if (action == "stop") { if (experiment != experimentId) throw new Rejected("EXPERIMENT_NOT_ACTIVE"); AddEvent("experiment_stop", experiment, null, Text(c, "origin"), Text(c, "trace_id")); experiment = null; }
                else throw new Rejected("UNSUPPORTED_EXPERIMENT_ACTION");
                return new { experiment_id = experimentId, action };
            case "TelemetryExport":
                Keys(p); return new { format = "region-lab.fp-telemetry", version = 1, world_epoch = epoch, snapshot = State(principal), events = events.ToArray(), first_retained_seq = events.Count == 0 ? 0 : events[0].GetProperty("seq").GetInt64(), receipts = fpReceipts.Values.Where(r => r.Subject == principal.Subject && Text(r.Reply, "operation") != "TelemetryExport").Select(r => r.Reply).ToArray(), completeness = "bounded epoch buffer; caller must persist every poll for longer experiments; export receipts excluded to prevent recursion" };
            default: throw new Rejected("UNSUPPORTED_OPERATION");
        }
    }
    private object BeginAction(JsonElement c, Principal principal, string fingerprint, DateTimeOffset deadline)
    {
        var p = c.GetProperty("payload"); string kind = Text(p, "action");
        if (bot == null || bot.Exited || !bot.Ready || scene.GetScenePresence(owner) is not { } avatar) throw new Rejected("BOT_OFFLINE");
        if (kind == "INSPECT") { Keys(p, "action"); return new { entity_id = "avatar/" + owner, position = V(avatar.AbsolutePosition), rotation = Q(avatar.Rotation) }; }
        if (kind == "INTERACT")
        {
            Keys(p, "action", "group_id"); var target = Group(p);
            if (target.PrimCount != 1 || !target.RootPart.Description.StartsWith("FP_DOOR:")) throw new Rejected("UNSUPPORTED_INTERACTION");
            var from = avatar.AbsolutePosition; var to = target.AbsolutePosition;
            if (Vector3.Distance(from, to) > 4) throw new Rejected("INTERACTION_TOO_FAR");
            if (Blocked(from, to, target.UUID)) throw new Rejected("INTERACTION_OCCLUDED");
            bool open = target.RootPart.Description == "FP_DOOR:closed";
            var rotation = open ? new Quaternion(0, 0, MathF.Sqrt(.5f), MathF.Sqrt(.5f)) : Quaternion.Identity;
            target.UpdateGroupRotationR(rotation); target.RootPart.Description = "FP_DOOR:" + (open ? "open" : "closed"); target.HasGroupChanged = true;
            if (Math.Abs(Quaternion.Dot(target.GroupRotation, rotation)) < .999f) throw new IOException("INTERACTION_NOT_CONFIRMED");
            AddEvent("interaction", "group/" + target.UUID, new { active = open, actor = "avatar/" + owner }, Text(c, "origin"), Text(c, "trace_id"));
            return new { active = open, rotation = Q(target.GroupRotation), observed = true };
        }
        if (actions.Count > 0) throw new Rejected("BOT_BUSY");
        Vector3 goal = Vector3.Zero; float yaw = 0;
        if (kind == "MOVE_TO")
        {
            Keys(p, "action", "position"); goal = Vector(p, "position"); Bounds(goal);
            if (Vector3.Distance(goal, avatar.AbsolutePosition) > 32 || Math.Abs(goal.Z - avatar.AbsolutePosition.Z) > 1) throw new Rejected("TARGET_OUTSIDE_ACTION_LIMIT");
        }
        else if (kind == "TURN")
        {
            Keys(p, "action", "yaw"); yaw = p.GetProperty("yaw").GetSingle();
            if (!float.IsFinite(yaw) || Math.Abs(yaw) > MathF.PI * 2) throw new Rejected("INVALID_YAW");
        }
        else throw new Rejected("UNSUPPORTED_ACTION");
        actions.Add(Text(c, "request_id"), new ActionJob(c, principal, fingerprint, kind, goal, yaw, deadline));
        return null;
    }
    private bool Blocked(Vector3 from, Vector3 to, UUID target)
    {
        // Conservative OBB visibility: never treats arbitrary meshes as empty space.
        foreach (var g in scene.GetSceneObjectGroups().Where(g => !g.IsAttachment && g.UUID != target))
        foreach (var part in g.Parts)
        {
            var inverse = Quaternion.Inverse(part.GetWorldRotation());
            var start = (from - part.GetWorldPosition()) * inverse;
            var delta = (to - from) * inverse; var half = part.Scale * .5f;
            float near = 0, far = 1;
            var a = V(start); var d = V(delta); var h = V(half);
            for (int axis = 0; axis < 3 && near <= far; axis++)
            {
                if (Math.Abs(d[axis]) < .00001f) { if (Math.Abs(a[axis]) > h[axis]) near = 2; }
                else { float t0 = (-h[axis] - a[axis]) / d[axis], t1 = (h[axis] - a[axis]) / d[axis]; near = Math.Max(near, Math.Min(t0, t1)); far = Math.Min(far, Math.Max(t0, t1)); }
            }
            if (near <= far && far > .001 && near < .999) return true;
        }
        return false;
    }
    private void AdvanceActions()
    {
        foreach (var pair in actions.ToArray())
        {
            var a = pair.Value; var avatar = scene.GetScenePresence(owner);
            if (DateTimeOffset.UtcNow > a.Deadline)
            {
                bot?.Control(botYaw, false);
                if (a.Kind is "spawn" or "despawn") { bot?.Dispose(); bot = null; }
                FinishAction(pair.Key, a, "failed", "ACTION_TIMEOUT"); continue;
            }
            if (a.Kind == "spawn")
            {
                if (bot != null && !bot.Exited && bot.Ready && avatar != null) FinishAction(pair.Key, a, "completed", "");
                else if (bot == null || bot.Exited || bot.Failed) FinishAction(pair.Key, a, "failed", "BOT_LOGIN_FAILED");
                continue;
            }
            if (a.Kind == "despawn")
            {
                if (avatar == null && bot != null && bot.Exited) FinishAction(pair.Key, a, bot.ExitCode == 0 ? "completed" : "failed", bot.ExitCode == 0 ? "" : "BOT_EXIT_FAILED");
                continue;
            }
            if (avatar == null || bot == null || bot.Exited || bot.Failed) { FinishAction(pair.Key, a, "failed", "BOT_LOST"); continue; }
            if (a.Kind == "MOVE_TO")
            {
                var offset = a.Target - avatar.AbsolutePosition; offset.Z = 0;
                if (offset.Length() < .55f)
                {
                    bot.Control(botYaw, false);
                    var velocity = avatar.Velocity; velocity.Z = 0;
                    if (velocity.Length() < .15f) FinishAction(pair.Key, a, "completed", "");
                }
                else if (tick % 5 == 0) { botYaw = MathF.Atan2(offset.Y, offset.X); bot.Control(botYaw, true); }
            }
            else if (a.Kind == "TURN")
            {
                var expected = new Quaternion(0, 0, MathF.Sin(a.Yaw / 2), MathF.Cos(a.Yaw / 2));
                if (Math.Abs(Quaternion.Dot(avatar.Rotation, expected)) > .999f) FinishAction(pair.Key, a, "completed", "");
                else if (tick % 5 == 0) { botYaw = a.Yaw; bot.Control(botYaw, false); }
            }
        }
    }
    private void FinishAction(string id, ActionJob action, string state, string error)
    {
        actions.Remove(id);
        Capture(Text(action.Command, "origin"), Text(action.Command, "trace_id"));
        var avatar = scene.GetScenePresence(owner);
        var result = FpReply(action.Command, state, error, new { observed = true, avatar_present = avatar != null, position = avatar == null ? null : V(avatar.AbsolutePosition), rotation = avatar == null ? null : Q(avatar.Rotation) });
        AddEvent("action_receipt", "request/" + id, result, Text(action.Command, "origin"), Text(action.Command, "trace_id"));
        try { PersistFp(action.Command, action.Principal, action.Fingerprint, result); }
        catch { fpReceipts[id] = new FpReceipt(action.Principal.Subject, action.Fingerprint, JsonSerializer.SerializeToElement(FpReply(action.Command, "result_unknown", "RECEIPT_STORAGE_UNAVAILABLE"))); }
    }
}
