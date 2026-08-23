# Host Adapter Plugin Contract

## Purpose

A host adapter provides the capability MCP itself does not guarantee: creating and bootstrapping a successor model session.

## Plugin form

Prefer a Swift protocol and compile-time registered target over runtime-loaded unsigned bundles.

Recommended modules:

```text
ForgeHostPluginKit
ForgeNativeSessionHostPlugin
ForgeHostPluginTests
```

`ForgeHostPluginKit` contains only stable domain contracts and value types. The application composition root registers plugins. Plugins do not import SwiftUI unless they provide a narrowly isolated settings surface.

A manifest identifies:

- stable identifier;
- version;
- minimum host contract version;
- supported provider/host type;
- capabilities;
- configuration keys;
- privacy requirements;
- migration version.

## Build requirement

Codex must build the plugin when capability detection shows that no existing adapter satisfies all of:

- create successor session;
- bootstrap handoff;
- report/estimate context budget;
- receive acknowledgment;
- resume/reconcile after crash;
- idempotent or reconcilable creation.

The plugin is part of the repository and normal build/test graph. Do not leave a design-only placeholder.

## Native plugin responsibilities

- use the existing configured model/provider client where possible;
- define logical sessions independent of one long transcript;
- persist provider identifiers and usage;
- support cancellation and deadlines;
- store secrets in Keychain or the existing secure store;
- redact logs;
- expose health/capability diagnostics;
- avoid retaining complete transcripts in memory;
- stream responses with bounded buffers;
- checkpoint before rollover;
- recover in-flight session creation.

## External adapters

Add an external-host adapter only when a public documented API exists and can be exercised in tests. Keep it optional and capability-driven. Failure to support autonomous creation in an external host must not break memory MCP or handoff tools.

## Testing

Each adapter runs the same contract suite against a fake host:

- capability negotiation;
- create/bootstrap/acknowledge;
- idempotency;
- cancellation;
- timeout;
- malformed response;
- rate limit/backoff;
- crash/recovery;
- concurrent projects;
- secret/log redaction;
- bounded streaming memory.

Native plugin integration additionally proves a full rollover through the app.
