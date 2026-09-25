# Dashboard parity — evidence & architecture

The visible native view is **Dashboard**. Historical evidence and stable
technical identifiers may still use “FORGE RIG” or `rig`; those compatibility
names are not a second dashboard.

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
`RigDashboardView` single board: Dashboard title bar with **Guided Setup** · sys
strip · multi-series load · orchestration
status · CPU/GPU aligned row · Storage/Managed Activity aligned row ·
orchestration · MCP servers/tools aligned row · agents/hot-processes aligned
row · audit live stream. Managed Activity uses a compact 130-point internal
scroller; constrained widths stack the instrumentation panels.

Managed Activity is a coalesced projection distinct from the legacy audit live
stream. The former uses the view-owned five-second Manager refresh to show the
active package and step, current phase/work/next action, durable managed
responses and tool transitions, orchestration events, and exact
project/generation policy events. Detailed activity text comes from the
authenticated exact run/project/generation route; the public snapshot preserves
bounded, redacted mission and work-item text plus non-sensitive state, identity,
and event metadata while omitting phase/next action,
assistant/model-error/tool summaries, and managed activity rows. Durable
storage retains at most
128 assistant plus 128 tool rows per run; presentation retains at most 100
app-local rows, caps durable event summaries at 2 KiB and displayed messages at
8 KiB, and is not token streaming. It does not persist or reconstruct a second
full provider transcript.
The legacy stream remains the bounded tool/agent diagnostic audit view.

## Manager console
`ManagerSettingsView`: **Start / Stop / Restart**, settings form (host/port/refresh/watchdog/TTL/shell/auto-restart), prune, doctor. It uses an in-process `ManagerNode` only when the GUI owns the service; with the normal LaunchAgent topology it uses the typed native `ManagerDashboardClient` and does not compete for the dashboard port.

## Tests
The [qualification status](QUALIFICATION-STATUS.md) records the exact local and
CI counts, source bindings, and current development version **0.14.3**, build
**9** identity. Historical `0.9.0 (1)` and `0.12.0 (4)` receipts remain
explicitly historical.
The retained local app-hosted tests and four production onboarding scenarios passed;
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
For the current layout/feed slice, a fresh native UI run passed 3/3 cases with
zero skips: minimum-window containment and alignment across all 14 primary
views, the populated compact equal-height Storage/Managed Activity row, and the
populated Rune Forge Policy Feed. The complete
installed/native UI and service-lifecycle matrix, manager-owned real-provider
rollover, filesystem E2, P10, Developer ID distribution, and representative
physical-hardware qualification remain open.
