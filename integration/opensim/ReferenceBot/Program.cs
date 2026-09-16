using System.Text.Json;
using OpenMetaverse;

if (args.Length == 2 && args[0] == "--worker") return await BotWorker.Run(args[1]);

// This is a bounded protocol smoke test, not an autonomous agent or a teleport-based move test.
if (args.Length != 3 || !int.TryParse(args[2], out int holdSeconds) || holdSeconds < 0 || holdSeconds > 600)
    throw new ArgumentException("Usage: ReferenceBot private-config.json new-report.json hold-seconds(0..600)");
string report = Path.GetFullPath(args[1]);
if (File.Exists(report)) throw new IOException("Refusing to overwrite a bot report.");
using var config = JsonDocument.Parse(File.ReadAllText(args[0]));
string Setting(string key) => config.RootElement.GetProperty(key).GetString();
if (!Uri.TryCreate(Setting("url"), UriKind.Absolute, out var uri) || uri.Scheme != "http" || uri.Host != "127.0.0.1")
    throw new ArgumentException("Only the isolated loopback reference is allowed.");
var client = new GridClient();
client.Settings.LOGIN_SERVER = uri.ToString();
client.Settings.USE_ASSET_CACHE = false;
client.Settings.MULTIPLE_SIMS = false;
client.Settings.SEND_AGENT_UPDATES = true;
client.Settings.SEND_PINGS = true;
client.Settings.OBJECT_TRACKING = false;
client.Settings.AVATAR_TRACKING = false;
client.Settings.STORE_LAND_PATCHES = false;
client.Settings.SEND_AGENT_APPEARANCE = false; // This bounded Bot does not bake or manage an outfit.
var samples = new List<object>();
using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", Setting("token"));
string epoch = "";
async Task<JsonElement> Observe(string operation = "GetSnapshot")
{
    var command = new { fp_version = "0.1", request_id = Guid.NewGuid().ToString(), trace_id = Guid.NewGuid().ToString(), world_epoch = epoch,
        operation, expires_at = DateTimeOffset.UtcNow.AddSeconds(30).ToString("O"), payload = new { } };
    using var response = await http.PostAsync(uri + "fusion/v0/regions/" + Setting("region_id") + "/commands",
        new StringContent(JsonSerializer.Serialize(command), System.Text.Encoding.UTF8, "application/json"));
    response.EnsureSuccessStatusCode();
    using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
    if (doc.RootElement.GetProperty("state").GetString() != "completed") throw new InvalidOperationException("OBSERVATION_FAILED");
    epoch = doc.RootElement.GetProperty("world_epoch").GetString();
    return doc.RootElement.GetProperty("data").Clone();
}
bool loggedIn = false, moved = false, turnConfirmed = false, loggedOut = false;
string error = "";
float[] V(Vector3 v) => new[] { v.X, v.Y, v.Z };
void Save(string state) => File.WriteAllText(report, JsonSerializer.Serialize(new
{
    test = "original-protocol-bot", state, logged_in = loggedIn, moved, turn_confirmed = turnConfirmed, logged_out = loggedOut, error,
    source = "OpenMetaverse client plus independent region-module observations", samples
}, new JsonSerializerOptions { WriteIndented = true }));
try
{
    await Observe("GetCapabilities");
    loggedIn = await Task.Run(() => client.Network.Login(Setting("first_name"), Setting("last_name"), Setting("password"), "RegionLabReference", "uri:V4 Reference&100&100&2", "0.4.0-dev"));
    if (!loggedIn) throw new InvalidOperationException("LOGIN_FAILED");
    await Task.Delay(2000);
    client.Self.Movement.Fly = false;
    var start = client.Self.SimPosition;
    var before = await Observe();
    samples.Add(new { phase = "start", position = V(start), region_avatars = before.GetProperty("avatars") });
    client.Self.Movement.BodyRotation = Quaternion.Identity;
    client.Self.Movement.HeadRotation = Quaternion.Identity;
    client.Self.Movement.AtPos = true;
    client.Self.Movement.SendUpdate();
    await Task.Delay(2000);
    client.Self.Movement.AtPos = false;
    client.Self.Movement.SendUpdate();
    await Task.Delay(1500);
    var after = await Observe();
    samples.Add(new { phase = "after_move", position = V(client.Self.SimPosition), region_avatars = after.GetProperty("avatars") });
    float oldX = before.GetProperty("avatars")[0].GetProperty("position")[0].GetSingle();
    float newX = after.GetProperty("avatars")[0].GetProperty("position")[0].GetSingle();
    moved = newX - oldX > 0.5f && newX - oldX < 8;
    client.Self.Movement.TurnToward(client.Self.SimPosition + new Vector3(0, 3, 0));
    client.Self.Movement.SendUpdate();
    await Task.Delay(1000);
    var turned = await Observe();
    samples.Add(new { phase = "turn", region_avatars = turned.GetProperty("avatars") });
    var q = turned.GetProperty("avatars")[0].GetProperty("rotation");
    turnConfirmed = MathF.Abs(q[2].GetSingle() - MathF.Sqrt(0.5f)) < 0.01f && MathF.Abs(q[3].GetSingle() - MathF.Sqrt(0.5f)) < 0.01f;
    if (!moved) throw new InvalidOperationException("MOVE_TIMEOUT");
    if (!turnConfirmed) throw new InvalidOperationException("TURN_NOT_CONFIRMED");
    Save("ready");
    Console.WriteLine("BOT_READY: login and bounded forward movement observed in the region. Send Enter to log out.");
    if (holdSeconds > 0) await Task.WhenAny(Console.In.ReadLineAsync(), Task.Delay(TimeSpan.FromSeconds(holdSeconds)));
}
catch (Exception e) { error = e is InvalidOperationException ? e.Message : e.GetType().Name; }
finally
{
    try
    {
        if (client.Network.Connected) client.Network.Logout();
        await Task.Delay(1500);
        var final = await Observe();
        loggedOut = loggedIn && final.GetProperty("avatars").GetArrayLength() == 0;
        samples.Add(new { phase = "logout", region_avatars = final.GetProperty("avatars") });
    }
    catch { error = error.Length == 0 ? "LOGOUT_OR_OBSERVATION_FAILED" : error; }
    Save("finished");
}
Console.WriteLine(JsonSerializer.Serialize(new { loggedIn, moved, turnConfirmed, loggedOut, error }));
return loggedIn && moved && turnConfirmed && loggedOut && error.Length == 0 ? 0 : 1;
