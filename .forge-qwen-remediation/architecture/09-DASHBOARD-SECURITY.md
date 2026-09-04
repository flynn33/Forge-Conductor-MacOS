# Dashboard transport and authorization

## Connection registry

The server owns all accepted `NWConnection` instances in a bounded registry. Admission checks a configured cap. Every connection has a monotonic header/body deadline, maximum bytes, request count limit, and cancellation token. `stop()` cancels the listener and every accepted connection.

## Parsing

Read incrementally with strict header and body limits. Reject malformed length, transfer encoding not supported, duplicate sensitive headers, and requests that exceed limits. Do not recurse indefinitely on incomplete reads.

## Authentication classes

- unauthenticated: minimal liveness/version endpoint with no project paths, runs, sessions, settings, or counts that reveal work;
- authenticated read: manager status, settings, operator snapshots, project/run/autonomy/provider/runtime/continuity status;
- authenticated mutation: all state changes.

Use the existing owner-only bearer secret and constant-time comparison. Rotate/reload safely without logging the token.

## Diagnostics

Expose accepted, active, rejected-capacity, expired, oversized, malformed, unauthorized, and stop-cancelled counts without sensitive peer data.
