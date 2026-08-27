# FC-PERF-001 decision and change summary

The resource policy and deterministic stress fixture provide useful partial evidence.
A Release fixture exercised 50 logical rollovers, 100 manager restarts, 100 project
cycles, bounded process output, a 500-record memory corpus, telemetry coalescing, and
cancellation release. It reported zero post-shutdown manager owners, a maximum of two
logical telemetry slots, zero slots after stop, and a zero slope across five immediate
post-release resident-memory samples.

The report was copied from `/tmp` and hashed. Its generating invocation was not captured
by the durable command recorder, so it is supporting measurement rather than standalone
gate proof. Independently recorded current Debug and Release full suites executed the
same stress and resource-policy tests successfully. The first artifact lint attempt used
a host `plutil` path that rejected JSON; Python's JSON parser then validated the same
bytes and the SHA-256 was recorded.

A subsequent 15-second Allocations capture attempted to attach `xctrace` to the Debug
application. The recorder never established a usable capture: all 799 diagnostic samples
of the `xctrace` main thread remained in `AuthorizationCopyRights` and its synchronous
authorization message path. The command was killed and exited 137. The small trace
directory contains only two partial files; it and the process sample are retained to
diagnose the host-authorization blocker, not accepted as application profiling evidence.

This work package remains incomplete. The short deterministic fixture is not an 8-hour
idle or 4-hour active soak, and its flat five-sample post-release window cannot prove the
absence of monotonic long-running growth. No successful Instruments or memgraph evidence
has been captured, actual hidden SwiftUI/Metal cadence has not been profiled, and this 48 GiB host
does not replace execution on representative lower-memory Macs. Do not promote the
fixture's internal `passed` status to an FC-PERF-001 gate pass.
