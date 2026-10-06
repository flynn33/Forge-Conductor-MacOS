# Context and agent continuity (v0.18.0)

The current native hosted rollover-control test passed numeric edits and public
accessibility stepper actions, including the 1 and 10,000 boundaries and default
200. This verifies the rendered control and staged settings binding; ordinary
current Manager save and LM Studio GUI rollover remain separate acceptance.

Current 0.18.0 (28) repair: the rollover threshold is saved in
`sessions.continuity_rollover_tool_calls`, defaults to 200, and is adjustable
from 1 to 10,000 in Manager → Settings. Durable project/generation/client
progress includes runtime and Xcode jobs and survives MCP helper restart.
Successful and failed eligible work calls both count. Ordinary MCP uses logical
epochs for its deployment; it has no supported external individual chat-context
identity or usage percentage. Managed runs apply the saved limit to unique
eligible calls with committed results, including returned tool errors, within
their active provider session. Forge-owned runs retain measured-capacity
evaluators; managed execution also retains the 32 provider-tool-round boundary.
Ordinary MCP checkpoints use the smaller of 50 and the saved limit and retain
the two-hour safeguard. Capacity, round and time safeguards can request rollover
before the chosen count limit.
Both status aliases refresh persisted settings before reporting the threshold,
while preserving staged edits. If configuration cannot be refreshed, recovery
status stays available and adds `configuration_refresh` with `state=failed`,
`using_cached_settings=true` and a bounded diagnostic. Healthy responses omit
this field. Audit mirroring and instruction queue initialization create their
storage directories without recreating a missing configuration or replacing
a cached shell opt-out with defaults; app bootstrap still initializes defaults.
Model checkpoints preserve the rollover budget. A rollover request remains
sticky while a live checkpoint claim is prepared, preserving that claim. One
SQLite transaction consumes the request and commits the actual handoff packet,
counts and progress/block state; rollback retains the request for recovery.
Projection-file failure reports the committed SQL handoff with a warning.
Exact successor handoff acknowledgement clears the block. Validation and retained
failures are in
[the repair record](LMSTUDIO-RUNTIME-REPAIR.md).
The Responses transport now has a private finite 5,120-event lifecycle/content
budget while the public decoder retains 4,096. Independent byte/time guards and
completed-response/ACK/seal requirements remain. Full source v8 and five exact
signed-native SSE controls passed; the original live stream validity is unknown,
and ordinary GUI/SIGKILL acceptance remains pending.
The later isolated native v7 observation durably acknowledged one successor
and sealed its predecessor. It missed the intended crash-test boundary; the
pending automatic continuation had no provider response or tool execution.
This establishes neither restart/replay nor ordinary LM Studio GUI succession.
The subsequent same-home ordinary restart completed the exact automatic turn.
Its one model-selected read used `/home/project/successor-only.txt` and failed
with `not_found`; the saved handoff instructed relative `successor-only.txt`.
The exact-one-marker check remains a non-pass, and stable replay did not run.
The controller paused before allowing the provider's tool-error feedback flow;
no product cause or successful task completion follows from this attempt.
The later separate ordinary resume completed the original error-feedback turn
with unchanged input and previous response, then read the exact owned marker
successfully by absolute path. Independent reconciliation retained the original
failed read and exact H/ACK/seal; one failed plus one successful read were
observed. The relative-path diagnostic remains a non-pass and stopped before
settled replay, with later feedback ambiguous. Final comprehension, crash and
ordinary GUI acceptance remain open; the repair record retains both attempts.
A separate two-launch paused replay passed in 12.636 seconds, with both Manager
exits zero and complete streams. The exact handoff/ACK/seal, failed and successful
reads, and provider/native ledgers remained stable for 10.134 seconds after the
second launch. The fourth feedback turn stayed ambiguous without a new accepted
response. This verifies the retained owned home's paused restart behavior.
Managed tool feedback now records a bounded success/failure outcome before
rollover. Failed invocations keep the first ordered action open and are omitted
from handoff completed work. Complete bounded legacy JSON with Boolean
`ok=false` is also excluded; missing or indeterminate historical outcomes keep
their previous presentation. A successful queued Xcode submission records the
submission only and does not establish a native build/test pass. Three baseline
negative cases reproduced the defect; 14 added and all 33 affected source
cases passed after repair without skips. New native validation is pending.
Manager settings and the existing Reload from disk action now use the same
validated refresh before returning the threshold, including saves by another
configuration owner. Unsaved local patches remain staged; missing/malformed
configuration returns cached values with the existing budget-policy diagnostic.
Two stale-read cases failed before repair. All three focused controls passed
afterward, followed by 288 passes/two explicit skips/zero failures in the 290-case
Manager/continuity selection. This remains source evidence.

This describes the current source identity. The owner-installed 0.16.4 startup
failure and corrected Xcode project are recorded in the qualification status.

## Current workflow

Continuity belongs to the ordinary LM Studio conversation. It is automatic and
is not started from the Forge Conductor Continuity view.

1. The user opens a normal LM Studio chat and asks the model to call
   `get_forge_status`.
2. Forge returns the registered project identity plus the project-file,
   instruction-package, Development Policy, and continuity locations and query
   tools. It requires the model to read every active policy source in priority
   order and follow applicable requirements before development changes.
   `resume=true` requests the latest resume-ready handoff.
3. While working, the model can save compact checkpoints. At context pressure
   it saves a resume-ready handoff.
4. After the durable handoff commit, Forge shows a 30-second countdown on the
   Dashboard.
5. At expiry the Manager activates LM Studio and creates exactly one foreground
   successor through its public macOS Accessibility controls, then submits the
   exact bootstrap input:

   ```text
   get_forge_status
   resume=true
   ```

6. The successor must acknowledge the exact handoff identifier. Only then does
   Forge seal the predecessor. Repeated watchdog ticks and restart recovery are
   idempotent.

Forge presses LM Studio's exposed **New** control, fills its exposed **Chat
input**, and presses **Send**. The visible chat uses the installed MCP tools in
the same way as an ordinary user-created chat. A deterministic nonce binds the
exact `get_forge_status` receipt to the handoff, while durable intent/submitted
state makes retry idempotent. This host action requires macOS Accessibility
permission and uses no `/api/v1/chat` integrations array or Forge-held LM Studio
credential.

## MCP surfaces

| Tool | Purpose |
|---|---|
| `get_forge_status` | Load registered project identity, query locations, available tools, and optional resume state without starting a run |
| `forge_status` | Compatibility alias for the same status contract |
| `session_checkpoint` | Durably update compact continuity state while work continues |
| `session_handoff` | Commit a resume-ready handoff and start automatic successor handling |
| `context_get` | Read the latest or named handoff |
| `context_list` | List bounded recent handoffs for the selected project |

All project-bound calls validate stable project identity and generation. With
multiple registered projects, callers pass `project_id` explicitly rather than
receiving another project's state.

## Durable packet

The current packet retains bounded task status, project identity, working-set
references, decisions, next actions, model narrative, and the exact handoff
identity. SQLite is authoritative. JSON, latest-pointer, and Markdown files are
rebuildable projections.

The handoff row and its pointer notes commit transactionally. Projection repair
rebuilds interrupted or older projections from the authoritative row. Content
and list sizes are bounded, and continuity arguments are redacted from ordinary
tool audit output.

## Automatic successor state machine

The Manager owns the countdown and successor transitions, independent of the
Continuity screen. A resume-ready handoff progresses through durable states for
countdown, successor creation, bootstrap submission, exact acknowledgement,
and predecessor sealing. The state machine preserves one successor identity so
retries cannot create an unbounded set of chats.

The V1 native adapter bounds active bootstrap ownership per instance and rejects
same-session intent replacement. After transport return it reacquires the row
and validates owner scope, status, handoff ID/digest and cancellation before
persisting acknowledgement. A late ACK cannot revive explicit cancellation.
Interrupted unacknowledged intent can retry after restart; changed content under
an acknowledged handoff ID requires a fresh ID. Existing V2 cancellation
contracts, ledger/schema and public fields are preserved.

Failure remains explicit and recoverable. Endpoint, authentication, model, MCP
integration, bootstrap, and acknowledgement failures retain the same handoff
identity and a bounded diagnostic instead of claiming rollover completion.

## Continuity view

The native Continuity view is intentionally limited to data management:

- a scrollable list containing only project IDs that have continuity data;
- single-project selection;
- **Copy Project ID**; and
- one confirmed **Delete** action for the selected project's continuity data.

The view does not expose checkpoint, rollover, successor, run-selection,
timeline, or recovery controls. Deleting the selected project entry clears its
continuity records and projections without deleting ordinary project files,
instruction packages, policy sources, credentials, or project memory.

Project reset, instruction-package deletion, and disposable-cache clearing are
separate controls on the Projects surface.

## Verification boundary

Deterministic tests cover durable handoff creation, the exact 30-second
boundary, single-successor idempotence, the LM Studio request contract,
exact-handoff acknowledgement, predecessor sealing, project isolation, and the
reduced Continuity UI. The later protocol fixtures verify bootstrap ownership,
late-cancellation fencing and cold restart retry. Ordinary LM Studio GUI rollover,
live threshold acceptance and actual GUI overlap remain unverified; these
fixtures do not establish live GUI behavior. The scoped current signed build,
identity, native Xcode and policy checks are recorded in the repair record;
current signed session-host acceptance and the complete owner-host flow remain
required.
