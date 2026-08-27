# FC-HOST-001 decision and change summary

The existing statically registered native session-host plugin now uses a real LM Studio
REST and SSE transport in production. Model inventory and one exact strict-schema
function-tool probe establish the provider version, loaded model identity, context length,
parallelism, tool capability, usage behavior, genuine response identifier, and stable
capability fingerprint before session creation can succeed.

The transport enforces separate connect, first-byte, idle, and total deadlines and bounded
request, JSON, SSE line/event, text, tool-argument, and aggregate response sizes. It maps
context overflow, truncation, disconnects, malformed payloads, authorization failures,
conflicts, rate limiting, endpoint absence, and server errors to typed fail-closed results.
Production bearer tokens are resolved from an opaque macOS Keychain reference; errors and
diagnostics redact secret-like material.

The adapter V2 ledger is atomic and bounded. It reconciles retries by idempotency key,
retains accepted-successor fencing through terminal compaction, and never promotes partial
stream text to a terminal result. The local logical transport remains available only as an
injected test double; no production source constructs it.

The live probe discovered that the loaded Qwen model can pause for more than 60 seconds
between stream events. The probe retained all contract requirements while increasing its
bounded idle and total deadlines to 180 and 300 seconds. The retry completed in 53 seconds
and returned one valid strict function call plus a genuine `resp_` provider identifier.
The provider did not report a usable version header, so the evidence records that field as
`unreported` rather than inventing a version.
