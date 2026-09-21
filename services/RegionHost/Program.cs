using System.Net;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Diagnostics;

if (args.Length == 2 && args[0] == "--certificate")
{
    string dir = Path.GetFullPath(args[1]); Directory.CreateDirectory(dir);
    if (File.Exists(Path.Combine(dir, "localhost.pfx"))) throw new InvalidOperationException("Certificate already exists");
    using var rsa = RSA.Create(2048);
    var request = new CertificateRequest("CN=Region Lab local test", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    var san = new SubjectAlternativeNameBuilder(); san.AddDnsName("localhost"); san.AddIpAddress(IPAddress.Loopback);
    request.CertificateExtensions.Add(san.Build());
    request.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
    request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment | X509KeyUsageFlags.KeyCertSign, true));
    using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddDays(30));
    File.WriteAllBytes(Path.Combine(dir, "localhost.pfx"), certificate.Export(X509ContentType.Pfx));
    File.WriteAllText(Path.Combine(dir, "localhost.pem"), certificate.ExportCertificatePem());
    Console.WriteLine("Local test certificate created; no OS trust store was changed."); return;
}
if (args.Length != 1) throw new ArgumentException("RegionHost <private-config.json>");
var config = JsonNode.Parse(File.ReadAllText(args[0]))!.AsObject();
string S(string key) => config[key]!.GetValue<string>();
int N(string key) => config[key]!.GetValue<int>();
string root = Path.GetFullPath(S("web_root")), storage = Path.GetFullPath(S("storage"));
var principals = config["principals"]!.AsArray().Select(p => p!.AsObject()).ToArray();
var builder = WebApplication.CreateSlimBuilder();
builder.Logging.ClearProviders(); builder.Logging.AddSimpleConsole(o => o.SingleLine = true);
builder.WebHost.ConfigureKestrel(options => {
    options.Limits.MaxRequestBodySize = 0;
    options.Listen(IPAddress.Loopback, N("http_port"));
    // Windows Schannel needs the normal key-provider-backed import. Loading an
    // ephemeral key here can bind the port but fail every TLS handshake.
    options.Listen(IPAddress.Loopback, N("https_port"), listener => listener.UseHttps(S("certificate")));
});
var app = builder.Build();
var throttle = new TransferClock(config["test_mbps"]?.GetValue<double>() ?? 0);
app.Use(async (context, next) => {
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    context.Response.Headers["Cross-Origin-Opener-Policy"] = "same-origin";
    context.Response.Headers["Cross-Origin-Embedder-Policy"] = "require-corp";
    context.Response.Headers["Referrer-Policy"] = "no-referrer";
    context.Response.Headers["Cache-Control"] = "no-store";
    try { await next(context); }
    catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested) { }
    catch (WebSocketException) { if (!context.Response.HasStarted) context.Response.StatusCode = 502; }
    catch (IOException) { if (!context.Response.HasStarted) context.Response.StatusCode = 503; }
});
app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(20) });
app.MapGet("/health", () => Results.Json(new { ok = true, role = "region-gateway", protocol = "0.3" }));
app.Map("/ws", async context => {
    string origin = context.Request.Headers.Origin.ToString();
    // Native clients have no Origin. Browsers must come from this exact gateway.
    if (!context.WebSockets.IsWebSocketRequest || (origin.Length != 0 && origin != $"{context.Request.Scheme}://{context.Request.Host}")) { context.Response.StatusCode = 403; return; }
    using var upstream = new ClientWebSocket();
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted); timeout.CancelAfter(TimeSpan.FromHours(8));
    try { await upstream.ConnectAsync(new Uri($"ws://127.0.0.1:{N("port")}"), timeout.Token); }
    catch (WebSocketException) { context.Response.StatusCode = 503; return; }
    using var downstream = await context.WebSockets.AcceptWebSocketAsync();
    var first = Pump(downstream, upstream, timeout.Token);
    var second = Pump(upstream, downstream, timeout.Token);
    await Task.WhenAny(first, second); timeout.Cancel();
    downstream.Abort(); upstream.Abort();
    try { await Task.WhenAll(first, second); } catch (OperationCanceledException) { } catch (WebSocketException) { }
});
app.MapGet("/assets/{name}", async (HttpContext context, string name) => {
    if (!Regex.IsMatch(name, "^[a-f0-9]{64}\\.glb$")) { context.Response.StatusCode = 404; return; }
    string authorization = context.Request.Headers.Authorization.ToString();
    JsonObject? principal = null;
    if (authorization.StartsWith("Bearer ", StringComparison.Ordinal))
    {
        byte[] supplied = SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(authorization[7..]));
        principal = principals.FirstOrDefault(p => CryptographicOperations.FixedTimeEquals(supplied, SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(p["token"]!.GetValue<string>()))) && p["expires_at_ms"]!.GetValue<long>() > DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    }
    if (principal is null) { context.Response.StatusCode = 401; return; }
    string catalogFile = Path.Combine(storage, "asset-catalog.json");
    if (!File.Exists(catalogFile)) { context.Response.StatusCode = 503; return; }
    var catalog = JsonNode.Parse(await File.ReadAllTextAsync(catalogFile, context.RequestAborted))!.AsObject();
    string hash = name[..64];
    if (catalog[hash] is not JsonObject entry || !entry["principals"]!.AsArray().Any(n => n!.GetValue<string>() == principal["id"]!.GetValue<string>())) { context.Response.StatusCode = 404; return; }
    string file = Path.Combine(storage, "objects", name);
    if (!File.Exists(file) || new FileInfo(file).Length > 2097152) { context.Response.StatusCode = 503; return; }
    byte[] bytes = await File.ReadAllBytesAsync(file, context.RequestAborted);
    if (Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != hash) { context.Response.StatusCode = 503; return; }
    context.Response.ContentType = "model/gltf-binary";
    // The same browser can log in as another principal. Never let its HTTP
    // cache bypass the authorization check for a previously permitted hash.
    context.Response.Headers["Cache-Control"] = "private, no-store";
    context.Response.Headers.ETag = '"' + hash + '"';
    context.Response.ContentLength = bytes.Length;
    await throttle.Wait(bytes.Length, context.RequestAborted);
    await context.Response.Body.WriteAsync(bytes, context.RequestAborted);
});
app.MapGet("/{**name}", async (HttpContext context, string? name) => {
    name = string.IsNullOrEmpty(name) ? "index.html" : name;
    // Only generated flat export files are public. Configurations and storage are
    // outside this directory and cannot be reached through path normalization.
    if (!Regex.IsMatch(name, "^[a-zA-Z0-9_.-]+$") || name.Contains("..")) { context.Response.StatusCode = 404; return; }
    string extension = Path.GetExtension(name).ToLowerInvariant();
    var types = new Dictionary<string, string> { [".html"]="text/html; charset=utf-8", [".js"]="application/javascript", [".wasm"]="application/wasm", [".pck"]="application/octet-stream", [".png"]="image/png", [".svg"]="image/svg+xml", [".ico"]="image/x-icon" };
    if (!types.TryGetValue(extension, out var type)) { context.Response.StatusCode = 404; return; }
    string file = Path.Combine(root, name);
    if (!File.Exists(file)) { context.Response.StatusCode = 404; return; }
    context.Response.ContentType = type;
    string encoding = context.Request.Headers.AcceptEncoding.ToString();
    if (encoding.Split(',').Any(x => x.Trim().StartsWith("br", StringComparison.Ordinal)) && File.Exists(file + ".br")) { file += ".br"; context.Response.Headers.ContentEncoding = "br"; }
    else if (encoding.Contains("gzip", StringComparison.Ordinal) && File.Exists(file + ".gz")) { file += ".gz"; context.Response.Headers.ContentEncoding = "gzip"; }
    context.Response.Headers.Vary = "Accept-Encoding";
    context.Response.Headers["Cache-Control"] = extension == ".html" ? "no-store" : "private, max-age=0, must-revalidate";
    string etag = '"' + Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(file, context.RequestAborted))) + '"';
    context.Response.Headers.ETag = etag;
    if (context.Request.Headers.IfNoneMatch == etag) { context.Response.StatusCode = 304; return; }
    await using var stream = File.OpenRead(file);
    context.Response.ContentLength = stream.Length;
    var buffer = new byte[262144]; int count;
    while ((count = await stream.ReadAsync(buffer, context.RequestAborted)) > 0)
    {
        await throttle.Wait(count, context.RequestAborted);
        await context.Response.Body.WriteAsync(buffer.AsMemory(0, count), context.RequestAborted);
    }
});
await app.RunAsync();

static async Task Pump(WebSocket source, WebSocket target, CancellationToken cancel)
{
    byte[] buffer = new byte[32768]; int size = 0;
    while (source.State == WebSocketState.Open && target.State == WebSocketState.Open)
    {
        var received = await source.ReceiveAsync(buffer.AsMemory(), cancel);
        if (received.MessageType == WebSocketMessageType.Close)
        {
            // Forward the authority's close status (for example SESSION_REVOKED)
            // so clients learn why the session ended instead of seeing an abort.
            if (target.State == WebSocketState.Open)
            {
                try
                {
                    using var grace = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                    await target.CloseAsync(source.CloseStatus ?? WebSocketCloseStatus.NormalClosure, source.CloseStatusDescription, grace.Token);
                }
                catch (WebSocketException) { } catch (OperationCanceledException) { }
            }
            return;
        }
        size += received.Count;
        if (size > 3 * 1024 * 1024 || received.MessageType != WebSocketMessageType.Text) { source.Abort(); return; }
        await target.SendAsync(buffer.AsMemory(0, received.Count), received.MessageType, received.EndOfMessage, cancel);
        if (received.EndOfMessage) size = 0;
    }
}

// Test-only aggregate egress pacing shared by all static requests. Empty initial
// bucket: a cold load cannot obtain an unmetered burst. 0 disables this locally.
sealed class TransferClock(double mbps)
{
    private readonly object gate = new();
    private double next;
    public async Task Wait(int bytes, CancellationToken cancel)
    {
        if (mbps <= 0) return;
        double now = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency, due;
        lock (gate) { next = Math.Max(now, next) + bytes * 8.0 / (mbps * 1000000.0); due = next; }
        double delay = due - Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
        if (delay > 0) await Task.Delay(TimeSpan.FromSeconds(delay), cancel);
    }
}
