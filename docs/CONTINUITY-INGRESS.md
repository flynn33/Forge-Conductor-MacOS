# Authorized continuity ingress

Source storage, task authorization and manager admission are implemented in the
existing native Core module. Internal source transfer connects the canonical
worker, native provider, exact retrieval broker and supervisor recovery. Public
CLU controls are implemented; authenticated attachment to an existing desktop
conversation and full native/live qualification remain open.
This change keeps product identity at 0.9.0 build 1.

## Source commit and delivery

`ContextContinuityService.commitAuthorizedHandoff` runs inside the control plane's
live task authorization guard. The source SQLite transaction persists a compatible
packet, an immutable canonical revision and, for a resume-ready handoff with
automatic delivery enabled, one durable outbox operation. A soft checkpoint does
not enqueue delivery. An explicit submission of the same revision converges on
the same operation instead of resetting attempts or creating another successor.

Each revision binds the exact continuity ID, revision number, packet digest,
project, generation, original task binding, assignment digest and tool scope.
Authorization is checked before duplicate lookup or content disclosure. Later
compatibility edits cannot change a frozen revision, and replaying an earlier
commit cannot rewind the current packet. Delivery leases and bounded retries use
conditional updates; expired owners cannot acknowledge or revive an operation.

Shared legacy `context_get` reads, lists, memory pointers and readable memory
files exclude task-owned packets. Scoped restoration uses an exact immutable
identity and authorization. It does not select global latest state, adopt a
workspace, or clear a predecessor fence.

## Task authority

Native task setup retains the approved document and execution inputs separately
from model-authored progress text. The assignment digest covers the document,
mission, provider/model, specification and exact authorization scope. Persisted
snapshots must pass bounded, strict byte decoding and canonical digest checks.

An opaque native-issued caller correlation selects an enrolled source task. It
does not prove that generic calls from a shared MCP process belong to one desktop
conversation. A process ID alone cannot select a task. Every owned source mutation checks
the live caller, task binding and active project generation while holding the
existing control-plane writer fence. Permanent revocation survives restart,
generic binding reactivation and cancellation of a project reset.

Source transfer additionally requires a durable native-issued record of the
original caller binding and scope. The current internal path admits only a caller
whose actual authority is read-only, unchanged and bounded. Narrowing a task under
a broader writable caller does not qualify. Missing origin proof or unsupported
task-scoped mutation dispatch returns `task_identity_unavailable` before source
transfer. Independent tasks remain available; the shared MCP process is never
globally fenced to stand in for exact task authority.

## Manager admission and execution hold

The persistent manager owns delivery through its existing watchdog. Each pass
examines a bounded page of operation IDs, claims due work with a lease, reads the
current scoped policy and submits the exact immutable revision to the control
plane. Automatic delivery disabled before admission leaves the operation pending
without consuming an attempt. Authenticated explicit submission issues one durable
operation-scoped start permit. It can promote an already acknowledged source
without resetting that delivery's receipt, claim or attempts. It cannot revive an
invalidated or exhausted operation. Reusing an idempotency key pins the first
accepted revision even if the source later changes under the same continuity ID;
using that key with another continuity ID conflicts.

Admission atomically associates the task with one run, retains the approved
assignment and exact source bytes, and records a stable acceptance receipt and
an execution hold. A previously linked run keeps its existing work, budget and
provider records. A new run starts in `awaiting_bootstrap`; no predecessor session
or provider usage is invented. The manager commits acceptance durably before
acknowledging the source outbox. Redelivery after interruption returns the same
receipt and run instead of creating a second successor.

Startup, scheduling, direct execution and provider/tool reservation paths enforce
the durable hold. Generic transitions cannot release it; cancellation remains
available. Current policy or an exact explicit start permit is checked again
before provider effects. A source outbox Boolean alone never grants permission
to bypass disabled automatic handoff.

Source schema version 8 adds explicit-submission provenance without resetting
existing claims. The control plane retains its public schema version 2 and uses
a verified backup before expanding the run-state constraint. Unknown table
extensions fail closed rather than being dropped during that migration.
The capability migration has its own named manifest while using the same
database lock and verified backup machinery. It preserves the runtime-job
schema's separate version lineage in the shared control-plane database.

## Bootstrap recovery and remaining integration

Source-origin operations use version 3 of the existing project-memory continuity
tables and operation journal. They retain the accepted source identity and a
random bootstrap nonce without inventing a provider predecessor. Versions 1 and
2 retain their handoff and memory-record wire contracts. The manager records a
candidate before requesting a fresh root, then records the actual root response,
successful retrieval proof and typed acknowledgment as separate durable steps.

The candidate receives only compact handoff identity before requesting the exact
`context_get`. A manager-issued grant binds the candidate, accepted operation,
nonce, source revision, project generation and current run lease. The broker
executes the immutable source read, commits its existing invocation result and
retrieval proof together, and sends those exact payload bytes to the provider.
Ordinary tool and provider paths remain blocked by the execution hold. Recovery
retains the same candidate and provider intents; uncertain remote outcomes keep
the native provider's existing idempotency fence.

Before either provider turn, the worker checks current scoped policy and the
selected loaded model's capacity. Its initial estimate includes escaped handoff
output, both schemas and both bounded responses. The acknowledgment preflight
also checks actual retained root usage. Tool admission consumes existing
turn/session/run and recovery limits. Explicit permits authorize only their exact
source operation; they do not enable future automatic handoffs or override current
model, numeric budget, cancellation, generation or lease checks.

The manager now discovers held source work through bounded metadata pages in its
existing watchdog. Source and ordinary coordinators share one concurrency limit
and alternate when both kinds are queued. Live task authorization and policy are
rechecked before the leased claim and before provider work. Disabled automatic
policy does not consume an attempt. The existing run-lease renewal owner covers
the exchange; cancellation reaches the same native adapter instance.

Control-plane capability version 4 adds scheduling metadata to existing holds
through a verified migration, preserving earlier manifests and acceptance bytes.
It permits eight attempts within 24 hours, with bounded exponential delays and
the native provider's 660-second unknown-outcome fence. A scheduling acknowledgment
is written only after the actual canonical acknowledgment, both provider results
and the successful exact-source retrieval agree. Restart then suppresses duplicate
bootstrap dispatch. This marker does not release the hold or accept a successor.
Capability version 5 adds bounded source-origin and explicit-permit records plus
activation recovery through the same verified migration lineage. Acknowledged
operations enter a distinct activation phase with a finite retry allowance;
activation never creates another provider root or resets bootstrap attempts.

## Successor activation and observed continuation

The control plane validates the canonical acknowledgment and its actual provider
and retrieval proofs, accepts one candidate, and retains a durable activation
receipt while keeping ordinary dispatch held. The continuation's parent is the
actual acknowledgment response. Canonical sealing then records that exact receipt
in the existing project-memory journal; only a verified seal releases the hold.
Both steps replay after interruption across the two databases. Source operations
retain the existing `predecessorSealed` wire state without inventing a provider
predecessor.

An issued continuation is not resumed proof. The ordinary provider loop must
complete its reserved continuation, execute an authorized non-bootstrap tool
through the broker, and complete a following turn whose input matches the full
durable tool outputs. The control plane records this proof through the canonical
journal before clearing the active source operation. Until then, a second
rollover remains excluded. Current context limits can defer consumption while
preserving its pending intent; they are not overridden to manufacture progress.
Generic run transitions require a lease for that exact run and retain the source
operation and accepted candidate until durable resumption proof exists. Ordinary
work can select a later operation after the source transfer has completed.

The source store accepts at most 256 KiB per packet, 32 KiB per authorization,
1,024 retained revisions, 256 pending deliveries and 32 rows per query. Delivery
attempts are capped at eight; leases are capped at 60 seconds. Capacity exhaustion
fails the transaction without silently pruning authority or resetting retries.

Initial task setup does not create a run or activate a provider. Internal
transport fixtures do not establish visible LM Studio desktop task correlation,
writable external task transfer, or repeated real-provider rollover. Those
capabilities and the complete crash/independent-manager matrix still require
their own evidence before package completion.

## Public controls and native task dispatch

The additive `clu_capabilities`, `clu_start_handoff`, `clu_status` and `clu_cancel`
tools use closed inputs and bounded structured responses. Status and cancellation
require one exact operation ID; an ID does not grant permission. A native task
session retains its original verified correlation and routes checkpoint and
handoff writes through the same source authorization transaction. Shared stdio
connections cannot derive task identity from a client or project binding and
return `task_identity_unavailable` for task controls.

Native reattachment selects one explicitly retained task and revalidates its
original caller before restoring control access. It neither enrolls another task
nor removes the source transfer fence. Shared stdio has no reattachment route;
the native owner must still authenticate which task its requests belong to.

CLU control permission is separate from approved work tools. Managed provider
advertisements exclude these controls, and the ordinary invocation broker rejects
them even under a wildcard grant. The CLU connector advertises and dispatches only
the four controls. Primary and fallback retain their existing tool surfaces.
Current installation includes all three roles in staging, commit, rollback,
verification and selective removal; historical two-role observations remain
readable without establishing CLU installation or readiness.

Control-plane capability 6 adds a verified migration for durable cancellation
requests. A request fences its exact operation before the manager quiesces the
provider. The existing watchdog consumes bounded pages, retains actual cleanup
markers in both stores, and retries under its existing lease owner. Unknown
provider outcomes remain uncertain and fenced; local cleanup alone cannot produce
a terminal receipt. A completed operation cannot cancel a later operation on the
same run. `delivery_state: unknown` means the source store was not observed, not
that a delivery failed or was acknowledged.

Native task dispatch does not establish authenticated attachment to an existing
LM Studio desktop conversation. Deployment, provider readiness, visible desktop
rollover, GUI-closed recovery and later rollover require matching observations;
the capabilities response does not infer these from native assignment metadata.

## Authenticated native source attachment

The native operator can prepare one approved task through the existing manager:

```text
forge-conductor manager task prepare --request /absolute/approval.json
forge-conductor manager task reconcile --task UUID
forge-conductor manager task rotate --task UUID --expected-epoch N --expires-at UTC
forge-conductor manager task revoke --task UUID --expected-epoch N
```

Preparation accepts the registered project ID and generation, exact assignment
bytes and scope, provider selection, completion gates, explicit source limits and
absolute expiry. The manager checks current folder authorization. Preparation
creates no run and does not contact a provider. The first source profile,
`forge.native-task-source` version 1, supports approved `fs_read` work with a
read-only filesystem scope and no network access. Unsupported work scope is
rejected. Source calls are capped at 64 per task, results at 64 KiB and deadlines
at 60 seconds; the approved limits and current policy can lower those ceilings.

Operator commands use manager authentication. A separate task credential stays
in the protected native task store; printed receipts omit its bearer value.
Commands retain their exact pending request before transmission. If a response
is lost, `reconcile` resends that request and verifies its retained receipt.
Rotation changes the credential epoch and revocation is permanent. Neither a
task ID nor an MCP session ID grants access. Credentials have explicit expiry,
at most seven days, with no automatic renewal.

The existing manager listener serves `/mcp/continuity` using MCP `2025-11-25`.
Attachment requires a verified loopback listener and peer, valid Host and Origin
headers, task authentication, initialization and a matching protocol session.
The endpoint advertises `fs_read`, `session_checkpoint`, `session_handoff` and the
four CLU controls. Source calls also require a canonical UUID in the static
`Forge-Source-Session-ID` header. The native client retains this namespace and the
exact JSON-RPC request ID when retrying after reconnect; those values identify a
request but grant no authority. Reusing an ID with different arguments conflicts.
A new logical source namespace uses a new UUID. Host retries that regenerate
request IDs still require separate qualification.

The endpoint bounds authentication and execution admission separately
at eight requests each and retains at most 32 protocol sessions. Cancellation is
isolated to the authenticated session and epoch. Stopping operational service
retains authenticated discovery, status and cancellation; source work and starts
are unavailable. Listener replacement invalidates old sessions, and process
shutdown closes admission and drains owned requests before closing storage.

Control-plane capability 7 retains task credentials as verifiers, command
receipts, source call debits and frozen source commit intents. A source read is
charged before dispatch; an uncertain read cannot refund its debit. Acceptance
carries that debit once into the run, where restoration, ordinary broker calls
and later rollovers retain the same accounting. Exact completed read requests
replay retained results only after current authority and source fences are
rechecked.

A checkpoint or handoff freezes its canonical packet before any source write.
The durable intent binds the request, authority, packet bytes, ID and timestamp.
A ready handoff intent immediately fences new source work. The source commit
uses those frozen bytes, allowing an interrupted request to recover the same
revision and outbox identity. The existing watchdog reconciles at most four
pending intents per pass under current authority and bounded retry rules.
Response size is checked with the actual MCP encoding before the intent, so an
oversized packet cannot commit and then be reported as a size rejection.

This attachment is an explicit native API path. Existing desktop conversation
association, writable source transfer, repeated live-provider rollover and the
full crash qualification remain separate requirements.
