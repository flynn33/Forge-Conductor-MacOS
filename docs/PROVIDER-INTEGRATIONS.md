# Provider integrations

Current source identity: version **0.16.5**, build **26**. Qualification remains
evidence-bound per host and candidate.

## Current provider workflow

Forge Conductor supports one selected provider at a time. The selectable
providers are LM Studio, Claude Code Desktop, and Codex Desktop. Grok Build is
visible only for Forge-owned artifact cleanup and forward compatibility; it is
not selectable.

For LM Studio, selecting the provider, choosing **Connect and Check**, using the
Advanced connection check, and invoking the probe all use the same Manager
preparation contract. None of those actions starts or resumes a Managed Run.

The preparation contract:

1. authenticates to the running Forge Manager;
2. loads the saved LM Studio endpoint; the same-host local path carries no LM
   Studio credential, while linked HTTPS endpoints may use one;
3. uses the supported `lms` command-line interface for bounded local-server
   discovery or recovery when the endpoint is offline;
4. fetches bounded model inventory;
5. resolves the exact configured model or the only compatible loaded model;
6. validates the model's current tool contract; and
7. saves a revision-bound readiness receipt.

Transport or Manager-authentication failures are reported separately from LM
Studio endpoint, inventory, model, or tool-contract failures. A failed check
does not manufacture a ready state.

## LM Studio conversation ownership

LM Studio owns the user-visible conversation. The user starts work in the
normal LM Studio chat interface and asks the model to call
`get_forge_status`. Forge supplies project-scoped instructions, files, memory,
policy, continuity, and tools through its installed MCP integration. Forge does
not expose a primary Managed Run action for this workflow.

When a model commits a resume-ready handoff, the Forge Manager owns the durable
30-second successor state machine. At expiry it activates LM Studio and uses
the app's public macOS Accessibility controls to create one visible foreground
successor, then submits:

```text
get_forge_status
resume=true
```

Completion requires an exact nonce-bound acknowledgement from
`get_forge_status` in that GUI chat. Durable intent/submitted state prevents a
retry from opening another successor. The GUI uses the installed MCP
registration directly; Forge sends no `/api/v1/chat` integrations array and
stores no same-host LM Studio credential.

## Desktop-provider integrations

Claude Code Desktop and Codex Desktop own their model and conversation
sessions. Forge provisions only its supported plugin, hook, MCP, and
project-scoped authorization artifacts. The host remains responsible for model
selection, permission prompts, activation, and any required reload.

Project scope identifies and generation-fences the durable work; it does not
confine native filesystem, Git, or shell paths. Each provider-launched Forge
process receives only the macOS access granted to its responsible signed host
and executable. Full Disk Access is a macOS TCC grant, not a Forge entitlement,
and the affected applications must be relaunched after that grant changes.

Forge never treats installation-file presence alone as proof that a desktop
integration is active. Provisioning and repair are transactional for
Forge-owned files and compatible settings entries; ambiguous host output,
timeouts, truncation, or failed inventory verification remain explicit.

## Stored configuration and credentials

Provider configuration and redacted readiness receipts are bounded under the
Forge application home. The same-host local path has no operator credential
control, never accepts a replacement token, and migrates an obsolete local
Keychain reference to a cleared state. Linked HTTPS provider tokens remain in
Keychain and are not returned in snapshots or written to receipts.

Saving configuration does not require LM Studio to be online. **Connect and
Check** is the operation that establishes current live readiness. Forge does
not scan arbitrary ports or load a model without the user's LM Studio action.

## LM Studio MCP deployment

Forge installs primary, fallback, and CLU MCP roles that resolve to the same
versioned `forge-conductor` executable and resource bundle. Deployment stages
the complete runtime before atomically changing the live registration. Doctor
reports stale, missing, or mismatched roles and does not treat an older binary
as current merely because it launches.

All roles use project identity and generation fences. CLU receives the ordered
Development Policy, monitors model observations, keeps separate bounded logs
per project, and sends a structured violation notice containing the violated
policy identity and applicable policy content.

## Repair, deactivation, and removal

Forge modifies only artifacts and compatible settings entries it owns. A
different selected provider is committed only after its verification succeeds.
Removing a desktop integration is fail-closed when the host cannot verify that
registration is gone; the UI reports the required user action instead of
claiming success from deleting source files alone.

Provider mutation uses revision fencing and bounded polling. Closing the
Provider screen does not cancel Manager-owned preparation, and reopening it
reconciles the durable operation state.

## Qualification boundary

A deterministic test proves only the tested request and state transition. A
source build proves compilation. Release acceptance separately requires the
current signed candidate to pass provider selection, **Connect and Check**, the
Advanced check, probe, ordinary LM Studio MCP use, CLU delivery, and automatic
successor rollover against the owner's actual running configuration.
