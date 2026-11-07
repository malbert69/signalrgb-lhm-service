# Validation status

Service and plugin logic validation is described below. Final integration validation must also check native SignalRGB discovery, temperature registration, and unavailable-sensor behavior.

## Version 0.2: generic service and board-specific plugins

Completed hardware-independent validation:

- Catalog: 251 new standalone plugins (252 total with the original ASUS plugin), 306 additional exact model strings/aliases, and 10 manufacturers. Mappings are extracted from the compiled LHM 0.9.6 library only along explicit model-specific source routes; exact SMBIOS aliases are checked with the library's identification functions. The three pinned source hashes are checked during extraction. The proxy only provides in-memory chip properties and throws on hardware operations.
- Every generated plugin: 3,070 chip/mapping combinations and 712 manufacturer/model alias combinations exercised in the SignalRGB adapter harness. Unique sensor-name registration, exact board selection, raw channel-name matching, unsupported chip and secondary chip rejection, stale/legacy protocol rejection, controller identity, discovery backoff, and shutdown are covered. Independent reference checks cover ASUS Z790 HERO, ASRock X870E TAICHI, MSI B550-A PRO, and Gigabyte X570 AORUS MASTER channels.
- Generation check: every packaged generated JS file and support-matrix document must match the catalog plus the root plugin runtime. The installer/uninstaller enumerate the root and generated-plugin directories and reject duplicate install filenames.
- Locked dependency restore and Release build: no warnings or errors.
- Service: multiple board identities without configuration, all readable native temperature IDs and raw labels, missing/null/nonfinite/out-of-range rejection, valid zero, duplicate-ID rejection, preserved source timestamps, serialized replies with echoed nonces, stale sample suppression, bounded oversized replies.
- Plugin: verified aliases only, rejection of wrong manufacturers and nearby model variants sharing the same sensor IDs, missing identity, protocol 1 rejection, timestamp and nonce checks, partial availability, zero degrees, duplicate configured IDs, reader/socket failure, recovery, shutdown.
- Discovery: no unconditional controller announcement, retry while absent/unavailable, reject wrong/stale boards or unverified channels, announce once on a matching fresh response, preserve the existing ASUS controller ID, and close discovery sockets after success/shutdown.
- A synthetic second motherboard plugin recognizes its own identity using the same protocol without service changes. This and the generated plugin harness checks do not establish physical-board validation.
- Installer/uninstaller/build PowerShell syntax; generic health checks accept one or three valid readings and reject invalid identity, nonce, protocol, timestamps, duplicate IDs, and invalid temperatures. Test extraction executes only the health function, without running installation.

The installed service was not replaced or restarted during these tests. All 251 new plugins remain hardware untested. Version 0.2's native SMBIOS identity, full temperature inventory, discovery socket lifecycle, and real SignalRGB registration/unavailable/fan fallback behavior require integration validation after upgrading both service and plugin. The existing installed service remained running on the fixed UDP port; the earlier live results below apply to version 0.1 only.

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

Version 0.2's installer requires a fresh protocol 2 response with structured motherboard identity and at least one valid native temperature. It does not require two sensors or verify that a board-specific plugin is supported.
