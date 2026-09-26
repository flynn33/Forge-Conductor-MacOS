# Provider integrations

Product identity: version **0.14.7**, build **13**. This document describes the
implemented integration contract; qualification remains evidence-bound per
host.

Forge Conductor supports one selected provider at a time. The **Provider** tab
is the control surface for all four visible integrations. Turning on a
selectable provider's toggle provisions or verifies its Forge-owned integration
before changing the durable selection. Turning on a different provider replaces
the selection. Turning off the active selector does not create an empty
selection; choose another provider to switch. An installed integration may
remain configured while inactive. The selectable providers in 0.14.7 are LM
Studio, Claude Code Desktop, and Codex Desktop. Grok
Build remains visible but non-selectable.

A desktop provider with a nonterminal task cannot be replaced, repaired, or
removed. Finish or cancel that provider's tasks in **Projects → Run Details**
first; Forge fails the integration request closed rather than mutating the
hook path of an active desktop session.

## Provider contract

| Provider | Stable ID | Execution strategy | Responsibility |
| --- | --- | --- | --- |
| LM Studio | `lmstudio` | `managed_provider_push` | Forge sends bounded managed-model turns to the saved LM Studio endpoint and owns the managed run lifecycle. |
| Claude Code Desktop | `claude-desktop` | `desktop_plugin_pull` | Claude owns the model and desktop session; its Forge plugin, hooks, and MCP registration connect that session to Forge orchestration. |
| Codex Desktop | `codex-desktop` | `desktop_plugin_pull` | Codex owns the model and desktop task; its Forge plugin, hooks, and MCP registration connect that task to Forge orchestration. |
| Grok Build | `grok-build` | Deferred; non-selectable | Visible for Forge-owned artifact cleanup and forward compatibility. Forge does not admit Grok runs or report Grok ready in 0.14.7. |

The selectable desktop providers are not alternate model APIs inside Forge. Forge does not
send their prompts, select their model, create a private desktop conversation,
or automate their user interface. A desktop-bound run records
`desktop_plugin_pull`, a `host-selected` model, the exact provider-selection
revision, and the verified plugin deployment identity. LM Studio runs record
`managed_provider_push` and continue through Forge's native managed-session
adapter.

Grok's current documented hook contract is insufficient for Forge assignment
ingress: output from passive startup hooks does not affect model context, and
the prompt-submit hook's stdout is discarded. Installing or discovering a Grok
package therefore cannot establish that Forge's initial project assignment
reached the model. Forge fails closed instead of converting package presence
into a false ready or run state.

## Run admission and continuity ownership

Autonomy preparation resolves the selected provider through the same durable
selection snapshot used by Provider. A desktop-bound descriptor records the
selection revision, verified deployment identity, `desktop_plugin_pull`, the
provider-specific adapter identifier, and `host-selected`. A changed selection
or deployment revision makes the preparation stale before a run is admitted.
An absent or unverified desktop receipt routes recovery back to Provider rather
than silently falling back to LM Studio.

For LM Studio ordered work, admission performs a fresh no-resume preparation
before changing queue state or creating a run. A saved model key alone is not
readiness: the endpoint must be reachable, the exact pinned model must be loaded,
and its current tool contract must pass. A failed check returns its exact
corrective action and leaves the package queued. Provider repair resumes only
waiting runs from each project's active generation; durable prior-generation
runs remain history and cannot interrupt current recovery.

LM Studio runs enter Forge's managed provider-push coordinator and native
session-host rollover flow. Desktop-bound runs never enter that coordinator,
including after Manager restart or an operator resume. The desktop host owns
its conversation. Forge continuity state remains available through the
project-scoped MCP tools and the authenticated hook context; checkpoint and
handoff behavior therefore occurs at the host/plugin boundary rather than by
Forge creating or replacing a private desktop conversation.

## What Connect and Check does

Every selectable provider card exposes one **Connect and Check** action. On an
inactive card it performs the complete revision-fenced, idempotent activation
operation and selects the provider only after readiness. On the selected LM
Studio card it repeats inventory and contract verification; on a selected
desktop card it verifies or repairs the Forge-owned integration:

1. Inspect the host and any existing Forge-owned package and registration.
2. Verify the same-build `forge-conductor` bridge.
3. Stage deterministic plugin, hook, skill, and MCP files when provisioning is
   required.
4. Commit only Forge-owned files and compatible settings entries, with rollback
   if a commit or verification step fails.
5. Use the host's supported CLI when it is available. A nonzero mutation result
   is accepted only for a narrowly recognized already-present outcome and only
   when a later live inventory call independently verifies the exact enabled
   plugin; timeouts, truncation, and ambiguous output fail closed.
6. Change the durable selection only after provisioning reaches a usable state.

The previous selection is retained when provisioning fails or requires a
separate user action. The UI shows the bounded operation state, resumes polling
after a lost mutation response, and supports cancellation while the operation
is cancellable. Selection state, recent operations, and redacted receipts are stored under
`~/.forge-conductor/managed-providers/`; credentials and raw CLI arguments are
not written to those receipts.

For LM Studio, retained provider-wait runs are not resumed by the initial
readiness probe. Forge first completes the integration deployment—which may
restart LM Studio—then performs a fresh readiness check and resumes those exact
runs. The Manager also owns a bounded fallback so closing the Provider view
cannot leave a successful deployment permanently suspended.

Managed LM Studio response receipts are bounded to 1,024 records. This retains
two complete receipt windows for the supported maximum of 16 concurrent runs
and 32 managed tool rounds while allowing terminal history to compact. The byte
ceiling remains 32 MiB. Restart replay therefore retains round zero for an
active maximum-round run without creating an unbounded ledger.

One context-budget request keeps the same continuity operation identity if its
severity escalates from checkpoint to rollover or emergency. The durable
operation remains bound to its original checkpoint observation, while the newer
request severity controls the next action. Cancelling a managed run quarantines
that exact operation and handoff as `run_cancelled` history before the run
becomes terminal. Recovery may clear an older stranded operation only after the
control-plane repository proves its exact owning run is terminal; otherwise the
project-wide continuity fence remains closed.

LM Studio has the same activation toggle as the selectable desktop hosts. Turning it on
runs the manager-owned **Connect and Check** workflow first and selects
`lmstudio` only after the exact saved configuration has a current readiness
receipt. Its activation uses the existing transactional primary, fallback, and
continuity MCP deployment; endpoint, exact model, credential, inventory, and
contract-probe controls remain under **LM Studio Advanced**.

An in-flight replaceable Provider snapshot load no longer swallows LM Studio
activation. The activation cancels that load, performs **Connect and Check**,
and proceeds through the same revision-fenced selection transaction.

The Grok Build card's activation toggle is disabled. Existing Forge-owned Grok
artifacts may be inspected or removed, but validation, enablement, or package
presence does not make Grok selectable.

## Dashboard and Guided Setup readiness

Dashboard and Guided Setup project the durable selected provider, not LM Studio
health as a universal prerequisite. LM Studio readiness continues to require
its reachable or contract-valid managed endpoint. Claude or Codex can display
**HOST READY** independently of LM Studio only when all of these agree:

1. the selected provider is selectable;
2. its verified deployment receipt is present;
3. no provider mutation is in flight;
4. Manager preparation reports `ready` for that exact provider; and
5. the preparation revision matches the current selection revision.

Missing integration evidence, a stale revision, a missing receipt, or a
non-selectable provider fails closed. Guided Setup keeps the provider step open
and Dashboard routes the operator to **Provider** rather than borrowing LM
Studio's health or showing a false ready state.

## Installed files and host configuration

All generated packages use the plugin name `forge-conductor`. Forge validates
the complete expected file set, rejects symbolic links and foreign ownership
conflicts, and preserves unrelated settings entries.

### Claude Code Desktop

- Forge stages a local marketplace at
  `~/.forge-conductor/managed-providers/desktop-provider-plugins/claude-marketplace/`.
- The plugin package is the marketplace's
  `plugins/forge-conductor/` child and contains
  `.claude-plugin/plugin.json`, `hooks/hooks.json`, the `forge-run` skill, and
  `.mcp.json`.
- Forge merges a directory marketplace and enabled-plugin entry into
  `~/.claude/settings.json` without replacing unrelated settings.
- When the `claude` CLI is available, Forge uses its supported validate,
  marketplace-add, install, and JSON list commands, and requires the exact
  Forge plugin to be enabled in that live inventory. Otherwise the operation
  reports the remaining desktop reload/activation action.
- Claude's permission and hook-trust review remains a user decision. Forge does
  not manufacture trust or approve a prompt.

### Codex Desktop

- Forge writes the Codex-compatible plugin to `~/plugins/forge-conductor/` with
  `.codex-plugin/plugin.json`, `hooks/hooks.json`, the `forge-run` skill,
  `.mcp.json`, and a bounded executable runtime closure.
- When provisioning from the signed Xcode app, that closure contains the signed
  manager helper, runtime launcher, and Core framework files needed by the
  copied bridge. The active compatibility registration names the signed app
  helper by absolute path because Codex `0.155` does not resolve a contained
  relative MCP command from its legacy manifest.
- Forge merges the local source `./plugins/forge-conductor` into the personal
  marketplace at `~/.agents/plugins/marketplace.json`.
- When the `codex` CLI is available, Forge uses the supported plugin add and
  JSON list flow, and requires the exact Forge plugin to be enabled in that live
  inventory. Otherwise the operation reports the remaining desktop restart
  action.
- Codex hook trust remains explicitly user-reviewed. Installing the package is
  not a trust decision, and Forge never marks an unreviewed hook trusted.

### Grok Build

- The descriptor and ownership rules remain available so Forge can recognize
  and clean up Forge-owned artifacts under `$GROK_HOME/plugins/forge-conductor/`
  (or `~/.grok/plugins/forge-conductor/` when `GROK_HOME` is unset).
- A legacy or staged package may contain `plugin.json`, `hooks/hooks.json`, the
  `forge-run` skill, and `.mcp.json`; those files are not readiness evidence.
- Generated compatibility hooks use Grok's documented passive event set and do
  not emit a permission decision for an event Grok does not support.
- The card is non-selectable and run admission rejects `grok-build`. Forge does
  not represent CLI validation, enablement, or inventory presence as live
  assignment support.

### LM Studio

LM Studio keeps its established deployment paths:

- `~/.lmstudio/mcp.json`
- `~/.lmstudio/extensions/plugins/mcp/forge-conductor/`
- `~/.lmstudio/extensions/plugins/mcp/forge-conductor-fallback/`

The provider contract now preserves an explicit versioned endpoint mode. Old
configuration decodes as `local`; the new `linked` form identifies a paired
node and requires HTTPS. This release slice supplies only the strict shared
types and owner-only paired-node registry. It does not yet add discovery,
pairing transport, a Linux companion, or a Provider control for remote nodes,
so no linked endpoint is represented as ready or selectable.

See [LM Studio connection](LM-STUDIO-CONNECTION.md) for its role-specific
deployment, verification, and recovery contract.

## Hook and MCP safety

Each desktop package invokes the same-build executable as:

```text
forge-conductor provider-hook <provider-id> <event> --home <forge-home>
```

For selectable desktop hosts, the bridge accepts bounded JSON from documented
hook events, forwards it only to the authenticated loopback Manager endpoint,
rejects redirects and non-loopback configuration, and returns bounded
host-compatible JSON. Supported Claude/Codex session-start and prompt-submit
hooks add a short orchestration/MCP context message. Forge never
returns an automatic allow decision for tool use or a permission request.

Successful trusted Codex `PostToolUse` events for tools already present in the
run's frozen allowlist are retained as a bounded deduplicated set. That evidence
can satisfy the corresponding compiled read-only completion obligation after
the host submits the exact completion marker; unknown or disallowed host tool
names are ignored.

When a desktop provider is inactive, its hook denies only a Forge MCP tool call
at `PreToolUse`; unrelated host tools remain under the host's own policy. If the
Manager or local hook policy is unavailable, the same narrow Forge-MCP
`PreToolUse` boundary fails closed while unrelated hook events return no policy
decision. This prevents an inactive or unverified desktop session from using
Forge project tools without taking over the host's general permission system.

The plugin's MCP entry starts
`forge-conductor serve --home <forge-home> --desktop-provider <provider-id>`
over stdio, using the same explicit canonical Forge home as its hooks. The
command-line provider role is immutable; an environment variable or generic
`serve` process cannot acquire it.

That process starts without project authority. Session-start and prompt-submit
assignment context directs the model to call `desktop_run_attach` first with a
hook-issued capability. The raw 256-bit token is returned only in that bounded
assignment, while Forge persists its digest. It expires after five minutes, is
single-use, and binds the exact provider, session, run, project UUID and
generation, selection revision, and verified deployment. Atomic consumption
binds the MCP client to the run's frozen authorization scope. All other Forge
tools fail closed before attachment; copied, changed, expired, replayed, or
cross-provider/run/project/session identities are rejected.

Issuing a newer assignment replaces the prior attachment for that run. Session
end, manager restart recovery, terminal run state, or run deletion revokes and
bounds the attached client records. After a successful attachment, the process
exposes the same project-scoped, authorized, bounded tool surface as other
Forge MCP clients; plugin installation does not expand project roots or bypass
shell, filesystem, completion, memory, or continuity checks.

## Repair, deactivate, and remove

- **Connect and Check** on the selected desktop provider re-inspects and
  transactionally regenerates its Forge-owned package and compatible
  registration when repair is needed.
- The active selector cannot be turned off into an empty selection. Select
  another provider to run its readiness-fenced activation and switch atomically;
  verified packages and redacted receipts remain available for later reuse.
- **Remove Integration** is available only while that provider is inactive. It
  removes only packages, receipts, and settings entries that Forge can prove it
  owns; a malformed or foreign conflicting entry is refused rather than
  overwritten. Host-owned caches, conversations, credentials, and unrelated
  plugins are outside this operation. Forge does not infer that a host
  registration disappeared merely because source files were deleted. If the
  supported host CLI or live inventory cannot verify unregister, the operation
  reports **Awaiting User Action** and preserves Forge-owned files and its
  receipt. After manual host removal, retrying inventory verification settles
  idempotently.

Selection, repair, and removal remain fenced while the affected desktop
provider has a nonterminal task or another provider mutation is still in
flight. Exact idempotent replays remain safe.

Restart recovery marks an interrupted operation honestly and retains the prior
selection. A receipt proves the installed artifact identity at its verification
boundary; it does not claim that a desktop application is currently open or
that a human has accepted its trust prompt.

## Qualification boundary

Deterministic tests can prove package contents, supported settings merges,
ownership refusal, rollback, bounded ledger recovery, revision fencing,
authenticated loopback transport, host-compatible hook responses, exact
attachment/replay fencing, project-scoped tool access, cleanup, and Manager
route behavior. A canonical Xcode build proves those files are in the native
product graph. Neither result proves that a particular desktop application is
open, has reloaded or enabled the package, has presented or accepted its trust
prompt, or has completed a live project-scoped session. Record live evidence
separately for Claude and Codex; a pass for one host does not qualify the other.
Grok requires a future supported assignment-ingress contract plus new
deterministic and live evidence before it can become selectable. See
[Qualification status](QUALIFICATION-STATUS.md).
