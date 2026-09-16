using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;

namespace RegionLab.Fusion;

/// <summary>Bounded child-process transport. No region mutation runs on these tasks.</summary>
internal sealed class BotProcess : IDisposable
{
    private readonly Process process;
    private readonly BlockingCollection<string> controls = new(32);
    internal volatile bool Ready;
    internal volatile bool Failed;
    internal bool Exited => process.HasExited;
    internal int ExitCode => process.HasExited ? process.ExitCode : -1;
    internal BotProcess(string dotnet, string dll, string configuration, string log)
    {
        var start = new ProcessStartInfo(dotnet) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Path.GetDirectoryName(dll) };
        start.ArgumentList.Add(dll); start.ArgumentList.Add("--worker"); start.ArgumentList.Add(configuration);
        process = Process.Start(start) ?? throw new IOException("BOT_START_FAILED");
        var gate = new object();
        long bytes = 0;
        void Log(string line)
        {
            lock (gate)
            {
                if (bytes > 1024 * 1024) return;
                // The worker never emits credentials. Keep bounded diagnostic output local.
                File.AppendAllText(log, line + "\n"); bytes += line.Length;
            }
        }
        _ = Task.Run(async () => {
            try { while (await process.StandardOutput.ReadLineAsync() is { } line) { if (line == "FUSION_BOT_READY") Ready = true; if (line.StartsWith("FUSION_BOT_ERROR")) Failed = true; Log(line); } }
            catch { Failed = true; }
        });
        _ = Task.Run(async () => { try { while (await process.StandardError.ReadLineAsync() is { } line) Log(line); } catch { Failed = true; } });
        _ = Task.Run(async () => {
            try { foreach (var line in controls.GetConsumingEnumerable()) { await process.StandardInput.WriteLineAsync(line); await process.StandardInput.FlushAsync(); } }
            catch { Failed = true; }
        });
    }
    internal void Control(float yaw, bool forward) => Send(new { operation = "control", yaw, forward });
    internal void Logout() => Send(new { operation = "logout" });
    private void Send(object value)
    {
        if (controls.IsAddingCompleted || !controls.TryAdd(JsonSerializer.Serialize(value))) Failed = true;
    }
    public void Dispose()
    {
        controls.CompleteAdding();
        // Only the child owned by this module is terminated. Normal despawn uses logout.
        if (!process.HasExited) process.Kill(true);
    }
}
