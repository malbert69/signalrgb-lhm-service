# SignalRGB LibreHardwareMonitor sensor service

Local Windows service and SignalRGB plugin for the ASUS PRIME Z790-P WIFI.
No HWiNFO, Fan Control, LibreHardwareMonitor GUI, cloud service, or paid sensor API is needed at runtime.

## What it does

`SignalRgbSensorBridge` runs as a Windows service, reads motherboard temperatures directly through LibreHardwareMonitorLib 0.9.6 and the existing PawnIO driver, and answers requests on **127.0.0.1 UDP port 43871**. The plugin registers native SignalRGB temperature sources for fan curves and Monitoring.

The initial board-specific configuration exports:

| SignalRGB name | Native LHM identifier | Chip source |
|---|---|---|
| Motherboard | `/lpc/nct6798d/0/temperature/2` | SYSTIN |
| VRM Thermistor | `/lpc/nct6798d/0/temperature/3` | AUXTIN0 |

LibreHardwareMonitor's generic labels for these are Temperature #2 and Temperature #3. The board-specific aliases were checked against the chip source table and reference readings. Unidentified channels are deliberately excluded. The chipset/PCH and OnSemi regulator temperatures seen in other software are not exposed by this library configuration.

The service **does not set fan speeds** or change curves. Choose a temperature source in SignalRGB only after checking its live reading.

## Requirements and installation

- Windows x64, .NET 10 runtime, and SignalRGB with Monitoring/Cooling enabled.
- PawnIO 2.2 was already installed on the target PC. The installer does not install or alter that shared driver.
- Administrator rights are required to install/start the service and for direct motherboard I/O. The plugin runs in SignalRGB normally.

Run `.\Install.cmd` and approve the Windows administrator prompt. The launcher uses a process-only execution-policy override, so it also works when PowerShell blocks scripts by default. It does not change the saved user or machine execution policy. Alternatively, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Service.ps1 -Elevate`.

The installer copies the compiled `bin` directory and `sensors.json` to `C:\Program Files\SignalRGB Sensor Bridge`, installs a delayed automatic Windows service with restart recovery, and copies `ASUS_LHM_Temperatures.js` to the current Windows Documents folder under `WhirlwindFX\Plugins`. An explicit `-PluginDirectory` overrides that location. From a source-only checkout, run `Build.ps1` first to create `bin`.

Restart SignalRGB after installation if the virtual provider does not appear automatically. Look for **ASUS PRIME Z790-P WIFI Temperatures**, then **Motherboard** and **VRM Thermistor** in the temperature dropdown.

Paths:

- Service name: `SignalRgbSensorBridge`
- Configuration: `C:\Program Files\SignalRGB Sensor Bridge\sensors.json`
- Bounded diagnostic log: `C:\ProgramData\SignalRgbSensorBridge\service.log`
- Plugin: redirected Windows Documents folder, `WhirlwindFX\Plugins\ASUS_LHM_Temperatures.js`

No scheduled task or extra tray application is required.

## Failure behavior

The hardware worker timestamps each successful native poll. The UDP responder does not refresh timestamps when answering requests. Old samples stop being published after ten seconds; SignalRGB then applies its native unavailable-sensor behavior. Missing/null, nonfinite, out-of-range, or unconfigured readings are not substituted with zero. The service reopens a failed native reader after fifteen seconds.

The plugin checks matching request/reply nonces, configured sensor IDs, and timestamp freshness. A failed service or suspended hardware reader cannot continually refresh cached temperatures. Existing SignalRGB fan control remains the only fan-speed writer.

## Validation commands

- `bin\SignalRgbSensorService.exe --self-test` — service data-validation tests.
- `bin\SignalRgbSensorService.exe --probe` — native motherboard sensor inventory; run as administrator.
- `bin\SignalRgbSensorService.exe --console` — interactive service mode using `sensors.json` beside the executable.
- `node test-plugin.cjs` — plugin data-validation and stale-source tests.

Rebuild and run the hardware-independent tests with `.\Build.ps1` (.NET 10 SDK and Node.js required for development). The script restores the locked NuGet dependencies, builds the service, and runs the service and plugin tests. Neither Node.js nor the SDK is needed by the installed service; it uses the .NET 10 runtime. Native live tests require administrator access to the actual motherboard.

## Removal

Run `Uninstall-Service.ps1` as administrator to stop and unregister the service. Add `-RemovePlugin` to remove this plugin file. It retains program files, logs, configuration, and PawnIO for review or reuse. Restart SignalRGB afterward.

## Source and third-party notices

Service and plugin source are included. LibreHardwareMonitorLib 0.9.6 is used unmodified under MPL-2.0: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/tree/v0.9.6 and https://www.mozilla.org/MPL/2.0/ . Its NuGet dependency identities and hashes are in `src/packages.lock.json`; the build's `.deps.json` records runtime dependencies. Microsoft service libraries and the other dependencies retain their respective upstream licenses. No driver binary is redistributed here.

SignalRGB API reference: https://docs.signalrgb.com/developer/plugins/fan-control/
