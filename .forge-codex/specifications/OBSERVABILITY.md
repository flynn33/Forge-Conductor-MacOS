# Observability Specification

## Unified logging categories

Use the app bundle identifier as subsystem and stable categories such as:

- `AppLifecycle`
- `ProjectLifecycle`
- `TelemetryProducer`
- `TelemetryDelivery`
- `GaugeScheduler`
- `GaugeRenderer`
- `ProcessSupervisor`
- `MemoryRepository`
- `MemoryMCP`
- `Continuity`
- `HostAdapter`
- `Migration`
- `Recovery`

Information logs mark meaningful boundaries. Debug logs carry bounded diagnostics. Errors include typed codes and identifiers, not raw private payloads.

## Signposts

Measure intervals for:

- telemetry aggregate-to-present;
- gauge active animation and draw;
- project open/close;
- process launch-to-exit;
- memory write/search/maintenance;
- MCP request;
- checkpoint build;
- host session creation;
- bootstrap-to-acknowledgment;
- migration;
- recovery.

Use stable operation IDs across logs, evidence, and state transitions.

## Metrics

At minimum expose bounded diagnostic snapshots:

### Telemetry

- events produced;
- snapshots published/delivered/replaced/dropped/stale;
- logical queue depth and maximum;
- delivery latency distribution;
- history sizes.

### Gauges

- visible/active surface count;
- draw count and active cadence;
- command queue/pipeline/buffer creation counts;
- buffer capacity;
- skipped draws by reason;
- last frame duration.

### Lifecycle

- active long-lived tasks;
- observers/subscriptions;
- child processes/readers;
- open project contexts;
- watcher/file descriptor counts where available.

### Memory MCP

- open databases;
- record counts by kind;
- database/WAL bytes;
- query latency;
- response bytes/truncation;
- cache cost/hit/eviction;
- maintenance work.

### Continuity

- current state;
- checkpoints/handoffs;
- rollover attempts;
- adapter latency/errors;
- exact versus estimated context budget;
- recovery actions.

## Health output

Provide a compact health model consumable by UI, logs, and tests. Do not expose raw memory content or secrets. Collection itself must be O(1) or bounded and must not retain histories beyond policy.

## Verification

Every permanent metric/log must have a test or deterministic runtime path proving that it fires exactly at the intended boundary and stops after shutdown.
