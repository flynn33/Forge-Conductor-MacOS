# Qwen Code start here

## Mission

Bring the supplied current Forge Conductor for macOS repository to a shippable, evidence-backed state without shipping it. Preserve all current behavior, implement every planned feature the audit found missing or incomplete, remove every release blocker, and stop at a private local release candidate with `shipped=false`.

## Why this package differs from a generic coding-agent package

Qwen3.8-27B 4-bit is capable but must not be asked to carry the full remediation program in one context. This package converts the original P00–P14 program into fresh, bounded, restartable Qwen Code sessions:

```text
persistent package state
    → select one ready work package
    → generate one small read-only plan
    → execute one coherent implementation slice
    → run focused tests
    → preserve raw output and evidence
    → update durable handoff
    → start a fresh session
```

The model never owns release truth. Deterministic scripts and native validators do.

## Mandatory first actions

From the package root:

```bash
python3 scripts/validate_package.py --deep
./scripts/bootstrap.sh
cd work/Forge-Conductor-MacOS-main
python3 .forge-qwen-remediation/scripts/qwen_preflight.py --repo .
```

Start the bounded autonomous driver only after the preflight proves:

- a compatible Qwen Code CLI;
- all required headless budget flags;
- a loopback OpenAI-compatible provider;
- an exact Qwen3.8-27B model match;
- verified 4-bit quantization, or an explicit post-verification override;
- a schema-constrained model response.

Then run:

```bash
./.forge-qwen-remediation/scripts/run_qwen_autonomously.sh .
```

For an existing checkout:

```bash
/path/to/package/scripts/install_into_repo.sh \
  /absolute/path/to/Forge-Conductor-MacOS
```

## Local provider discovery

The configuration script probes these loopback OpenAI-compatible endpoints:

```text
http://127.0.0.1:1234/v1
http://127.0.0.1:8080/v1
http://127.0.0.1:8000/v1
http://127.0.0.1:30000/v1
```

Override with:

```bash
export QWEN_OPENAI_BASE_URL=http://127.0.0.1:1234/v1
export QWEN_MODEL_ID='exact-provider-model-id'
export FORGE_QWEN_LOCAL_API_KEY=local-only
```

The script refuses non-loopback HTTP providers. It refuses a different model. It does not silently assume a 4-bit artifact from the model name alone. When the provider omits quantization metadata, verify the loaded artifact independently and then set:

```bash
export QWEN_ACCEPT_UNVERIFIED_QUANTIZATION=1
```

That override is recorded as a downgrade and is not proof of quantization.

## Required reading order per slice

Do not read the entire package into one model context. Read:

1. `.forge-qwen-state/current-task.md`;
2. the referenced `qwen/work-package-cards/Pxx.md`;
3. `.forge-qwen-state/current-handoff.json`;
4. only the architecture, tests, audit excerpts, and source files listed by the card;
5. the full phase playbook only when the card requires it.

## Critical path

- `P00` establishes the exact source, environment, feature, and evidence baseline.
- `P01` is the first product-code repair: remove the generic hash-presence completion bypass.
- `P02` makes canonical project-scoped continuity the sole managed-mode authority.
- `P03` finishes E2 before secure package ingestion depends on it.
- Queueing, reset, operator UI, XPC, pressure policy, dashboard hardening, parity, native qualification, endurance, and local release readiness follow their declared dependencies.

Do not build the autonomous queue on the weak completion validator. Do not build secure ingestion on an unresolved validate-then-mutate filesystem path.

## Hard non-regression rules

- Shell remains enabled by default.
- `shell_exec` remains registered and behaviorally compatible.
- No model-selected hash can pass a gate.
- No global latest project or handoff can authorize stateful work.
- Managed continuity never instructs the operator to open a new chat.
- Packages never execute from a user-selected source path.
- Features are optimized, not removed.
- Missing signing, provider, runtime, or profiling prerequisites remain truthful blockers.
- No shipping action is permitted.

## Fresh-session continuity

Every implementation slice ends by calling:

```bash
python3 .forge-qwen-remediation/scripts/statectl.py \
  --repo . \
  handoff \
  --summary "<verified work and evidence>" \
  --next "<exact next action>"
```

The driver also produces a conservative handoff when the model exits because of budget, malformed structured output, provider failure, or context pressure.

## Gate and finding closure

A registered validator must emit a receipt conforming to `schemas/gate-result.schema.json`:

```bash
python3 .forge-qwen-remediation/scripts/accept_gate_result.py \
  --repo . \
  --receipt /path/to/validator-receipt.json
```

A finding closes only after all mapped gates pass:

```bash
python3 .forge-qwen-remediation/scripts/close_finding.py \
  --repo . \
  --closure /path/to/finding-closure.json
```

`statectl.py` cannot directly pass a gate or prematurely complete a work package.

## Advisory review

A second bounded Qwen session may review a completed slice:

```bash
./.forge-qwen-remediation/scripts/run_qwen_review.sh .
```

Review output is advisory. It may reopen work or identify defects. It cannot pass a gate.

## Terminal boundary

The final state is:

```json
{
  "ready_to_ship": true,
  "shipped": false
}
```

Create local artifacts and the readiness attestation, validate them, then stop.

