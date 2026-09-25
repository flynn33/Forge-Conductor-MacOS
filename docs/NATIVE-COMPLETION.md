# Completion evidence and instruction-package requirements

Product identity: **0.14.4, build 10**.

Completion is owned by two explicit sources:

1. Forge's built-in evidence checkboxes, selected in **Autonomy → Start Task**.
2. Additional requirements declared by the exact instruction package bound to
   the run.

Instruction-package requirements are displayed read-only and are supplied
exclusively by the exact bound package. Forge configuration exposes only the
recognized built-in checks.

## Built-in completion checks

The native Autonomy sheet exposes six selectable checks:

- **Buildable project**
- **No build errors**
- **No build warnings**
- **Available tests pass**
- **Instruction packages complete**
- **No unresolved operations**

These stable selections compile into a deterministic Manager-owned completion
plan. Project structure and the task class may also add the minimum automatic
obligations needed to prove that the instruction artifact remains registered,
that a requested read-only report was delivered, and that relevant side effects
are reconciled.

The plan is bound to the project identity and generation, instruction-artifact
digests, provider/configuration revision, resolved capabilities, and run. Start
revalidates those inputs before it persists a task.

## Instruction-package ownership

The package schema retains the field name `completion_gates` for wire and file
compatibility. Its values are instruction-package completion requirements.

When the Manager prepares a package-backed task, it copies the package's exact
ordered identifiers into the immutable run artifact. They remain read-only in
Forge configuration and are evaluated from durable run evidence.

## Evidence evaluation

Only durable, run-bound evidence can complete the automatic plan. The Manager
pages bounded invocation and instruction-delivery records and considers the
latest relevant result for each typed obligation:

- a successful build can supersede an earlier relevant build failure;
- a warning-free result requires complete, non-truncated build output;
- a test obligation requires a successful, non-skipped relevant test result;
- instruction delivery uses the durable artifact-delivery journal;
- unresolved, ambiguous, interrupted, timed-out, or truncated effects remain
  unresolved;
- an unrelated successful read cannot prove a build, test, or repair task.

The model cannot mark its own prose as authoritative completion evidence.

## Autonomy recovery

The running-task view labels this section **Completion evidence**. It shows
built-in and package-owned requirements as a read-only record, including passed
state where available.

If evidence is not yet sufficient, Forge preserves the task and its completion
request. Correct the named project output or instruction result, then choose
**Retry** when that control is available; otherwise Forge re-evaluates when the
running task next requests completion. Provider waits route to **Provider →
Connect and Check** and resume the retained task when the provider is ready.

## Safety and compatibility boundary

- Completion requirement identifiers remain bounded, unique, and validated.
- Package requirements can enter only through the exact prepared artifact.
- Built-in configuration choices cannot widen project, tool, network, or shell
  authority.
- Completion history and evidence references remain project/run scoped.

The root `VERSION`, `BUILD_NUMBER`, Xcode build settings, protocol constants,
and version assertions use `0.14.4 (10)`. Source and deterministic test evidence
do not by themselves qualify an installed app, Developer ID artifact,
notarization, Gatekeeper acceptance, or shipment.
