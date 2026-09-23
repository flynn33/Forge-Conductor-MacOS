# Telemetry architecture (real-time native)

## Product model

Telemetry is a **continuous native stream**, not a multi-second snapshot poll.

| Layer | Behavior |
|-------|----------|
| `RealtimeMetricsEngine` | Samples host CPU/RAM/GPU/disk/process at ~30 Hz via Apple APIs |
| `TelemetryService` | Publishes a live frame on every host sample; forge/MCP recomposed on a short utility cadence |
| Native GUI | Receives bounded latest-value delivery; Metal gauges draw on demand, stop while hidden/detached, and resume with the latest values |
| Web UI (`telemetry/static`) | Primary: `EventSource /api/stream?hz=20`; fallback: `/api/live` only if stream stalls |
| HTTP current frame | `GET /api/live` (alias `/api/snapshot`) returns the **current** live frame for tools/compat |

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
- **Autonomy** reports manager service state plus bounded active/deferred load.
- **Continuity** reports automatic monitoring, active rollover, attention, and
  the greatest available context-load fraction.
- **Rune Forge** reports selected/indexed policy-source and observation state.
  It remains an additive observer and never claims authorization enforcement.
- **Project** reports exact delivered instruction-document steps and completed
  instruction packages for the active project. Failed or blocked packages
  surface an attention state.

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

At normal widths, intrinsic Grid rows align CPU/GPU, Storage/Managed Activity,
MCP servers/tools, and agents/processes. Managed Activity scrolls within a
compact 130-point region, and constrained widths stack the instrumentation
panels instead of clipping them.

The title bar exposes **Guided Setup**, an eight-step state-aware wizard for
Manager readiness, provider connection, project registration, instruction
ordering, automation review, run start, monitoring, and recovery. It reads the
same bounded operational snapshot to recommend the next required step; it does
not introduce another telemetry or render loop.

## Qualification boundary

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

`0.14.0`

Build: `6`
