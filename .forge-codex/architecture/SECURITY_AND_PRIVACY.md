# Security and Privacy Boundaries

## Inputs

Treat MCP requests, project paths, model/provider data, subprocess output, imported memories, and handoff documents as untrusted.

Validate:

- maximum encoded size;
- required schema version;
- string and collection limits;
- allowed project identity;
- path containment;
- identifier format;
- timestamps and numeric ranges;
- transport authentication where applicable.

## Project path safety

Resolve symlinks and standardize paths. Operations must remain inside the authorized project root or Forge application-support directories. Reject traversal and alias confusion.

## Secrets

- Use the existing secure store or Keychain for credentials.
- Never persist tokens in memory records, handoffs, logs, test fixtures, or crash evidence.
- Redact environment variables, authorization headers, command arguments, and provider errors.
- Memory ingestion performs pattern and source-aware redaction before persistence.
- Tests include representative secret formats.

## MCP transport

- Stdio inherits process trust but still validates messages.
- Local sockets bind to loopback and use authentication tokens/permissions.
- Remote listening is disabled unless an existing explicit product feature requires it.
- Apply request deadlines, cancellation, rate limits, and maximum concurrency.
- Return typed errors without internal file contents or secrets.

## Database/files

Use least-privilege file permissions. Prevent another project from opening a memory store by path substitution. Export is explicit, checksummed, and redacted according to policy.

## Plugin boundary

Host plugins receive only capabilities and data required for session creation. They do not gain arbitrary project filesystem access by default. Provider credentials remain behind a secure client abstraction.

## Logging

Use `Logger` with stable subsystem/categories and privacy annotations. Never use raw prompt/document body values in logs. Signposts use IDs and sizes, not content.
