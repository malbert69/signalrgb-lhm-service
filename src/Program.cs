using System.Net;
using System.Net.Sockets;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.Json;
using LibreHardwareMonitor.Hardware;
using LibreHardwareMonitor.PawnIo;

internal static class Program
{
    public const string ServiceName = "SignalRgbSensorBridge";
    public const int Port = 43871;
    public const string Request = "srgb-lhm/1";
    public const int StaleMs = 10000;
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
    public static readonly string DataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), ServiceName);

    public static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Contains("--self-test")) return SelfTest.Run();
            if (args.Contains("--probe"))
            {
                var result = Probe();
                string json = JsonSerializer.Serialize(result, new JsonSerializerOptions(Json) { WriteIndented = true });
                int output = Array.IndexOf(args, "--output");
                if (output >= 0 && output + 1 < args.Length) File.WriteAllText(args[output + 1], json);
                Console.WriteLine(json);
                return result.Sensors.Length > 0 ? 0 : 2;
            }
            if (args.Contains("--console") || args.Contains("--test-server"))
            {
                using var cancellation = new CancellationTokenSource();
                if (args.Contains("--test-server")) cancellation.CancelAfter(TimeSpan.FromSeconds(12));
                Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };
                await ServiceCore.RunAsync(cancellation.Token);
                return 0;
            }
            if (Environment.UserInteractive)
            {
                Console.WriteLine("Use --probe to inspect native sensors, --console to run interactively, or install as a Windows service.");
                return 0;
            }
            ServiceBase.Run(new SensorWindowsService());
            return 0;
        }
        catch (OperationCanceledException) { return 0; }
        catch (Exception error) { Console.Error.WriteLine(error); Log(error.ToString()); return 1; }
    }

    public static bool IsAdmin => new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
    private static ProbeResult Probe()
    {
        using var source = new NativeSource();
        for (int i = 0; i < 3; i++) { source.Read(); Thread.Sleep(500); }
        return new ProbeResult(IsAdmin, PawnIo.IsInstalled, PawnIo.Version?.ToString(), source.Board,
            source.Read().ToArray());
    }
    public static void Log(string message)
    {
        Console.WriteLine($"{DateTimeOffset.Now:O} {message}");
        if (Environment.UserInteractive) return;
        try
        {
            Directory.CreateDirectory(DataDirectory);
            string path = Path.Combine(DataDirectory, "service.log");
            if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024) File.Move(path, path + ".previous", true);
            File.AppendAllText(path, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}

internal record NativeReading(string Identifier, string Hardware, string Name, double? Celsius);
internal record ProbeResult(bool Administrator, bool DriverInstalled, string? DriverVersion, string Board, NativeReading[] Sensors);
internal record Mapping(string Identifier, string Name);
internal record BridgeConfig(string ExpectedBoard, Mapping[] Sensors);
internal record Query(int Protocol, string Request, string Nonce);
internal record Reading(string Id, string Name, double Celsius);
internal record Packet(int Protocol, string Status, long SourceTimeMs, string Detail, Reading[] Sensors, string? Nonce = null);

internal sealed class NativeSource : IDisposable
{
    private readonly Computer _computer;
    public string Board { get; }
    public NativeSource()
    {
        // Fresh in-memory settings keep LHM's fan ControlMode undefined.
        // This service never calls a sensor's Control property or any SetSoftware method.
        _computer = new Computer() { IsMotherboardEnabled = true };
        _computer.Open();
        Board = string.Join("; ", _computer.Hardware.Select(h => h.Name));
    }
    public List<NativeReading> Read()
    {
        var result = new List<NativeReading>();
        foreach (var hardware in _computer.Hardware) ReadHardware(hardware, result);
        return result;
    }
    private static void ReadHardware(IHardware hardware, List<NativeReading> readings)
    {
        hardware.Update();
        foreach (var sensor in hardware.Sensors)
        {
            if (sensor.SensorType != SensorType.Temperature) continue;
            readings.Add(new NativeReading(sensor.Identifier.ToString(), hardware.Name, sensor.Name, sensor.Value));
        }
        foreach (var child in hardware.SubHardware) ReadHardware(child, readings);
    }
    public void Dispose() => _computer.Close();
}

internal static class PacketBuilder
{
    public static Packet Build(IEnumerable<NativeReading> values, Mapping[] mappings, long now)
    {
        var allowed = mappings.ToDictionary(m => m.Identifier, StringComparer.Ordinal);
        var result = new List<Reading>();
        var seen = new HashSet<string>();
        foreach (var value in values)
        {
            if (!allowed.TryGetValue(value.Identifier, out var mapping) || value.Celsius is not double temperature ||
                !double.IsFinite(temperature) || temperature < -20 || temperature > 150) continue;
            if (!seen.Add(value.Identifier)) throw new InvalidDataException("Duplicate native sensor identity.");
            result.Add(new Reading(value.Identifier, mapping.Name, Math.Round(temperature, 3)));
        }
        return new Packet(1, result.Count > 0 ? "ok" : "unavailable", now,
            $"{result.Count}/{mappings.Length} configured native sensors available", result.ToArray());
    }
    public static BridgeConfig LoadConfig()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "sensors.json");
        var config = JsonSerializer.Deserialize<BridgeConfig>(File.ReadAllText(path), Program.Json)
            ?? throw new InvalidDataException("Missing sensor configuration.");
        var mappings = config.Sensors ?? [];
        if (string.IsNullOrWhiteSpace(config.ExpectedBoard)) throw new InvalidDataException("Configure the expected motherboard model.");
        if (mappings.Length is 0 or > 32 || mappings.Any(m => string.IsNullOrWhiteSpace(m.Identifier) || string.IsNullOrWhiteSpace(m.Name) || m.Name.Length > 120) ||
            mappings.Select(m => m.Identifier).Distinct().Count() != mappings.Length || mappings.Select(m => m.Name).Distinct().Count() != mappings.Length)
            throw new InvalidDataException("sensors.json must contain 1–32 unique, verified native identifiers and display names.");
        return config;
    }
}

internal static class ServiceCore
{
    private static Packet _latest = new(1, "unavailable", 0, "Native sensor reader starting", []);
    public static async Task RunAsync(CancellationToken cancellation)
    {
        BridgeConfig config = PacketBuilder.LoadConfig();
        Mapping[] mappings = config.Sensors;
        // A stalled hardware read cannot keep old data fresh: UDP runs separately and
        // returns the original sample timestamp, which the plugin must validate.
        Task reader = Task.Run(() => Poll(config, cancellation), cancellation);
        using var udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, Program.Port));
        Program.Log($"Listening only on 127.0.0.1:{Program.Port}; native driver={PawnIo.Version}; configured sensors={mappings.Length}");
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                UdpReceiveResult request = await udp.ReceiveAsync(cancellation);
                if (!IPAddress.IsLoopback(request.RemoteEndPoint.Address) || request.Buffer.Length > 512) continue;
                Query? query;
                try { query = JsonSerializer.Deserialize<Query>(request.Buffer, Program.Json); }
                catch (JsonException) { continue; }
                if (query?.Protocol != 1 || query.Request != Program.Request || string.IsNullOrEmpty(query.Nonce) || query.Nonce.Length > 96) continue;
                Packet packet = Volatile.Read(ref _latest);
                if (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - packet.SourceTimeMs > Program.StaleMs)
                    packet = new Packet(1, "unavailable", packet.SourceTimeMs, "Native sensor samples are stale", []);
                byte[] data = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(packet with { Nonce = query.Nonce }, Program.Json));
                await udp.SendAsync(data, request.RemoteEndPoint, cancellation);
            }
        }
        finally
        {
            // Shutdown is bounded even if a third-party hardware call is blocked.
            await Task.WhenAny(reader, Task.Delay(5000, CancellationToken.None));
        }
    }
    private static void Poll(BridgeConfig config, CancellationToken cancellation)
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                using var source = new NativeSource();
                if (!source.Board.Contains(config.ExpectedBoard, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The detected motherboard does not match sensors.json.");
                Program.Log("Native motherboard backend opened: " + source.Board);
                string previous = "";
                while (!cancellation.IsCancellationRequested)
                {
                    var values = source.Read();
                    Packet packet = PacketBuilder.Build(values, config.Sensors, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                    Volatile.Write(ref _latest, packet);
                    string state = packet.Status + ": " + packet.Detail;
                    if (state != previous) { Program.Log(state); previous = state; }
                    if (cancellation.WaitHandle.WaitOne(1000)) break;
                }
            }
            catch (Exception error)
            {
                Program.Log("Native reader failed: " + error.Message);
                Volatile.Write(ref _latest, new Packet(1, "unavailable", 0, "Native hardware reader failed; retrying", []));
                if (cancellation.WaitHandle.WaitOne(15000)) return;
            }
        }
    }
}

internal sealed class SensorWindowsService : ServiceBase
{
    private CancellationTokenSource? _cancellation;
    private Task? _worker;
    public SensorWindowsService() { ServiceName = Program.ServiceName; CanStop = true; AutoLog = true; }
    protected override void OnStart(string[] args)
    {
        _cancellation = new CancellationTokenSource();
        _worker = Task.Run(async () =>
        {
            try { await ServiceCore.RunAsync(_cancellation.Token); }
            catch (OperationCanceledException) { }
            catch (Exception error) { Program.Log(error.ToString()); ExitCode = 1; _ = Task.Run(() => Stop()); }
        });
    }
    protected override void OnStop()
    {
        _cancellation?.Cancel();
        // Don't wait on ourselves if a fatal worker failure invoked Stop().
        if (_worker is not null && Task.CurrentId != _worker.Id) _worker.Wait(TimeSpan.FromSeconds(8));
        Program.Log("Service stopped");
    }
}

internal static class SelfTest
{
    public static int Run()
    {
        var mappings = new[] { new Mapping("/lpc/test/temperature/0", "Motherboard") };
        var readings = new[] { new NativeReading(mappings[0].Identifier, "test", "raw", 31),
            new NativeReading("/unconfigured", "test", "other", 50) };
        void Assert(bool result, string name) { if (!result) throw new Exception("FAILED: " + name); Console.WriteLine("PASS: " + name); }
        var packet = PacketBuilder.Build(readings.Reverse(), mappings, 1234);
        Assert(packet.Sensors.Length == 1 && packet.Sensors[0].Name == "Motherboard" && packet.Sensors[0].Celsius == 31, "stable identifiers survive enumeration order changes");
        Assert(PacketBuilder.Build([readings[0] with { Celsius = null }], mappings, 1234).Status == "unavailable", "missing reading is unavailable, not zero");
        Assert(PacketBuilder.Build([readings[0] with { Celsius = double.NaN }], mappings, 1234).Sensors.Length == 0, "NaN is rejected");
        Assert(PacketBuilder.Build([readings[0] with { Celsius = 500 }], mappings, 1234).Sensors.Length == 0, "impossible temperature is rejected");
        Assert(PacketBuilder.Build([readings[0] with { Celsius = 0 }], mappings, 1234).Sensors.Length == 1, "a valid configured zero-degree reading remains valid");
        Assert(packet.SourceTimeMs == 1234, "source timestamp is preserved");
        try { PacketBuilder.Build([readings[0], readings[0]], mappings, 1234); Assert(false, "duplicate identity"); }
        catch (InvalidDataException) { Console.WriteLine("PASS: duplicate identity is rejected"); }
        Console.WriteLine("All service logic tests passed.");
        return 0;
    }
}
