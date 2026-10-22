// Compares the findings of two InspectCode SARIF files.
// Usage: dotnet run repro/CompareSarif.cs -- <cached.sarif> <cold.sarif>
// Prints findings only in the first file (+) and only in the second file (-). Exit code 1 if they differ.
using System.Text.Json;

if (args.Length != 2)
{
    Console.Error.WriteLine("usage: CompareSarif <cached.sarif> <cold.sarif>");
    return 2;
}

var cached = Load(args[0]);
var cold = Load(args[1]);
var extra = Subtract(cached, cold);
var missing = Subtract(cold, cached);

foreach (var finding in extra)
{
    Console.WriteLine($"    + {finding}");
}

foreach (var finding in missing)
{
    Console.WriteLine($"    - {finding}");
}

Console.WriteLine($"    {cached.Count} findings with the cache, {cold.Count} without; {extra.Count} extra, {missing.Count} missing");
return extra.Count + missing.Count == 0 ? 0 : 1;

static List<string> Load(string path)
{
    using var document = JsonDocument.Parse(File.ReadAllText(path));
    var findings = new List<string>();
    foreach (var run in document.RootElement.GetProperty("runs").EnumerateArray())
    {
        if (!run.TryGetProperty("results", out var results))
        {
            continue;
        }

        foreach (var result in results.EnumerateArray())
        {
            if (result.TryGetProperty("suppressions", out var suppressions) && suppressions.GetArrayLength() > 0)
            {
                continue;
            }

            var location = result.GetProperty("locations")[0].GetProperty("physicalLocation");
            var uri = location.GetProperty("artifactLocation").GetProperty("uri").GetString();
            var line = location.TryGetProperty("region", out var region) && region.TryGetProperty("startLine", out var start)
                ? start.GetInt32()
                : 0;
            var level = result.TryGetProperty("level", out var l) ? l.GetString() : "warning";
            var rule = result.GetProperty("ruleId").GetString();
            var message = result.GetProperty("message").GetProperty("text").GetString();
            findings.Add($"{level} {rule} {uri}:{line} {message}");
        }
    }

    findings.Sort(StringComparer.Ordinal);
    return findings;
}

static List<string> Subtract(List<string> from, List<string> remove)
{
    var remaining = new List<string>(from);
    foreach (var finding in remove)
    {
        remaining.Remove(finding);
    }

    return remaining;
}
