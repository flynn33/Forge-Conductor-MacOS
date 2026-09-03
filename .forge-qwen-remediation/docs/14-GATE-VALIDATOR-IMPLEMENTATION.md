# Gate validator implementation contract

Each gate in `plans/gates.json` has one registered `validator_id` and `validator_version`. Production work-package completion and the remediation ledger both reject unregistered proof.

## Validator requirements

A validator is code owned by the repository, not provider-generated command text. Its executable, arguments/native action, expected result, timeout, environment, artifact set, and parsing logic are fixed by a versioned definition. Parameters are hashed before execution. A validator:

1. verifies project, generation, run/package assignment, gate definition revision, and current source manifest;
2. persists an execution intent and lease before starting;
3. executes with bounded time, output, memory, and cancellation;
4. records raw output and native artifacts before interpretation;
5. returns explicit pass/fail/blocked/cancelled/timed-out status;
6. computes its receipt checksum over canonical JSON excluding `receipt_sha256`;
7. never changes source while validating;
8. supports crash recovery without accepting duplicate irreversible effects.

## Receipt acceptance

The result must conform to `schemas/gate-result.schema.json`. At least one artifact is required, and every artifact path, byte count, and SHA-256 is checked. The receipt’s validator identity must match `plans/gates.json`; its source manifest must equal the repository’s current manifest. Use:

```bash
./.forge-qwen-remediation/scripts/accept_gate_result.py \
  --repo . \
  --receipt .forge-qwen-state/validator-output/<receipt>.json
```

A passing command evidence record from `record_evidence.py` is supporting evidence only. It is not a gate receipt.

## Composite and native gates

Composite validators enumerate named child receipt hashes. Native gates also capture built product hashes, signing identities without private material, entitlements, host and OS versions, process/session identifiers, timestamps, and protocol transcripts. Instruments gates preserve the raw trace plus a deterministic extraction report.

## Source changes after validation

Any product-source change invalidates every accepted receipt for final release readiness. The receipts remain historical evidence, but P14 reruns every mandatory validator against the exact final source manifest.
