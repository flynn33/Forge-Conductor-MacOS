# Qwen Code 3.8 27B 4-bit execution profile

## Purpose

This document defines how the remediation program is executed by Qwen Code with a locally served Qwen3.8-27B 4-bit model. It changes the implementation-agent workflow, not the Forge Conductor target architecture, findings, work-package dependencies, or release gates.

## Core decision

Do not attempt to solve P00–P14 in one conversation. Use fresh headless sessions and durable repository state.

The Qwen model receives only:

- the compact root `QWEN.md`;
- `.forge-qwen-state/current-task.md`;
- one work-package card;
- the current durable handoff;
- the source files and evidence explicitly referenced by that card;
- one JSON output schema.

This keeps the working set bounded and prevents stale narrative context from becoming authority.

## Two-pass slice

Every implementation slice has two independent sessions.

### Pass 1 — read-only plan

Qwen Code runs with:

```text
approval mode: plan
fresh session: yes
agent tool: excluded
maximum session turns: 8
maximum wall time: 12 minutes
maximum top-level tool calls: 12
structured schema: qwen-slice-plan.schema.json
```

The plan identifies the exact files, tests, risks, rollback, and stop condition. The normal production-file limit is six. Broader changes require an explicit atomicity justification.

### Pass 2 — implementation

A new session runs with:

```text
approval mode: yolo
fresh session: yes
agent tool: excluded
maximum session turns: host profile
maximum wall time: 45 minutes
maximum top-level tool calls: host profile
structured schema: qwen-invocation-result.schema.json
```

The implementation session may edit and test one coherent slice. It may not pass a gate. It must update the durable handoff.

## Why subagents are disabled

Qwen Code's top-level tool-call limit does not necessarily count tool calls performed inside an agent/subagent. A subagent could therefore exceed the resource and side-effect budget while the outer session still appears bounded. The autonomous driver excludes the `agent` tool.

Independent review uses a separate read-only bounded Qwen session. That review is advisory and cannot pass a gate.

## Context management

The Qwen3.8 family supports a large native context, but a 4-bit 27B deployment still pays host memory for model weights, KV cache, runtime buffers, and concurrent macOS/Xcode workloads. The package therefore uses a conservative context profile based on physical memory and never assumes the model's maximum context is operationally efficient.

A session ends before it becomes the continuity mechanism. State is transferred through:

- `.forge-qwen-state/run-state.json`;
- `.forge-qwen-state/current-handoff.json`;
- accepted evidence and gate receipts;
- source and package manifests;
- the selected work-package card.

The model's own managed memory features remain disabled to prevent hidden, non-project-scoped state from overriding the ledger.

## Structured output boundary

JSON Schema constrains terminal reports so scripts can parse them. It does not make a statement true.

The finalizer:

1. preserves raw stdout and stderr;
2. records the process exit code;
3. extracts structured output if valid;
4. verifies the selected work-package identifier;
5. ignores any attempted gate-pass claim;
6. computes before/after source and state identities;
7. creates a conservative handoff when Qwen did not;
8. records an immutable invocation envelope.

Only the registered gate validator can pass a gate.

## No-progress behavior

Progress is measured from:

- product source-manifest changes; or
- an authoritative state transition such as accepted evidence, gate receipt, finding closure, or completed work package.

A handoff timestamp alone is not progress.

After three no-progress slices:

- discard the stale implementation plan;
- create a fresh plan;
- isolate the smallest deterministic reproducer;
- inspect source ownership and durable state;
- choose a reversible alternate implementation;
- preserve the blocker and continue independent work.

## Failure classes

| Failure | Required action |
|---|---|
| Qwen CLI missing | Use the opt-in installer only when `QWEN_AUTO_INSTALL=1`; otherwise record prerequisite |
| Required CLI flag missing | Stop autonomous execution; do not run an unbounded fallback |
| Provider unreachable | Preserve state, record blocked provider prerequisite, continue host-independent scripts |
| Wrong model | Refuse to run |
| Quantization unverified | Refuse strict preflight unless explicit post-verification override is set |
| Optional reasoning fields rejected | Retry the provider probe without those optional fields and record the downgrade |
| Malformed structured output | Preserve raw output; do not infer success; create conservative handoff |
| Turn/tool/wall/context limit | Treat as bounded interruption; preserve handoff and begin a fresh session |
| Test failure | Diagnose and fix; do not weaken or skip the test |
| Model claims gate passed | Ignore and record the attempted claim |
| Publication command attempted | Block through the pre-tool hook and record it |

## Review

`run_qwen_review.sh` is used after meaningful slices or before requesting a validator. It runs in plan mode, reads the diff and evidence, and returns structured findings. A review can reject a slice. It cannot accept a gate or close a finding.

