# Debugging and regression protocol

## Failure classification

Classify every failure before editing:

- compile or link failure;
- test assertion;
- crash or signal;
- race or timing flake;
- signing, entitlement, sandbox, Keychain, LaunchAgent, or Developer Mode setup;
- provider protocol or model availability;
- migration/data fixture;
- resource budget regression;
- release-evidence or source-manifest mismatch.

Record the smallest failing scope and preserve the first real error. Do not repeatedly run the full suite without a new hypothesis.

## Repair loop

1. Reproduce with the smallest deterministic test.
2. Identify the owner and invariant that failed.
3. Add a regression test at the narrowest layer.
4. Apply a bounded, reversible fix.
5. Run the focused test repeatedly where concurrency is involved.
6. Run the enclosing target and feature-parity tests.
7. Run the work-package gate validator.
8. Re-run affected previously passed gates when the source manifest changes.

## Concurrency and lifecycle

For actors, tasks, timers, Combine subscriptions, network connections, XPC connections, processes, file descriptors, security-scoped leases, and Metal resources, document:

- creator and owner;
- maximum count;
- cancellation/stop trigger;
- deallocation/release point;
- behavior under manager restart;
- evidence proving quiescence.

Use strict concurrency warnings as errors. Replace `@unchecked Sendable` where possible; otherwise document the exact lock/actor invariant and add stress tests.

## Performance

Compare identical workflows after warmup. Separate live retained growth from allocator/driver caching. Measure main-actor work, pending tasks, telemetry queue depth, event/database growth, file descriptors, child processes, Metal draw cadence, and provider payload size. A lower one-time RSS value is not sufficient proof.

## Security

Never fix a security test by broadening allowed roots, following symlinks, weakening authentication, disabling sandboxing, suppressing errors, or changing an unsupported operation into best-effort success. Ambiguity must fail closed or quarantine with a durable receipt.

## Compatibility

Before changing a public contract, snapshot MCP `tools/list`, schemas, result fields, error codes, settings defaults, migrations, CLI output, manager routes, UI identifiers, and package formats. New capabilities are additive unless a versioned migration with compatibility tests is explicitly approved by this package.
