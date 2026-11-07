# Validation status

Service and plugin logic validation is described below. Final integration validation must also check native SignalRGB discovery, temperature registration, and unavailable-sensor behavior.

## Version 0.2: generic service and board-specific plugins

Completed hardware-independent validation:

- Catalog: 251 new standalone plugins (252 total with the original ASUS plugin), 306 additional exact model strings/aliases, and 10 manufacturers. Mappings are extracted from the compiled LHM 0.9.6 library only along explicit model-specific source routes; exact SMBIOS aliases are checked with the library's identification functions. The three pinned source hashes are checked during extraction. The proxy only provides in-memory chip properties and throws on hardware operations.
- Every generated plugin: 3,070 chip/mapping combinations and 712 manufacturer/model alias combinations exercised in the SignalRGB adapter harness. Unique sensor-name registration, exact board selection, raw channel-name matching, unsupported chip and secondary chip rejection, stale/legacy protocol rejection, controller identity, discovery backoff, and shutdown are covered. Independent reference checks cover ASUS Z790 HERO, ASRock X870E TAICHI, MSI B550-A PRO, and Gigabyte X570 AORUS MASTER channels.
- Generation check: every packaged generated JS file, installer identity manifest, and support-matrix document must match the catalog plus the root plugin runtime. Installer metadata rejects duplicate filenames and overlapping identities.
- Locked dependency restore and Release build: no warnings or errors.
- Service: multiple board identities without configuration, all readable native temperature IDs and raw labels, missing/null/nonfinite/out-of-range rejection, valid zero, duplicate-ID rejection, preserved source timestamps, serialized replies with echoed nonces, stale sample suppression, bounded oversized replies.
- Plugin: verified aliases only, rejection of wrong manufacturers and nearby model variants sharing the same sensor IDs, missing identity, protocol 1 rejection, timestamp and nonce checks, partial availability, zero degrees, duplicate configured IDs, reader/socket failure, recovery, shutdown.
- Discovery: no unconditional controller announcement, retry while absent/unavailable, reject wrong/stale boards or unverified channels, announce once on a matching fresh response, preserve the existing ASUS controller ID, and close discovery sockets after success/shutdown.
- A synthetic second motherboard plugin recognizes its own identity using the same protocol without service changes. This and the generated plugin harness checks do not establish physical-board validation.
- Installer/uninstaller/build PowerShell syntax; generic health checks accept one or three valid readings and reject invalid identity, nonce, protocol, timestamps, duplicate IDs, and invalid temperatures. Test extraction executes only the health function, without running installation.

The installed service was not replaced or restarted during these tests. All 251 new plugins remain hardware untested. Version 0.2's native SMBIOS identity, full temperature inventory, discovery socket lifecycle, and real SignalRGB registration/unavailable/fan fallback behavior require integration validation after upgrading both service and plugin. The existing installed service remained running on the fixed UDP port; the earlier live results below apply to version 0.1 only.

## Version 0.2.1: device-page grouping

- Added `DeviceType()` returning `lightingcontroller` and `SubdeviceController()` returning `true` to the shared JS runtime and all generated plugins.
- Applied the update to the installed plugins with backups. The existing hardware service continued running.
- Confirmed in SignalRGB 2.5.86 that the ASUS PRIME Z790-P WIFI temperature provider appears under **Fan & RGB Controllers**, alongside its physical motherboard controller. The device console reported native motherboard sensors receiving after hot reload. This confirms category placement on this installation; it does not establish native fan fallback behavior or hardware validation for other boards.
- Generated-file checks and the existing plugin/catalog tests pass.

## Automatic installer selection

- Manufacturer and exact model selection tested for all 252 plugins, including the original ASUS plugin, alternate SMBIOS aliases, case/whitespace normalization, missing identities, wrong manufacturers, nearby model variants, and ambiguous multi-board matches.
- Temporary filesystem tests confirm a fresh install copies one JS file, upgrades back up replaced and unused packaged plugins, unrelated plugins remain intact, trailing directory separators work, and package sources cannot be selected as the installation destination.
- Invalid relative paths, duplicate plugin filenames, and overlapping board identities are rejected by the manifest loader.
- Read-only detection on this PC selected `ASUS_LHM_Temperatures.js` for `ASUSTeK COMPUTER INC.` / `PRIME Z790-P WIFI`. Full elevated service reinstallation was not required for these checks.

## Earlier version 0.1 native validation

Previously completed:

- Release build: no warnings or errors.
- Direct native probe: administrator access, PawnIO 2.2.0, ASUS PRIME Z790-P WIFI, Nuvoton NCT6798D.
- Direct sensor access used LibreHardwareMonitorLib, not a HWiNFO export or API.
- Service logic: stable native IDs, missing/null values, NaN, impossible values, valid zero-degree readings, timestamps, duplicate-ID rejection.
- Plugin logic: registered sensor mapping, expired samples, nonce mismatch, unconfigured sensors, invalid values/timestamps, reader failure, valid zero-degree readings.
- Temporary 12-second native server plus the actual plugin source run in a test harness over real loopback UDP: **11 native samples**, last values **Motherboard 31°C**, **VRM Thermistor 39.5°C**.
- After that server exited, the plugin stopped reporting temperatures once their source timestamps expired.
- Installer and uninstaller PowerShell syntax parsed successfully. No service, scheduled task, or plugin was installed by these tests.

The test harness replaces only SignalRGB's device-registration and UDP module adapters. Real SignalRGB module loading, discovery, native temperature registration, and unavailable-sensor/fan fallback behavior still need verification after installation. Existing fan curves have not been changed.

The current installer requires a uniquely matching motherboard plugin plus a fresh protocol 2 response with consistent motherboard identity and at least one valid native temperature. It does not require two sensors. The generic health check does not establish that every channel mapped by the chosen plugin is available.
