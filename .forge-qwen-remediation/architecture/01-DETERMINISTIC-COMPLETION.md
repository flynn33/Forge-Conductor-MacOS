# Deterministic completion architecture

## State model

```text
running
  -> completionRequested
  -> validatingCompletion
       -> completed
       -> blockedValidation
       -> running (after recoverable failure or changed source)
```

The provider can request `completionRequested`; it cannot choose validator output.

## Persistence

Add tables equivalent to:

- `gate_definitions` — immutable gate identity and validator version;
- `gate_executions` — one validator attempt, lease, source manifest, timestamps;
- `gate_results` — pass/fail, structured summary, receipt checksum;
- `gate_artifacts` — bounded immutable artifact references;
- `completion_claims` — provider summary and run revision only.

Foreign keys bind every record to project, project generation, autonomous run, and package run where applicable.

## Production interfaces

```swift
protocol GateValidating: Sendable {
    var validatorID: String { get }
    var version: String { get }
    func validate(_ request: GateValidationRequest) async throws -> GateValidationReceipt
}

actor GateExecutionService {
    func requestCompletion(runID: RunID, expectedRevision: Int64, summary: String) async throws
    func executeReadyGates(runID: RunID) async
    func reconcileNonterminalExecutions() async
}
```

## Command validators

A command validator stores the executable and fixed argument template in trusted code or an immutable gate definition. Model text is never interpolated as shell. Run through direct process arguments, a fixed working directory, sanitized environment, total deadline, output cap, and source-manifest comparison.

## Artifact validators

Package artifacts are registered separately. A gate may require an artifact role, MIME/format, size, checksum, schema, and producer operation. The model cannot point a gate to an arbitrary repository file without the validator checking it.

## Composite gates

A composite gate passes only when all named child validator receipts pass against the same project generation, run revision, source manifest, and release-candidate identity.

## Migration

Existing `completion_gate.<gate>.proof_sha256` metadata is display-only legacy data. Never treat it as pass authority. Existing in-progress runs should transition to `blockedValidation` and receive registered gates; do not mark them completed automatically.
