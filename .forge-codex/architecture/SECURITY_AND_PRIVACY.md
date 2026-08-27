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

Session bindings and continuity packets may narrow access to a configured root, but they never create a new authorization root. Project shell tools are enabled by the corrected schema-v2 local policy and expose an explicit native opt-out. `shell_exec` still requires an authorized project root, and a working directory alone is not treated as confinement for a general shell.

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

Migration pathname checks cover stable moved-file substitutions and
cooperating processes. The current macOS VFS also fails closed in the tested
A-to-B-to-A restoration cycle, but sequential observations are not an atomic
security boundary. Hostile same-user namespace substitution and direct
mutation of owner-controlled database files remain excluded unless a custom
SQLite VFS pins the database family and/or an independent privilege boundary
prevents same-owner mutation.

## Managed runtime execution

Managed shell and interpreter jobs execute only through the native runtime launcher. Production app and CLI builds require an exact, signed product identity, enclosing application seal where applicable, and a matching staged-helper code-directory hash. Exact-path, ad-hoc SwiftPM pairings are accepted only for local development products with allowlisted identifiers; they are not distribution authority.

Each job has independently authorized canonical read and write roots. Write roots must be a subset of read authority. Manager-owned stdout and stderr artifacts are outside the child-writable scratch directory. Artifact reads revalidate the regular-file type, owner, link count, device, inode, bounded size, and digest so replacement or mutation fails closed.

The launcher applies bounded CPU, descriptor, output-file, and core-dump limits before execution. Runtime discovery uses semantic, deadline-bounded probes rather than executable presence alone. Jobs run in isolated process groups under a deny-default profile, with bounded descendant census and a configured descendant limit. Termination phase and exact process identity are durable; shutdown and restart recovery continue bounded TERM, KILL, and liveness probing until group death is confirmed. An unconfirmed group remains owned and prevents stores from closing underneath the reaper.

## Plugin boundary

Host plugins receive only capabilities and data required for session creation. They do not gain arbitrary project filesystem access by default. Provider credentials remain behind a secure client abstraction.

## Logging

Use `Logger` with stable subsystem/categories and privacy annotations. Never use raw prompt/document body values in logs. Signposts use IDs and sizes, not content.
