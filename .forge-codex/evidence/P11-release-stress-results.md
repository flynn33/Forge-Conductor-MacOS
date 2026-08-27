# P11 release stress results

The current strict Debug and Release suites each passed 395 tests with two skips and no
failures. Their deterministic Release fixture exercised 50 rollovers, 100 manager
restarts, 100 project cycles, 25 process cycles, bounded telemetry delivery, and managed
owner shutdown. These passing measurements are retained as useful short-run evidence.

P11 is not passed. The fixture is not the required 8-hour idle soak or 4-hour active
tool-loop soak, actual GUI open/close and multi-project interleaving remain unexecuted,
and neither sanitizer configuration reached product test entry on this host. The short
fixture must not be promoted to release-stress completion.
