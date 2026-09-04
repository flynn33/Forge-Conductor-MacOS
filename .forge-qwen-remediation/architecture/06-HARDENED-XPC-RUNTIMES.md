# Hardened XPC runtimes

## Profiles

- `workspaceIsolated`: current manager-launched process with sanitized environment, project root checks, output/time/resource bounds. Explicitly not an OS security boundary.
- `hardenedXPC`: separately signed App Sandbox XPC service with scoped project access and declared network policy.

## Targets

- shared value/protocol module;
- `ForgeRuntimeXPC` service target in Xcode;
- manager-side client and connection pool;
- test host and signed integration scheme.

SwiftPM may compile shared models and non-XPC logic; Xcode is authoritative for the service bundle and entitlements.

## Request contract

Each request includes job ID, project/generation, runtime profile, executable identity, fixed arguments or staged script descriptor, cwd bookmark ID, environment allowlist, timeout, output cap, network profile, and lease epoch. The XPC service rejects stale, malformed, overlarge, or unauthorized requests before launch.

## Security-scoped access

Bookmarks are created from user-authorized project roots, stored securely, refreshed when stale, balanced with start/stop access, and never returned to provider/model output.

## Process containment

The service creates a process group, drains stdout/stderr concurrently, enforces timeout/output limits, terminates descendants on cancel/connection loss, and returns a signed structured receipt. No shell profile loading occurs for clean runtime profiles.

## Shell compatibility

Legacy `shell_exec` remains on its existing manager path. Hardened XPC is additive and selected per durable job. A sandbox limitation cannot disable shell globally.
