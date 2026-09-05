# Native completion validation

This development snapshot uses `InstalledNativeGateRegistry` as the manager's
completion dependency. A model can request completion with a bounded summary.
It cannot supply authoritative gate results. Legacy `gate_evidence` fields are
accepted as non-authoritative input, and historical result hashes remain useful
only as provenance.

Missing or invalid installed policy leaves the run in `blockedConfiguration`.
A failed assertion leaves work available for correction. Completion requires a
fresh native result under the current run, lease, generation, specification,
source inputs, and policy. Restart discards process-local approval authority and
requires validation again; decoding an old receipt does not restore approval.

## Installed policy and ownership

The manager reads one owner-only policy at:

```text
<Forge home>/native-validation/policies/<run UUID>.json
```

Approved prebuilt test packages reside below
`native-validation/packages/<package UUID>/`. Native results reside below
`native-validation/results/<run UUID>/<gate ID>/<job UUID>/`. The installed
policy is operator-owned data. There is no model tool for installing definitions,
selecting an executable, supplying a shell command, or approving a result.
Rollover retains the run identity and its policy. CLU enrollment integration is
separate work under the active correction contract.

`InstalledNativeGatePolicy` in the Core module defines schema version 1:

| Field | Meaning |
|---|---|
| `schemaVersion`, `policyRevision` | Exact supported schema and current correction revision. |
| `runID`, `projectID`, `projectGeneration` | The exact durable assignment. These use the existing identity encodings. |
| `sourceInputs` | Explicit relative qualification inputs; missing inputs, links, and changes during capture are rejected. |
| `candidateSourceSHA256` | The approved native source-snapshot digest for a prebuilt candidate. G00–G14 require it. A work-product policy can omit it when its fixed native assertions inspect changing output data. |
| `buildIdentity`, `xcodeVersion`, `architecture` | Build label, required Xcode version, and selected native architecture. Package and policy digests are incorporated into the observed build identity. |
| `correctionCaseBindings` | Exact native case identifiers for the added acceptance requirements. Missing bindings block affected gates. |
| `gates` | Unique, versioned definitions with package identity/digest, covered inputs, signed products, test plan, exact test selectors/cases, minimum count, and deadline. |

Prepare policy from a separately authorized native build and the same
`QualificationInputSnapshotter` used by validation. Its digest is not a Git
commit hash. Include all relevant source, tests, package/project/workspace,
resources, scripts, schemas, and controlling policy inputs. Evidence output
must be outside those inputs. An updated prebuilt candidate needs a matching
source and package binding; relabeling an old result cannot qualify new source.

The loader reads at most 256 KiB, admits at most 32 definitions, rejects linked
or non-private policy files, and binds a loaded definition immutably through
its activation. It rechecks the policy around execution. Native jobs have
bounded admission, deadlines, output, input traversal, and retained job counts.
A full retained result directory blocks further work until operator cleanup;
results are not silently deleted to obtain another pass.

## Native execution and adjudication

The compiled handler verifies the approved package and product signatures,
checks Xcode, and invokes `xcodebuild test-without-building` with fixed argument
construction. It uses an explicit environment and an exclusive result path.
The installed Xcode result tool extracts semantic test records from the actual
`.xcresult` bundle. The manager checks required case identities, counts,
failures, skips, process exit/signal, timeout, output truncation, timestamps,
job nonce, and source freshness before issuing a completion receipt.

A zero exit code or a directory named `.xcresult` is insufficient. A real
passing test whose inputs changed during execution is stale. Source risks,
fixtures, API qualification, visible desktop qualification, and release
qualification retain their distinct scopes. The correction's desktop cases
cannot be satisfied by API-only test bindings.

Approval issuance remains in the manager process and is consumed under the
current lease and run revision. Persisted receipts retain evidence and identity;
they are not reusable bearer approval tokens. These protections address ordinary
project tools and their subprocesses. They do not claim protection against an
unconstrained malicious process sharing the manager's user identity.

## Project tool compatibility

Filesystem authorization reserves the validation namespace even under broader
project grants. Destructive parent operations cannot rename it out of that
boundary. Text reads, writes, edits, and directory creation use no-follow parent
traversal after authorization, preventing a swapped parent link from redirecting
an ordinary write into policy storage.

Git, search, glob, and compatibility shell subprocesses use the existing
project sandbox. Recursive search still finds ordinary project content while
validation storage is inaccessible. Git hooks execute inside that sandbox;
commit/index reconciliation uses invocation-owned scratch and remains bounded.
Git uses native binaries from Xcode or Command Line Tools. Hooks should use
native tools available on the scoped `PATH`: Apple's `/usr/bin/git` dispatcher
uses a spawn operation prohibited by the existing process-group escape policy.
The sandbox also keeps the validation toolchain, including Xcode's shared
frameworks, read-only to model project work.

Tool names, structured response fields, shell default/opt-out settings,
completion-request compatibility, and durable run/lease identities are
preserved. Source version remains 0.9.0 build 1; these changes do not constitute
release approval.

## Regression evidence

The native regression
`AutonomySupervisorTests/testInstalledNativeJobFailurePreventsCompletionUntilActualEffectIsCorrected()`
executes three real child XCTest jobs through installed policy: a failing
assertion, a passing assertion with a concurrent source change, and a fresh
passing assertion. Only the final case completes the run. It retains all three
native bundles, process records, source-change observation, and run states.
It exercises a disposable work product, not live-provider or desktop behavior.

Additional regressions cover failed/unrelated hashes, cross-identity replay,
missing and skipped cases, fabricated results, stale policy/source bindings,
missing production policy, explicit non-approving injection, broader-root
access, Git-hook overwrite, parent-path replacement, and existing tool
cancellation/reconciliation behavior. Exact qualification remains tied to the
source and artifacts recorded by the active rescue run.
