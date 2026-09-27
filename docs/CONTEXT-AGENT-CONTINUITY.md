# Context and agent continuity (v0.15.0)

## Current workflow

Continuity belongs to the ordinary LM Studio conversation. It is automatic and
is not started from the Forge Conductor Continuity view.

1. The user opens a normal LM Studio chat and asks the model to call
   `get_forge_status`.
2. Forge returns the registered project identity plus the project-file,
   instruction-package, and continuity locations and query tools.
   `resume=true` requests the latest resume-ready handoff.
3. While working, the model can save compact checkpoints. At context pressure
   it saves a resume-ready handoff.
4. After the durable handoff commit, Forge shows a 30-second countdown on the
   Dashboard.
5. At expiry the Manager creates exactly one stored successor chat through LM
   Studio's supported stateful-chat API and submits the exact bootstrap input:

   ```text
   get_forge_status
   resume=true
   ```

6. The successor must acknowledge the exact handoff identifier. Only then does
   Forge seal the predecessor. Repeated watchdog ticks and restart recovery are
   idempotent.

LM Studio documents that `POST /api/v1/chat` creates a stored stateful chat and
supports installed MCP integrations. Its public API does not promise that an
API-created chat becomes the foreground GUI tab. Forge does not use unsupported
private UI automation to make that claim.

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
reduced Continuity UI. Shipment still requires the current candidate to repeat
the complete flow against the owner's running LM Studio configuration.
