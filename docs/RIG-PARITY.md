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
The [qualification status](QUALIFICATION-STATUS.md) records the exact local and
CI counts, source bindings, and version **0.9.0**, build **1** identity. The
retained local app-hosted tests and four production onboarding scenarios passed;
the installed-app qualifier remains partial because its own System Events
Settings step was not run. The separate native Settings off/on case passed.
Subsequent Swift Debug/Release CI failed the Python containment test when the
sandbox blocked its Xcode framework dependency. The earlier local passes do not
make those later CI runs green.

The native Release gauge component run passed four tests, including 100
lifecycle cycles, hidden/visible draw behavior, buffer reuse, and weak-owner
release assertions. Closed fixture windows accumulated to 101, so these results
do not establish whole-app window or leak closure. The older 100-cycle Rig/MCP
navigation result remains historical supporting evidence.

Source bindings and artifact IDs are retained in the
[shipping checkpoint](../.forge-codex/state/release-handoff.md#retained-qualification).
This documentation update does not rerun those tests. The complete
installed/native UI and service-lifecycle matrix, manager-owned real-provider
rollover, filesystem E2, P10, Developer ID distribution, and representative
physical-hardware qualification remain open.
