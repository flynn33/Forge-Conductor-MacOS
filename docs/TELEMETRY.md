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
| `GET /` | FORGE RIG static UI |
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

`0.9.0`

Build: `1`
