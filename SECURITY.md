# Security Policy

## Supported Versions

Security updates are provided for the latest release of this project.

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |
| older   | :x:                |

## Local control-plane boundary

The dashboard binds only to loopback and rejects non-loopback Host values.
State-changing requests require same-origin JSON plus route authorization.
Native Manager clients use the owner-only bearer stored in
`manager-control.secret`. The browser control page receives a separate random
per-server capability limited to its visible Manager controls and session
prune/close; it never receives the durable bearer. Privileged shell and
filesystem tools are not exposed as dashboard HTTP routes.

## Desktop-provider integration boundary

Claude Code Desktop and Codex Desktop invoke the same-build Forge CLI through
generated hooks. The `provider-hook` bridge accepts only supported
desktop provider/event identifiers, an absolute bounded Forge-home path, and a
bounded JSON envelope. It forwards that envelope only to the configured
loopback Manager endpoint with the owner-only Manager credential. The client
does not follow redirects, does not resolve a credential-bearing request to a
non-loopback address, disables cookies and caches, enforces a short deadline,
and validates a bounded JSON response before writing host-facing stdout.

Grok Build remains a non-selectable compatibility and cleanup surface. Its
current documented startup and prompt hook outputs cannot deliver Forge's
initial assignment context to the model, so Forge does not admit Grok runs or
represent Grok as ready. Any retained Grok package remains subject to the same
ownership checks and may be removed without widening the security boundary.

Desktop integration does not widen host permission policy. Forge never emits an
automatic allow decision for tool use or a permission request. If a desktop
provider is inactive, or the local orchestration policy is unavailable, the
hook denies only a recognized Forge MCP `PreToolUse` call; unrelated host tools
and events remain under the host's own policy. MCP still enforces the existing
project root, shell, filesystem, completion, memory, and continuity boundaries.
Generated hook and MCP entries receive the same explicit canonical Forge home;
the MCP command uses
`serve --home <forge-home> --desktop-provider <provider-id>` rather than relying
on a GUI host's inherited environment. The provider role comes only from that
immutable command-line argument; an environment variable cannot opt a generic
MCP process into desktop-run authority.

A provider-specific MCP process starts unattached. It may list the stable tool
catalog for host compatibility, but every Forge project tool fails closed until
`desktop_run_attach` consumes the exact capability returned in the current hook
assignment. Forge persists only the capability digest. The raw 256-bit token is
single-use, expires after five minutes, and is bound to provider, session, run,
project UUID and generation, provider-selection revision, and deployment.
Atomic consumption copies the autonomous run's frozen authorization scope to
that exact MCP client. Replay, copied identities, a generic `serve` process,
another provider, and another project/run/session are rejected. A replacement
assignment, desktop session end, terminal run state, manager restart recovery,
or run deletion revokes and bounds the durable attachment rows.

Provisioning stages and hashes deterministic Forge-owned packages, refuses
symbolic links and foreign ownership conflicts, preserves unrelated compatible
settings entries, and rolls back an incomplete commit. Repair and removal act
only on artifacts and settings entries whose Forge ownership can be verified.
Removal does not infer that host registration disappeared from source-file
deletion alone. If supported CLI or live inventory cannot verify unregister,
Forge preserves its artifacts and receipt and reports **Awaiting User Action**;
an idempotent retry can settle after the operator removes the host registration.
Receipts are bounded and redacted: they record artifact identity and command
result metadata, not credentials or raw command arguments. A receipt is not
proof that a desktop application is open or that a person accepted a host trust
prompt.

## Reporting a Vulnerability

Please do **not** report security vulnerabilities through public GitHub issues.

### Preferred: private vulnerability report

If private vulnerability reporting is enabled for this repository, use GitHub’s
**Security** tab → **Report a vulnerability**, or open a private advisory from
the repository’s Security page.

### Alternative: email

You may also email **[contact@ravenforgesoftware.com](mailto:contact@ravenforgesoftware.com)** with the subject line:

`[SECURITY] <repository-name>`

### What to include

Please include as much of the following as you can:

* A description of the vulnerability
* Steps to reproduce the issue
* Potential impact
* Affected versions (if known)
* Any suggested fix (optional)

## What to expect

* We will acknowledge receipt of your report as soon as possible.
* We will investigate and keep you informed of progress.
* Once a fix is available, we will coordinate disclosure as appropriate.
* Please give us a reasonable time to address the issue before any public disclosure.

Thank you for helping keep this project and its users safe.
