# Qwen autonomous driver, recovery, and safety

## State directories

The installed package uses:

```text
.forge-qwen-remediation/   immutable operational design and scripts
.forge-qwen-state/         mutable run state, handoffs, logs, receipts, plans
.qwen/                     project-local Qwen Code settings
```

All are excluded from the product source manifest. Installation must not alter product source.

## Invocation records

Each plan, implementation, or review session writes:

```text
qwen-invocations/<number>-<kind>.stdout.json
qwen-invocations/<number>-<kind>.stderr.txt
qwen-invocations/<number>-<kind>-normalized.json
qwen-invocations/<number>-<kind>-record.json
```

The record includes:

- invocation number and kind;
- selected work package;
- before/after product source manifest;
- before/after authoritative state fingerprint;
- before/after handoff hash;
- raw output byte count and SHA-256;
- parsed structured result when valid;
- exit code and parse errors;
- ignored completion claims;
- `shipped=false`.

## Authoritative progress fingerprint

The no-progress detector ignores timestamps, chat logs, and handoff-only updates. It hashes:

```text
current_work_package
completed_work_packages
work_package_status
gate_status
gate_receipts
finding_status
open_findings
accepted evidence identifiers
```

A source change or a change to that fingerprint is progress. Rewriting the same handoff is not.

## Publication guard

`qwen_pretool_guard.py` evaluates shell commands before execution and rejects:

- `git push`;
- Git tags;
- remote add/set-url operations;
- PR creation or merge;
- release creation;
- package publishing;
- store submission;
- notarization upload/submission;
- `scp`, `sftp`, `rsync` to remote destinations;
- destructive repository cleaning or hard reset;
- broad destructive `rm`;
- commands that invoke alternate shells to bypass the same checks.

The guard does not disable shell. Normal builds, tests, local Git status/diff/commit, local signing, local archives, and local release-candidate creation remain available.

## Gate execution

The model never invokes an arbitrary command and labels it a gate. `run_ready_gates.sh` uses `plans/gate-validator-registry.json`. A validator:

1. checks prerequisites;
2. captures source manifest and environment;
3. runs its fixed command or native scenario;
4. verifies expected assertions and artifacts;
5. emits a schema-valid receipt;
6. signs the receipt with its content checksum;
7. submits it to `accept_gate_result.py`.

The acceptance script verifies gate ID, validator ID/version, source identity, artifact hashes, result, and current state.

## Crash and interruption recovery

The driver is restartable from disk. On restart it:

1. runs doctor;
2. validates the event chain;
3. reconciles the current work package;
4. loads the latest handoff;
5. checks whether the prior invocation left product changes;
6. runs focused tests or recovery commands before new edits;
7. creates a fresh Qwen session.

It never resumes an opaque long conversation as the source of truth.

## Provider outage

When the provider disappears:

- the active Qwen process exits within its wall/idle timeout;
- raw stdout/stderr and exit code are retained;
- no gate is passed;
- the current handoff identifies the interruption;
- host-independent validators and repository hygiene work may continue;
- provider-dependent gates remain blocked.

The package does not silently switch models.

## Completion and stop

When `verify_completion.py` returns ready:

- all work packages are complete;
- all findings have valid current closure receipts;
- all G00–G20 gates have current accepted receipts;
- the release readiness record points to the exact final source and local candidate hash;
- `verify_no_ship.py` proves no shipping marker or remote publication occurred.

The driver prints the local-readiness result and stops.

