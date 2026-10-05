# Dashboard parity — evidence & architecture

The native Graphite UI implementation and required QA are complete for
0.17.0 (27). Persistent main-window shortcuts are removed; their actions remain
in Settings and menus, with six independently enabled optional view controls.
Current production checks, normal/minimum native view fixtures and signed
ordinary workflows passed in their named scopes. Earlier failed and passing
checkpoints retain their original inputs and results in
[Graphite Workbench](GRAPHITE-WORKBENCH.md). Exact owner publication/readback/
synchronization refs are retained externally.

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
| `MetalLoadChart` / `LoadTraceRenderer` | Compact CPU/RAM/GPU/disk history with fraction meter on one surface |
| `MultiSeriesLoadRenderer` | Combined CPU/RAM/GPU load trace |
| `MetalToolLoadTile` | MCP tool load tiles |

## UI

The Graphite Workbench phase applies shared native tokens to panels and Metal
traces while preserving published metrics and the combined Compute Cores frame.
The added review scope calls for reference-matching sparklines and static
luminous material. Seven changed-geometry cases, four native production
lifecycle cases and the earlier persistent-header check passed.
Sixteen Rig and two telemetry contract cases preserve measurement parity.
Earlier checkpoint top/lower visual review and all four ordinary-candidate
onboarding/export cases passed in [Graphite Workbench](GRAPHITE-WORKBENCH.md). Prior receipts below
remain bound to their historical source.

The latest source opens without a global control bar. **Settings → Workbench**
and the Navigation, Telemetry and Guide menus retain the global actions. Six
separate preferences can opt into individual controls above the selected view;
all six are off by default. **Guided Setup** is available from Workbench Settings,
the Guide menu or its explicitly enabled optional control. The current native
preferences and every-view normal/minimum QA passed in their named fixture
scopes, with separate ordinary Settings observations.
`RigDashboardView` single board: sys
strip · multi-series load · orchestration
status · combined **COMPUTE CORES** frame · Storage/Managed Activity aligned row ·
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

The Dashboard's project tracker resolves current live MCP presence to the
matching active durable `mcp_client` binding. Recent audit activity orders
multiple live clients and heartbeat order is the deterministic fallback. A
matching nonterminal run is used only when no live binding resolves; the first
registered project is never used as an activity substitute. Current status
bootstrap creates the exact durable binding for an explicit project or the sole
active project, and deployment-scoped MCP identity preserves it across helper
restart and primary/fallback/CLU failover, so the tracker does not lose the
active project merely because LM Studio relaunched the helper.

## Manager console
`ManagerSettingsView` has local sections for Authorized Folders, Service,
Runtime, Settings, Project Shell, Protected Filesystem, Maintenance and Doctor.
**Start / Stop / Restart**, staged host/port/refresh/watchdog/TTL/shell/auto-restart
settings, pruning and doctor retain their existing model operations. Switching
sections does not save or reload drafts. It uses an in-process `ManagerNode`
only when the GUI owns the service; with the normal LaunchAgent topology it
uses the typed native `ManagerDashboardClient` and does not compete for the
dashboard port.

## Tests
The [qualification status](QUALIFICATION-STATUS.md) records the exact local and
CI counts, source bindings, and current source version **0.17.0**, build
**27** identity. Historical `0.9.0 (1)` and `0.12.0 (4)` receipts remain
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
For the earlier layout/feed slice, a native UI run passed 3/3 cases with zero
skips across the then-current 14 primary views, the populated compact
equal-height Storage/Managed Activity row, and the populated Rune Forge Policy
Feed. The 0.14.5 navigation case separately passed with the redundant
Autonomy destination absent and Project run controls reachable from Projects.
The complete
installed/native UI and service-lifecycle matrix, manager-owned real-provider
rollover, filesystem E2, P10, Developer ID distribution, and representative
physical-hardware qualification remain open.
