using System.Text.Json;
using OpenMetaverse;

// This process owns exactly one protocol connection. The region module supplies
// bounded movement controls over redirected stdin; it verifies authoritative results.
internal static class BotWorker
{
    internal static async Task<int> Run(string configuration)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(configuration));
        string S(string key) => doc.RootElement.GetProperty(key).GetString();
        if (!Uri.TryCreate(S("url"), UriKind.Absolute, out var uri) || uri.Scheme != "http" || uri.Host != "127.0.0.1") return 2;
        var client = new GridClient();
        client.Settings.LOGIN_SERVER = uri.ToString();
        client.Settings.USE_ASSET_CACHE = false;
        client.Settings.MULTIPLE_SIMS = false;
        client.Settings.SEND_AGENT_UPDATES = true;
        client.Settings.SEND_PINGS = true;
        client.Settings.OBJECT_TRACKING = false;
        client.Settings.AVATAR_TRACKING = false;
        client.Settings.STORE_LAND_PATCHES = false;
        client.Settings.SEND_AGENT_APPEARANCE = false;
        int result = 0;
        try
        {
            bool Login() => client.Network.Login(S("first_name"), S("last_name"), S("password"), "RegionLabFusionBot", "uri:V4 Reference&100&100&2", "0.4.1");
            bool connected = await Task.Run(Login);
            // The pinned standalone login service clears a crash-stale GridUser
            // record while returning this one specific failure. Retry once only;
            // never retry authentication failures or disable duplicate checks.
            if (!connected && client.Network.LoginErrorKey == "presence" && client.Network.LoginMessage.StartsWith("You appear to be already logged in.", StringComparison.Ordinal))
            {
                Console.WriteLine("FUSION_BOT_STALE_PRESENCE_RETRY");
                await Task.Delay(1000);
                connected = await Task.Run(Login);
            }
            if (!connected) return 3;
            Console.WriteLine("FUSION_BOT_READY");
            var end = DateTime.UtcNow.AddMinutes(10);
            while (client.Network.Connected && DateTime.UtcNow < end)
            {
                var read = Console.In.ReadLineAsync();
                var completed = await Task.WhenAny(read, Task.Delay(TimeSpan.FromSeconds(20)));
                if (completed != read) break; // Parent heartbeat disappeared; stop, never keep walking.
                string line = await read;
                if (line == null || line.Length > 2048) break;
                using var command = JsonDocument.Parse(line);
                var c = command.RootElement;
                if (c.GetProperty("operation").GetString() == "logout") break;
                if (c.GetProperty("operation").GetString() == "control")
                {
                    float angle = c.GetProperty("yaw").GetSingle();
                    if (!float.IsFinite(angle) || Math.Abs(angle) > MathF.PI * 2) throw new InvalidOperationException("INVALID_CONTROL");
                    var q = new Quaternion(0, 0, MathF.Sin(angle / 2), MathF.Cos(angle / 2));
                    client.Self.Movement.Fly = false;
                    client.Self.Movement.AtPos = c.GetProperty("forward").GetBoolean();
                    client.Self.Movement.BodyRotation = q;
                    client.Self.Movement.HeadRotation = q;
                    client.Self.Movement.SendUpdate();
                }
            }
        }
        catch (Exception e) { Console.WriteLine("FUSION_BOT_ERROR " + e.GetType().Name); result = 4; }
        finally
        {
            if (client.Network.Connected)
            {
                client.Self.Movement.AtPos = false;
                client.Self.Movement.SendUpdate();
                client.Network.Logout();
            }
            Console.WriteLine("FUSION_BOT_EXIT");
        }
        return result;
    }
}
