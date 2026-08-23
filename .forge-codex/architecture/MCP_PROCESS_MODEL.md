# MCP Server Process Model

## Composition

Prefer extending the existing server executable. If a separate memory executable is required, supervise it through the same bounded `ProcessSupervisor` and preserve a unified capability surface where possible.

The MCP service must not depend on a SwiftUI application process being foregrounded. Project memory remains durable when the GUI restarts.

## Transport

### Stdio

- read framed/line-delimited messages according to the existing protocol implementation;
- cap message bytes before decoding;
- process bounded concurrent requests;
- serialize writes;
- flush responses;
- handle EOF as shutdown;
- cancel requests on disconnect;
- never block waiting for a pipe that is not concurrently drained.

### Local socket, when already supported

- loopback only by default;
- authenticate;
- enforce connection/request limits;
- idle deadlines;
- graceful close;
- same schemas as stdio.

## Server lifecycle

```text
created → starting → ready → stopping → stopped
                  ↘ failedRecoverable
```

`start()` performs migrations and capability detection before announcing ready. `stop()` rejects new work, cancels requests, flushes repositories, closes transports, and returns under a deadline.

## Request execution

A request context contains:

- request ID;
- project identity;
- deadline;
- cancellation handle;
- payload budget;
- response budget;
- diagnostics operation ID.

The transport does not directly own project repositories. It obtains a bounded lease/context from the project memory service.

## Protocol testing

Spawn the real executable and communicate over the real transport. Verify initialize negotiation, malformed/oversized input, concurrent requests, cancellation, shutdown, restart, and compatibility snapshots.
