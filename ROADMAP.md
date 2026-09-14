# Forge Conductor macOS — project roadmap

Audit baseline: September 12, 2026, source `4750e8ee93aeb7dbbcde6b3408d409cb47ee2be1`; reconciled September 13, 2026 to source `b8e927c76bb13a58e6f161789c162ddac629ef95` after owner PR #45. Remote and local `main` were rechecked September 14, 2026 at `50d18219fd7f898f2a7cb9bb5cc057aa3c2d9a3e` after owner PR #46. These are evidence baselines, not checkout/reset instructions. Confirm newer merged work before updating a row.

The roadmap is the canonical phase/milestone record. The owner authorizes one small task at a time; this table is not an automatic task selector. Follow [the delivery workflow](docs/DELIVERY-WORKFLOW.md).

## Status and acceptance

**Recorded** means the linked PR is merged and supplies the stated narrow evidence. **Needs check** means implementation exists but this milestone's current evidence/repair is not closed. **Open** means an unfulfilled requirement. **Ready in PR** means proposed, not accepted. **Blocked** retains its exact missing dependency. **Deferred** requires an owner decision and never means complete.

Every PR updates its affected row with a real link, evidence, and limitation. Before the number is known, use the actual branch; replace that reference locally after PR creation. GitHub's merge state determines acceptance. A phase also requires README, Unreleased changelog, affected-document closeout, and a post-merge local/Xcode synchronization receipt on its closing PR. Do not mark a phase complete from an open PR or a successful build alone.

## Phases and milestones

| Phase | Milestone / assigned slice | Audit status | Acceptance and current evidence |
|---|---|---|---|
| TRACKING | T-ROADMAP / tracking setup | Recorded through [PR #46](https://github.com/flynn33/Forge-Conductor-MacOS/pull/46); prerequisite refresh ready in [PR #47](https://github.com/flynn33/Forge-Conductor-MacOS/pull/47) | PR #46 merged as `50d1821`. Its [post-merge receipt](https://github.com/flynn33/Forge-Conductor-MacOS/pull/46#issuecomment-5654771876) records the first local synchronization; local and remote `main` equality was independently rechecked September 14, 2026. PR #47 records that refresh and the current release prerequisites; its documentation-only diff leaves the native graph unchanged. |
| FOUNDATION | F-DISPATCH / 01 | Recorded | One owner-selected slice replaces historical dispatch. [PR #39](https://github.com/flynn33/Forge-Conductor-MacOS/pull/39). Documentation validation only. |
| FOUNDATION | F-BUILD / 02 | Recorded | CLI build and six focused atomic-file tests reported passing. [PR #40](https://github.com/flynn33/Forge-Conductor-MacOS/pull/40); [build note](docs/BUILD-BASELINE.md). Not native GUI execution. |
| FOUNDATION | F-RESUME / 03 | Recorded | Coherent current task and review pause survive save/restore; explicit seed must match caller narrative. [PR #41](https://github.com/flynn33/Forge-Conductor-MacOS/pull/41); [resume note](docs/COHERENT-RESUME.md). |
| FOUNDATION | F-TOOLS / 04 | Recorded | Focused read/edit/command result checks pass without production-tool changes. [PR #42](https://github.com/flynn33/Forge-Conductor-MacOS/pull/42); [tool-path note](docs/EDIT-BUILD-TOOL-PATH.md). |
| FOUNDATION | F-MEMORY / 05 | Recorded | Selected-project records persist across reopen and reject cross-project/default fallback. [PR #43](https://github.com/flynn33/Forge-Conductor-MacOS/pull/43); [memory note](docs/PROJECT-MEMORY.md). |
| NATIVE | N-BASELINE / native baseline | Needs check | Current ordinary signed workspace app build and graph review on the owner Mac. Baseline CI Debug/Release Xcode lanes passed; that compilation and the CLI baseline remain separate from owner-Mac signed execution. |
| NATIVE | N-GENERATION / 06 | Recorded | One-project generation fencing preserves other projects, settings, and durable records. [PR #44](https://github.com/flynn33/Forge-Conductor-MacOS/pull/44); [reset note](docs/PROJECT-RESET.md). This is not clearing. |
| NATIVE | N-RESET-UI / 07 | Needs check; partially delivered by [PR #45](https://github.com/flynn33/Forge-Conductor-MacOS/pull/45); remaining confirmation-identity and receipt-matching work pending | PR #45 (merged as `b8e927c`) delivered the no-effect cancel, duplicate-submission dedupe, fenced confirmation dialog, durable-record preservation, and refresh-failure isolation with a focused five-test reset suite. Remaining: keep the presented project ID and expected generation as the request identity, reject a stale selection or generation with a fresh confirmation, and validate the returned receipt against that request before reporting success. |
| NATIVE | N-PROVIDER / 08 | Needs check | Offline save, saved-configuration discovery, and connection status remain distinct from managed-continuity readiness. |
| NATIVE | N-MANAGER / 09 | Needs check | Existing GUI attachment uses one manager owner; GUI close does not terminate its independent work. |
| NATIVE | N-CLEAR-SCOPE / reset scope | Open | Publish precise per-project clearing modes and a small implementation breakdown. Scope agreement alone does not implement clearing. |
| NATIVE | N-CLEAR-MEMORY / later owner card | Open | Actual selected-project memory clearing, preserved other-project/global data, receipt, and interruption-safe recovery. |
| NATIVE | N-CLEAR-CONTINUITY / later owner card | Open | Actual selected-project continuity clearing and fenced stale work, without collateral data loss. |
| NATIVE | N-CLEAR-COMBINED / later owner card | Open | Memory and continuity cleared under one recoverable project transition; no half-completed success claim. |
| NATIVE | N-CLEAR-HISTORY / later owner card | Open | Explicit run-history clearing preserves required current authority and recovery evidence. |
| CONTINUITY | C-PRESSURE / 10 | Needs check | Observed context capacity/usage plus full operation reserves trigger durable handoff before exhaustion, independently of arbitrary tool counts. |
| CONTINUITY | C-DELIVERY / 11 | Needs check | Exact authorized source revision is durably delivered and accepted once; replay does not create another run. |
| CONTINUITY | C-RESTORE / 12 | Needs check | Exact immutable context and durable retrieval proof; other task/project/stale-generation access denied. |
| CONTINUITY | C-ACK / 13 | Needs check | Typed acknowledgment matches actual candidate, retrieval, nonce, source identity, and provider response. |
| CONTINUITY | C-RESUME / 14 | Needs check | Canonical acceptance/seal precede release; non-bootstrap work executes and the next turn consumes its full durable output. |
| CONTINUITY | C-RECOVERY / 15 | Needs check | One named interruption/cancellation transition recovers without duplication. Broader crash coverage remains separate. |
| CONTINUITY | C-CONTROLS / 16 | Needs check | CLU status reports actual authorized operation state; connected tooling is not represented as active managed continuity. |
| INTEGRATIONS | I-WRITE / 17 | Open | One explicit task-scoped source write through the normal broker, with read-only and other-task denial. The reviewed native source profile is read-only. |
| INTEGRATIONS | I-DESKTOP / 18 | Open; supported host contract needed | Exact authenticated existing-desktop attachment and separately observed desktop behavior. API success is not a desktop pass. |
| CANDIDATE | K-LIVE / 19 | Open; partial earlier live evidence | A real context-triggered rollover must include actual ordinary work and a following turn consuming its output. Earlier [PR #38](https://github.com/flynn33/Forge-Conductor-MacOS/pull/38) reached acknowledgment/activation but the ordinary read remained pending. |
| CANDIDATE | K-NATIVE / 20 | Needs check | Coherent ordinary app/helpers/resources from one build plus focused real native launch/navigation; no replacement of the working host. |
| CANDIDATE | K-RECORD / 21 | Open | Evidence-bound candidate record, README/changelog/current-doc updates, and truthful owner-review handoff. |
| CANDIDATE | K-REPEAT / later owner card | Open | Repeated real-provider rollover without authority widening or duplicate work. One success does not qualify this. |
| CANDIDATE | K-GUI-CLOSED-RECOVERY / later owner card | Open | Independent-manager continued work with GUI closed and real provider interruption/recovery. A fixture reopen is not this evidence. |
| DISTRIBUTION | D-FILESYSTEM / separate release work | Open | Retained filesystem race/recovery qualification and unavailable production move/recursive delete remain accurately recorded. Do not bypass safeguards to close this row. |
| DISTRIBUTION | D-SIGNED-RELEASE / separate release work | Open | Current-source distribution signing, native/service lifecycle, archive, notarization, stapling, and Gatekeeper evidence. No default per-slice campaign. |
| DISTRIBUTION | D-HARDWARE / owner-deferred scope | Deferred, not complete | Representative physical hardware qualification, as retained in the existing qualification record. |

## Phase closeout state

| Phase | State at audit / required closeout |
|---|---|
| TRACKING | Recorded through merged [PR #46](https://github.com/flynn33/Forge-Conductor-MacOS/pull/46) and its [post-merge receipt](https://github.com/flynn33/Forge-Conductor-MacOS/pull/46#issuecomment-5654771876). The September 14 prerequisite refresh is ready in [PR #47](https://github.com/flynn33/Forge-Conductor-MacOS/pull/47); merge acceptance and its post-merge synchronization remain pending. |
| FOUNDATION | The five component slices are merged at their recorded scope. Consolidated phase documentation and the new local/Xcode receipt were not established by this audit; reconcile without repeating the tests. |
| NATIVE | Partial. Generation fencing is recorded; native build/UI verification and actual selectable clearing remain separate. |
| CONTINUITY | Existing implementation and historical tests; milestone-specific verification and any narrow corrections remain open. |
| INTEGRATIONS | Writable-source and desktop requirements are independent open boundaries, not extensions implied by an MCP connection. |
| CANDIDATE | Partial historical live evidence; consumed work, coherent current native execution, and broader retained recovery requirements remain open. |
| DISTRIBUTION | Open/deferred outside the default working-candidate task sequence. No shipment authorization is implied. |

## Dependencies and useful next work

Tracking is recorded. The next owner-authorized product slice should obtain an early ordinary native baseline before more UI work. Original slices 01–06 are accepted history, not fresh assignments. The owner may separately assign FOUNDATION documentation catch-up without reopening its unchanged implementation.

Generation-reset UI work must preserve the recorded reset semantics. Actual clearing starts with its own scope contract, followed by one mode-specific implementation at a time. Those later cards require owner authorization; this roadmap does not authorize bulk database deletion.

Continuity pressure/delivery/restore/acknowledgment precede proof of consumed ordinary work. Reuse existing tests where they already prove a row; add only missing evidence or a demonstrated repair. A full reserved result not fitting an accelerated test policy is a boundary to explain, not permission to truncate data or weaken production admission.

Manager-owned API live testing may be independently owner-authorized while desktop attachment remains open. Its evidence cannot close desktop or writable-source milestones. A partial candidate can be useful and accurately described; it cannot be labelled feature-complete while required scope remains unfulfilled.

## Evidence boundaries

The baseline is six merged commits beyond the prior package review. Those commits changed instructions, tests, and verification notes, not production sources or the native build graph. Test counts in the linked PRs are reported historical executions, not new tests run by this roadmap. After the audit, owner PR #45 (merged as `b8e927c`) changed the native reset action and its focused tests; that acceptance is recorded on the N-RESET-UI row.

Current build, provider, and release boundaries remain documented in [XCODE.md](XCODE.md), [continuity ingress](docs/CONTINUITY-INGRESS.md), and [README.md](README.md). Historical package gates are not silently closed or reinstated as automatic dispatch.

## Current prerequisite snapshot — September 14, 2026

- **Source and review state:** the configured fetch/push remote is `flynn33/Forge-Conductor-MacOS`; local `main`, `origin/main`, and GitHub's current `main` ref equal `50d18219fd7f898f2a7cb9bb5cc057aa3c2d9a3e`. GitHub reports PR #46 merged and no open pull requests. Pre-existing untracked lock files, a profiling result, and an alpha-recovery directory remain preserved and excluded.
- **Native host:** the inspected host is an Apple-silicon Mac16,7 with 48 GiB physical memory, macOS 26.6.2, Xcode 26.6 build 17F113, and Apple Swift 6.3.3. This is prerequisite inventory, not a signed build or hardware-support matrix.
- **Signing and notarization:** Release settings still resolve marketing version 0.9.0, build 1, Developer ID Application, and team `2Y25RTLZET`. The current keychain exposes a usable Apple Development identity but no Developer ID Application identity. No approved notarization profile was identified. Distribution remains blocked pending owner-provided credentials and later product gates.
- **Provider:** LM Studio and its CLI are installed, but the local server was off during this inspection. No provider workflow or continuity claim was exercised.
- **Authority:** the current owner-directed one-slice workflow remains active. This prerequisite reconciliation does not authorize merge, replacement of the working installation, credential creation, notarization, public shipment, or another product slice.
