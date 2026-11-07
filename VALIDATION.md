# Validation status

Service and plugin logic validation is described below. Final integration validation must also check native SignalRGB discovery, temperature registration, and unavailable-sensor behavior.

Completed:

- Release build: no warnings or errors.
- Direct native probe: administrator access, PawnIO 2.2.0, ASUS PRIME Z790-P WIFI, Nuvoton NCT6798D.
- Direct sensor access used LibreHardwareMonitorLib, not a HWiNFO export or API.
- Service logic: stable native IDs, missing/null values, NaN, impossible values, valid zero-degree readings, timestamps, duplicate-ID rejection.
- Plugin logic: registered sensor mapping, expired samples, nonce mismatch, unconfigured sensors, invalid values/timestamps, reader failure, valid zero-degree readings.
- Temporary 12-second native server plus the actual plugin source run in a test harness over real loopback UDP: **11 native samples**, last values **Motherboard 31°C**, **VRM Thermistor 39.5°C**.
- After that server exited, the plugin stopped reporting temperatures once their source timestamps expired.
- Installer and uninstaller PowerShell syntax parsed successfully. No service, scheduled task, or plugin was installed by these tests.

The test harness replaces only SignalRGB's device-registration and UDP module adapters. Real SignalRGB module loading, discovery, native temperature registration, and unavailable-sensor/fan fallback behavior still need verification after installation. Existing fan curves have not been changed.

The service installer additionally requires a successful fresh two-sensor UDP health check before it reports installation success.
