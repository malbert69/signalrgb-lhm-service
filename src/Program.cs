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
    public const int Protocol = 2;
    public const string Request = "srgb-lhm/2";
    public const int StaleMs = 10000;
    public const int MaxPacketBytes = 60000;
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
internal record BoardIdentity(string Manufacturer, string Model, string Version);
internal record ProbeResult(bool Administrator, bool DriverInstalled, string? DriverVersion, BoardIdentity Board, NativeReading[] Sensors);
internal record Query(int Protocol, string Request, string Nonce);
internal record Reading(string Id, string Hardware, string Name, double Celsius);
internal record Packet(int Protocol, string Status, long SourceTimeMs, string Detail, BoardIdentity? Board, Reading[] Sensors, string? Nonce = null);

internal sealed class NativeSource : IDisposable
{
    private readonly Computer _computer;
    public BoardIdentity Board { get; }
    public NativeSource()
    {
        // Fresh in-memory settings keep LHM's fan ControlMode undefined.
        // This service never calls a sensor's Control property or any SetSoftware method.
        _computer = new Computer() { IsMotherboardEnabled = true };
        _computer.Open();
        var board = _computer.SMBios?.Board;
        // Publish only the fields needed for board matching; never serial numbers.
        Board = new BoardIdentity(board?.ManufacturerName?.Trim() ?? "", board?.ProductName?.Trim() ?? "", board?.Version?.Trim() ?? "");
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
    public static Packet Build(IEnumerable<NativeReading> values, BoardIdentity board, long now)
    {
        var result = new List<Reading>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var value in values)
        {
            if (string.IsNullOrWhiteSpace(value.Identifier) || value.Celsius is not double temperature ||
                !double.IsFinite(temperature) || temperature < -20 || temperature > 150) continue;
            if (!seen.Add(value.Identifier)) throw new InvalidDataException("Duplicate native sensor identity.");
            if (result.Count == 128) throw new InvalidDataException("Native temperature inventory exceeds 128 sensors.");
            result.Add(new Reading(value.Identifier, value.Hardware, value.Name, Math.Round(temperature, 3)));
        }
        return new Packet(Program.Protocol, result.Count > 0 ? "ok" : "unavailable", now,
            $"{result.Count} native motherboard temperatures available", board, result.ToArray());
    }

    public static byte[] Reply(Packet packet, string nonce, long now)
    {
        if (now - packet.SourceTimeMs > Program.StaleMs || packet.SourceTimeMs > now + 2000)
            packet = packet with { Status = "unavailable", Detail = "Native sensor samples are stale", Sensors = [] };
        byte[] data = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(packet with { Nonce = nonce }, Program.Json));
        if (data.Length <= Program.MaxPacketBytes) return data;
        return Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new Packet(Program.Protocol, "unavailable", packet.SourceTimeMs,
            "Native sensor inventory exceeds the UDP packet limit", null, [], nonce), Program.Json));
    }
}

internal static class ServiceCore
{
    private static Packet _latest = new(Program.Protocol, "unavailable", 0, "Native sensor reader starting", null, []);
    public static async Task RunAsync(CancellationToken cancellation)
    {
        // A stalled hardware read cannot keep old data fresh: UDP runs separately and
        // returns the original sample timestamp, which the plugin must validate.
        Task reader = Task.Run(() => Poll(cancellation), cancellation);
        using var udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, Program.Port));
        Program.Log($"Listening only on 127.0.0.1:{Program.Port}; protocol={Program.Protocol}; native driver={PawnIo.Version}");
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                UdpReceiveResult request = await udp.ReceiveAsync(cancellation);
                if (!IPAddress.IsLoopback(request.RemoteEndPoint.Address) || request.Buffer.Length > 512) continue;
                Query? query;
                try { query = JsonSerializer.Deserialize<Query>(request.Buffer, Program.Json); }
                catch (JsonException) { continue; }
                if (query?.Protocol != Program.Protocol || query.Request != Program.Request || string.IsNullOrEmpty(query.Nonce) || query.Nonce.Length > 96) continue;
                Packet packet = Volatile.Read(ref _latest);
                byte[] data = PacketBuilder.Reply(packet, query.Nonce, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                await udp.SendAsync(data, request.RemoteEndPoint, cancellation);
            }
        }
        finally
        {
            // Shutdown is bounded even if a third-party hardware call is blocked.
            await Task.WhenAny(reader, Task.Delay(5000, CancellationToken.None));
        }
    }
    private static void Poll(CancellationToken cancellation)
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                using var source = new NativeSource();
                Program.Log("Native motherboard backend opened: " + source.Board);
                string previous = "";
                while (!cancellation.IsCancellationRequested)
                {
                    var values = source.Read();
                    Packet packet = PacketBuilder.Build(values, source.Board, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                    Volatile.Write(ref _latest, packet);
                    string state = packet.Status + ": " + packet.Detail;
                    if (state != previous) { Program.Log(state); previous = state; }
                    if (cancellation.WaitHandle.WaitOne(1000)) break;
                }
            }
            catch (Exception error)
            {
                Program.Log("Native reader failed: " + error.Message);
                Volatile.Write(ref _latest, new Packet(Program.Protocol, "unavailable", 0, "Native hardware reader failed; retrying", null, []));
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
        var board = new BoardIdentity("Test manufacturer", "Test board", "1.0");
        var readings = new[] { new NativeReading("/lpc/test/temperature/0", "test", "Temperature #1", 31),
            new NativeReading("/another-chip/temperature/0", "another chip", "Raw channel", 50) };
        void Assert(bool result, string name) { if (!result) throw new Exception("FAILED: " + name); Console.WriteLine("PASS: " + name); }
        var packet = PacketBuilder.Build(readings.Reverse(), board, 1234);
        Assert(packet.Sensors.Length == 2 && packet.Sensors.Single(s => s.Id == readings[0].Identifier).Celsius == 31, "all native identifiers survive enumeration order changes without board mappings");
        Assert(packet.Sensors[1].Name == readings[0].Name && packet.Sensors[1].Hardware == "test", "raw names and hardware are preserved without aliases");
        Assert(packet.Board == board && packet.Protocol == 2, "structured board identity accompanies protocol 2 samples");
        Assert(PacketBuilder.Build(readings, board with { Manufacturer = "Other", Model = "Other board" }, 1234).Sensors.Length == 2, "other motherboards need no service configuration");
        Assert(PacketBuilder.Build([readings[0] with { Celsius = null }], board, 1234).Status == "unavailable", "missing reading is unavailable, not zero");
        Assert(PacketBuilder.Build([readings[0] with { Celsius = double.NaN }], board, 1234).Sensors.Length == 0, "NaN is rejected");
        Assert(PacketBuilder.Build([readings[0] with { Celsius = double.PositiveInfinity }], board, 1234).Sensors.Length == 0, "infinity is rejected");
        Assert(PacketBuilder.Build([readings[0] with { Celsius = 500 }], board, 1234).Sensors.Length == 0, "impossible temperature is rejected");
        Assert(PacketBuilder.Build([readings[0] with { Celsius = 0 }], board, 1234).Sensors.Length == 1, "a valid zero-degree reading remains valid");
        Assert(packet.SourceTimeMs == 1234, "source timestamp is preserved");
        var reply = JsonSerializer.Deserialize<Packet>(PacketBuilder.Reply(packet, "test-nonce", 1234), Program.Json)!;
        Assert(reply.Nonce == "test-nonce" && reply.Board == board && reply.Sensors.Length == 2, "wire reply preserves identity, readings, and request nonce");
        var stale = JsonSerializer.Deserialize<Packet>(PacketBuilder.Reply(packet, "stale", 1234 + Program.StaleMs + 1), Program.Json)!;
        Assert(stale.Status == "unavailable" && stale.Sensors.Length == 0 && stale.SourceTimeMs == 1234, "UDP replies do not refresh stale samples");
        var large = packet with { Sensors = [new Reading("large", "test", new string('x', Program.MaxPacketBytes), 30)] };
        var bounded = PacketBuilder.Reply(large, "large", 1234);
        Assert(bounded.Length <= Program.MaxPacketBytes && JsonSerializer.Deserialize<Packet>(bounded, Program.Json)!.Status == "unavailable", "oversized inventories fail closed within UDP limits");
        try { PacketBuilder.Build([readings[0], readings[0]], board, 1234); Assert(false, "duplicate identity"); }
        catch (InvalidDataException) { Console.WriteLine("PASS: duplicate identity is rejected"); }
        Console.WriteLine("All service logic tests passed.");
        return 0;
    }
}
