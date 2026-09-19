# Documentation guide

Start with the shortest document that answers the question. Historical evidence
is retained for auditability, but it is not current operating guidance.

## Use and setup

| Document | Purpose |
| --- | --- |
| [User guide](../USER-GUIDE.md) | Install, configure, and operate Forge Conductor |
| [Xcode guide](../XCODE.md) | Build, test, archive, sign, and inspect the native app |
| [LM Studio connection](LM-STUDIO-CONNECTION.md) | Deploy and diagnose the LM Studio MCP connection |
| [Instruction packages](INSTRUCTION-PACKAGES.md) | Queue ordered project work |
| [Native completion](NATIVE-COMPLETION.md) | Configure protected completion gates |

## Architecture and contracts

| Document | Purpose |
| --- | --- |
| [Architecture](ARCHITECTURE.md) | Product boundaries, ownership, persistence, and trust |
| [Project memory](PROJECT-MEMORY.md) | Project-scoped durable memory contract |
| [Project reset](PROJECT-RESET.md) | Generation reset and isolation behavior |
| [Continuity ingress](CONTINUITY-INGRESS.md) | Authorized source attachment and rollover |
| [Context and agent continuity](CONTEXT-AGENT-CONTINUITY.md) | Handoff packet and host behavior |
| [Telemetry](TELEMETRY.md) | Metrics, delivery, and gauge invariants |
| [Budget policy](BUDGET-POLICY.md) | Persisted defaults and project overrides |
| [Versioning](VERSIONING.md) | Product-version and build-number rules |

## Delivery and current status

| Document | Purpose |
| --- | --- |
| [Roadmap](../ROADMAP.md) | Canonical phase and milestone record |
| [Qualification status](QUALIFICATION-STATUS.md) | Current evidence and remaining release gates |
| [Delivery workflow](DELIVERY-WORKFLOW.md) | Local-first update and verification process |
| [Functional-build record](FUNCTIONAL-DEVELOPMENT-BUILD.md) | Detailed candidate and artifact receipts |

## Historical records

Files whose names begin with `AUDIT-`, `BUILD-BASELINE`, `COHERENT-RESUME`,
`EDIT-BUILD-TOOL-PATH`, `G1-`, `RELEASE-`, or `RIG-PARITY` are retained as
evidence for the version and date named in the file. They do not override the
README, roadmap, qualification status, or current implementation.
