# Forge Conductor shippable-remediation package for Qwen Code and Qwen3.8-27B 4-bit

This package contains the current Forge Conductor repository, complete audit evidence, specialist designs, a dependency-ordered remediation program, deterministic gate validators, and a bounded autonomous driver customized for Qwen Code using a locally served Qwen3.8-27B 4-bit model.

The architecture remains a consolidation around Forge Conductor's existing durable project-scoped manager control plane. It is not a rewrite. Every current feature is preserved. The original P00–P14 work packages cover completion integrity, canonical continuity, E2, immutable package ingestion, queueing, project reset, operator UI, hardened XPC, resource pressure, dashboard security, repository parity, native qualification, endurance, and local release readiness.

## Qwen-specific controls

- A compact `QWEN.md` is loaded on every fresh session.
- Only a loopback OpenAI-compatible endpoint is accepted.
- Provider metadata must identify Qwen3.8-27B. Four-bit quantization must be identifiable, or explicitly acknowledged through `QWEN_ACCEPT_UNVERIFIED_QUANTIZATION=1` after verification.
- Context, output, tool, turn, and wall-clock budgets are conservative and host-memory-aware.
- Planning and implementation use separate fresh headless sessions.
- Terminal reports are constrained by JSON Schema but never pass product gates.
- The `agent` tool is excluded so subagent inner calls cannot bypass top-level tool budgets.
- Managed auto-memory, auto-dream, auto-skill, and team-memory sync are disabled. The remediation ledger and Forge project memory remain authoritative.
- A `PreToolUse` command hook blocks publication, distribution, remote upload, destructive repository reset, and shipping actions.
- Raw Qwen JSON and stderr are retained. Exit codes caused by turn, tool, wall-time, provider, or context budgets preserve a conservative handoff.
- No model, tool, automation, or generator attribution may enter product source, commits, PR text, metadata, documentation, or release notes.

## Start with the bundled current repository

```bash
unzip Forge-Conductor-Shippable-Remediation-Qwen-Code-3.8-27B-4bit-Package.zip
cd Forge-Conductor-Shippable-Remediation-Qwen-Code-3.8-27B-4bit-Package
./scripts/bootstrap.sh
```

Start a local OpenAI-compatible server with Qwen3.8-27B 4-bit loaded. The installer probes common loopback endpoints, including LM Studio's usual endpoint. Custom values use `QWEN_OPENAI_BASE_URL` and `QWEN_MODEL_ID`.

```bash
cd work/Forge-Conductor-MacOS-main
export FORGE_QWEN_LOCAL_API_KEY=local-only
./.forge-qwen-remediation/scripts/qwen_preflight.py --repo .
./.forge-qwen-remediation/scripts/run_qwen_autonomously.sh .
```

Qwen Code is not installed silently. To permit installation through Homebrew or npm when missing:

```bash
QWEN_AUTO_INSTALL=1 \
  ./.forge-qwen-remediation/scripts/qwen_preflight.py --repo .
```

## Install into an existing checkout

```bash
./scripts/install_into_repo.sh /absolute/path/to/Forge-Conductor-MacOS
```

The installer adds operational control files excluded from the product source manifest. It does not alter Forge Conductor product source.

## Completion authority

Qwen output, a model-selected hash, a local review, or a successful build cannot pass a gate. A mandatory gate passes only when its registered validator creates an immutable receipt accepted against the exact current source manifest. Any later product-source change makes final receipts stale.

The terminal state is:

```json
{
  "ready_to_ship": true,
  "shipped": false
}
```

The package may build a private local release candidate and local readiness attestation. It must not push, merge, tag, publish, upload, submit, distribute, or notarize for distribution.
