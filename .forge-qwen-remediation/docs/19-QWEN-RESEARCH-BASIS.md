# Qwen Code and Qwen3.8 research basis

## Purpose

This file records the external product facts used to customize the Forge Conductor remediation package for Qwen Code and a locally served Qwen3.8-27B 4-bit model. These facts affect only the execution harness. The Forge Conductor audit findings, target architecture, P00–P14 dependency graph, deterministic validators, and G00–G20 release gates remain unchanged.

Research was verified on 2026-08-29 against official Qwen Code and Qwen model documentation.

## Qwen Code capabilities used

Official Qwen Code headless execution supports prompt mode and bounded execution controls including:

```text
--model
--approval-mode
--output-format
--json-schema
--max-session-turns
--max-wall-time
--max-tool-calls
--exclude-tools
--append-system-prompt
```

The autonomous driver refuses to run when any required flag is absent. It does not substitute an unbounded legacy invocation.

The top-level tool-call limit is not treated as a complete budget for nested agents. The package excludes the `agent` tool and performs independent review in another bounded, read-only session.

Official documentation:

- https://qwenlm.github.io/qwen-code-docs/en/users/features/headless/
- https://qwenlm.github.io/qwen-code-docs/en/users/features/approval-mode/
- https://qwenlm.github.io/qwen-code-docs/en/users/features/sub-agents/

## Repository memory used

Qwen Code loads project instructions from `QWEN.md`. The installed root file is deliberately short and points to durable package state, one selected work-package card, and the current handoff. Managed auto-memory, dream, skill, and team-memory features are disabled so hidden model memory cannot override project identity, gate state, or continuity.

Official documentation:

- https://qwenlm.github.io/qwen-code-docs/en/users/features/memory/
- https://qwenlm.github.io/qwen-code-docs/en/users/configuration/settings/

## Tool hook used

Qwen Code `PreToolUse` command hooks may return a structured permission decision. The package installs a project-local command hook that returns `allow` for local development work and `deny` for push, merge, tag, release, upload, distribution, destructive reset, and shipping commands.

The hook is not a shell-disable mechanism. Normal shell builds, tests, diagnostics, local commits, local signing, local archives, and local release-candidate construction remain permitted.

Official documentation:

- https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/
- https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/reference/

## Model facts used

The official Qwen3.8-27B model card describes a dense 27B model with a native 262,144-token context and thinking enabled by default. The package records the documented sampling defaults:

```text
temperature = 1.0
top_p = 0.95
top_k = 20
presence_penalty = 0.0
```

The package does not use the full native context by default. A 4-bit deployment still consumes host memory for weights, KV cache, runtime buffers, macOS, Xcode, tests, Instruments, and Forge Conductor. Conservative host-memory profiles cap normal sessions between 16K and 98K tokens. The absolute 262,144 limit is retained only as a hard ceiling for validated overrides.

Official model card:

- https://huggingface.co/Qwen/Qwen3.8-27B

## Provider contract

Qwen Code supports custom OpenAI-compatible model providers. This package accepts only loopback HTTP providers, requires an exact Qwen3.8-27B model match, and rejects silent fallback to another model or remote service. Four-bit quantization must be visible in provider metadata or independently verified before the explicit downgrade environment variable is used.

Official documentation:

- https://qwenlm.github.io/qwen-code-docs/en/users/configuration/model-providers/
- https://qwenlm.github.io/qwen-code-docs/en/users/configuration/settings/

## Installation boundary

Qwen Code is not installed silently. The opt-in preparation script uses the official Homebrew package or npm package and enforces the documented Node.js 22-or-newer prerequisite for npm installation.

Official documentation:

- https://qwenlm.github.io/qwen-code-docs/en/users/quickstart/
- https://github.com/QwenLM/qwen-code

## Derived execution decisions

The following are package design decisions derived from the official capabilities and the smaller local-model operating envelope:

1. One fresh planning session and one fresh implementation session per bounded slice.
2. No opaque conversation continuation as authority.
3. No subagents.
4. One Qwen process at a time.
5. Compact work-package cards rather than loading the whole remediation corpus.
6. JSON Schema output for parseability, never as proof of correctness.
7. Gate-specific native validators remain the sole completion authority.
8. Source manifests, accepted receipts, and durable handoffs carry state across sessions.
9. Three no-progress slices force a new plan and alternate strategy.
10. The final state is local readiness only: `ready_to_ship=true`, `shipped=false`.
