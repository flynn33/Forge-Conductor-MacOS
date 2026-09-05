# Context & Agent Continuity (v0.9.0)

## Summary

Operator walkthrough: [USER-GUIDE.md](../USER-GUIDE.md).

Forge Conductor preserves **context handoff** and **agent session continuity**
for externally owned LM Studio chats over the existing **stdio MCP** server
(`serve`). Managed Autonomy is a separate manager-owned provider path: the
persistent manager owns provider turns, context accounting, fresh-root
rollover, and automatic continuation while the GUI is closed.

## Product constraints

- Dependency-free (Foundation + system SQLite only)
- Same Mac app auto-deploy path (`LMStudioDeployService` / mcpBridge)
- Work developed in this repository; does not alter a running install until the operator deploys the next build

## Surfaces (stdio MCP)

| Tool | Purpose |
|------|---------|
| `session_checkpoint` | Soft save: write/update handoff packet; continue working |
| `session_handoff` | Finalize packet; mark resume-ready; return seed for new chat |
| `context_get` | Load latest (or id) packet for bootstrap in a new chat |
| `context_list` | List recent handoffs |

`forge_status` reports `continuity` (latest handoff id, resume_ready, open agent sessions).

## Packet (`schema_version: 1`)

- **meta** — id, timestamps, source (`model` \| `budget` \| `user`), chat_label, client_id
- **task** — goal, status, project_slug, cwd, blockers, next_actions
- **working_set** — key files / decisions
- **agents** — open sessions with session_id, agent_id, goal, cwd, status (reattach instructions)
- **narrative** — capped free text
- **resume** — bootstrap string, custom-seed marker, and continuation instructions

Durable copies:

- SQLite `context_handoffs` (authoritative, transactionally ordered by write sequence)
- SQLite `memory_notes` pointers `continuity/latest` and `continuity/resume_ready`
- `memory/handoffs/<id>.json`
- `memory/handoffs/LATEST`
- Projection into `memory/current-task.md`

Primary and fallback MCP processes serialize continuity mutations through a
home-scoped lock. A handoff row and its SQLite pointer notes commit in one
transaction. JSON and Markdown are rebuildable projections; bootstrap repairs
them from SQLite after an interrupted or older-version write.

## Triggers (hybrid)

1. **Model** — calls checkpoint/handoff tools
2. **Budget** — ToolRouter tracks canonical consecutive tool fingerprints. The fourth identical call writes a soft handoff signal; the ninth is blocked with `identical_call_loop`. Continuity calls do not count toward the loop.
3. **External MCP compatibility** — `ContinuityAutomation` retains the legacy
   progress-tool/time fallback for a chat Forge does not own. It can persist a
   resume-ready handoff and fence that external client, but cannot claim an
   automatic successor.
4. **Managed provider** — the persistent manager records provider-reported
   capacity and usage, calculates explicit reserves, and triggers a fresh-root
   rollover without waiting for a model continuity-tool call. After exact
   acknowledgment it fences the predecessor and issues the successor's
   continuation automatically.

## Manager-owned provider path

The established external MCP handoff path remains available: Forge returns a
`resume_seed`, and an operator can start a new LM Studio GUI chat and call
`context_get`. The current source also implements manager-owned provider
session creation through the native session-host adapter, persisted successor
and fencing state, automatic-continuation records, and provider receipt
recovery. Those implemented surfaces are not, by themselves, proof of a
qualified autonomous rollover.

Accepted provider receipts survive manager restart. When a provider response is
unresolved after a crash, the request is fenced for **660 seconds** before a
retry may proceed. LM Studio exposes no request-ID receipt lookup, so each retry
attempt can create at most one duplicate model inference and repeated operator
or recovery retries can repeat inference. Manager tool-effect reconciliation
prevents the same reconciled tool effect from executing twice. This is
mitigation, not elimination of the provider-response race.

Release qualification still requires one threshold-forced manager-owned run
against the real provider that proves exact successor acknowledgment,
predecessor fencing and idempotent sealing, automatic continuation, GUI-closed
operation, and recovery from every durable crash state. Unit and synthetic-host
tests do not satisfy that boundary.

The native **Provider** screen creates and updates validated, revisioned
endpoint/model settings through authenticated manager routes. Credentials can
be kept, replaced, or cleared; replacement tokens are stored in Keychain and
are not returned in snapshots. **Save** persists settings even while LM Studio
is offline. **Refresh Models**, **Test Connection**, and **Run Contract Probe**
use the saved configuration; load models in LM Studio itself. See the
[provider workflow](../USER-GUIDE.md#configure-the-managed-provider).

Separate native onboarding tests passed offline save/rejection/manager
replacement and real-provider discovery/connection. These configure and probe
the provider; they do not prove autonomous rollover. The retained final
manager-owned run failed before an accepted bootstrap receipt and did not reach
the intended injected crash. A smaller passing fresh-root/continuation
diagnostic remains supporting evidence, as recorded in the
[shipping checkpoint](../.forge-codex/state/release-handoff.md#retained-qualification).
See [qualification status](QUALIFICATION-STATUS.md) for the current summary of
retained local and CI results.

## Bootstrap (new chat)

1. Enable `mcp/forge-conductor` (or fallback)
2. Call `context_get` (or read `forge_status.continuity`)
3. Reattach agents via `agent_run_status` / complete+restart as needed
4. Continue task from the packet
5. Pass the returned `handoff_id` to later checkpoints or handoffs so the resumed packet is updated explicitly

`agent_run_status(session_id)` transfers an open session binding to the calling
MCP client and restores its goal, workspace, tool policy, and output contract.
Only sessions owned by the calling client are included in new packet snapshots.

Packet identity and schema metadata are validated before projection. Narrative
text is capped at 4,000 characters, list limits are clamped to 1–100, and
continuity content is redacted from tool-audit arguments.
