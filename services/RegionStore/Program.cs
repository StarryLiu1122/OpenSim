using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;
using RegionLab.Storage;

if (args.Length != 2) { Console.Error.WriteLine("Usage: RegionStore request.json new-response.json"); return 2; }
string input = Path.GetFullPath(args[0]), output = Path.GetFullPath(args[1]);
if (input == output || File.Exists(output)) { Console.Error.WriteLine("Response must be a new file, distinct from the request."); return 2; }
object reply;
int code = 0;
try
{
    var bytes = Store.ReadBounded(input);
    Store.NoDuplicateKeys(bytes);
    var request = JsonNode.Parse(bytes)!.AsObject();
    using var store = new Store(request);
    reply = store.Execute(request);
}
catch (Exception e)
{
    code = 1;
    string error = e is StoreError ? e.Message : e is SqliteException s && s.SqliteErrorCode is 5 or 6 ? "DATABASE_BUSY" : e is SqliteException ? "DATABASE_ERROR" : e is IOException or UnauthorizedAccessException ? "STORAGE_UNAVAILABLE" : "INVALID_REQUEST";
    reply = new { ok = false, error, detail = e is StoreError ? e.Message : e.GetType().Name };
}
Directory.CreateDirectory(Path.GetDirectoryName(output)!);
using (var file = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None))
{ file.Write(JsonSerializer.SerializeToUtf8Bytes(reply, new JsonSerializerOptions { WriteIndented = true })); file.Flush(true); }
Console.WriteLine(JsonSerializer.Serialize(new { ok = code == 0, response = output }));
return code;
