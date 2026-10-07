# Telemetry architecture (real-time native)

Current source documentation is `0.25.0`, build `35`. The PDF writer and shared
semantic reader own per-call native resources without adding a recurring
producer, timer or cache. The corrected owning-area source selection passed
101 methods and the compiled native selection passed 102 tests on the original
450-input PDF product snapshot. Candidate and Qwen native processes exited
normally with full EOF and no forced cleanup. This is not general leak, GUI
responsiveness or quiescence qualification; synchronous native parsing is not preempted by the reader's quotas.
The original native compiler's XCTest self-capture warning remains historical E2
test-fixture evidence. A later immutable fixture capture correction freshly
compiled without the warning; its focused native regression and all 19 writer
methods passed. No runtime race or production reachability was observed, and no
production resource boundary or concurrency check changed. The independent r6
validator passed 82 controls and the Debug/Release/Qwen artifacts with normal
exits and full EOF; its revised operand quota is separate from framework latency/heap bounds.
Native PNG review covered ten Release and two Qwen PNG pages. PDFKit compatibility
remains open. The PDF source/wiki checkpoint was published and synchronized; this
later test/documentation publication is pending in
[native PDF writing](NATIVE-PDF-WRITING.md).

## Preceding 0.24.0 listing resource evidence

The per-call listing
helper introduces no recurring timer, watcher, cursor cache or subprocess. Its
source descriptor owner uses explicit idempotent close with a deinit fallback;
the source and compiled Core regression observes exactly one successful close
on success, cancellation, quota and stale-context paths. This is not broad leak
qualification. Final checks passed 173 source and the same 173 compiled Core
cases; the interim failed selections remain NONPASS. The helper's bounded
scan/output work and actual native/model checks are recorded in
[filesystem list paging](FILESYSTEM-LIST-PAGING.md); no new telemetry or
quiescence pass is implied.

Five Thread Performance Checker QoS warnings occurred in the compiled test host
at `DiagnosticLog` flush/shutdown drain lines 64/75, in three existing Core tests
and two existing router-deadline tests. All those cases passed. Ordinary GUI
reachability and a product priority-inversion defect are not established by
those warnings; they remain separate from the new listing/renderer MCP passes.

Preceding 0.23.0 native renderer process
launch, exit, child and pipe-reader counters use the existing diagnostics owner.
The [renderer record](NATIVE-WEB-RENDERING.md) gives their verification limits. The telemetry
operating contracts below remain in force; preceding receipts keep their tested
source identities.

The preceding `0.18.0` repair starts MCP serve processes with on-demand metrics,
while the GUI retains its bounded continuous stream. Fresh one-shot collection
runs on the telemetry worker and does not start a timer or enqueue GUI delivery.
Its tests and candidate measurements are recorded in
[the repair record](LMSTUDIO-RUNTIME-REPAIR.md); preceding UI/telemetry receipts
retain their source identities.
The preceding native Compute v3 ordering diagnostic failed its unchanged
active/key/exposed startup predicate before any cover variant. Its one actual
test, two assertions, native exit 65, complete streams and corrected foreground
SecurityAgent identity remain in the repair record. Neither cover quiescence
nor a production renderer defect follows from this startup failure.

Dashboard lower panels use two independent equal-width columns: MCP Servers
above MCP Tools at left, Sub-agents above Hot Processes at right. Outer
bounds align; internal splits follow content, and Hot Processes fills the
remaining right-column height. The preceding `81a91a81…` source's 13-method
native matrix passed, and all 358 images were individually reviewed. [Native
QA](GRAPHITE-NATIVE-QA.md) records exact fresh build/fixture identities and
preceding checkpoint limits; approved Compute/telemetry inputs are unchanged.

## Preceding telemetry qualification — source 28548a73…

**Preceding UI implementation and QA complete.**
0.17.0 (27) source manifest 28548a73… passed **116 distinct production tests in 140
successful executions**, with zero failures/skips. The separate native view
matrix passed **21 unique methods in 22 invocations**; all **463 selected PNGs**
were individually opened and reviewed. The 15-check/434-input audit, matching
signed Debug build and four scoped ordinary workflows passed. Historical
failures and superseded inputs remain separate. Native caches, genuine Metal
readbacks and ordinary observations retain their explicit limits; no
installation, notarization, App Store upload or distribution was performed.
Exact owner publication/readback/synchronization refs are retained externally.

Preceding 0.17.0 (27) Graphite/Compute implementation/native QA/checks are complete; exact owner publication/readback/synchronization refs are retained externally. The operating contracts below
remain in force; exact current and historical evidence is separated in
[Graphite Workbench](GRAPHITE-WORKBENCH.md) and [Compute Cores](COMPUTE-CORES.md).

## Product model

Telemetry is a **continuous native stream**, not a multi-second snapshot poll.

| Layer | Behavior |
|-------|----------|
| `RealtimeMetricsEngine` | Samples host CPU/RAM/GPU/disk/process at ~30 Hz via Apple APIs |
| `TelemetryService` | Publishes a live frame on every host sample; forge/MCP recomposed on a short utility cadence |
| Native GUI | Receives bounded latest-value delivery; Metal gauges draw on demand, stop while hidden/detached, and resume with the latest values |
| Web UI (`telemetry/static`) | Primary: `EventSource /api/stream?hz=20`; fallback: `/api/live` only if stream stalls |
| HTTP current frame | `GET /api/live` (alias `/api/snapshot`) returns the **current** live frame for tools/compat |

The added Graphite review scope calls for CPU/RAM/GPU/disk sparklines, shaded
fills and static luminous material matching the selected reference. Existing
values/units, missing-sample gaps, retained-history bounds, shared rendering
resources and demand drawing are retained. Seven changed-geometry cases and
four production native lifecycle cases passed. Earlier checkpoint Dashboard/
lower-row native pixel review and 100-cycle navigation passed in
[Graphite Workbench](GRAPHITE-WORKBENCH.md).
Earlier telemetry receipts do not qualify these newer presentation inputs.

## Compute Cores revision 2 — verified current scope

Current Compute uses one exact reference PNG, two cached native CPU/GPU crops,
two immutable Metal textures and one sampler. Runtime logical CPU samples or
explicit host-average fallback drive bounded local regions; aggregate GPU
activity drives illustrative regions without measured-core claims. Source
registry/time/quality and stale/zero/missing semantics remain independent.
Trace travel is simulated, bounded and quiescent when hidden/paused.

The preceding 0.17.0 Compute 29, regression 68, proper canonical Provider 33 and
fresh Core 8/H0/G1 checks passed: 116 distinct production tests in 140 successful
executions. The separate 21-method/22-invocation native view matrix passed with
463 reviewed PNGs. All 68 Compute layers, the verified 20-frame MOV, strict
signed candidate/library packaging and four scoped ordinary workflows passed.
Actual normal Dashboard/Pause/Resume and Settings/preferences/restoration
complement native fixtures. Detailed resource/lifecycle measurements and
capture limits are in [Compute Cores](COMPUTE-CORES.md) and
[native QA](GRAPHITE-NATIVE-QA.md); no universal renderer-exclusive CPU cost,
installed-product, whole-window MOV or unavailable 1× claim is made. Exact owner
publication/readback/synchronization refs are retained externally; the operating
telemetry invariants below remain in force.

## Endpoints

| Endpoint | Role |
|----------|------|
| `GET /` | Dashboard telemetry UI |
| `GET /static/*` | `app.js`, `style.css`, … |
| `GET /api/health` | Continuous mode + measured Hz |
| `GET /api/stream?hz=20` | **Continuous SSE** of live frames (keep-alive) |
| `GET /api/live` | Current live frame (JSON) |
| `GET /api/snapshot` | Compat alias of `/api/live` |
| `GET /api/system` | Latest host sample |
| `GET /api/forge` | Last forge composition |

Legacy clients that pass `interval=2` are **not** held to 0.5 Hz — the server upgrades them to a realtime rate.

## What is *not* the product clock

- Multi-second “take a snapshot” timers
- One-shot SSE that closes after a single frame
- GUI `refresh()` as the continuous path (manual forge recompose only)

## Contract

Frame shape still validated by `TelemetryContract` and
`Tests/ForgeConductorTests/Fixtures/telemetry_contract_keys.json`.

Continuous behavior is proven by `RealtimeStreamTests` (engine samples,
service listener frames, multi-event SSE).

## Orchestration status

The native Dashboard places a shortened Load Trace beside four compact status/load
cards and one full-width project-progress row. They combine the existing bounded
telemetry frame with a separate
five-second, view-owned Manager refresh:

- **Provider** projects the durable selected provider. LM Studio distinguishes
  a reachable headless Provider API from process presence alone and labels its
  desktop Chat as separate. Claude or Codex can show **HOST READY** independent
  of LM Studio health only when ready preparation, the current selection
  revision, and a verified receipt agree. Missing, stale, in-flight, or
  non-selectable evidence fails closed.
- **Project Runs** reports manager service state plus bounded active/deferred load.
- **Continuity** reports automatic monitoring, active rollover, attention, and
  the greatest available context-load fraction.
- **Rune Forge** reports selected/indexed policy-source and observation state.
  It remains an additive observer and never claims authorization enforcement.
- **Project** reports exact delivered instruction-document steps and completed
  instruction packages for the project bound to the active MCP client. It
  correlates live presence with the durable `mcp_client` binding, uses an exact
  nonterminal run only as a fallback, and does not call a merely registered
  project active. Failed or blocked packages surface an attention state.

The Manager refresh starts only while Dashboard is visible, owns one cancellable
task, coalesces each response into one value snapshot, and stops on detach. The
Metal gauges reuse the Dashboard's existing bounded renderer and add no independent
render clock.

## Managed activity feed

In the compact Storage/Managed Activity row, the native Dashboard presents one
bounded, coalesced **Managed Activity** projection. The five-second operational
refresh composes the active project and instruction package, current inferred
document step, durable delivered count, current run phase/work item/next
action, Manager orchestration events, durable managed-provider responses and
tool transitions, and the newest policy events for the active project
generation. The public snapshot retains bounded, redacted mission and work-item
text plus non-sensitive state, identity, and event metadata. The Dashboard uses
authenticated `GET /api/manager/operator/activity` with exact run, project, and
generation identity for current phase/next action,
assistant/model-error/tool summaries, and managed activity rows. Its durable
summaries are capped at 2 KiB, sequence ordered, redacted at the owner boundary,
retained as at most 128 assistant plus 128 tool rows per run, and displayed
through an 8 KiB UTF-8 cap.

The app retains at most 100 rolling presentation rows and merges them by stable
identity rather than enqueueing an unbounded task per update. The frame stops
refreshing with the Dashboard view. It does not add a render clock, persist a second
event log, stream provider tokens, or create a full LM Studio conversation
transcript. Durable Manager events, instruction coverage, and the Stjornarvald
policy log remain the authoritative sources; Manager, instruction, and policy
availability is labeled so retained rows are not presented as fresh evidence.

Rune Forge presents the newest policy events again in its verbose **Policy
Feed** so policy-specific review does not require selecting every violation.
That global newest feed and Dashboard's exact project/generation feed are bounded by a 100-event,
1 MiB serialized-event Manager window; both native clients stream ordinary
responses through a strict 4 MiB ceiling and cancel on overflow. Both preserve
Stjornarvald's non-interference boundary.

The existing **COMPUTE CORES** frame now contains the source-integrated CPU/GPU
chip presentation, with native host labels and provenance. All 68 current
Compute layers and the normal/minimum Dashboard integration layers were
reviewed with explicit cache/drawable limits. Storage/Managed Activity retain
their aligned instrumentation layout. The lower Dashboard columns stack MCP
Servers/MCP Tools at left and Sub-agents/Hot Processes at right, with equal
widths and matching outer bounds rather than equal internal row heights.
Managed Activity scrolls within a compact 130-point region, and constrained
widths stack the instrumentation panels instead of clipping them.

Workbench Settings and the Guide menu expose **Guided Setup** for the
eight-step state-aware wizard covering
Manager readiness, provider connection, project registration, instruction
ordering, automation review, run start, monitoring, and recovery. It reads the
same bounded operational snapshot to recommend the next required step; it does
not introduce another telemetry or render loop. The wizard opens on explicit
request and never covers the app at launch. Its optional view control appears
only after enablement in Workbench Settings. Navigation visibility and telemetry
updates are also available in Settings; existing Navigation and Telemetry menus
retain their shortcuts. The preceding native matrix and scoped ordinary Settings
workflow verified opt-in controls, draft preservation, persistence and
restoration; their exact evidence boundaries remain in the phase record.

## Qualification boundary

The earlier qualifications below retain their original source/runtime scopes.
They remain separate from the preceding 0.17.0 production counts and four
manual ordinary workflows recorded above; neither set qualifies this new slice.

Telemetry contract and stream tests qualify only this subsystem. The retained
Apple Development installed-app qualifier passed bounded shell app/manager
restart checks but remains partial because its own System Events Settings step
was not run. A separate native Xcode run passed four production onboarding
scenarios, including Settings shell off/on with fresh MCP processes.

The later native Release gauge component run passed four tests, including 100
lifecycle cycles, hidden/visible draw behavior, buffer reuse, and weak-owner
release assertions. Closed fixture windows accumulated to 101; whole-app
window/leak closure is not established. The earlier exact-revision 100-cycle
Rig/MCP navigation result remains historical supporting evidence. See
[qualification status](QUALIFICATION-STATUS.md) for local/CI test counts and source scopes.

P10, filesystem E2, current G09-G12, Developer ID Release signing, the complete
installed/native UI/settings/service matrix, manager-owned real-provider
autonomous continuity, long-duration resource budgets, and owner-deferred
representative physical-hardware qualification remain open.

## Version

`0.25.0`

Build: `35`
