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

## Legacy migration during project registration

Manager registration and MCP project initialization invoke the existing legacy
migrator after exact project activation, while holding the registration transition
fence. The migrator imports records with provable project identity as read-only
history and quarantines ambiguous records with a retained explanation. Migration
does not create a successor or use `LATEST` as project authority. It preserves
the original legacy files and uses the existing transactional migration receipts
for restart and replay.

The registration scan is limited to 128 JSON candidates and 512 directory entries.
It opens candidates relative to a pinned directory descriptor and rejects symbolic
links, hard links, FIFOs, oversized files and other non-regular inputs. Invalid
candidates retain a quarantine explanation without copying linked content. An
inventory exceeding either limit fails before any migration commit and leaves
registration reconciliation pending; it never reports a partial prefix as complete.

MCP initialization reports `legacy_continuity_migration` as `pending`, `complete`
with receipt and counts, or `not_needed`. A migration failure after registration
commits preserves that primary result and requests an exact retry. Manager results
likewise retain the committed project identity and its current lifecycle state
when migration still needs reconciliation. These migrations grant no active run
or task authority.

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

Native process evidence now covers forced termination after source commit,
source claim, manager acceptance and source acknowledgment. Each child test host
runs the production source or delivery service and is terminated with SIGKILL;
recovery uses the persistent manager's normal delivery entrypoint. Retained effect
records verify the original packet hash, one run, acknowledged delivery and no
second acceptance. The two claimed cases advance the injected clock by 31 seconds
to make their persisted leases eligible. Coverage ends at `awaiting_bootstrap`;
remote provider acceptance and the complete rollover crash matrix remain separate
qualification requirements.

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


## Manager-owned source conversations

An approved native task can now send work through the manager's existing native
Responses provider. The manager owns this conversation and its bounded provider
permit. The operator uses stable request IDs to reconcile the same logical input:

```sh
forge-conductor manager task send --task UUID --request-id UUID --input-file /absolute/input.txt
forge-conductor manager task status --task UUID --request-id UUID
forge-conductor manager task cancel --task UUID --request-id UUID --cancel-request-id UUID
```

The input is a protected UTF-8 file of at most 16 KiB. The task's original
assignment, project generation, approved tool scope and credential remain the
authority. Reusing a request ID with different input is rejected. Status reports
bounded metadata; credentials and complete provider transcripts are not returned.

Control-plane capability 8 adds a bounded conversation journal. Each provider
request freezes its exact local preflight, capability observation and identity
before a single submission. The same transport encoder checks request bytes and
output limits. An uncertain submission stays eligible only for recorded-receipt
lookup, including after restart; elapsed time cannot authorize another POST.
Provider configuration remains pinned while source or managed work owns it.
Control-plane capability 9 adds bounded, paired pressure metadata/digest columns
and an exact source-reservation link through a verified 8-to-9 migration. New
requests retain their original logical input separately from the assembled prompt.
Older canonical request bytes and missing input fields remain unchanged. Both
control-plane and co-resident runtime schema checks reject partial or unknown
pressure extensions. Read-only budget snapshots authenticate the exact task,
stage and live lease before returning retained measurements.

Actual provider call IDs enter the existing authenticated source dispatcher.
Reads and checkpoint/handoff commits retain exact results and debits. Before a
read or result continuation, admission reserves the full approved result bound,
including JSON escaping. Already canonical JSON payloads reserve at most twice
their byte ceiling when quoted once as a provider output string; raw input text
does not use this bound. Actual envelope framing is measured separately.
A ready handoff fences the source and enters the existing
outbox, acceptance, exact restoration, acknowledgement and sealing sequence.
Current source call quotas include the immutable count of reads admitted before
conversation enrollment plus admitted provider calls. Provider reads are counted
once. Ready handoffs retain this quota check even though they need no further
source-provider output continuation.

The successor inherits original context/output ceilings, reserve floors and tool
allowances while applying tighter current policy. Its retained context begins
with the actual bootstrap acknowledgement, without importing the old source
conversation's cumulative usage. Missing usage uses conservative serialized
history. Ordered tool-output prefixes are charged once; completed response-chain
recovery verifies the original provider and broker receipts before replaying
work. Equivalent stored usage JSON formatting remains compatible, while changed
values, response identities and expired ownership are rejected.

## Pressure components and qualification

Typed pressure evaluation distinguishes rollover/emergency measurements from
blocked policy or quota decisions and uncertain provider outcomes. The pure
packet builder accepts only matching typed pressure metadata. It retains the full
approved assignment, original logical input or exact legacy request, completed
progress and results, untouched call arguments, uncertainty and remaining
budgets. A compact decision projection binds the complete canonical decision
SHA and in-packet identity; actual usage stays separate from prospective
reservations. Full audit metadata remains the control plane's responsibility,
not a replacement for successor-readable task data.

The projection is capped at 4 KiB. The complete exact `context_get` result must
fit the 64 KiB and original inline bounds, tighter original/effective result-byte
ceilings, and retained-result token policy. The ordinary 4,096-token limit is
unchanged. Oversized critical work produces a typed construction failure;
optional previews alone may be clipped.

The control plane can durably record pressure before a provider POST or after an
accepted response. It recomputes the decision from the retained request,
capability probe, response and ordered journal facts before atomically stopping
ordinary source work. Opaque storage claims retain one five-minute deadline;
recovery changes the lease epoch without extending that deadline. Expired owners,
competing owners and cancellation cannot commit a fence or resume inference.
An ordinary inference lease cannot release pending pressure-storage ownership.
Quota blockers receive no storage claim. Cancellation preserves the exact
provider state and decision for reconciliation.

The source store also provides an internal exact prepared-commit receipt read.
It checks metadata ownership before decoding and uses a read snapshot without
creating a revision, outbox row or write reservation. It can read an existing
invalidated receipt for reconciliation; live ingress remains fenced. This helper
still requires the control-plane recovery claim to be connected at its caller.

Under a live pressure claim, the control plane now builds the recovery packet
from retained assignment, logical input, complete progress, verified outputs and
untouched call arguments. Domain-separated identities bind the complete pressure
disposition to one source reservation, charged as zero tool calls. The prepared
packet and pressure link commit atomically; generic recovery excludes that row.

Storage reads the exact existing source receipt before reserving an attempt and
again before writing. Each of at most eight attempts is consumed durably before
its possible source effect. A consumed attempt may recover a receipt but cannot
invoke its writer twice. An interrupted control-plane receipt write is recovered
from the actual source commit. Successful receipt retention fences the source
conversation, including when the ready handoff has no automatic delivery.

A current automatic opt-out can be frozen before writing only after exact
readback proves no revision exists. Re-enabling the setting after a disabled
source commit does not enqueue delivery during recovery. Actual existing receipts
are preserved without policy rewriting; failed readback never means absence.

After cancellation, revocation or storage expiry, a separate 30-second receipt
claim validates the retained task, dispatch lineage, pressure decision and source
reservation. It needs no bearer grant and exposes only an exact source read and
audit update. It cannot invoke a source writer, extend the original deadline,
clear cancellation or restore provider execution. Missing receipts are retained
and quarantined; unavailable reads throw without being treated as absence.
Expiry at commit rolls back the audit update, and a new lease fences old owners.

The control plane also reconstructs the pending tool-output continuation from
the accepted response and verified completed prefix. Local transport measurement
runs outside the database transaction. A second transaction checks the same
pending call, lease and prefix before admission or durable pressure recording.
Cancellation during measurement grants no output or storage authority. Reads
retain their full approved allowance; checkpoint requirements measure a prepared
packet and its response without committing it. Admission returns that frozen
checkpoint for the execution owner to use. A ready handoff has no continuation
measurement requirement.

Successor acceptance now verifies the exact committed pressure source receipt
and retains a separate pressure journal digest. It counts every admitted provider
call, including untouched calls, plus reads admitted before enrollment once.
The pressure decision's tightened ceilings survive later policy increases and
repository restart. A prepared stage before POST contributes its retained intent
but no invented provider response or usage. A receipt recovered after storage
expiry can be accepted while the source remains stopped. The established
provider-requested handoff digest format remains unchanged.

Stage ordinals restart at one for each logical source message. Pressure admission
checks contiguous stages within each message, rejects interleaved request reuse,
and verifies the exact provider response chain across messages.

The source owner now checks pressure before provider dispatch, after every
accepted response (including assistant-only answers), and before tool effects.
It stops and joins inference renewal before adopting the fixed storage claim.
The manager uses the real continuity writer and commits the exact checkpoint
packet measured during output admission. Intrinsically oversized read allowances
are rejected before any read or handoff effect.

The existing watchdog separately pages unfinished pressure storage and expired
receipt cleanup. Storage failures retain a short lease cooldown and the original
five-minute deadline; writer attempts remain capped at eight. Receipt read
failures use durable exponential retry delays and quarantine after eight failed
reads. Neither recovery path acquires a provider permit or issues a model POST.
Shutdown retains ownership until a pending storage callback actually exits.

If frozen critical data cannot fit its inherited packet, decision, retrieval or
commit-response limit before reservation, the owner records a specific terminal
pressure reason and releases the storage claim. It preserves the pressure data
without creating a source reservation or repeatedly attempting the same packet.

The compact bootstrap root explicitly names acknowledgment contract version 2,
separately from envelope schema 3.0. The adapter still requires exactly one typed
acknowledgment with the correct identity, checksum and nonce; a second corrected
call cannot make a multiple-call response valid.
The root also supplies the complete expected acknowledgment object, encoded by
the same typed wire model used for validation. This challenge is included in
bootstrap byte admission. It grants no authority and cannot fill missing fields
in the model's actual acknowledgment.
Tool discovery uses a separate cancellation token bounded by the current lease.
Its admission deadline cannot shorten the five-minute source exchange deadline;
the owner renews the lease during provider inference. Task cancellation still
cancels discovery, and the existing per-call and provider limits remain enforced.
A native regression crosses the initial 30-second lease with a 31-second response.

Pending-intent writes require the lease to identify the same target run before
any mutation. A native process probe verifies one lease winner, preservation of
the exact pending intent after that process is killed, epoch advancement after
expiry, and rejection of the old lease. This covers the repository ownership
boundary; the complete manager/provider crash matrix remains separate.

Source exchange failure diagnostics record the provider/owner phase, a bounded
code and cancellation/deadline flags. Prompts and raw exception text are excluded.

A disposable real-provider pressure test now reaches source handoff commit,
manager admission, a fresh successor root and exact context retrieval. Gemma 4
E4B returned multiple acknowledgment calls, including incomplete calls, which
were rejected without successor activation. Its larger-packet attempt also
retained an unknown provider outcome after the request deadline. A separate
Qwen3 Coder 30B attempt ended without a source response receipt during prompt
processing. These failed runs retain their native receipts and recovery fences;
they do not prove resumed successor work or pass G04.
A later direct Gemma run, using a disposable 90-second provider wait setting,
completed exact retrieval, a single valid acknowledgment and successor activation.
The successor requested `fs_read`, but reserving the full approved 64 KiB result
crossed that fixture's inherited emergency threshold before the read. The pending
work remained durable. This proves activation, while continued work under that
policy and complete gate qualification remain open.

Integration tests exercise real source/outbox commits, untouched reads, failed
writes, interrupted receipts, expiry and shutdown with a fixture provider. Real
provider pressure rollover and complete G04 qualification remain open. Product
identity remains 0.9.0 build 1.

At the September 8 component checkpoint, signed native and selected Release
suites each passed 293 tests, and the separate packet suite passed 13 tests,
with no skips or failures. A disposable Gemma 4 E4B 4-bit conversation in
LM Studio 0.4.23+1 at 131,072 context completed one approved file read and
answered with the returned marker. After a manager restart, exact replay
preserved the answer, provider receipts and debits without another provider
call or file read. Conflicting input and generic source access were rejected.
The full 65,536-byte read allowance remained unchanged.

A separate Qwen conversation accepted a root and completed one approved read,
then LM Studio's tool-call parser failed during the read-output continuation.
That continuation remained `outcome_unknown` with no repeat POST. The successful
Gemma case used an independent task and did not retry that uncertain request.
These source-only observations do not qualify automatic handoff caused by source
context pressure, writable source work, association with an existing external
desktop conversation, repeated real-provider rollover or complete native/process
qualification.
A large result allowance can still exceed available headroom before a read;
the owner distinguishes intrinsic capacity failure from transferable context
pressure before any read. Repeated real-provider pressure rollover, G04 and
release readiness remain unqualified.
