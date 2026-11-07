# SignalRGB LibreHardwareMonitor sensor service

Generic local Windows temperature service with **252 separate motherboard-specific SignalRGB plugins** across 10 manufacturers. The original ASUS PRIME Z790-P WIFI plugin has native sensor validation; **251 additional plugins are derived from LibreHardwareMonitor 0.9.6's source tables and remain hardware untested**. See the [complete motherboard/plugin list](plugins/README.md).
No HWiNFO, Fan Control, LibreHardwareMonitor GUI, cloud service, or paid sensor API is needed at runtime.

## What it does

`SignalRgbSensorBridge` runs as a Windows service, reads motherboard temperatures directly through LibreHardwareMonitorLib 0.9.6 and the existing PawnIO driver, and answers requests on **127.0.0.1 UDP port 43871**. It publishes raw sensor IDs, hardware names, LHM channel names, and motherboard manufacturer/model/revision from SMBIOS. It has no board profiles or sensor mapping configuration and does not publish serial numbers.

Each JS plugin checks the reported manufacturer and exact model, selects its mapped sensor IDs, and registers native SignalRGB temperature sources for fan curves and Monitoring. Generated plugins also require the raw LHM channel names to match their source tables. Nonmatching plugins do not announce a controller. Discovery retries every five seconds while the service is unavailable and backs off to once a minute after a board mismatch; a matched controller polls once a second.

The included `ASUS_LHM_Temperatures.js` plugin exports:

| SignalRGB name | Native LHM identifier | Chip source |
|---|---|---|
| Motherboard | `/lpc/nct6798d/0/temperature/2` | SYSTIN |
| VRM Thermistor | `/lpc/nct6798d/0/temperature/3` | AUXTIN0 |

LibreHardwareMonitor's generic labels for these are Temperature #2 and Temperature #3. The board-specific aliases were checked against the chip source table and reference readings. Other raw channels may be present in the service response, but this plugin excludes them from SignalRGB. The chipset/PCH and OnSemi regulator temperatures seen in other software are not exposed by this library configuration.

The service **does not set fan speeds** or change curves. Choose a temperature source in SignalRGB only after checking its live reading.

## Requirements and installation

- Windows x64, .NET 10 runtime, and SignalRGB with Monitoring/Cooling enabled.
- PawnIO 2.2 was already installed on the target PC. The installer does not install or alter that shared driver.
- Administrator rights are required to install/start the service and for direct motherboard I/O. The plugin runs in SignalRGB normally.

Run `.\Install.cmd` and approve the Windows administrator prompt. The launcher uses a process-only execution-policy override, so it also works when PowerShell blocks scripts by default. It does not change the saved user or machine execution policy. Alternatively, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Service.ps1 -Elevate`.

The installer reads the motherboard manufacturer and model from Windows SMBIOS through `Win32_BaseBoard`, matches them against `plugins/install-manifest.json`, and installs **only the matching JS plugin** into the current Windows Documents folder under `WhirlwindFX\Plugins`. It copies the compiled `bin` directory to `C:\Program Files\SignalRGB Sensor Bridge` and installs a delayed automatic Windows service with restart recovery. An explicit `-PluginDirectory` overrides the plugin destination. You can also copy the relevant JS plugin manually. From a source-only checkout, run `Build.ps1` first to create `bin`.

Matching is case insensitive and normalizes whitespace, but requires the complete manufacturer and model or a listed exact alias. Unknown or ambiguous boards stop installation before service or plugin changes. The installer also confirms that the running service reports the same motherboard selection before copying plugins.

On upgrades from an all-plugin installation, other packaged motherboard plugins in that destination are renamed to `.js.backup-unused-<timestamp>` files so SignalRGB stops loading them. The selected plugin's previous copy is backed up too. Unrelated user plugins remain in place. Restart SignalRGB afterward to refresh its device and third-party service lists.

Installation requires a fresh protocol 2 response with motherboard identity and at least one valid native temperature, regardless of sensor count. This checks the generic backend and board selection; a usable SignalRGB provider also requires available mapped channels. Source-derived support has not been confirmed on those physical boards; verify readings before using them for fan curves. The identity manifest is used only by the installer. Neither it nor the catalog is needed by the running service or plugins.

**Upgrading from 0.1:** rebuild, rerun the installer to update both the service and plugins, and restart SignalRGB. Protocol 2 intentionally requires board identity; old protocol 1 services/plugins cannot communicate with the new version. The old `sensors.json` is no longer read and may remain on disk without effect. The ASUS controller ID and temperature names are retained.

Restart SignalRGB after installation if the virtual provider does not appear automatically. Look for **ASUS PRIME Z790-P WIFI Temperatures** under **Fan & RGB Controllers**, then **Motherboard** and **VRM Thermistor** in the temperature dropdown. The plugins declare `DeviceType()` as `lightingcontroller` and `SubdeviceController()` as `true` for device-page grouping; temperature reporting remains their only hardware function.

Paths:

- Service name: `SignalRgbSensorBridge`
- Bounded diagnostic log: `C:\ProgramData\SignalRgbSensorBridge\service.log`
- Plugin: redirected Windows Documents folder, `WhirlwindFX\Plugins\ASUS_LHM_Temperatures.js`

No scheduled task or extra tray application is required.

## Failure behavior

The hardware worker timestamps each successful native poll. The UDP responder does not refresh timestamps when answering requests. Old samples stop being published after ten seconds; native SignalRGB unavailable-sensor/fan fallback behavior still needs integration verification. Missing/null, nonfinite, or out-of-range readings are not substituted with zero. The service reopens a failed native reader after fifteen seconds. Inventories exceeding 128 valid channels or the 60,000-byte UDP reply limit fail as unavailable rather than being truncated.

The plugin checks matching request/reply nonces, protocol version, board identity, verified sensor IDs, and timestamp freshness. A failed service or suspended hardware reader cannot continually refresh cached temperatures. Existing SignalRGB fan control remains the only fan-speed writer.

## Adding another motherboard

1. Run `bin\SignalRgbSensorService.exe --probe --output board-probe.json` as administrator on that motherboard. The output contains the same structured board identity used by the protocol and raw temperature inventory. Existing hardware monitoring tools may contend for hardware access; use a controlled test session.
2. Verify which raw channels correspond to physical sensors using upstream board/chip documentation and reference readings. Sharing a chip or having plausible temperatures does not establish channel meanings. Leave unidentified channels out.
3. Copy `ASUS_LHM_Temperatures.js` to a new `Vendor_Model_LHM_Temperatures.js` beside the installer or inside `plugins/`. Update `Name()` and the `BOARD` object: exact SMBIOS manufacturer aliases/model, a unique controller ID/name, and the verified sensor-ID-to-name map in `sensors`. The generated plugins use `models` for explicit aliases and grouped `variants` for chip-specific mappings, including raw channel-name checks. Keep controller IDs and registered sensor names stable after release because fan curves may reference them.
4. Keep the protocol, board checking, freshness validation, and discovery behavior intact. The shared service needs no changes or rebuild when only adding a plugin. Do not broaden an existing plugin's model match to cover unverified variants.
5. Add tests using probe-derived fixtures for the new plugin, including a nonmatching board with the same chip/IDs. Verify discovery, registration, temperatures, and unavailable behavior in real SignalRGB on the target board before marking support verified. For a custom plugin outside the generated catalog, copy its JS file directly to SignalRGB's Plugins folder and restart SignalRGB. To include it in automatic installer selection, extend the generator to include its exact identities in `plugins/install-manifest.json` and validate that there are no overlapping matches.

The `BOARD` object is the only runtime mapping for each plugin. Multiple board plugins can coexist, but the installer copies only the detected board's plugin. It uses a generated identity manifest rather than executing JS or maintaining a second set of channel mappings. The uninstaller finds packaged plugin names by the `*_LHM_Temperatures.js` convention in the root and `plugins/` directories; disabled backups are retained.

## Source-derived plugin catalog

The additional plugins cover ASRock (29), ASUS (61), Biostar (2), DFI (2), ECS (1), EVGA (2), Gigabyte (124), MSI (28), Shuttle (1), and Supermicro (1). Their 306 exact SMBIOS model strings include aliases for the same board. They cover explicit model-specific Super I/O routes in the pinned LHM library, with generic/unknown/AUX channels excluded. Primary chip instance zero is supported; secondary chips and embedded-controller-only boards require additional work. Multiple possible chip paths reflect upstream code routing, not confirmation of which chip is physically fitted.

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Generate-Plugins.ps1` after building to regenerate the catalog and standalone plugins. It checks pinned upstream source hashes and executes only mapping functions against a hardware-free proxy that rejects hardware operations. The root ASUS plugin supplies the shared JS runtime. `plugins/catalog.json` is build-time provenance and generator data, not service configuration. `plugins/install-manifest.json` is generated installer-only identity metadata for all 252 plugins, including the original ASUS plugin. Generated JS files contain their channel mappings directly. See the [support matrix](plugins/README.md) and [mapping attribution](plugins/NOTICE.md).

## Local protocol

Send JSON `{ "protocol": 2, "request": "srgb-lhm/2", "nonce": "unique-request-id" }` to the loopback UDP port. Replies contain `protocol`, echoed `nonce`, `status` (`ok` or `unavailable`), `sourceTimeMs`, `detail`, `board` (`manufacturer`, `model`, `version`), and `sensors` (`id`, `hardware`, raw `name`, `celsius`). Board identity may be null during startup or reader failure. Plugins must reject missing or nonmatching identity and select IDs explicitly; raw service channel names are not verified physical labels.

## Validation commands

- `bin\SignalRgbSensorService.exe --self-test` — service data-validation tests.
- `bin\SignalRgbSensorService.exe --probe` — native motherboard sensor inventory; run as administrator.
- `bin\SignalRgbSensorService.exe --console` — interactive generic service mode; the installed service must be stopped first to free the UDP port.
- `node test-plugin.cjs` — plugin mapping, board checks, discovery, and stale-source tests.
- `node test-catalog.cjs` — shared runtime tests plus every generated plugin's chip/channel variants, exact model/manufacturer aliases, discovery, wrong-board/channel rejection, and cleanup.
- `node tools/generate-plugins.cjs --check` — check all generated JS files, the installer identity manifest, and the support list against the catalog and shared runtime.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-installer.ps1` — script syntax, generic service health, automatic board selection, single-plugin installation, and reversible upgrade cleanup in a temporary fixture directory. Does not change real services or installed plugins.

Rebuild and run the hardware-independent tests with `.\Build.ps1` (.NET 10 SDK and Node.js required for development). The script restores the locked NuGet dependencies, builds the service, and runs service, plugin, and installer tests. Neither Node.js nor the SDK is needed by the installed service; it uses the .NET 10 runtime. Native live tests require administrator access to the actual motherboard. For the existing ASUS live harness, stop the installed service in a controlled session, start `bin\SignalRgbSensorService.exe --test-server` as administrator, and immediately run `node test-live.cjs` in another terminal. The temporary server exits after twelve seconds; the harness checks that publications stop after expiry. Restart the installed service afterward.

## Removal

Run `Uninstall-Service.ps1` as administrator to stop and unregister the service. Add `-RemovePlugin` to remove installed copies of the `*_LHM_Temperatures.js` files packaged beside that uninstaller and inside `plugins/`. It retains program files, logs, old configuration files, and PawnIO for review or reuse. Restart SignalRGB afterward.

## Source and third-party notices

Service and plugin source are included. LibreHardwareMonitorLib 0.9.6 is used unmodified under MPL-2.0: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/tree/v0.9.6 and https://www.mozilla.org/MPL/2.0/ . Its NuGet dependency identities and hashes are in `src/packages.lock.json`; the build's `.deps.json` records runtime dependencies. Microsoft service libraries and the other dependencies retain their respective upstream licenses. No driver binary is redistributed here.

SignalRGB API reference: https://docs.signalrgb.com/developer/plugins/fan-control/
