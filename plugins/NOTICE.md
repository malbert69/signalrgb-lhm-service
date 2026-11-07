# Mapping provenance

The generated motherboard mappings are derived from LibreHardwareMonitor 0.9.6:

- [SuperIOHardware.cs](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/blob/v0.9.6/LibreHardwareMonitorLib/Hardware/Motherboard/SuperIOHardware.cs): board/channel mapping tables.
- [Identification.cs](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/blob/v0.9.6/LibreHardwareMonitorLib/Hardware/Motherboard/Identification.cs): exact SMBIOS model names and manufacturer recognition.
- [Model.cs](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/blob/v0.9.6/LibreHardwareMonitorLib/Hardware/Motherboard/Model.cs): model identifiers.

Upstream notices: Copyright (C) LibreHardwareMonitor and Contributors. Partial Copyright (C) Michael Möller, Open Hardware Monitor, and Contributors. The upstream source is distributed under the [Mozilla Public License 2.0](https://www.mozilla.org/MPL/2.0/). Obtain the corresponding source through the links above. The SHA-256 hashes used for extraction are recorded in `catalog.json` and enforced by `tools/Generate-Plugins.ps1`.

The runtime is shared with this project's root ASUS JS plugin. Each generated JS file is standalone; neither `catalog.json`, `install-manifest.json`, nor the extractor is used by the running service or plugins. The installer uses `install-manifest.json` only to select an exact motherboard match. Upstream-derived mapping does not establish physical-board or SignalRGB validation. No driver binary or upstream source cache is distributed in this directory.
