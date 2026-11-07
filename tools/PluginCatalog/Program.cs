using System.Collections;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using LibreHardwareMonitor.Hardware;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

// Evaluates only LHM's mapping tables, against a proxy that rejects hardware calls.
// No Computer instance, driver, or hardware reader is opened by this tool.
string root = Path.GetFullPath(args.Length > 0 ? args[0] : ".");
string cache = Path.Combine(root, "tools", "upstream-cache");
string superSource = File.ReadAllText(Path.Combine(cache, "SuperIOHardware.cs"));
string idSource = File.ReadAllText(Path.Combine(cache, "Identification.cs"));
string modelSource = File.ReadAllText(Path.Combine(cache, "Model.cs"));
var sources = new[] { "SuperIOHardware.cs", "Identification.cs", "Model.cs" }.Select(name => new
{
    file = name,
    url = "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/blob/v0.9.6/LibreHardwareMonitorLib/Hardware/Motherboard/" + name,
    sha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.Combine(cache, name)))).ToLowerInvariant()
}).ToArray();
var expectedHashes = new Dictionary<string, string>
{
    ["SuperIOHardware.cs"] = "25efbf2f88c99662e046bd21ffad835297594c42df0f8ab4a4f5644de8b945cd",
    ["Identification.cs"] = "c1dc6999d9d35b3569fd0cdb2c437f778c695112aef73a54df67fe24637fd683",
    ["Model.cs"] = "07873ab54fe613461db995a62124116d1a1c31aa043ed0b81521a03902cafdd8"
};
if (sources.Any(s => s.sha256 != expectedHashes[s.file])) throw new InvalidDataException("Pinned upstream source hashes do not match.");
var library = typeof(Computer).Assembly;
if (library.GetName().Version?.ToString() != "0.9.6.0") throw new InvalidDataException("Use LibreHardwareMonitorLib 0.9.6.0.");
var syntax = CSharpSyntaxTree.ParseText(superSource).GetRoot();
var methods = syntax.DescendantNodes().OfType<MethodDeclarationSyntax>().ToDictionary(m => m.Identifier.Text);
var chipSections = methods["GetBoardSpecificConfiguration"].DescendantNodes().OfType<SwitchSectionSyntax>()
    .Where(s => s.Labels.SelectMany(l => l.DescendantNodes()).OfType<MemberAccessExpressionSyntax>().Any(n => n.Expression.ToString() == "Chip")).ToArray();
string[] Chips(SwitchSectionSyntax section) => section.Labels.SelectMany(l => l.DescendantNodes()).OfType<MemberAccessExpressionSyntax>()
    .Where(n => n.Expression.ToString() == "Chip").Select(n => n.Name.Identifier.Text).Distinct().ToArray();
var aliases = CSharpSyntaxTree.ParseText(idSource).GetRoot().DescendantNodes().OfType<SwitchSectionSyntax>()
    .Select(s => new
    {
        model = s.Statements.OfType<ReturnStatementSyntax>().Select(r => r.Expression).OfType<MemberAccessExpressionSyntax>()
            .FirstOrDefault(m => m.Expression.ToString() == "Model")?.Name.Identifier.Text,
        names = s.Labels.SelectMany(l => l.DescendantNodes()).OfType<InvocationExpressionSyntax>()
            .Where(i => i.Expression is MemberAccessExpressionSyntax m && m.Expression.ToString() == "name" && m.Name.Identifier.Text == "Equals")
            .Select(i => i.ArgumentList.Arguments.FirstOrDefault()?.Expression).OfType<LiteralExpressionSyntax>()
            .Select(l => l.Token.ValueText).ToArray()
    }).Where(a => a.model != null && a.names.Length > 0).GroupBy(a => a.model!)
    .ToDictionary(g => g.Key, g => g.SelectMany(a => a.names).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.Ordinal).ToArray());

var modelVendors = new Dictionary<string, string>();
string vendor = "";
foreach (string line in modelSource.Split('\n'))
{
    var comment = Regex.Match(line, @"^\s*//\s*(ASRock|ASUS|BIOSTAR|DFI|ECS|MSI|EVGA|Gigabyte|Shuttle|Supermicro|Framework)\s*$", RegexOptions.IgnoreCase);
    if (comment.Success) vendor = comment.Groups[1].Value;
    var model = Regex.Match(line, @"^\s*([\w]+),");
    if (model.Success) modelVendors[model.Groups[1].Value] = vendor.Equals("BIOSTAR", StringComparison.OrdinalIgnoreCase) ? "Biostar" : vendor;
}
var manufacturers = new Dictionary<string, string[]>
{
    ["ASUS"] = ["ASUSTeK COMPUTER INC.", "ASUS"],
    ["ASRock"] = ["ASRock"],
    ["Gigabyte"] = ["Gigabyte Technology Co., Ltd.", "Gigabyte Technology Co., Ltd", "Gigabyte"],
    ["MSI"] = ["Micro-Star International Co., Ltd.", "Micro-Star International Co., Ltd", "MSI"],
    ["Biostar"] = ["BIOSTAR Group", "BIOSTAR"],
    ["DFI"] = ["DFI", "DFI Inc.", "DFI Inc"],
    ["ECS"] = ["ECS", "ELITEGROUP"],
    ["EVGA"] = ["EVGA", "EVGA Corp."],
    ["Shuttle"] = ["Shuttle Inc.", "Shuttle"],
    ["Supermicro"] = ["Supermicro", "Super Micro Computer, Inc."]
};
var candidates = new Dictionary<(string Vendor, string Model, string Chip), int>();
foreach (var model in syntax.DescendantNodes().OfType<MemberAccessExpressionSyntax>().Where(m => m.Expression.ToString() == "Model"))
{
    string modelName = model.Name.Identifier.Text;
    var methodSyntax = model.Ancestors().OfType<MethodDeclarationSyntax>().FirstOrDefault();
    if (methodSyntax == null || !aliases.ContainsKey(modelName)) continue;
    string methodName = methodSyntax.Identifier.Text;
    string? manufacturer = model.Ancestors().OfType<SwitchSectionSyntax>()
        .SelectMany(s => s.Labels.SelectMany(l => l.DescendantNodes()).OfType<MemberAccessExpressionSyntax>())
        .FirstOrDefault(m => m.Expression.ToString() == "Manufacturer")?.Name.Identifier.Text;
    manufacturer ??= modelVendors.GetValueOrDefault(modelName);
    if (manufacturer == null || !manufacturers.ContainsKey(manufacturer)) continue;
    // This old ASRock route creates a process-wide hardware mutex; never invoke it.
    if (methodName == "GetIteConfigurationsA" && manufacturer == "ASRock") continue;
    IEnumerable<SwitchSectionSyntax> routes = methodName == "GetBoardSpecificConfiguration"
        ? model.Ancestors().OfType<SwitchSectionSyntax>().Where(s => chipSections.Contains(s)).Take(1)
        : chipSections.Where(s => s.DescendantNodes().OfType<InvocationExpressionSyntax>().Any(i => i.Expression.ToString() == methodName));
    foreach (string chip in routes.SelectMany(Chips))
        candidates.TryAdd((manufacturer, modelName, chip), model.GetLocation().GetLineSpan().StartLinePosition.Line + 1);
}
var sioType = library.GetType("LibreHardwareMonitor.Hardware.Motherboard.Lpc.ISuperIO", true)!;
var chipType = library.GetType("LibreHardwareMonitor.Hardware.Motherboard.Lpc.Chip", true)!;
var proxy = DispatchProxy.Create(sioType, typeof(FakeSuperIO));
var fake = (FakeSuperIO)proxy;
var hardware = library.GetType("LibreHardwareMonitor.Hardware.Motherboard.SuperIOHardware", true)!;
var mapping = hardware.GetMethod("GetBoardSpecificConfiguration", BindingFlags.Static | BindingFlags.NonPublic)!;
var manufacturerType = mapping.GetParameters()[1].ParameterType;
var modelType = mapping.GetParameters()[2].ParameterType;
var identification = library.GetType("LibreHardwareMonitor.Hardware.Motherboard.Identification", true)!;
var getManufacturer = identification.GetMethod("GetManufacturer", BindingFlags.Static | BindingFlags.Public)!;
var getModel = identification.GetMethod("GetModel", BindingFlags.Static | BindingFlags.Public)!;
var entries = new List<CatalogEntry>();
var excluded = new List<object>();
foreach (var board in candidates.GroupBy(c => (c.Key.Vendor, c.Key.Model)).OrderBy(g => g.Key.Vendor, StringComparer.Ordinal).ThenBy(g => g.Key.Model, StringComparer.Ordinal))
{
    var variants = new List<Variant>();
    foreach (var candidate in board.OrderBy(c => c.Key.Chip, StringComparer.Ordinal))
    {
        fake.Chip = Enum.Parse(chipType, candidate.Key.Chip);
        object?[] call = [proxy, Enum.Parse(manufacturerType, board.Key.Vendor), Enum.Parse(modelType, board.Key.Model), 0, null, null, null, null, null, null, null, null, null, null];
        mapping.Invoke(null, call);
        if (call[13] != null) throw new InvalidOperationException("Unexpected hardware mutex path.");
        var sensors = ((IEnumerable)call[5]!).Cast<object>().Select(t => new SensorSpec(
            (int)t.GetType().GetField("Index")!.GetValue(t)!, (string)t.GetType().GetField("Name")!.GetValue(t)!))
            .Where(t => !Regex.IsMatch(t.Name, @"^(Temperature|Auxiliary|AUX|Unknown|SMBus|Virtual|Device|Agent|PECI|Unused|EC_TEMP\w*|T[12])\b", RegexOptions.IgnoreCase))
            .OrderBy(t => t.Index).ToArray();
        if (sensors.Length == 0) continue;
        // Preserve ambiguous upstream labels as distinct channels, never pick a BIOS-dependent CPU sensor silently.
        sensors = sensors.Select(s => s with { DisplayName = sensors.Count(other => other.Name == s.Name) > 1 ? s.Name + " (channel " + s.Index + ")" : s.Name }).ToArray();
        string signature = JsonSerializer.Serialize(sensors);
        var existing = variants.FirstOrDefault(v => JsonSerializer.Serialize(v.Sensors) == signature);
        if (existing != null) existing.Chips.Add(candidate.Key.Chip.ToLowerInvariant());
        else variants.Add(new Variant([candidate.Key.Chip.ToLowerInvariant()], sensors));
    }
    if (variants.Count == 0) { excluded.Add(new { vendor = board.Key.Vendor, model = board.Key.Model, reason = "No named primary Super I/O temperature channels" }); continue; }
    string filename = Regex.Replace(board.Key.Vendor + "_" + board.Key.Model.TrimStart('_'), @"[^a-zA-Z0-9_]", "_") + "_LHM_Temperatures.js";
    string id = "local-lhm-" + Regex.Replace(board.Key.Vendor + "-" + board.Key.Model, @"[^a-zA-Z0-9]+", "-").Trim('-').ToLowerInvariant();
    var exactManufacturers = manufacturers[board.Key.Vendor].Where(m => getManufacturer.Invoke(null, [m])!.ToString() == board.Key.Vendor).ToArray();
    if (exactManufacturers.Length == 0 || aliases[board.Key.Model].Any(m => getModel.Invoke(null, [m])!.ToString() != board.Key.Model))
        throw new InvalidDataException("Upstream identity mismatch: " + board.Key.Model);
    entries.Add(new CatalogEntry(filename, board.Key.Vendor, board.Key.Model, aliases[board.Key.Model], exactManufacturers, id,
        "upstream-derived; hardware untested", board.Min(c => c.Value), variants.ToArray()));
}
Directory.CreateDirectory(Path.Combine(root, "plugins"));
var json = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
File.WriteAllText(Path.Combine(root, "plugins", "catalog.json"), JsonSerializer.Serialize(new { libraryVersion = "0.9.6", sources, entries, excluded }, json) + "\n");
Console.WriteLine($"Extracted {entries.Count} motherboard plugins, {entries.Sum(e => e.Models.Length)} exact model aliases; excluded {excluded.Count} unnamed mappings.");
foreach(var group in entries.GroupBy(e => e.Vendor)) Console.WriteLine($"{group.Key}: {group.Count()}");
Console.WriteLine("Channel labels: " + string.Join(", ", entries.SelectMany(e => e.Variants).SelectMany(v => v.Sensors).Select(s => s.Name).Distinct().Order()));

record SensorSpec(int Index, string Name, string? DisplayName = null);
record Variant(List<string> Chips, SensorSpec[] Sensors);
record CatalogEntry(string Filename, string Vendor, string ModelEnum, string[] Models, string[] Manufacturers, string ControllerId, string Validation, int SourceLine, Variant[] Variants);

public class FakeSuperIO : DispatchProxy
{
    public object? Chip { get; set; }
    protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
    {
        "get_Chip" => Chip,
        "get_Temperatures" => new float?[32],
        "get_Voltages" => new float?[32],
        "get_Fans" => new float?[16],
        "get_Controls" => new float?[16],
        _ => throw new InvalidOperationException("Unexpected hardware operation: " + method.Name)
    };
}
