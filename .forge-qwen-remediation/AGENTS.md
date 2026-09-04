# Forge Conductor shippable-remediation execution contract

## Final objective

Produce a locally validated Forge Conductor for macOS release candidate that satisfies every mandatory gate in `plans/gates.json`, preserves every current feature, implements every planned capability the audit found missing or incomplete, closes every Critical and High finding, resolves or truthfully blocks every remaining release condition, and records:

```json
{
  "ready_to_ship": true,
  "shipped": false
}
```

Do not ship, publish, distribute, merge, push, tag, submit, notarize for distribution, or update a production release channel.

## Authoritative materials

This package is authoritative for the remediation run. Use:

1. the supplied current repository;
2. `audit/Forge-Conductor-Current-State-Audit.md`;
3. `plans/work-packages.json`;
4. `plans/gates.json`;
5. the continuity and E2 specialist designs;
6. accepted validator receipts bound to the exact current source manifest.

Do not rewrite the application. Consolidate the existing project-memory, continuity, process, manager, queue, provider, telemetry, Metal, and session-host primitives around the durable project-scoped manager control plane.

## Qwen Code operating contract

The intended implementation agent is Qwen Code using a locally served Qwen3.8-27B 4-bit model.

The model is a bounded implementation worker, not an authority for completion. Every invocation must:

- begin as a fresh headless session;
- read `QWEN.md`, `.forge-qwen-state/current-task.md`, and only the selected work-package card and referenced source;
- plan one coherent slice before editing;
- normally touch no more than six production files plus focused tests;
- use direct source inspection rather than assumptions;
- run the smallest relevant build or test scope;
- update `.forge-qwen-state/current-handoff.json` before ending;
- return the required JSON-Schema-constrained report;
- stop when the turn, wall-clock, tool, context, or slice boundary is reached.

Do not use the `agent` tool. Qwen Code's top-level tool cap does not bound inner subagent calls. Independent read-only review is performed by a separate bounded invocation through `run_qwen_review.sh`.

Managed Qwen auto-memory, auto-dream, auto-skill, and team-memory synchronization remain disabled. The remediation ledger, repository, test evidence, and Forge project memory are the only durable authority.

## Mandatory start sequence

From an installed repository:

```bash
python3 .forge-qwen-remediation/scripts/doctor.py --repo .
python3 .forge-qwen-remediation/scripts/statectl.py --repo . show
python3 .forge-qwen-remediation/scripts/select_next_work.py --repo .
python3 .forge-qwen-remediation/scripts/prepare_qwen_task.py --repo .
```

Work only on the selected ready package or an explicitly independent diagnostic. Do not jump to a later phase because it is easier.

## Evidence and gate rules

- A source change is not complete until the smallest relevant tests pass.
- A gate passes only when its registered validator creates an immutable receipt and `accept_gate_result.py` accepts it against the exact current source manifest.
- Qwen narrative output, structured output, a hash selected by the model, a code review, or a successful build cannot pass a gate.
- Build success is not runtime proof.
- `build-for-testing` is not an executed XCUITest.
- A synthetic provider is not real-provider rollover proof.
- Lower aggregate memory is not leak closure without the same-flow comparison, allocation evidence, and ownership proof.
- An unrelated SHA-256 is never completion evidence.
- A finding closes only through `close_finding.py` after every mapped gate has passed with current receipts.
- Product-source changes make previous final-qualification receipts stale.

Every accepted receipt must identify the project, project generation, run, work package, gate, validator ID and version, source manifest, command or native action, start/end times, exit/result status, artifacts, byte counts, and checksums.

## Feature preservation

Before modifying a feature surface, create or update parity tests. Existing MCP names, JSON fields, settings, defaults, migrations, accessibility identifiers, project formats, CLI commands, shell behavior, manager routes, and durable records remain compatible unless a versioned migration is implemented and tested.

The following are non-negotiable:

- `shell_exec` remains in MCP `tools/list`.
- `shell_exec` retains its established `/bin/bash -lc` compatibility behavior and result contract.
- Shell defaults enabled on clean install and after migration; explicit user opt-out is respected.
- `process.run`, `shell.run`, `bash.run`, `python.run`, `powershell.run`, and hardened XPC are additive.
- Failure to locate Python, PowerShell, an XPC helper, or a provider cannot disable native shell or Bash.
- Project memory remains isolated by exact project ID and generation.
- Managed autonomy continues with the GUI closed.
- Canonical project-scoped continuity is the only managed-mode authority.
- Legacy manual-new-chat continuity cannot block managed tools.
- Latest-value telemetry delivery remains bounded.
- Metal resources remain shared, paused when hidden, and rendered on demand.
- Every current application tab, MCP tool, manager route, migration, and supported project format remains present.

## Engineering constraints

- Production implementation remains native Swift/SwiftUI/AppKit/Metal/Foundation/Network/Security/SQLite3/XCTest.
- A small C interoperability target is permitted only for public Darwin filesystem APIs required by E2.
- A separately signed XPC helper is permitted and required where the plan specifies a real sandbox boundary.
- No Electron, web-shell replacement UI, Java application runtime, or interpreted production control plane.
- No unbounded queue, event table, cache, history, task creation, retry loop, process output, network read, render loop, package extraction, provider payload, or in-memory result set.
- No blocking process waits, database work, recursive traversal, provider calls, or compression work on the main actor.
- Every actor, task, timer, continuation, file descriptor, listener, connection, process, XPC connection, security-scoped lease, database handle, and Metal resource has one documented owner and shutdown boundary.
- Preserve irreversible results across cancellation and deadlines. Never report cancellation when an operation committed.
- Do not weaken, delete, skip, or relabel a failing test to pass a gate.
- Do not use environment limitations as passing evidence.

## Completion integrity

Remove `EvidenceBoundCompletionValidator` from production wiring. It may remain only as a migration reader or a regression fixture that proves rejection.

The model may request completion, but it cannot select evidence. The manager starts the registered deterministic validators for the package's declared gates. Only accepted validator receipts may transition a run, work package, finding, or release state.

The remediation ledger follows the same rule: `statectl.py` cannot set a gate to passed and cannot complete a work package with an open gate.

## Project and continuity authority

Every stateful operation is bound to:

```text
project_id
project_generation
client/session/run/job identity
authorization scope
```

Missing identity fails with `project_context_required`. Stale identity fails with `stale_project_generation`. There is no global latest-project or latest-handoff fallback for model bootstrap or tool authorization.

Managed rollover is complete only after:

1. threshold detection independent of model cooperation;
2. predecessor admission closure;
3. in-flight tool reconciliation;
4. durable project-scoped handoff;
5. fresh real-provider root;
6. exact acknowledgment of project, generation, run, operation, handoff, checksum, and nonce;
7. at-most-one accepted successor;
8. predecessor fencing and sealing;
9. automatic continuation;
10. crash recovery from every nonterminal state.

External MCP compatibility mode may prepare a handoff but must not claim that it created or continued a successor.

## E2 filesystem rule

A validate-then-mutate pathname sequence is forbidden for security-sensitive mutation. Use the specialist E2 atomic-capture design:

- descriptor-pinned roots and parents;
- no-follow and beneath resolution;
- atomic capture or publication as the linearization point;
- post-capture identity/content validation;
- exclusive restore or bounded quarantine on conflict;
- crash-recoverable durable transaction records;
- no internal shell command as a substitute for the secure filesystem primitive.

E2 remains open until the exact adversarial, crash, filesystem-capability, and outside-root tests pass.

## Qwen fail-forward policy

- Persist intent before an external or irreversible side effect.
- Use bounded retries, explicit deadlines, idempotency keys, and reconciliation.
- A failed Qwen invocation is not a failed remediation phase. Preserve raw output, stderr, exit code, source manifest, and handoff.
- After three no-progress slices, do not repeat the same command sequence. Isolate a deterministic reproducer, narrow the surface, or choose a reversible alternate design.
- If structured output is malformed, preserve raw output and produce a conservative handoff; do not infer success.
- If the local model server disappears, record a blocked environment prerequisite and continue host-independent validation through package scripts.
- A blocked native gate blocks local release readiness but not independent work.
- Never wait indefinitely and never require operator choice for an implementation detail resolvable from source, tests, or the contract.

## Publication and authorship

Use only the repository owner's configured human Git identity. Do not add generator credits, automated-author notices, co-author trailers, model names, tool names, or authorship watermarks to source, commits, branches, PR text, documentation, metadata, screenshots, artifacts, or release notes.

The `PreToolUse` guard is defense in depth. The instruction contract is primary. Do not bypass, edit, disable, or route around the guard.

## Final source-manifest rule

Before P14 completion:

1. freeze product source;
2. regenerate the source manifest;
3. rerun every mandatory validator on that exact manifest;
4. regenerate every finding closure;
5. build the private local release candidate;
6. create the local release-readiness attestation;
7. validate G20 against the candidate hash and attestation;
8. stop with `ready_to_ship=true` and `shipped=false`.

