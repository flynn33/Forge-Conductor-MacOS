# D — Exercise the application people will actually use

**Goal:** actual successful product behavior, not another layer of empty scenario declarations.

## Reuse current machinery

Read the existing P10 feature baseline, required assertions, evidence schema and `qualify_p10_features.py` interface. Implement missing scenarios in that system. Reuse `record_command.py`, the signed shell/manager qualifier, native tests, and filesystem qualifier rather than creating a second recorder or gate registry. Inspect each script's `--help` and source before invoking unfamiliar options. Never assume a template already performs a test.

The audit found a registry count of 104 features / 259 assertions and zero implemented production scenarios. Verify the current counts; do not hardcode those numbers as a permanent goal. Cover every required assertion in the current approved contract. A single end-to-end scenario may cover multiple assertions when each has a concrete observed postcondition.

## Required scenario families

| Family | Concrete behavior and negative coverage |
|---|---|
| First use and onboarding | Install the coherent signed artifact; actual folder picker authorizes a fixture root; save provider configuration through native controls; invalid root/provider/credential produces actionable failure without corrupting prior state. |
| LM Studio MCP | GUI deployment preserves unrelated registrations, writes/verifies the expected revision, smokes both primary/fallback servers, and exposes compatible tool schemas. Test response loss/reload failure/rollback. Do not destroy unrelated chats. |
| Shell and jobs | Native Settings disable denies execution; native re-enable succeeds; `shell_exec` preserves login Bash, output/error/result shape, timeout/cancellation and authorization. Repeat after GUI restart and real manager PID replacement. Verify durable `bash.run` separately, not as a replacement. |
| Projects and memory | Project identity/generation/root binding, cross-project denial, memory CRUD/search/batch/import/export as promised, bounded results, restart persistence and migration/recovery. Preserve legacy tools. |
| Managed continuity | Real provider run crosses a deliberately small supported context threshold; exact durable handoff is loaded/acknowledged by the successor; predecessor is fenced/sealed; run continues with GUI closed and through every durable crash state. |
| Native control surface | Rig, MCP, Agents, Tools, Feed, Projects, Autonomy, Continuity, Runtimes, Provider, Evidence, Diagnostics, Manager and Settings all navigate and perform their documented actions. Check errors, cancellation and relaunch, not screenshots alone. |
| Protected filesystem | Work order C signed matrix, both successful supported operations and denied adversarial cases, recovery and service lifecycle. |
| Installation and resources | Clean install, current-version upgrade, manager/CLI/launcher matching identities, app open/close ownership, bounded background work, hidden-gauge quiescence, cancellation cleanup, and representative hardware. |

## Real-provider rollover proof

Use the actual manager-owned execution path and the installed supported LM Studio model. Record provider/model/server versions and effective context budget; lower the budget through a supported configuration/test control, not by fabricating a receipt. Use a deterministic harmless fixture task with a uniquely recorded tool effect. Prove automatic rollover without an operator opening a new chat, successor acknowledgment of the identical handoff ID, sealed predecessor inability to mutate, and resumed progress with the GUI closed.

Kill/restart at each durable state, include response loss and repeated recovery, and verify no duplicate tool effects or lost committed work. Keep the documented distinction between duplicate model inference and duplicate tool execution: the adapter's 660-second uncertainty fence and absence of provider request-receipt lookup do not prove exactly-once inference. Do not shorten the fence just to make a test pass; use explicit bounded test-only timing control only for supporting deterministic tests, plus an honest real-policy runtime case.

## Native execution and performance

Use XCTest/XCUITest and the supported native process/service interfaces. Do not substitute private UI automation or a deterministic panel hook for production `NSOpenPanel` observation. Do not disable TCC or protected platform controls. A denied required consent is a recorded blocked scenario, not a pass. Where macOS owns an approval dialog, perform the minimal owner-mediated action and retain product-side evidence; continue other tests while blocked.

Run Address Sanitizer and Thread Sanitizer separately. Use Release for performance/resource measurements. Compare repeated visible/hidden/minimized/app-closed flows, idle/load transitions, manager restart, and cancellation using the same fixture and measurement duration. Use the repository's existing resource budgets and physical-hardware matrix; do not invent an easy threshold or claim one 128 GB Mac represents every supported machine. A genuinely owner-deferred hardware gate remains visible and unpassed unless satisfied or explicitly re-scoped by the owner.

## Evidence acceptance

Each scenario must record source/artifact identity, configuration and environment, command/driver, exact executed assertion IDs, observed outcomes, raw artifacts, duration, selected/executed/skipped counts where applicable, cleanup, and exit status. Reject zero-test selections, truncated required logs, synthetic success, missing screenshots/traces where required, stale builds, and status-only Boolean rows.

Fix product defects and rerun affected scenarios. Keep unexecuted and blocked separate. A process alive for five seconds is not a native feature pass. A test runner returning zero after selecting zero tests is a failed proof. Do not promote partial old shell/XCUI records to complete current qualification.
