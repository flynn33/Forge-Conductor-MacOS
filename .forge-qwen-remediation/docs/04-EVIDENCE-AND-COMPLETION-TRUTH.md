# Evidence and completion truth

## Defect to eliminate

The current production path allows a model-provided SHA-256 from any tool result to be associated with a declared gate. The validator checks only hash shape and membership in a generic evidence array. This is not validation.

## Required model

### Gate registry

Each gate is declared before run start:

```swift
struct GateDefinition {
    let gateID: String
    let validatorID: String
    let validatorVersion: String
    let projectID: ProjectID
    let projectGeneration: ProjectGeneration
    let parameters: Data
    let timeoutSeconds: Int
    let requiredPlatform: GatePlatform
}
```

### Completion claim

The provider may submit a summary and request validation. It may not select evidence hashes or mark a gate passed.

### Gate execution

The manager creates a durable `GateExecution` with a unique execution ID, lease epoch, source manifest, validator identity, and expected run revision. The validator runs independently of the provider loop.

### Receipt

A passing receipt contains:

- project ID and generation;
- package ID and package-run ID when applicable;
- autonomous run ID;
- gate ID;
- validator ID and version;
- source manifest before and after;
- command/native action descriptor;
- exit code or structured result;
- start/end time and duration;
- output/artifact hashes;
- explicit pass/fail;
- receipt checksum.

The database enforces uniqueness for one accepted pass per gate definition revision. Revalidation creates a new execution and supersedes rather than mutates prior evidence.

## Validator types

- command validator with fixed executable/arguments and bounded environment;
- XCTest/XCUITest validator;
- native protocol transcript validator;
- filesystem adversarial validator;
- Instruments budget validator;
- schema/migration validator;
- artifact/hash validator;
- composite validator requiring named child validators.

## Required bypass tests

Reject evidence that is unrelated, failed, stale-generation, wrong-project, wrong-run, wrong-gate, wrong-validator-version, expired, model-invented, or reused from another source manifest.

## Production wiring

`EvidenceBoundCompletionValidator` must not be injected by `ManagedAutonomyRuntime`. Production must use a gate registry and deterministic validator service. Legacy evidence metadata may be imported for display but never grants completion.
