# FORGE RIG parity — evidence & architecture

## Evidence source
- Classic panels: `Sources/ForgeConductorCore/Resources/TelemetryStatic/index.html` + `app.js`
- Required system keys: `TelemetryContract.systemKeys`
- Required forge keys: `TelemetryContract.forgeKeys`
- Panel checklist: `TelemetryContract.rigPanels`

## Modular collectors (OOP)
| Type | Responsibility | Evidence-based choice |
|------|----------------|----------------------|
| `CPUCollector` | Aggregate + **true per-core** via `host_processor_info` | Darwin API; no shell; EP-safe |
| `GPUCollector` | Util via **IOKit** (`IOAccelerator` / `AGXAccelerator` / `IOGPU`) | Avoids hanging `ioreg` subprocess |
| `DiskIOCollector` | Rates via **IOKit IOBlockStorageDriver** cumulative counters + delta | Optional `iostat -c 1` ≤1.5s only as fallback |
| `ProcessMetricsCollector` | Hot processes | Filtered `ps` ≤1.5s; XCTest skips to discovery |
| `ForgeCollector` | MCP, agents, tools, orch, feed | Pure Swift process + SQLite |
| `SystemCollector` | Composes the above | Facade for snapshot |

## Metal gauges (all meters)
| Component | Used for |
|-----------|----------|
| `MetalBarGauge` | Sys strip, storage, I/O, orch, processes, agent bars, feed duration |
| `MetalRingGauge` / labeled | MCP activity rings, agent ON/SB |
| `MetalCoreBarsView` | Per-core bar field |
| `MultiSeriesLoadRenderer` | CPU/RAM/GPU load trace |
| `MetalToolLoadTile` | MCP tool load tiles |

## UI
`RigDashboardView` single board: sys strip · multi-series load · cores · storage · orchestration · MCP servers · MCP tools · agents · hot processes · live stream.

## Manager console
`ManagerSettingsView`: **Start / Stop / Restart**, settings form (host/port/refresh/watchdog/TTL/shell/auto-restart), prune, doctor. It uses an in-process `ManagerNode` only when the GUI owns the service; with the normal LaunchAgent topology it uses the typed native `ManagerDashboardClient` and does not compete for the dashboard port.

## Tests
The current full Swift package Release suite executes **1,001 tests**, with
**5 declared environment skips** and **0 failures** under warnings-as-errors.
The dedicated Apple Development-signed `ForgeConductorAppTests` Xcode scheme
executes **2 app-hosted contract tests** with **0 failures**. These regression
results do not replace the still-open native UI, real-provider, filesystem E2,
P10, or release-signing qualification lanes.
