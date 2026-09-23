# Native completion validation

Current source uses `InstalledNativeGateRegistry` as the manager's
completion dependency. A model can request completion with a bounded summary,
either as the complete JSON reply or as a valid completion-request JSON object
at the end of a longer reply. An object followed by additional prose is not a
request.
It cannot supply authoritative gate results. Legacy `gate_evidence` fields are
accepted as non-authoritative input, and historical result hashes remain useful
only as provenance.

Completion gates have two explicit owners. The built-in package gate and every
native `CompletionCheckPreset` are manager-owned automatic checks. Forge
evaluates them from the compiled project-instruction completion plan; they do
not load an installed policy and do not require a separate gate environment.
Unknown gate identifiers declared by an instruction package are custom native
gates. Only those identifiers enter the protected policy path described below.

A missing or invalid installed policy leaves a run in `blockedConfiguration`
only when that run explicitly contains a custom native gate. A failed automatic
check or custom assertion leaves work available for correction and Autonomy
shows the exact failed condition. Correct an automatic condition and choose
**Retry Automatic Checks**. Import a policy through **Import Custom Completion
Policy…** only for the explicitly named custom gate. Restart discards
process-local custom approval authority and requires custom validation again;
decoding an old receipt does not restore approval.
The September 15 owner-host read-only LM Studio run invoked project-bound
`fs_read` three times and emitted a completion object after explanatory prose.
The installed manager did not parse that suffix and yielded the run in `running`
with no active coordinator or passed gate. Current source accepts the bounded
suffix and a focused regression passes. No per-run policy is installed on this
host, so the run is not recorded as completed.
A separate current-source development-signed candidate run on the same loaded
LM Studio model persisted an `fs_read` evidence reference, recognized the
model's completion marker, and reached native validation. The manager recorded
`blocked_configuration` with `completion_validation_failed` because the
owner-only per-run policy was absent. No gate was approved or passed.
A second disposable read-only run used a private schema-1 policy bound to its
run and project generation. An arm64 signed XCTest package, built from the
canonical workspace, passed its exact preflight case. The current-source
development-signed manager then consumed one LM Studio `fs_read` evidence,
accepted the model's completion request, and executed the same native case:
one passed, zero failed or skipped, exit 0, no timeout or output truncation.
The manager recorded `completed` at revision 10 with `tests` passed, and that
state remained after restart. The result bundle and process record are retained
under the isolated home at
`/private/tmp/forge-current-source-devrelease-home/native-validation/results/e58073b3-c597-497b-95b3-d541db749531/tests/2fa89a7c-9369-431a-b6e2-b76f21c73878/`.
This proves a disposable native completion path. The new operator import path
below separately verifies policy enrollment from the native GUI and from Core;
the installed root-service and an ordinary GUI run reaching terminal completion
remain open.
The notarized Developer ID ZIP built from the policy-import source also ran a
separate packaged, isolated-home LM Studio flow. Its manager saved the loaded
model, passed the live contract probe, consumed `fs_read`, and used an exact
imported signed XCTest policy before admitting the run. It reached `completed`
revision 8 with `tests` passed; the child `.xcresult` recorded one required case
passed, zero failed/skipped, process exit 0, and no timeout/truncation. The
same terminal state survived a full app/manager process restart. The exact
paths and artifact hash are in the [packaged native completion receipt](FUNCTIONAL-DEVELOPMENT-BUILD.md#september-16-2026-packaged-native-completion-receipt).
The final current-local-workspace archive then included the updated canonical
Xcode UI-test target graph. Its five production code-directory hashes match
that notarized submission; the export stapled, and the extracted ZIP passed
strict Release checks and local Gatekeeper. The final unshipped ZIP SHA-256 is
`f77f63c19807be2522d245c9a6e827d0713c99a04cf76d6f14baaaaebe470b19`.
The test-run receipt above applies to identical production code, while direct
GitHub `main` publication and root-service qualification remain open.
The signed production onboarding GUI also admitted and persisted a read-only
Autonomy assignment after native project registration, folder authorization,
and live LM Studio Provider setup. Its seven-case class passed with no skips or
failures, followed by two exact combined-case passes. One earlier full-class
attempt returned a live Provider `unreachable` result before Autonomy run start;
that non-pass and its incomplete probe error record are retained in the
[functional-build evidence](FUNCTIONAL-DEVELOPMENT-BUILD.md). The GUI run-start
test now opens and cancels the policy picker, then selects a prepared run-bound
manifest fixture through that picker. It reads back byte-identical protected
policy data at mode `0600`. That fixture is not a signed executable package and
does not qualify terminal completion; the separate signed-package case proves
manager adjudication.

## Native operator policy import

Select a persisted run in **Autonomy**, expand **Custom policy controls** under
Completion checks, and use **Import Custom Completion Policy…**. Choose a separately approved schema-1
JSON policy. Its signed XCTest package must already be under the exact protected
`native-validation/packages/<package UUID>/` path. Forge's native importer does
not compile arbitrary tests, take executable or shell selectors, or grant gate
approval. The GUI reloads the current manager run and project generation before
calling the actor. The actor reads at most 256 KiB without following the chosen
file's final link and requires the policy's run, project, generation, and
complete custom-native gate set to match. It captures
the named project inputs and each approved package manifest, requires signed
product paths to be covered by those manifests, rejects aliased protected
directories, and rechecks the input/policy bytes before an atomic owner-only
write. A canceled picker leaves the run and protected policy unchanged and
re-enables the import control.

**E0 — focused comparison:** the wrong run binding and a changed package digest
each left the protected policy path absent; the exact prepared policy persisted
byte-for-byte with mode `0600`. The existing signed native gate fixture now
imports through that production service and executes three real child XCTest
jobs: an incorrect effect fails, stale source remains non-approving, and the
corrected effect passes. One focused Core import test and one signed-fixture
test each executed with zero skips/failures. A Developer ID Release native UI
test registered the exact authorized folder, reached the loaded LM Studio
Provider, started a read-only run, opened the policy picker, canceled it, and
retained that run. Its first focused pass executed one case with no skips or
failures at `/private/tmp/forge-policy-import-native-release-picker-cancel.xcresult`.
The exact Release UI picker-cancel test was repeated with the import button
re-enabled and the persisted run retained at
`/private/tmp/forge-policy-import-native-release-final.xcresult`: one selected
case, zero skips or failures. An extended Release native case then selected the
prepared run-bound fixture through NSOpenPanel and read back the exact policy
at mode `0600`: one selected test, zero skips or failures at
`/private/tmp/forge-policy-import-native-positive-20260915.xcresult`. Its
manifest-only product cannot pass native execution. The ordinary installed-stack terminal run, package preparation UX, and root
service remain unqualified; import is not an assertion that the package's
native cases have passed.

## Installed policy and ownership

This section applies only to explicit custom native gate identifiers. It does
not apply to Buildable project, No build errors, No build warnings, Available
tests pass, Instruction packages complete, No unresolved operations, or the
built-in package-completion gate. Instruction packages remain the authority for
declaring custom gates; Forge Conductor does not invent one as a prerequisite.

The manager reads one owner-only policy at:

```text
<Forge home>/native-validation/policies/<run UUID>.json
```

Approved prebuilt test packages reside below
`native-validation/packages/<package UUID>/`. Native results reside below
`native-validation/results/<run UUID>/<gate ID>/<job UUID>/`. The installed
policy is operator-owned data. There is no model tool for installing definitions,
selecting an executable, supplying a shell command, or approving a result.
Rollover retains the run identity and its policy. Other enrollment workflows
must preserve the same installed-policy and manager-adjudication boundary.

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
preserved. The original completion checkpoint retained source identity
`0.9.0 (1)`; the current repository identity is `0.14.0 (6)`. Neither the
checkpoint nor the current development identity constitutes release approval.

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
