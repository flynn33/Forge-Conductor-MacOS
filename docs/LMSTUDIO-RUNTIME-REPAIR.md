# LM Studio runtime repair — 0.18.0 (28)

This repair is in progress. Source implementation, deterministic tests, native
candidate execution, the installed app, and the ordinary LM Studio chat remain
separate evidence classes. The working installation and its registrations have
not been replaced. An inspection-tool relaunch migrated the live SQLite store;
the incident and recovery gate are recorded below. The owner ships the qualified
build separately.

## Owner publication and installation checkpoint

The owner requests publication of the current **0.18.0 (28)** source/document
checkpoint and wiki synchronization, then will handle installation. Further
product repair waits for the owner's installation report. Publication and
synchronization are not claimed complete here; exact owner revisions/readback
and local-main synchronization belong to their verified external receipts.
Existing signing, identity, executable modes and installation boundaries remain.

Current source `5af17b77…` retains **93 passing affected source cases**, the two
separate **passing native XCTest regressions**, and subsequent five-role Debug
identity/settings evidence above. Earlier negative receipts, the fresh Debug
cleanup NONPASS and incremental-only confirmation scope are preserved. Version
and build authorities remain **0.18.0/28**; the canonical graph remains
`534e6476…`. Historical version/evidence references keep their original inputs.

The first current managed-policy attempt remains **NONPASS before model
activation**. Its harness supplied a **3,233-byte mission ending in a newline**;
`ManagerNode.validatePreparedMission` requires the mission to equal its trimmed
value, so readiness failed before any run start. The retained HTTP010 transport
response has **216 bytes**, SHA
`e7862ba5f8413431b3f25f7965eaf724493f27a74681705303709493b46c5ee7`;
root's closed-file reconstruction matched that readiness-failure response. This
is a harness preparation failure, not an observed model or detector failure.
Manager **3596** exited native **0**, stdout/stderr **0/192 bytes**, complete EOF,
without forced signals. The original receipt also retains its closeout-observation
failure; separate protected-process/registration checks do not requalify it.
Receipt
`candidate-probes/managed-stjornarvald-model-notice-correction-prepared-v1/run-root-admitted-one-policy-attempt/receipt.json`,
SHA `69e4f2e3cf73f0339cebec5e05992a9aabd34a7c2867faa0ce5ae233b485e9f5`.

Actual model notice consumption/correction, ordinary GUI rollover, crash,
installed, full-policy and all-feature gates remain open. One automatic detector
and14 guidance-only rules remain; this handoff adds no detector or feature scope.

## Managed policy feedback and source replay — source checkpoint

The immediate-feedback baseline executed
`StjornarvaldPolicyNoticeTests/testToolQueuedManagedNoticeReachesImmediateFeedbackWithoutChangingCanonicalOutput`
and failed **three assertions**: a notice queued by that tool did not reach its
next feedback request or become presented after acceptance. The executor now
adds bounded optional notice context before freezing that feedback input,
preserves canonical tool outputs and accounting, and defers the notice when
item/body/budget limits or frozen replay input forbid it. Presentation still
requires the matching completed provider response. Ordinary transports without
optional preflight keep their existing output path; mandatory source admission
is unchanged. The same regression passed **1/1, zero failures/skips**, native
command **0**, full **1,704-byte EOF** in **5.414773292 seconds** on retained
source `21260e35…`, with all439 inputs unchanged and unforced cleanup. Receipt
`candidate-probes/managed-policy-tool-feedback-fixed-capture-v4/capture-receipt.json`,
SHA `b9684d9e7e7ceae78efaa3f11e7e4680d26148bc5fff9ddf49e55fa9eb70ece2`.

The four affected classes then executed **62 cases: 61 passed, one failed, zero
skipped**, native command **1**, full **20,898-byte EOF** in **183.7446005 seconds**.
`SourceDerivedSuccessorPreflightTests/testPendingFeedbackNoticePreservesExactSourcePrefixAndCompletedReplay`
failed after the notice/output-prefix assertions; the exact diagnostic reported
`waitingResource` / `source_continuation_effect_required`. The repository's source
resumption query required the output-only full-input hash, so it could not select
the actual child whose input included the appended notice. Receipts
`managed-policy-tool-feedback-four-class-capture-v2` (`a93176ca…`) and
`managed-policy-source-feedback-diagnostic-capture-v1` (`4138d2a5…`) stay **NONPASS**.

The local repair stores an optional exact output-prefix digest in the existing
FULL-durable source preflight receipt, derived only after validating the actual
complete input SHA and bounded canonical output-plus-notice shape. Child discovery
preserves the legacy exact-input branch and its ambiguity bound; an appended
child must pass the complete stored receipt/hash/intent validation before its
prefix can qualify. No table, receipt version, dispatch authority or legacy
output-only input is changed. The **same original failing case passed 1/1**, zero
failures/skips, native command **0**, full **2,301-byte EOF** in **17.835217542 seconds**
on source `5af17b77…`, all439 inputs unchanged, unforced cleanup and no survivors.
Receipt `candidate-probes/source-feedback-prefix-proof-fixed-case-capture-v1/capture-receipt.json`,
SHA `fed10f634a9e35fc9a343938c624603db90e153e90f0d576ef90776f83556b45`.
Two disjoint source selections then passed **93 cases, zero failures/skips** on
the same `5af17b77…` inputs:

- Four affected classes: **65 passed**, full **21,473-byte EOF**,
  **187.60256375 seconds**; receipt
  `candidate-probes/source-feedback-prefix-proof-four-class-capture-v1/capture-receipt.json`,
  SHA `688ea0f7f58c604b20d61b2d4da3d985207da7796e67e75d9338add29eff4838`.
- Adjacent bootstrap-authority and source-journal classes: **28 passed**, full
  **10,185-byte EOF**, **4.09458275 seconds**; receipt
  `candidate-probes/source-feedback-prefix-proof-adjacent28-capture-v1/capture-receipt.json`,
  SHA `c149df14b24da4f3f3f7260546fa3bec55aa210f2602ac0bffdd1a01af16a0e3`.

Both native commands returned **0**, all439 inputs stayed unchanged, cleanup was
unforced and no owned processes remained. The 65 include the original replay
case and the new prefix-receipt negative controls; these are selected source
regressions, not a new unfiltered suite or actual-model policy proof.

Fresh Debug13 returned native **0** and one BUILD SUCCEEDED marker, retaining
**530,398 bytes/full EOF**, **86.541915875 seconds** and unchanged439 inputs.
Its whole capture remains **NONPASS**: owned Xcode `ibtoold` PID **99460** remained
after the **28-second** observation grace and cleanup sent **SIGINT**. The retained
parent chain and identity-bound, arguments-free observation identify that helper;
this is not a product compilation failure or evidence of a Forge leak. No owned
processes, ambiguity or cleanup errors remained. Receipt
`candidate-probes/canonical-native-policy-feedback-debug-v13/debug-build-capture/capture-receipt.json`,
SHA `a3838686f9f5e2ef0af8a9a0a216ba637c3c2acf08575fa7d3b3ff33b62b30a0`.
A **separate incremental Debug confirmation** using that same DerivedData passed:
native **0**, one build-success marker, full **26,477-byte EOF**,
**1.673297417 seconds**, unchanged439 and unforced cleanup with no survivors.
Receipt `candidate-probes/canonical-native-debug-confirmation-v13/debug-build-capture/capture-receipt.json`,
SHA `ac58c59284838072c0a2d73ddc57747b779e177226bced213da36481ccde9ebf`.
This does not requalify the fresh capture or establish fresh-compilation success.
At the preceding source checkpoint, selected native XCTest, post-test five-role
identity and the actual managed notice/correction mission were pending.

### Subsequent native regression and Debug identity checkpoint

Using the separately qualified incremental Debug confirmation, the two intended
cases then each passed **1/1**, no failures/skips, native command **0**, unchanged
439 inputs and full EOF/unforced cleanup:

- Immediate-feedback notice case:
  `StjornarvaldPolicyNoticeTests/testToolQueuedManagedNoticeReachesImmediateFeedbackWithoutChangingCanonicalOutput`,
  actual test **0.036 seconds**, capture **41.380422083 seconds**, full
  **237,480-byte EOF**. Receipt
  `candidate-probes/canonical-native-policy-feedback-one-xctest-confirmation-v13/native-test-capture/capture-receipt.json`,
  SHA `af9070ee5e033791de7d5f044d08c17c910e78cc78e7b807d633f2ed51a0b559`.
- Original source-replay case:
  `SourceDerivedSuccessorPreflightTests/testPendingFeedbackNoticePreservesExactSourcePrefixAndCompletedReplay`,
  actual test **1.428 seconds**, capture **3.315848417 seconds**, full
  **17,702-byte EOF**. Receipt
  `candidate-probes/canonical-native-source-feedback-one-xctest-confirmation-v13/native-test-capture/capture-receipt.json`,
  SHA `c796e1086bea7f29c274e7085bbf09db75048c40fe1347453caca5c3e2827de7`.

The subsequent Debug identity passed all **five roles/15 native-zero controls**
(metadata, entitlements and strict verification), with all30 bounded stdout/stderr
streams complete and no errors. Summary
`candidate-probes/canonical-native-policy-feedback-debug-v13/debug-identity-capture-v13/summary.json`,
SHA `0ce835ef4e80d522e6f4d153f91554b71dffb303b1690916da710ffd86affbef`.
Both effective-settings queries passed native **0**, full streams and unforced
cleanup: scheme **0.662244167 seconds**, stdout/stderr **48,024/225 bytes**
(receipt `0ba0fbcc…`); all-targets **0.840879458 seconds**, **501,550/0 bytes**,
13 rows (receipt `74c05bbd…`). Version/build remain **0.18.0/28** and all439 source
inputs stayed unchanged.

These are current compiled regression, Debug platform identity and settings
results. They do not requalify the fresh Debug cleanup NONPASS, confer fresh-
compilation success or add a current Release result. The actual managed
notice-specific response/correction mission remains **unverified**; no model
understanding, GUI rollover, crash, installed or all-feature acceptance is added.

The original baseline remains NONPASS; its closed-file reconciliation
`4a60d0e2…` records the actual one-case/three-assertion failure separately from the
capture's dot-form versus Objective-C-form identity mismatch. The fixed-V3
capture's compile failure (`136ba2e5…`, zero executed cases, invalid nil fixture
usage arguments) also remains NONPASS. One automatic detector and14 guidance-only
rules remain. These source results do not establish model notice understanding,
ordinary GUI rollover, crash, installed, full-policy or all-feature acceptance.
All earlier signed/runtime/source results and explicit skips keep their original
inputs. Publication remains OPEN as recorded below; no owner/signing or executable
mode protection is relaxed. The canonical graph remains `534e6476…`.

## Forge-owned saved-count rollover mission — PASS

The separate actual-model mission on retained source `e3762543…` and the signed
v11b Debug CLI passed. It retained **five accepted completed provider turns** and
**four exact successful `fs_read` results**: three predecessor reads triggered the
saved threshold **3**, then one successor read and its completed feedback. One
operation and two sessions retained the same handoff, typed V2 acknowledgement
and sealed predecessor. The model's final 272-character prose-plus-terminal JSON
was accepted by production completion parsing; native validation committed
**completed revision 16**, expected revision **15**, one passed
`forge.package.tool-success` gate and ordered completion events **60→61**.
Empty evidence references are allowed by that gate's existing contract.

Completed proof stayed unchanged for **10.072459625 seconds**. Ordinary
authenticated APIs then restored private output **8,192→4,096** and count
**3→200**, with readback/disk proof. Before/after Qwen inventory matched context
**262,144** and parallelism **1**; no load/unload or budget override was used.
Manager **93152** and handoff hash helper **93468** returned native **0** with
complete bounded stdout/stderr EOF, no cleanup signals/errors and confirmed
owned absence. Manager retained **0 stdout/192 stderr bytes**. Source439,
five candidate roles, ten original protected identities and registration stayed
unchanged. Of **19 HTTP attempts**, the first was an expected pre-listen
connection refusal; the other **18** were accepted with full EOF. That startup
negative and the initial overstrict file-audit assertion remain retained.

Receipt:
`candidate-probes/managed-saved-count3-full-mission-v11b-prepared-v1/`
`run-root-admitted-full-mission-one-attempt/receipt.json`, SHA
`884972a76e493d9fae4ae03c883d005a524428b076192d58d229ee563ea06104`;
closed-file reconciliation SHA
`64587b5506295b8c2c47df5d9856583fa0a365655406bf121cb954d7cd5b6625`.
The full completion receipt is retained and bound to the native trusted writer
and completion events; its proof hash and event-chain preimages were **not
independently reconstructed**. Raw provider request wire bodies were not
captured. Remote-provider quiescence, ordinary GUI rollover, policy notice
comprehension, crash, installation and all-feature acceptance are not claimed.
All earlier failed/paused missions and NONPASS receipts retain their original
scopes. Newer policy-feedback source work is separate from this retained mission;
this pass supplies no validation credit for later inputs. Publication remains
**OPEN**, with these source/document changes local.

## Typed Simulator and managed Xcode workflows — scoped evidence

The third typed Simulator fixture passed in **76.908 seconds**, with outer exit
**0** and `qualified=true`. All **20 native jobs** returned zero; their **40 full
output streams** reconciled **598,651 bytes**, exact hashes, producer EOF, no read
errno and complete page EOF. The owned iPhone 17 Pro/iOS 26.5 fixture ran both
`SimulatorFixtureTests/testRunsAsNativeIOSSimulator` and
`SimulatorFixtureTests/testUsesExactOwnedFixtureHost`: **2 passed, 0 failed,
0 skipped**. Cleanup removed device `47274467-3fb0-4d70-9cc4-fda13fa87ffb`,
preserved all **32 pre-existing device identities/states**, confirmed known owned
runtime absence and retained source439/protected-process guards. Absence of all
unobserved runtime processes is not claimed. Both earlier Simulator attempts
remain NONPASS; the second attempt's separate cleanup does not requalify it.
This is **typed tool/fixture proof**, not model-driven Simulator, installed or
all-feature acceptance.

Evidence: `candidate-probes/simulator-typed-xctest-followup-v10-prepared-v1/`
`run-root-admitted-third-attempt/execute/receipt.json`, SHA
`3c95235fc174fefaa4c16d0e20becf4489785b5cdf4606800e70698358248339`;
root reconciliation SHA
`1dfa4d2b8d6ef7668a040c683deac3dff7a311d8f05b33abf548197e5a88509c`.

The retained actual-model Xcode workflow independently reconciles **15 linked
accepted turns**, **15 completed successful calls**, three native-zero jobs and
all six native streams consumed through nine pages. Exact intended arguments,
command fingerprints, producer EOF/no errno/no loss, status/DB byte totals,
prerequisite order and typed counts remain required. The selected
`RuneForgeAppTests/testNewerPolicyReorderSurvivesOlderLateSuccess` passed once;
xcresult reports **1 total/1 pass/0 fail/0 skip/0 expected failures**.

The 1,906-byte final message contains prose before a terminal 550-byte completion
object. Production `completionRequestSummary(from:)` accepts that shape; its
strict 456-byte inner summary matches actual job IDs/counts/title. The exact owned
query-only durable record confirms **completed revision 9**, an identical
assistant projection and a passed manager validation receipt at expected
revision 8, with completion-requested event 168 followed by completed event 169.
The original harness parsed the whole message and failed with `JSONDecodeError`;
original receipt
`b49c39c5f9f113201b98e0c1e3f42996d59dafdeafabb0ef40e6be7d5ecc550f`
remains **NONPASS**. After-provider inventory and later default-policy checks were
not reached. Separate nine post-run signature controls passed in their own scope.
Independent evidence is
`candidate-probes/model-xcode-completion-independent-reconciliation-v1/reconciliation.json`,
SHA `f049cf9a26ad908e31378a84ed651c8efb2c7f48d22fb00c051200bdf1aebf03`.
This is scoped actual-model native workflow/completion proof, not a retroactive
full-harness pass or fresh-compilation claim. Both workflow positives retain
source `80f542fa…`; newer repairs below need their own validation.

## Applied policy, diagnostics and Debug signing corrections — source and native scopes

The original six-case source baseline remains **NONPASS**: six failed tests,
ten assertions, full 7,498-byte EOF/native 1/unforced in 10.350 seconds (receipt
`916b024c44f8e7a8068254a158c327fcb15f95b35b328ff85e0b21fc0a970bef`).
The first post-fix attempt retained **4 passes/2 unexpected fixture failures**
(`7c02041e…`). Setup used an unstarted HTTP manager and an incomplete lost-receipt
response. Fixture corrections use an actual durable ordinary MCP binding and a
separate lost **completed** receipt mode; old modes and detector/cache assertions
are preserved. The ordinary tool-response setup assertion was replaced with
actual durable repository binding.
Reverting only the managed-policy/local-origin production patches then reproduced
**3 failures/3 passes**, three assertions and zero unexpected failures in
15.072 seconds (receipt
`a055d51981d7ae51c308597901bf4a6d8eeaad3dbbab4775956bc035e2d75dd9`).
Restoring those patches retained **5 passes/1 unexpected fixture failure**
(`16722790f69895a2c4dae1783c7ce2e73450b7085523d8d48e13939e4c135014`):
the second managed-session fixture reused a provider/response identity and hit
the existing SQLite uniqueness guard. All failed receipts remain unchanged.

The final fixture uses a unique session-specific response identity, preserving
the guard, both-session/cache/detector assertions and all six selectors. The same
**six source controls now pass**, **0 failures/0 skips**, in **6.357 seconds**:
command exit **0**, full **4,077-byte EOF**, unchanged source439 and unforced
cleanup with no owned survivors. This is a selected `swift test` result;
inherited “unfiltered” receipt labels are rejected by the actual argv/identities.
Receipt `candidate-probes/managed-policy-and-activation-diagnostics-fixed-v3-test/`
`capture-receipt.json`, SHA
`9551f5abb2ab14fb84c50a666a53d64caabb38a12f2af2a42eccf0b4a62c9937`;
raw SHA `29b815b3d828f9c548d05558f301c0fc0a3d6e36ffda72dcc4da2f32b247fbf4`.

Four production corrections are applied:

- Managed native policy capture validates the current accepted run/session
  binding before and after traversal and isolates retained digests by run/session;
  invalid, stale and foreign ownership stays rejected. Ordinary MCP capture and
  one-of-15 automatic detector coverage are retained.
- The supervisor records the first bounded, sanitized activation failure per run;
  transition events retain error code/summary before later last-error replacement.
  Existing ownership, retries and last-error behavior remain in place.
- Optional `local_intent_conflict` receipt evidence identifies an observed local
  unexpired-intent fence. Existing conflict enum/code/description, retry disposition
  and the 660-second lease are retained. Legacy absence means unknown and does
  not establish HTTP 409 or recover the earlier initiating exception.
- The Debug CLI enables existing Xcode base-entitlement injection for native
  debugging. The signed Debug CLI now has `get-task-allow=true`; all five
  Release roles have it disabled, with existing distribution settings retained.
  Scoped actual-model CLI debug/production completion is now independently
  verified; broader debug validation remains pending.

The four affected source classes subsequently started **119 tests**: **115
passed, four explicitly skipped, zero failures**, command exit **0**, full
**38,250-byte EOF** in **177.995 seconds**, unforced cleanup/no owned survivors
and the same source439 inputs. `AutonomySupervisorTests` executed 48 (46 pass,
two skip); `ManagedModelProviderBridgeTests` executed 11 (all pass);
`ProductPathReliabilityTests` executed 35 (33 pass, two skip); and
`StjornarvaldIntegrationQualificationTests` executed 25 (all pass). The two native
job controls require explicitly prepared packages/evidence; the two candidate/
peer controls require signed candidates and an older same-version peer. These
**four skips are not passes**. Receipt
`candidate-probes/managed-policy-and-activation-area-regression-v1-test/capture-receipt.json`,
SHA `b2e05ae47a4a36ea0438e8db5fdc41e810c48daba095976708e955b9bbf68b30`;
raw SHA `623f0df9024f57ea500944451e6f361a6ee4aec9b8a59455f0b3433985895d1b`.

Fresh native captures use the same `e3762543…` source439 and project graph.
The first Debug capture returned native **0**, one `BUILD SUCCEEDED` marker and
full **515,467-byte EOF**, but remains **NONPASS**: after a 28-second observation
grace, the runner sent **SIGINT** to tracked owned `ibtoold` PID 87035. This is
cleanup evidence, not a Forge leak/hang or inferred helper-cause claim. Receipt
`016c3f1879516cdbc761461f5e6be5aaaa775eeaaf38ba75465554987408d9e5`
remains unchanged. A separate **same-candidate incremental Debug confirmation**
passed native **0**, full **25,565-byte EOF**, unforced cleanup/source stability
in **1.726 seconds** (receipt
`923e52caa904a330fd41a8e22ee7cb72f377bd2787dfe712ac314473c0270a13`).
It is not a fresh-compilation claim. The separate fresh Release build passed
native **0**, one success marker, full **541,633-byte EOF**, unforced/source439
stability in **149.875 seconds** (receipt
`1e6b8674001480afaf1bd6557f91ebe2af24739c960f11895f59b757dd8cfbd7`).
App/Core binary hashes changed across distinct captures with actual `CodeSign`
lines; final platform identity pins follow the incremental confirmation.

All **four effective-settings queries** and **30 platform signature/metadata/
entitlement controls** passed with complete native streams and unforced cleanup.
Debug five-role identity SHA
`8bc61c8e467c796295aec186dc131fdaf1c917d36270432d0fa0f5afa9154bec`;
Release SHA `a1917e07fa1276582eeaab1b2fd4ca89271ad7cedaec0b8383e13000d16524ec`.
The actual Debug CLI has `com.apple.security.get-task-allow=true`; all five
Release roles have it disabled. Existing Developer ID/Manual/team/hardened
Release settings remain in place; no signing override or key was introduced.
Evidence is `candidate-probes/canonical-native-closeout-v11b/`, plus the separate
`candidate-probes/canonical-native-debug-confirmation-v11b/` confirmation.

The same **six compiled native Core controls passed**, **0 failures/0 skips**,
native exit **0**, full **705,989-byte EOF**, unforced/source439 stability in
**96.702 seconds**. Both managed-policy producer/detector/cache ownership cases
executed in the compiled Core target; this does not establish model/session
notice understanding. Receipt
`canonical-native-closeout-v11b/native-test-capture/capture-receipt.json`, SHA
`0fca4ae857dd684be708d2e31ea6246652d480bfef53893198eded3fa32c9bf3`;
raw SHA `37e9c3c3dfbfc181fd8337f0bb1dc5b5c8aaa92d013d0c183180d9eebbbef62a`.

The actual-model **LLDB v2 attempt remains NONPASS** (receipt
`35271baf9ced496f07b9668033907a64d56077469bbcd9ff06af459a74a8d02c`
at `candidate-probes/owned-managed-forge-cli-lldb-v11b-followup-prepared-v2/`
`run-native-v1/receipt.json`). Its native job returned **0** with complete
**2,425-byte** producer-EOF output: the signed CLI launched, stopped at `main`
breakpoint 1.2 and produced a backtrace. `continue` stopped at another `main`
location (1.1), then the script quit; required CLI help and inferior exit-zero
proof are absent. Root preserved snapshot 7 and stopped the controller with
SIGINT. Manager exited **0** with full streams, no cleanup signals/survivors,
and source439/five roles/protected10/registration guards preserved. After-provider
inventory is NULL; remote quiescence is unknown. Signing/debug launch is positive
in this scope; the complete debug mission is not. The corrected closed v3 recipe
adds `breakpoint disable 1` after the backtrace and before continue; every required
completion/output predicate remains. The four earlier source skips remain skips.

The corrected actual-model **LLDB v3** native transcript now contains all six
ordered commands, the first main stop/backtrace, disabled breakpoint, CLI help
and inferior PID 90196 exit **0**: native job **0**, full **3,955-byte stdout**
(SHA `df0c0753df5ab6c2b71b6a6fe41554fbb594c10449e417d4c8288a85957087af`),
zero-byte stderr, both producer EOF/no errno/no loss. Retained snapshot 7 shows
**completed revision 8**, four turns/four calls. Its original receipt
`842daee9cddc26c12fc5cf8d252cd55f6f6d1d1430ba047e4a7996a492652c64`
remains **NONPASS** after a whole-message `JSONDecodeError`. Independent and
root closed-file reconciliation both verify **scoped actual-model native debug/
production completion**, without requalifying the original harness. The final
**1,759-byte** prose-plus-terminal-object reply ends with a **322-byte** object;
its **246-character** strict summary matches the actual debug job, marker, main/
backtrace/help observations and native/inferior identity/zero exits. Production
`completionRequestSummary(from:)` accepts this terminal shape within its existing
16,384-character tail, eight-opening, 8-KiB JSON and 2,048-character summary bounds.
The durable run is **completed revision 8** with passed validation at revision 7,
one `forge.package.tool-success` gate, two automatic obligations and four paged
evidence records; proof
`efb50dd191bd13e2f5922f500275e3dd890d951add6554d535f97b3e21edec84`.
Completion-requested event 44 precedes completed event 45. All **43 retained event
preimages** were checked: **31 audit events plus 12 independent managed-activity
projections**, with audit links verified across those projections. Reconciliation
`candidate-probes/owned-managed-forge-cli-lldb-v11b-followup-prepared-v3/`
`root-closed-reconciliation-v1/reconciliation.json`, SHA
`1ab61901fa955bca128f21b5ddff101fa9c8794071ea7e9ff81fa7085d21fafc`,
is byte-identical to the independent report. Manager exited
**0**, full EOF/unforced/no cleanup signals/errors/survivors, with the same source/
five-role/protected10/registration guards. After-provider inventory remains NULL;
remote quiescence is unknown. Target-after physical stat is also NULL; the full
original prelaunch PID set was not independently reconstructed, while the retained
fresh native PID guard remains. This is signed Debug **CLI `--help` debug/managed
completion proof only**, not full app mission, all-feature debug, fresh compilation,
GUI, crash, installation or shipment acceptance. Evidence is
`candidate-probes/owned-managed-forge-cli-lldb-v11b-followup-prepared-v3/run-native-v1/`.

The two separate signed-candidate opt-in controls passed **2/2**, **0 failures/
skips**, native **0**, full **1,785-byte EOF**, unchanged source439 and 15 candidate
file byte/stat bindings, and no outer cleanup signals/errors/survivors in
**4.714 seconds**. They exercise candidate identity/version-drift rejection and
reporting a different same-version running executable. Receipt
`candidate-probes/native-candidate-optin-two-case-v11b-capture-v2/capture-receipt.json`,
SHA `ccfdaabe70edef794c0ec03449b4b6e12f022791f78d4324800e0ac8d0f1a663`;
raw SHA `52cda97e13dabec8821ca9031f9cc096bb4b82c764dc3062418ca93d1beab3ec`.
Internal peer fallback signals and graceful exit were not measured, so graceful
peer shutdown is not claimed. These are separate results: the earlier four
source-area skips remain unchanged, and the other two Autonomy opt-ins were not run.

Fresh managed-policy model runtime, ordinary GUI rollover, broader debugging,
crash and installed/all-feature acceptance remain open. The separate continuity mission subsequently passed in its retained
`e3762543…`/v11b scope, recorded above. The six
source passes do not establish the second 8,192-token failure's original cause,
new count/UI functionality, additional detector coverage or installed acceptance.
Current source439 manifest:
`e3762543e1c863a965955c81c0c95551eb6b28744f9e075449ed27f2da2f347a`;
canonical project hash after the single Debug setting change:
`534e64769726b4fe2b07840d83165bd6b906d7696db47d451f8dd153bba00c59`.
All earlier scoped passes, explicit skips and negative receipts remain retained;
the running installation remains separate.

At the preceding publication checkpoint, source/document changes remained local
at `f0dd195636117c210356621ee844b24a9af46fe2`, without a commit or push. The SSH-agent
and keyless GraphQL limitations recorded then retain that scope.

For the current owner-directed handoff, root verified owner account `flynn33`
and the existing authorized Admin Role bypass. The planned route is an
owner-authored local Git commit and direct push; the source commit will be
**unsigned**, with no verified-signature claim. No new signing key, repository
rule change, native-app signing change or executable-mode weakening is part of
that route; mode **100755** on
`Sources/ForgeConductorCore/Resources/Agents/precommit-audit.md` remains preserved.
Publication, source/wiki readback and safe local-main synchronization are not
claimed complete before execution. Exact resulting revisions and verification
receipts will be retained externally after the push.

The first current **8,192-token actual-model attempt remains NONPASS**. It
reached the saved-three-call trigger, same-handoff acknowledgement and predecessor
seal, one successor marker read and its completed feedback. The protected-process
count guard then rejected the paused-stability check; cleanup sent one owned
SIGTERM. Stability, ordinary shutdown, restoration and final inventory/coherence
gates did not complete. Later ten-process parity does not requalify that run or
identify the initiating cause.

The current ordinary GUI attempt also remains **NONPASS**. Root's retained CUA
summary records default 200, stepper 4→3, Save 3 and unsaved 7→Reload 3; API/disk
captures agree. Provider output Save/Refresh, restart persistence, restoration and
ordinary Quit remain unverified after SkyComputerUseService failures. Three crash
reports name that service/SIGTRAP; its triggering mechanism and any Forge
accessibility role are unknown. The summary is not raw AX export. Prior source,
native and negative receipts retain their scopes; exact evidence is in the repair
record. Neither partial result qualifies ordinary GUI rollover, actual-model
Xcode/LLDB, Simulator XCTest, crash recovery or the installed product.

The current **private native Stjornarvald v10 replay passed** in 10.182 seconds
on the same `80f542fa…` inputs. It detected the declared production Python fixture,
presented its notice over MCP and recorded correction after membership removal;
resource-only JavaScript stayed advisory, alias roles raised the native finding,
and an unavailable graph preserved history. Manager and both MCP processes
returned zero with full captured EOF and unforced cleanup; 439 inputs, five
candidate binaries, ten protected identities and registration remained unchanged.
Automatic coverage is still **one of 15 indexed rules**, with 14 guidance-only
rules. This private detector/correction/transport fixture establishes no model
comprehension, policy GUI, installed or full-policy compliance; historical job
page EOF receives no native producer-EOF credit. Exact evidence is in the repair
record.

## Current private Stjornarvald native v10 replay — scoped pass

The current private fixture at source `80f542fa…` completed in **10.182 seconds**.
Declared production Python membership opened a finding at confidence **0.99**;
one notice was marked `presented` to the exact scoped MCP client, and removing
that membership recorded correction at **0.98**. A fresh resource-only JavaScript
declaration retained an advisory review finding at **0.45**. Adding source/copy
aliases for the same file produced the native finding at **0.99**; an unavailable
graph retained that history and open state, and actual membership removal
recorded correction. The fixture script was declared evidence and was not
executed as production application behavior.

Manager and both owned MCP stdio processes returned **0**, with complete bounded
captured EOF and unforced cleanup. Root's independent reconciliation retains the
same **439 source inputs**, five candidate binary hashes, original ten protected
identities and registration, and confirms all three owned PIDs absent. Evidence
is at `assessment/native-candidate-v10/`: summary
`57092a8d8dc14b7544e0ab4a3fcfd428cf205e5b6cc8b5b54ce535d74c71718a`,
root reconciliation
`6a9f1ba2c825088beff58ba33536469149223c2cf492f09f7d93f9778b313d3c`.

This is **current native private detector/correction/MCP transport proof**.
`RFD-NATIVE-001` remains the only automatic detector among **15 indexed rules**;
14 are guidance only. Presented transport does not prove model comprehension or
correction by a model. Declared resource roles do not decide browser-resource
policy applicability or inspect binary runtime contents. No Rune Forge GUI,
ordinary chat, installed product, full-policy compliance or full-feature
acceptance is qualified. The older fixture job's terminal/page reads do not
establish native producer EOF. Earlier source/native receipts, explicit skips
and all NONPASS results remain retained. This replay changes no production
source, signing, shell capability, detector scope or canonical graph.

## Latest GUI, second 8,192-token and model LLDB attempts — NONPASS

These attempts retain source `80f542fa…` and signed candidate v10; they do not
qualify a later source manifest. The CLI-Manager GUI variant used the same
candidate's embedded CLI for Manager and app executable for the GUI. Its
`initial-default`, `saved3` and `reloaded3` API/disk captures matched counts
200→3→3; provider output stayed 4,096 at revision `0`. Root observed count
Save/Reload through CUA. Two further **SkyComputerUseService** crash reports,
`2026-10-06-144043.ips` and `144047.ips`, retain `EXC_BREAKPOINT`/`SIGTRAP` and
`Array.remove(at:)` fault frames. Repetition with the separate CLI Manager does
not identify the trigger or a causal Forge accessibility role. Provider
Save/Refresh, relaunch persistence, restoration and ordinary Quit remain open.
The owned GUI exited `-15` during cleanup and Manager exited `0`; final source,
five-binary, protected-process and registration checks passed, while the full
phase sequence, commands, required child-identity and ordinary-exit gates did not.

The second owned **8,192-token mission remains NONPASS**, with
`qualified=false`, `diagnostic_complete=false` and no canonical/replay/paused
proof reference. Root's retained reconciliation records three completed
predecessor `fs_read` results, followed by two successor `fs_read` error results
without the assigned marker. A later tool-continuation turn reached attempt
four and remained `ambiguous` with `lmstudio_conflict`; the run was paused.
The first-error cause remains unknown. The owned Manager returned `0` with full
stdout/stderr EOF, no signals or cleanup errors; count 200 was restored and the
private output setting remained 8,192. Source, five candidate binaries, original
protected identities and registration were preserved. No after-model inventory,
final output-coherence, remote-provider quiescence or full mission proof exists.
The earlier first-attempt marker/feedback observation retains only its own scope.

The actual LM Studio model submitted **`xcode.debug`** for the signed Debug
Forge CLI with `--help`. LLDB created the target and set 37 `main` breakpoint
locations, then `run` reported **“Not allowed to attach to process.”** The job
failed with native exit `1`; stdout 612 bytes and stderr 309 bytes each retained
actual producer EOF and no truncation. No breakpoint hit, backtrace, continued
inferior exit or completed debugger mission was verified. The controller's
49.394-second receipt is **NONPASS**; its owned Manager returned `0`, all owned
identities were absent, and source/five binaries/protected processes/registration
were preserved. The denying macOS subsystem and required authorization remain
unknown; signing and entitlement protections were not changed.

| Retained evidence under `candidate-probes/` | SHA-256 |
| --- | --- |
| `ordinary-native-gui-settings-v10-cli-manager-prepared-v1/runs/b5d36007-c8bc-4ece-bd62-5fbcec327055/ownership-receipt.json` | `e56bf418166fd4ab9b4891fcf62364e61129ca85fea429dde9eb5c2d91fb7365` |
| Same GUI run, `final-identity-receipt.json` | `11b6a730d7b7a2a40b7017009d7bcd93481ccf716844ec7ef732f3d49cb97e15` |
| `managed-saved-count3-output8192-protected-rejection-second-attempt-prepared-v1/run-root-admitted-second-attempt/receipt.json` | `f4882e9a52d2fac748df1bfd7b1265f28b9f7ce59d5d7159336bfe80a944f76b` |
| Same second attempt, `root-second-attempt-reconciliation.json` | `9b592761852c7a748431a2b3348dfb14f74ffeb46066ae1b60ffdd8efd96e9e4` |
| `owned-managed-forge-cli-lldb-prepared-v1/run-native-v1/receipt.json` | `132b989cc7c292306d8442d98d5dad8408b493fba4b638aca9d0c8d5b121a525` |
| Same LLDB run, `snapshot-004.json` | `6d4d854e798d3785571bb5768a4e2eed0015f4771cdea336914b353e4859fb7f` |

These failures remove no feature and grant no Simulator, crash-recovery,
ordinary-chat rollover, installed-product or full-feature acceptance. Earlier
negative receipts and scoped passes remain retained. This documentation-only
addition changes no canonical source/resource/test membership.

## First current 8,192-token attempt and partial ordinary GUI — NONPASS

At source `80f542fa…`, the first owned 8,192-token experiment retained an actual
saved-count-three rollover request, the same-handoff V2 acknowledgement and
`predecessorSealed`, one successor `fs_read` of `successor-only.txt`, and its
completed tool feedback. The paused cut contains two sessions, four tool results
and five completed ordinary provider turns. This is scoped lifecycle/effect
proof; it is not full-run qualification or evidence that increasing the output
allowance caused the different response. The prior 4,096-token empty-terminal
measurement and its unknown cause remain unchanged.

The run's receipt is **NONPASS**, `qualified=false` and
`diagnostic_complete=false`: the exact protected-process count guard rejected the
ten-second post-feedback stability check. Cleanup retained
`public_shutdown:Failure` and sent one SIGTERM to its owned Manager; that process
returned zero with complete stdout/stderr EOF, which does not make its forced
cleanup a pass. The receipt has no after-model inventory or final output-coherence
proof, and threshold restoration to 200 did not complete; the owned retained
configuration still holds threshold 3 and output allowance 8,192. The output
allowance was saved once through authenticated Manager configuration APIs in the
private home; it grants no real-home change or remote-provider quiescence claim.
Later root reconciliation found the original ten protected identities and
registration unchanged and the owned Manager absent. That point-in-time result
cannot reconstruct the initiating mismatch or requalify the run.

The retained run is
`candidate-probes/managed-saved-count3-output8192-terminal-metadata-controller-prepared-v1/run-root-admitted-one-attempt/`:
receipt `c7a6dc125dd79af66d8e895592fd798543960759e5bdfe46cb460b07ab1fac6a`,
paused cut `17e2db41dd53dd327dfea5cebdab4e70dd70f0c9ab98d8d75eac70c966ffb3fd`,
saved-output proof `9d44f0072feb48115e58c7ff2a7a4a8b715b76f89013c395308023f409dd713d`,
and later protected reconciliation
`23de0fe0e5e3728622dd0214eb808ad709f07a7c3c025ae15a8214819af8c34e`.
The closed second-attempt diagnostic preparation grants no executed outcome.

The ordinary native GUI v10 run is also **NONPASS**. Root's retained semantic
CUA summary observes the exact candidate's owned Settings home, default count
200, text entry 3, stepper increment 4/decrement 3, Save 3, and unsaved entry
7 followed by Reload back to 3. The `initial-default`, `saved3` and `reloaded3`
API/disk captures corroborate those values; provider output remained 4,096 at
revision `0`. This summary records prior CUA observations, not a raw AX export.
Provider output Save/Refresh, current ordinary GUI restart persistence, GUI
restoration to count 200/provider 4,096, and ordinary GUI Quit before stopping the
owned Manager were not verified. The fixed API/disk phase-sequence and clean
ordinary GUI-exit gates are false; cleanup reaped the owned GUI with exit `-15`
and Manager with exit `0`. Final identity checks retain all 439 source inputs,
five candidate binary hashes and original registration/protected identities.

Three retained crash reports identify **SkyComputerUseService** with
`EXC_BREAKPOINT`/`SIGTRAP`; the triggering mechanism and any causal Forge
accessibility role are unknown. They are not Forge application-crash or recovery
qualification. GUI evidence is at
`candidate-probes/ordinary-native-gui-settings-v10-prepared-v1/runs/a7bb7514-8843-4bf7-944f-570896180a8c/`:
ownership receipt `cdf90e99cc3fd3d1fd6edd4d5ab04141897e7a3c2bb428e4fcb576f217aef8b0`,
final identity receipt `7647078ea578578889ad767e22d94f0e92b495a5aa868f8315b4d0a2f2922f9c`,
and root CUA/closeout/crash reconciliation
`8e88f70ebfb73db2cc7702d9828811cb1f910d43b3551be1aa51a6654b3a47fa`.

These two partial results preserve the earlier source v14, selected native v10,
platform-identity evidence, explicit skips and all negative receipts. Full
ordinary GUI rollover, actual-model Xcode/LLDB, Simulator XCTest, crash recovery,
installed and full-feature acceptance remain open. The canonical graph and all
439 source inputs are unchanged by this documentation checkpoint.

The current `80f542fa…` checkpoint now has both source and signed native
validation. Full source v14 executed **2,310 cases: 2,297 passed, 13 explicitly
skipped, zero failed**; both Swift products built. Canonical native v10 Debug
and Release builds returned zero with full EOF and unforced cleanup. The Debug
selection passed **49 Core plus two app-hosted cases**, with no failures/skips;
all four build/test captures retained the same 439 inputs. Both configurations'
five roles passed all **30 signature/metadata/entitlement controls**, and all
four effective-settings queries passed. These results close current source,
selected native test, build and platform-identity scopes. Fixture/loopback and
view-model controls do not qualify actual-model Xcode/LLDB, a larger-output
LM Studio mission, onscreen GUI/ordinary rollover, Simulator XCTest, crash or
installed acceptance. Those gates remain open; the 13 source skips receive no
pass credit. Earlier checkpoints and all negative receipts retain their scopes.
Exact current receipts and binary identities are in the repair record.

A subsequent settings/compatibility checkpoint at source `80f542fa…` passed all
**14 focused cases**, native zero, no failures/skips, full **7,073-byte** EOF.
It covers output defaults/omission/persistence and CAS, malformed/authenticated
loopback updates, view-model Save/Reload and unsaved-action gating, immutable
REST-fixture 8,192-token probe/root/continuation bodies and accepted-receipt replay,
and budget headroom/inherited-ceiling checks. The six ordinary source classes
then selected **168 cases**: **166 passed**, **two explicitly skipped**, none
failed; native zero, full **52,355-byte** EOF. Both retained all 439 inputs and
finished unforced with no owned survivor. The two opt-in skips are the live
LM Studio fresh-root/continuation and disposable real-Keychain tests; neither
receives pass credit. This adds deterministic source settings/HTTP/view-model
coverage to the earlier pending checkpoint below. It does not qualify an actual
onscreen GUI, larger-output LM Studio run, refreshed full suite/native candidate,
Xcode/Simulator workflow or installed product. The empty-response cause and full
mission remain open; exact methods, receipts and scope are in the repair record.

A later source slice adds a saved **Maximum output tokens** field to the Provider
form: default **4,096**, range **1–65,536**, including reasoning and the answer.
Legacy configurations without this field use 4,096; explicit saved limits are
preserved. An omitted update preserves the saved value. The existing revision check and busy guard remain in place. This field is
an immutable requested transport limit, not a measured model/service ceiling.
The source repair carries it through capabilities so ordinary budget hooks retain
the same output reserve after provider/tool observations and evaluator restart.
Two REST-fixture regressions passed after their baseline failures; the broader
selection passed **33 REST cases plus one configuration-boundary case**, with zero
failures/skips, native zero, complete **11,351-byte** EOF, stable 439 inputs and
unforced cleanup. These are source checks at `31dcfd8b…`. Settings API/CAS/busy and
UI parity checks, a refreshed full suite/native candidate, and actual LM Studio
use of a larger output allowance remain pending. The v13/v9 results below predate
this slice; they qualify their retained `c1805d1a…` inputs. The empty-continuation
cause and full mission remain unresolved. Exact receipts are in the repair record.

The latest full source v13 run returned zero in **715.678 seconds**: **2,297**
actual cases executed, **2,284 passed**, **13 explicitly skipped** and none failed.
Exact case identities/statuses, class and bundle counts matched the retained
2,286-case v12 baseline plus 11 added QoS, provider-metadata and catalog cases.
The complete **688,301-byte** output reached EOF, all 439 inputs remained stable
and cleanup was unforced with no owned process remaining. Both v13 Swift product
builds also returned zero with full EOF and unforced cleanup. This is source
compilation/test evidence; the 13 skips receive no pass credit.

Canonical native v9 Debug compilation passed in **54.946 seconds**, native
zero with one build-success marker and complete **512,938-byte** EOF. Its selected
native XCTest capture passed **37 of 37** cases, with no skips/failures, native
zero and complete **718,240-byte** EOF. Both retained all 439 inputs unchanged
and finished without forced cleanup or owned survivors. All five Debug roles
passed strict signature, metadata and entitlement controls, and both Debug
effective-settings queries passed. These results are scoped to source
`c1805d1a…`; fixture-driven XCTests do not qualify actual Apple CLI workflows.

One owned actual-model saved-count diagnostic with threshold 3 reached the same handoff acknowledgement
and predecessor seal, then measured the first observed accepted empty successor
`automatic_continuation`. The completed response had provider transport EOF,
one reasoning item, **4,095 reasoning/output tokens**, and zero text/tool calls
under the unchanged **4,096-token** output setting and **262,144-token** context.
The receipt has `diagnostic_complete: true`, `qualified: false`, and
`failure: null`: the full mission marker/feedback proof was not reached. Manager
shutdown returned zero with both streams at full EOF; settings were restored to
200 and all 439 source inputs, ten protected processes and registration were preserved.
The cause remains unknown; no remote-provider quiescence or zero-extra-generation
claim is made. Current actual-model typed Xcode/LLDB, simulator XCTest, ordinary
GUI rollover, crash recovery and installed/artifact acceptance remain open.
Exact receipts are in the repair record.

Earlier canonical native v8 Release compilation passed in **151.458 seconds**, native
zero with one build-success marker, full **538,533-byte** EOF, stable 439 inputs
and unforced cleanup. Debug xcodebuild also returned zero with one build-success
marker and full **512,934-byte** EOF in **57.345 seconds**, but its capture remains
**NONPASS**: cleanup sent SIGINT to tracked PID 52101. Its first ancestry and
executable path are unknown; this does not establish a Forge leak or hang.
At that v8 checkpoint, native37 and refreshed identity/settings had not run.
The later v9 observations above retain the v8 NONPASS receipt; they establish no
cause for its tracked process and add no process exemption or product repair.
Current model workflow, simulator XCTest, ordinary GUI/crash and installed
acceptance remain separate. Earlier checkpoints below retain their own source
and artifact scope.


### Full source v14 and Swift products — output-setting checkpoint

All paths here are relative to `candidate-probes/`. The current tested source
manifest is `80f542faeb362d590d2ca3e87ece108f536c1a9f35ea21df128c088031487fc6`.
The unfiltered `/usr/bin/swift test` command executed exactly 2,310 XCTest cases:
2,297 passed, 13 explicitly skipped, none failed. Independently reading every
raw start/terminal line reconciled all 2,310 identities/statuses and the receipt;
all 2,297 prior v13 cases retained their outcomes, and every one of 13 added
output-setting/reserve/compatibility cases passed. The filesystem-support bundle
passed 30/30; the Core bundle selected 2,280, with 2,267 passes and 13 skips.
Swift Testing's separate zero-test messages receive no execution/pass credit.

| Capture | Receipt SHA-256 | Actual result |
| --- | --- | --- |
| `full-source-classifier-v14` | `6e0d7d621e9e4149321bec43e401412d0bc7331290ddc598b32ef269408effa1` | Exit0; 2,310 executed / 2,297 passed / 13 skipped / 0 failed; 715.460544417s; full 692,106-byte EOF; unforced |
| `source-cli-build-v14` | `4b2c5ab395be964a219870701958e861902b26a29bea0c05680d7a873af3d483` | Exit0; incremental Swift CLI product build; 1.011967458s; full 53-byte EOF; unforced |
| `source-app-build-v14` | `59930cebd1f663ea66af669fb529891969fdc6b1208087837a6e4487274dba49` | Exit0; incremental Swift app product build; 1.001708792s; full 98-byte EOF; unforced |

The raw log hashes are respectively
`1443f36590cc3a3bf1223d178e9f807d7a77967d1bb118dd5795e7a969f08733`,
`21254f729f3092a428bafa9b3968dee99483bd9ae1a89ee32098b7593883dc9c`, and
`73c37f9002eeabd6766577983f60b0225b19ef777aa47153b843a6cd89214d8e`.
Root's retained `full-source-classifier-v14/root-exact-case-reconciliation.json`
has SHA-256 `295635d0d2689c171715a86460db742c4d35d5c87cba4e207687aabb609da278`.
All three receipts have exactly the same 439 before/after source hashes and
bytes, complete EOF, no timeout/bound failure/cancellation or cleanup signal,
no ambiguous/remaining owned process, and unchanged canonical project graph
`a6c85ff538223a7111fc5e8e7db96cf03dddef98fa083e3bccbb3fac05822240`.

The 13 skips are the same exact cases as v13; they remain unavailable checks:

| Skipped case (`ForgeConductorTests`) | Retained reason |
| --- | --- |
| `AutonomySupervisorTests/testInstalledNativeJobFailurePreventsCompletionUntilActualEffectIsCorrected` | Native job qualification requires an explicitly prepared test package and evidence directory |
| `AutonomySupervisorTests/testNativeJobFailurePreventsCompletionUntilActualEffectIsCorrected` | Native job qualification requires an explicitly prepared test package and evidence directory |
| `LiveLMStudioManagedAutonomyTests/testRealProviderAutomaticThresholdCrashRecoveryPreservesRunningInstalledGUIAndMCPRegistration` | Set FORGE_LIVE_LMSTUDIO_COEXISTING_GUI=yes for the separate owned live fixture |
| `LiveLMStudioManagedAutonomyTests/testRealProviderAutomaticThresholdRolloverRecoversAfterBootstrapCrashAndContinuesViaManagerRoute` | Set FORGE_LIVE_LMSTUDIO_MODEL to run the real-provider manager test |
| `ManagerTests/testExternalProcessRelinkLockHolder` | External relink helper runs only under the parent process harness |
| `ManagerTests/testLiveProviderProbeRouteUsesProductionRegistryAndConfiguration` | Set FORGE_LIVE_LMSTUDIO_MODEL to run the production provider route test |
| `NativeSessionHostPluginTests/testLiveLMStudioFreshRootAcknowledgementAndAutomaticContinuation` | Set FORGE_LIVE_LMSTUDIO_MODEL to run the real-provider system test |
| `ProcessRunnerTests/testNativeGateEffectFixture` | Native gate effect fixture runs only under its parent qualification harness |
| `ProductPathReliabilityTests/testNativeCandidateBundlesPreserveIdentityAndRejectVersionDrift` | Native candidate qualification requires prepared signed bundles and an older same-version peer |
| `ProductPathReliabilityTests/testNativeSameVersionPeerReportsDifferentRunningExecutable` | Native candidate qualification requires prepared signed bundles and an older same-version peer |
| `ProviderConfigurationTests/testDisposableRealKeychainKeepReplaceClearAndRestart` | Set FORGE_TEST_DISPOSABLE_KEYCHAIN=1 to exercise unique disposable Keychain items |
| `ProviderRuntimePreparationTests/testLiveConnectAndCheckPersistsAndReusesExactReadiness` | Set FORGE_LIVE_LMSTUDIO_MODEL to run live provider preparation |
| `RuntimeExecutionJobTests/testAdvertisedPowerShellProfileExecutesWithoutProcessGroupEscape` | PowerShell is not installed on this host |

These current source results supersede the earlier refreshed-full-source pending
statements only for the tested80f inputs. The earlier focused14, affected168,
34-case REST/bounds controls and all baseline negatives keep their exact scope.
The c180/v13/v9 native and accepted-empty metadata results remain historical
positives at their recorded inputs, and the v8 Debug forced-cleanup result stays
NONPASS. The following v10 checkpoint separately supplies current signed native build,
selected hosted/Core tests and platform identity/settings evidence. Actual
larger-output provider and model-driven Xcode/LLDB, Simulator XCTest, onscreen
GUI/ordinary rollover, crash recovery and installed/artifact acceptance remain
separate gates. This source regression neither expands Stjornarvald's one-of-15
automatic detector scope nor establishes the empty successor's cause or the
full successor mission. Source results alone make no native/runtime claim; the v10 evidence follows.

### Canonical native v10 — same output-setting source inputs

All paths are relative to `candidate-probes/canonical-native-closeout-v10/`.
Debug and Release used the canonical workspace/project and existing signing
settings, with no compilation/signing/home/authentication override. Each build
returned zero with exactly one build-success marker. The selected Debug Core
and app-hosted captures executed exactly 49 and two distinct cases respectively;
every actual raw start/pass identity matched its receipt/selection and no test
was skipped or failed. All 37 prior v9 native identities are retained within the
51-case union; the added output-setting tests cover ordinary budget, immutable
REST fixtures, persistence/CAS and app-hosted loopback/view-model behavior.
They do not exercise an actual model or onscreen GUI.

| Native capture | Receipt SHA-256 | Actual result |
| --- | --- | --- |
| `debug-build-capture` | `245b21c584aee02875b2544cd589ae1f355e908fd9b9fd8e208947a6349fe9ad` | Exit0; Debug compilation / one build-success marker; 57.098856250s; full 514,181-byte EOF; unforced |
| `release-build-capture` | `6c3060ee4d5d322ab9b133bb0f354c65a8c8f2984761d2c558574ea64b2479f9` | Exit0; Release compilation / one build-success marker; 153.281052125s; full 540,072-byte EOF; unforced |
| `native-test-capture` | `950b6c6aae77f6d7ee577f6b23d8a8d34bd52f8703a5b0dc295293d6fdbd70d6` | Exit0; 49 executed / 49 passed / 0 skipped / 0 failed; 103.973861875s; full 726,154-byte EOF; unforced |
| `hosted-settings-test-capture` | `920bef2ff38df375b9b9b5048cf553abb431605e68662560064ac165ec1f2505` | Exit0; 2 executed / 2 passed / 0 skipped / 0 failed; 72.792653708s; full 609,455-byte EOF; unforced |

Raw log SHA-256 values in the same order are
`802a9a91f7eb1633a2debca4a72756db212096473b1c9f8b0429b3be15901445`,
`fb99f4869a80d6b31bb0dd25abcead8991b3daf3b0a6bd36486759ebd34d27bd`,
`83a02711ceadb02216e2850e034a702c0e7feceeee3c738ba46ac4b78b7af70f`,
`3553e0d64214a0c9326ef53f28d701fa3e21f977757581aea74d513e3cc18435`.
All four captures retained exactly the current80f manifest's 439 before/after
inputs, no timeout/truncation/cancellation or cleanup signal, and no ambiguous
or remaining owned process. The canonical project graph is unchanged. Earlier
v8 Debug SIGINT and other negative receipts are retained as NONPASS; these new
captures establish no cause or reclassification for the old tracked process.

Both Debug and Release passed strict requirement verification, metadata and
entitlement capture for the app, Core framework, CLI, Runtime Launcher and
Filesystem Daemon: 15 zero-exit controls per configuration, all retained stream
hashes/byte counts/EOF verified. Debug retains its existing Apple Development
requirements; Release retains Developer ID requirements and has no
`com.apple.security.get-task-allow` entitlement on any role. Version/build are
0.18.0/28. Both scheme settings queries returned one row and both all-target
queries returned 13 rows, with exit0/full two-stream EOF/unforced cleanup.

| Platform identity/settings evidence | SHA-256 |
| --- | --- |
| `debug-identity-capture-v10/summary.json` | `82e8f738a266e0f2e5dfab1b75f0cfb6d42cc2d8ce869bc16c6b5adc406963b1` |
| `release-identity-capture-v10/summary.json` | `bbf6bf363de53adbfbe99ae6e261e7ee5608506be86aea1430dc00e222efe018` |
| `debug-effective-settings-v10.capture-receipt.json` | `0b1880d1c1e612add43def4192c75255f6aba2a84ec780cb8ad1941b9e9a2a3b` |
| `debug-all-target-settings-v10.capture-receipt.json` | `38ec315401d1b43851769f2a55c7964b7a2abbd602481ee1fb2b8e97edae4578` |
| `release-effective-settings-v10.capture-receipt.json` | `8192ba27bed53dc58fa8dff5ff197834154365cdf2ae2e7693e475b53eedc86f` |
| `release-all-target-settings-v10.capture-receipt.json` | `853f72d93fa9b55e45ddc000763dfdd77f8660f9ecab741691105a3d3906aa0a` |

| Role | Debug binary SHA-256 | Release binary SHA-256 |
| --- | --- | --- |
| `ForgeConductor` | `5e3936acdb52e4e74bb3d5ac47a0915668304c5ba651ffa23e959ae8855b9519` | `29d12125ea09432e56f6451de587f43b4836334254af25728d7298ca71990959` |
| `ForgeConductorCore` | `e6d176cb5ad9edfea9c03a6c4b2da75d7f76dd3abead829d325de8533b73c9e9` | `33a65c5cdae7638ba5b2cea9aca29077a72980029acc90e7d64d1cb53e4320d5` |
| `forge-conductor` | `425992ee2e001b9c3bf274cd20401c60d32cd1e706b037d0bf07f8611736bda8` | `71c3c41f1874195354cad1f3f4eff217e89970d4a11e903a9a3907876c352741` |
| `ForgeRuntimeLauncher` | `42b763223fd63ce9e98f0b56268ccf4321960761566c4075eacfcf4ad9db1099` | `3f993dd0a26ff50044f4ead839c90e247be1f86a44b75fe7cd33e58691057fd4` |
| `ForgeFilesystemDaemon` | `96a3045db1c0679f11d33f59d8632376ea7c41f0da926dc81802f02bc1293e69` | `fbccdfbd174cd9096575b38670f834dbcbbdcb8fcccba151b57e7a92da61a89c` |

Root's independent Debug/Release build/identity reconciliations are retained at
`root-debug-identity-release-build-reconciliation.json` (SHA-256
56d7a0d533628e99a6deff3240440ee30f2c87565e14e84f8dd2be3da244992e) and
`root-release-settings-identity-reconciliation.json` (SHA-256
18c11b0b2da11b22a27552f5b13f5a4bba34c75c873b61925ad200a7f9eefa4f).

These are build, selected native XCTest and platform identity/settings results,
not installed or complete runtime acceptance. Actual model-driven Apple build,
XCTest/result/LLDB workflows, the experimental8192 provider diagnostic/full
successor mission, Simulator XCTest, onscreen GUI/ordinary successor rollover,
crash recovery and installed/artifact acceptance remain open. The empty accepted
successor's cause remains unknown. No completion, shell, policy, data-isolation,
producer EOF or signing protection was weakened, and Stjornarvald detector
coverage remains one automatic rule out of15. All previous scoped positives,
13 source skips, baseline failures and NONPASS receipts remain retained.

### Provider output setting — settings and compatibility source controls

The later source checkpoint is
`80f542faeb362d590d2ca3e87ece108f536c1a9f35ea21df128c088031487fc6`.
All **14** selected focused cases passed in **9.853 seconds**, native zero,
without skips/failures and with complete **7,073-byte** EOF. They exercise:

- legacy absent/null capability and configuration fields, retained explicit output
  limits, optional update omission, 65,536 persistence/reopen and rejected stale
  revisions/out-of-range values without changing committed bytes;
- actual loopback Manager route authentication and malformed-value rejection with
  an injected configuration service, and Provider view-model Save/Reload plus
  unsaved model/probe action gating through the Manager client;
- production REST probe/root/continuation bodies in the injected URLSession
  fixture, each using **8,192** `max_output_tokens`, with root/continuation preflight
  body hashes and byte counts matching the captured fixture requests;
- accepted receipt replay after a new client has a 16,384 output configuration:
  the original 8,192 capabilities/metadata/receipt bytes remain, the old client is
  immutable and replay sends no new HTTP request; a new intent uses 16,384;
- requested output/preflight mismatch, selected context/headroom and inherited
  ceiling rejection while original reserve floors and legacy-unknown behavior
  are preserved.

These source controls use fixtures and in-process Manager services. They do not
exercise the ordinary onscreen Provider form or an actual LM Studio generation
at the larger allowance. The exact selected identities are:

| Class | Method |
| --- | --- |
| `ContextBudgetSupervisorTests` | `testRequestedOutputLimitCannotRaiseInheritedCeilingOrLowerOriginalReserve` |
| `ContextBudgetSupervisorTests` | `testRequestedOutputLimitPreservesLegacyWireAndValidatesConstructorBounds` |
| `ContextBudgetSupervisorTests` | `testRequestedOutputLimitRejectsPreflightMismatchAndContextHeadroomViolation` |
| `LMStudioContractFixtureTests` | `testConfigurableOutputLimitKeepsLegacyDefaultAndFiniteProductBounds` |
| `LMStudioContractFixtureTests` | `testOrdinaryRESTOutputFloorSurvivesCachedObservationAndEvaluatorRestart` |
| `LMStudioContractFixtureTests` | `testOrdinaryRESTPreflightOutputFloorSurvivesNilPreflightConfiguration` |
| `ManagedModelProviderPreflightTests` | `testAcceptedOutputLimitReceiptReplaysOriginalCapabilitiesAfterConfigurationChangeWithoutPost` |
| `ManagedModelProviderPreflightTests` | `testConfigured8192OutputLimitReachesProbeRootAndContinuationWireBodies` |
| `NativeSessionHostPluginTests` | `testProviderConfigurationDefaultsAndBoundsOutputTokens` |
| `ProviderConfigurationAppTests` | `testOutputLimitEditsGateUnsavedActionsAndSaveReloadThroughManagerClient` |
| `ProviderConfigurationAppTests` | `testOutputLimitRouteAuthenticatesValidNumbersAndRejectsMalformedOrOutOfRangeUpdates` |
| `ProviderConfigurationTests` | `testInvalidMaximumOutputTokensAndStaleRevisionPreserveCommittedBytes` |
| `ProviderConfigurationTests` | `testMaximumOutputTokenLegacySnapshotAndUpdateDecodingKeepDefaultsAndOmission` |
| `ProviderConfigurationTests` | `testMaximumOutputTokensPersistBeyondLegacyCeilingAndOmittedUpdateSurvivesRestart` |

The ordinary six-class selection ran **168** actual cases in **11.870 seconds**:
**166 passed**, **two explicitly skipped**, none failed; native zero and full
**52,355-byte** EOF. Counts are 22 ContextBudgetSupervisor, 34 LMStudioContractFixture,
17 ManagedModelProviderPreflight, 33 NativeSessionHostPlugin, 35
ProviderConfigurationApp and 27 ProviderConfiguration. The two skipped identities
and retained reasons are:

- `NativeSessionHostPluginTests/testLiveLMStudioFreshRootAcknowledgementAndAutomaticContinuation`:
  requires `FORGE_LIVE_LMSTUDIO_MODEL` for the real-provider system test.
- `ProviderConfigurationTests/testDisposableRealKeychainKeepReplaceClearAndRestart`:
  requires `FORGE_TEST_DISPOSABLE_KEYCHAIN=1` for unique disposable Keychain items.

Neither skip is a pass. Independent raw-output reconciliation matched every
started identity and terminal status to the receipts, with no duplicate or extra
case. Both captures retained the same before/after 439-input maps, had unforced
cleanup and no owned survivor. These are selected source checks; inherited
unfiltered scope text in the receipt does not override the exact filtered argv.

Receipts are under `candidate-probes/output-limit-settings-and-budget-v1/`:

| Capture | Receipt SHA-256 | Raw output SHA-256 |
| --- | --- | --- |
| `post-settings-compatibility-focused-capture-v3` | `53eecb35222a563873308c15b4306bee46544a180ec4f706b8572422529f6604` | `77d33646fba57bea6753e87db36a4e660771e4e6c3b311fa61cb2fbb05814e87` |
| `post-normal-classes-capture-v4` | `126106439f23b35a53cf0c884571cde542f33e5fd914ce2ce6c71f860f6e5eca` | `1d57633aaa60712fd7914bbebf31d5dc18d3437b28bfc36f1045bfaf733e1858` |

The earlier nil-preflight/lifecycle baseline failures and 2/34-case repaired
checkpoints remain preserved. These later controls supply the previously pending
deterministic settings/HTTP/view-model and compatibility evidence. They do not
replace full-source, refreshed signed native, actual model/GUI/Xcode/Simulator,
crash or installed acceptance. The original 4,096 empty-successor diagnostic
remains unqualified for its full mission and has no established cause. A prepared
8,192 actual-provider diagnostic is closed and has not executed; its private-home
scope, proof requirements and preserved bounds are distinct from these source
fixtures. Version remains **0.18.0 (28)** and the canonical graph is unchanged at
`a6c85ff538223a7111fc5e8e7db96cf03dddef98fa083e3bccbb3fac05822240`.

### Provider output setting and ordinary reserve coherence — source checkpoint

The two new `LMStudioContractFixtureTests` use the production REST client with
an injected URLSession fixture. The first baseline failed one case/two assertions:
a root preflight reserved 4,096 output tokens, but an ordinary nil-preflight
configuration reduced that reserve to 2,048. The lifecycle baseline failed both
cases/six assertions. Its second case observed the same reduction after cached
provider/tool observations and in a newly constructed persisted evaluator; used
accounting remained asserted. These are observed source failures, distinct from
the earlier actual-model empty response. No causal connection between that
response and the reserve defect has been established.

`PersistedManagedRunBudgetEvaluator.configuration` previously had no immutable
requested output limit in its capabilities when `providerPreflight` was absent.
The new optional `requestedMaximumOutputTokens` capability carries the transport
configuration through REST probing and source-pressure/conversation copies.
The central budget builder validates its capacity and preflight consistency and
keeps the maximum required output reserve at all ordinary hooks, including a
fresh evaluator. This does not report a provider/service ceiling or raise the
SSE event, byte, deadline or continuation-round bounds.

The Provider form now contains **Maximum output tokens** with accessibility ID
`provider-maximum-output-tokens`; it includes reasoning and the answer. The shared
contract defaults to **4,096** and validates **1–65,536**. Legacy files without this field decode
to 4,096; an explicit saved limit is preserved. Snapshot/readback includes `maximumOutputTokens`; an omitted update
preserves the saved value. `LMStudioConfigurationService.updateLocked` retains the
existing busy guard and revision CAS before persisting. Manager's existing PUT
whitelist accepts this field, and the Provider view model includes it in saved
and dirty state. These are inspected implementation facts. New API/CAS/busy and
UI parity checks are still pending; no actual GUI setting change or larger-output
LM Studio generation is claimed.

The repaired focused capture ran these exact methods:

- `LMStudioContractFixtureTests/testOrdinaryRESTPreflightOutputFloorSurvivesNilPreflightConfiguration`
- `LMStudioContractFixtureTests/testOrdinaryRESTOutputFloorSurvivesCachedObservationAndEvaluatorRestart`

Both passed in **20.777 seconds**, native zero, full **3,256-byte** EOF, no skips,
stable 439 inputs and unforced cleanup. The broader fixed selection passed all
**33 `LMStudioContractFixtureTests` cases** and
`NativeSessionHostPluginTests/testProviderConfigurationDefaultsAndBoundsOutputTokens`
in **6.426 seconds**, native zero, no failures/skips, complete **11,351-byte** EOF,
stable 439 inputs and unforced cleanup with no owned survivor. The existing
boundary test intentionally accepts 65,536 and rejects 65,537 under the expanded
contract. This is a 34-case selected source check, not an unfiltered full suite;
the inherited receipt scope label does not override its exact argv/case inventory.

Receipts below are under
`candidate-probes/output-limit-settings-and-budget-v1/`; each retains its complete
`swift-test.log`. Earlier negative receipts are preserved.

| Capture | Receipt SHA-256 | Actual result |
| --- | --- | --- |
| `baseline-capture-v3` | `c8cbe4bb834c7aacc6388b96f4f168d5759cddb06ea09b7b3d38045a34f2df92` | 1 failed case / 2 assertions; native 1; full 2,540-byte EOF |
| `baseline-lifecycle-capture-v4` | `6643c50d20b1cd339b04e3157e2245e865745cd8083f2d5408f64592260d145b` | 2 failed cases / 6 assertions; native 1; full 16,945-byte EOF |
| `post-focused-capture-v1` | `cfbae81e6c1e68db0afa82b714a87959868cd7478f0c8ec88c139af967935f68` | 2 passed; native 0; no skips; full 3,256-byte EOF |
| `post-contract-class-capture-v2` | `0f3b639e503db922feabda2696d9e8366259fcd2e32c4cafdc96fab337f02f30` | 34 passed; native 0; no skips; full 11,351-byte EOF |

The focused manifest was
`6d1b58c783446804160017ca89fabc8a77b160a3ac432ee0f068086fdaf6f6ec`;
the broader manifest is
`31dcfd8bdd8f4fbd031b5c973bf2f42140dcb9f2d5f1215c680c31bb161d3db2`.
All before/after maps matched within each capture. Version remains **0.18.0 (28)**
and the canonical graph remains
`a6c85ff538223a7111fc5e8e7db96cf03dddef98fa083e3bccbb3fac05822240`.
The ten production inputs, two new REST cases and expanded existing boundary
postdate the full source v13 and signed v9 candidate at `c1805d1a…`; those positive
receipts remain scoped historical evidence. Full-source, refreshed native and
actual-provider/GUI/Xcode/Simulator/installed acceptance of this new slice remain
open. The earlier 4,096-output actual-model diagnostic remains retained and
unqualified for the full mission; a larger allowance is not yet a demonstrated
remedy.

### Canonical native v9 and accepted empty successor diagnostic — October 6

The v9 Debug build returned zero in 54.946346666 seconds with one build-success
marker and lossless 512,938-byte output at actual EOF. The 37 selected native
XCTests returned zero in 100.438411791 seconds: all 37 passed, none skipped or
failed, with lossless 718,240-byte output at EOF. Actual names/statuses and the
10 class counts match the fixed selection: the original 26 plus two QoS, seven metadata and
two catalog controls. The catalog pair asserted descriptor closure, closed API behavior,
idempotence and durable reopen; the Xcode case exercises the completion gate,
not an Apple build/test workflow. All 439 inputs remained unchanged at
`c1805d1aefdee2bf5039db3332a74a4bd577339571ff1dceaa3109f627b3b37f`,
with no forced cleanup, owned survivor, ambiguous ownership or output loss.

Debug platform identity and effective settings passed for the app, Core, CLI,
Runtime Launcher and Filesystem Daemon. Each role's three strict verify,
metadata and entitlement controls returned zero with full bounded streams;
15 controls were checked. Both scheme and all-target Debug settings queries
returned zero with full streams. The roles retain Apple Development, automatic
signing, team `9AQ2C2838M`, hardened runtime and version/build `0.18.0 (28)`.
This is Debug platform identity/settings evidence, separate from compiled peer
admission and general runtime or installed-product acceptance. It does not
supply v9 Release identity. The earlier v8 Release compilation remains its own
passed scope, and the v8 Debug SIGINT capture remains NONPASS. The measurement
change allowed observation after validated native success within the existing
cleanup budget, with no process exemption or production change. It does not
establish the earlier tracked process's ancestry, executable path or cause.

A preceding metadata preflight rejected the 278,702-byte build receipt at its
256 KiB consumer bound, before its output directory existed. That negative is
retained (`6b82934dff501fc259693fe2efa57c9c85f4ce7b37339c7cbf049f760f73858c`).
Root changed only that build-receipt read to the producer-enforced 8 MiB limit;
other receipt bounds and native/model/default controls stayed unchanged.

The fresh owned LM Studio Qwen diagnostic saved threshold 3 and verified three
completed predecessor reads, one count-triggered request, the same handoff's V2
acknowledgement and predecessor seal. Its first observed accepted successor
`automatic_continuation` response was completed with `streamEOFObserved: true`
and `metadataComplete: true`. The private metadata records one `reasoning` output
item, 4,095 reasoning tokens, provider-exact output usage of 4,095 tokens, and
zero streamed/output/parsed text bytes and function-call/argument bytes. Parsed
messages and tool calls were empty. The request retained output limit 4,096;
loaded model/context 262,144/parallelism 1 stayed unchanged. `incompleteReason` is
unknown; the accepted raw status is completed and the derived finish reason is
stop. These are observations, not a causal diagnosis of the model or provider.

The diagnostic receipt records `diagnostic_complete: true`, `qualified: false`,
`failure: null` and no full-mission reference. The successor marker/feedback
requirement remains unqualified. The controller paused the owned run, retained
its exact observed state/receipt set during a 10-second local window, restored
the owned threshold to 200 and shut down the Manager normally: native zero, empty
stdout and 192-byte stderr, both full EOF and hashes, no forced signal or owned
survivor. Final guards preserved all 439 source inputs, the five candidate binaries, all ten
original protected processes and current MCP registration. The diagnostic grants
no remote-provider quiescence, zero-extra-generation, SIGKILL, ordinary GUI,
installed or shipment claim. Provider transport EOF is separate from native
producer EOF and retained-artifact page EOF; no current actual-model Xcode/LLDB
producer qualification is supplied by this diagnostic.

Receipts and raw evidence, under
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-05-functional-repair/`:

- Debug build: `candidate-probes/canonical-native-closeout-v9/debug-build-capture/capture-receipt.json`,
  SHA `65311014256f5a946a9c47fb9fd4025ef7c423c73e23700473e6cf7b000a41b5`;
  raw log `261a9e1f701fb9209d41c3e417e6d0a2639ed814b06d6269135f4fcb48db5e6a`.
- Native37: `candidate-probes/canonical-native-closeout-v9/native-test-capture/capture-receipt.json`,
  SHA `908b2a1e65526f1bb8a15847d3dae35577c10a532f488c06e6c5911f7b89a766`;
  raw log `b23af13a022ba1750be059d5e4d3abe85bf9410d77c8cc7e8c0391858ff56744`.
- Debug identity/settings: `candidate-probes/canonical-native-closeout-v9/debug-identity-capture-v9/summary.json`,
  SHA `0853c98027f2b46f4ca6d91c8d9ca5d4a78bc53a302dd1c80d07dfff23d9bec7`.
- Empty-successor diagnostic: `candidate-probes/managed-saved-count3-terminal-metadata-controller-prepared-v1/run-root-admitted-one-attempt/receipt.json`,
  SHA `85c5103472c7ed10977750357f3944fff87c023fbd9e3941623e1f8010870873`.
  Exact measurement SHA `6b5e8c1a5fc7d56c51092a61cc57573f7aeb7ab7bfb9889fd05a2bbbae94f5d7`;
  diagnostic closeout SHA `7bbcdb7fbd5348ded98629605d2c439acf12127a303a344531e76acec2040848`.

The completed full source v13 result remains 2,297 executed /2,284 passed /13
explicit skips /0 failures. These native/diagnostic results do not turn its
skips into passes, rewrite prior failed receipts or qualify the remaining
actual-model typed-Xcode, simulator XCTest, ordinary GUI rollover, crash or
installed/artifact gates. The canonical graph is unchanged.

The refreshed full v10 source run returned zero in 708.278 seconds: 2,264
actual cases selected, 2,251 passed, 13 explicitly skipped and none failed.
All 32 added repair cases passed; complete 678,541-byte EOF, all 439 stable
inputs and unforced cleanup were independently reconciled. Receipt:
`613906ead4407edafc1d17ca9389214acc54bc22499c36850629823485ea6623`.
Fresh canonical native v6 Debug and Release builds returned zero in 57.907
and 152.060 seconds, with full output and all 439 inputs unchanged. All five
roles passed strict signature, metadata and effective-settings checks in each
configuration. The focused native Core selection executed 32 cases: all passed,
none skipped or failed, with full EOF and unforced cleanup. The hosted bootstrap cancellation case and five Rune reorder cases also passed.
The native rollover UI case passed text edits and increment/decrement actions
at both range boundaries. The current signed Stjornarvald control also passed deliberate violation,
ordinary MCP notice delivery, correction and unavailable-graph history checks.
Automatic detection covers one of 15 indexed Raven rules; the other 14 remain
guidance. The current signed candidate’s `xcode.debug` control passed breakpoint,
main backtrace, continuation and target-zero-exit checks for the unchanged signed
owned C fixture. An actual LM Studio model also built for testing, ran one exact
XCTest, read its passing xcresult and reached a completed managed run. That run’s
receipt remains NONPASS because build-for-testing changed two test-host binary
hashes. Six separate read-only post-build signature, metadata and entitlement
controls passed against the current products. This preserves the original
nonpass and does not establish native producer pipe EOF for that historical run.
These scoped results do not qualify the installed app or shipment.
The retained full v10 and native v6 checkpoints predate the subsequent producer
evidence and managed saved-count changes recorded below.
The current typed debugger control completed in 1.798 seconds with native and
MCP exits zero, fully reconstructed retained 1,551-byte stdout and empty stderr
artifacts, all 439 source inputs
and five candidate binaries unchanged, no forced cleanup and the nine original
protected processes and registration preserved. Its receipt is
`d2af451593db4eb02d423821b4465cd9316e3adfa90ea115a1284dd6a084150f`;
independent closeout is `2092f87f7afa96181d2e29c3499acd67cf70dd022c32bfcb8d49d0fa8872d3b3`.
Scope is the actual `xcode.debug` path and signed C fixture, without a model-driven
debug or Forge-target debug claim. A preceding admission stopped before launch
because an owner-created identity summary had mode 0644; restricting it to 0600
preserved its bytes and allowed the same pinned admission to proceed.

The actual model mission took 234.696 seconds and issued three distinct native
jobs: build-for-testing, one selected Rune XCTest and xcresult test_summary. All
three returned zero. The model reconstructed all six retained output artifacts
through their final pages, with exact bytes and SHA-256. Those durable fields do
not establish true native pipe EOF or exclude forced reader closure. The model
reported the exact 1 total / 1 pass / 0 failure / 0 skip / 0 expected failure
counts before normal completion. The original receipt
`b08733dabf04f53681cf9f26c97b83157470b9d6ed9936a5b1e79b982a5fcea1`
remains **NONPASS** (`current test binary changed`); the retained workflow proof is
`e9871a52f3932e20edd7c45d3f17f647547e404bdefb8e538ddc38ce01fbd07d`.
Actual build output records copying embedded Core and replacing Apple Development
signatures. The app/Core test-host hashes changed while the XCTest executable did
not. This supports a build-product rewrite; signature-only change is unproven
without retained original binary bytes. The controller’s immutable pre-build
product check prevented that controller’s post-build signing checks. A separate
later six-command read-only signing control passed without altering the original
receipt (signature evidence `83ae97d72495a589ca5619dbea57bf96f8744acf044165ff4ae0f217bad20f0b`,
independent audit `4617324804b3bfb0569676f466b4e2fe8cb6e7d3759bbd6d0b795e49a7392495`).
No fresh compilation, complete producer-output qualification, simulator,
automatic rollover or shipment is claimed.

Native v6 build receipts have SHA-256
`750159c0a76ce2a270a2aeadc2f3ffcd720cd0692d0d35ee4d4cb77eb02ea664`
(Debug) and `c1d28132ba7d28a5f9ad2e68dc9d5e894187818ab28fe252ec47c02100e7a32b`
(Release). Five-role identity receipts are
`c199b64f72b18fc0ac747ed35d4883b3fcf3597849f5e3518a70076fb51808ff` and
`1bb8592ef8db01d52d6de53b47b665f318cd1ed5a20c3f0dc076a9a7648c7ee5`.
Four bounded native settings queries and 30 read-only signing controls returned
zero with complete streams. Release preserves Developer ID, hardened runtime,
no development compilation condition or debug task entitlement; Debug retains
Apple Development. Compiled peer admission remains separate. The native Core32
receipt is `c2d656ff391454c3e4136fb21173b517a26a2e05a7178a1bdde85d42ec71b1ec`,
raw log `5f65e1139f45c4e709ff639d12138cdc54698e7f7e456899734d7a0d762d7733`,
112.958 seconds. Actual identities and all five class counts were independently
reconciled against the 32 selectors; no fixture-driven test is Apple CLI proof.
Three separately selected native hosted controls completed with no skips or
failures, full EOF, all 439 inputs unchanged and unforced cleanup: the original
cancellation/retry case (receipt `9bdb575d9f480b70135fa33a435e2f87c1c949432e8ec5cd35b8adee8d7ebaca`),
five Rune policy-reorder cases (receipt `a0b9a2ac496a50791db7c2fa7d72b7ad03db42588d1248f465ed420d50eaecfd`),
and one actual hosted rollover-control case (receipt
`cc5d95ca7d6c3bdd8f87998b7b9364cbad163698cb77ee5541076c8707dc2e98`).
The last control edited the actual native numeric field and invoked public
accessibility increment/decrement actions, verifying the staged binding and
rendered value at 1, 10,000, 3, 1,234 and default 200. This is component UI
proof. A separate ordinary candidate Settings session saved 3, restored 3 after
Reload and native Quit/same-home GUI relaunch, then saved 200. Independent Manager
API and disk readback matched all five phases. The native stepper displayed 4
then 3, and Reload discarded an unsaved 7. All three owned GUI/Manager processes
exited zero and were reaped; the ten protected processes and registration were
preserved. Root semantic record: `ordinary-native-gui-settings-v6-prepared-v2/runs/9ba125f4-dde2-497b-8dd6-0eeff867d204/root-cua-semantic-observations.md`
(`e8dfde5f3ac3abdd72f56b764e219bcff4b65a3db45b30daca8fbeab03097fa4`).
This verifies candidate settings controls and persistence, without automatic
successor creation or installed acceptance. All 39 selected native cases passed;
source v10 remains the preceding normal full-suite result. The canonical graph
is unchanged.

A later exact inherited-writer reproducer executed one case against the unchanged
production reader and failed two assertions: forced-closed stdout and stderr were
both marked `artifactTruncated: false`. Reader closure stayed within 250 ms and
the owned child exited zero and was reaped, so this run does not demonstrate a
blocked reader or leaked process. Direct Swift exit was one, complete output
2,443 bytes, 439 stable inputs and unforced cleanup. Receipt
`1081234a8abe7ee519cafd352807066cdc4b0412ce9ff777628c4f1c8a492344`,
raw log `1987fe46764c9bcca05a5d60a555058bba9c60ec51b996bb510850e64dcf9213`.
The source repair now records `producer_end_reason` (`eof`, `read_error` or
`forced_close`) and optional `producer_read_errno`. Runtime-output schema 6
migrates existing rows with unknown producer state; legacy JSON also remains
unknown. Forced closure/read failure marks output incomplete. The reader worker
retains sole descriptor ownership until it stops, and typed Xcode completion
requires actual producer EOF for both streams as well as complete retained bytes.
The existing page `eof` still means the end of retained byte pages.

The exact 16-case producer selection passed with zero failures/skips, terminal
zero, complete 6,119-byte output, all 439 inputs unchanged and unforced cleanup.
Receipt `4c817323ee7f41411566e3c887fa4c4e6c3332b7536be3abc234e279d1391f1d`,
raw log `f835fc556d4b938eb6a1c489381bf92ff732a3f85f29cf682fe56c299023dd0d`,
in `candidate-probes/producer-output-eof-focused-test-v2/`. The original baseline
and first repair attempt remain NONPASS; no later source check supplies the
missing producer evidence for historical model/native artifacts.

Managed saved-count testing then reproduced the missing production wiring: with
saved limit 3, two successful reads and one returned error were followed by a
fourth invocation and no pending count request. The baseline selected one case
and failed three assertions, terminal one (receipt
`cfc756b5e42dc94c32d7a8d342450048644eeb3e3bda535f56a03bf1568e0b7c`,
raw `7283ae051e7f031b621edeeafe1e6251c9d29801ab6a84bb738e69de67943f6f`).
After wiring the saved limit into the persisted managed evaluator, the same
case passed, terminal zero (receipt
`c379bb8e78de6b5a0ac7eb61aa96b559dde8c787d915bd0fbc3717aa6178b29a`,
raw `5d07ba0d292b6330be716e9a5961d156e7cad99c55f01187b34518a5292a3b4d`).
Both captures retained full output, unchanged 439 inputs and unforced cleanup.

The evaluator validates the exact current committed call and result hash, counts
eligible unique invocations through that journal row, and waits until replay
reconstructs the retained result tail before creating or honoring count rollover.
A pending request remains sticky after the limit is raised. Verified historical
source replay skips this new count boundary while it reconstructs the existing
completed child chain. The setting key, default/range, measured context budget
and 32-provider-tool-round safeguard remain available.

The later 13-case selection passed 12, including all three ordinary app/file
reopen recovery cases and both original/limit-1 source-history replay controls.
It failed only the successor-session fixture with
`UNIQUE constraint failed: provider_sessions.run_id`; the aggregate remains
NONPASS (receipt `246adb280f103a494b32a27c4ff637288bcf3e7193bcf85669b2d1ca5a4a7373`,
raw `7ac9533374a2c1df40aed6f8086199c296e9458a7189d15d55f846dd2dfb795b`).
Its complete 6,555-byte output and all 439 unchanged inputs were reconciled,
with no skips or cleanup signals. The fixture now uses the existing predecessor
fence and atomic acceptance of its fully reserved successor candidate, preserving
the one-active-session invariant and isolation assertions. The corrupted-result
fixture verifies all intended bytes, including its SQL-inserted NUL, before
checking hash/size/string rejection. These are owned repository component
fixtures and establish no actual host ACK or project-memory seal.

The corrected exact 14-case selection passed all 14 with zero failures/skips,
terminal zero in 12.464 seconds, complete 6,570-byte output, all 439 inputs stable
and unforced cleanup. Receipt
`65733d6454957f2f8a6076df66c137315a64226c12f16243ff8b9fb29d104741`,
raw `885dab12e4e291448e6d623d11018fb308e5a4aecadd2fccbe028faccb0083e6`,
in `candidate-probes/managed-saved-count-repository-test-v4/`. Actual class counts
are ManagedAutonomyRuntime 4, ProjectControlPlaneRepository 8 and
SourceDerivedSuccessorPreflight 2. All three ordinary reopen recovery cases,
original/limit-1 historical child-chain replay, candidate/successor isolation,
raised/lowered limits, returned errors, deduplicated replay, exact current-call
admission and corrupt/oversized/NUL result rejection passed. The receipt's
inherited scope text says unfiltered; its exact `swift test --filter` argv and
14 actual test identities establish selected source evidence only.

These source changes postdate full v10 and native v6. Normal unfiltered v11
returned one in 710.803 seconds: 2,286 actual cases selected, 2,270 passed,
13 explicitly skipped and three failed migration cases. Four assertions expected
runtime version 5 instead of 6 in ContinuityIngressAcceptanceTests,
NativeSourceConversationJournalTests and NativeSourcePressureJournalTests.
Complete 686,043-byte output, all 439 stable inputs, unforced cleanup and no
owned survivors were verified. The aggregate remains NONPASS, receipt
`f3f2870e21dfc67aed181521bd0cfe7fcad3f3182b1416a424cb5d357a817dd9`
(`candidate-probes/full-source-classifier-v11/`).

The first four-case lineage selection passed three and failed the full-app
manifest expectation, terminal one (receipt
`452b0640b0a22e0ef5c40c7e0d614aca594d7f5a5141c1dbea84819a01a8b533`).
The initial correction assigned that manifest to the wrong database owner.
ForgeApp.bootstrap opens SQLiteStore at separate store.sqlite; RuntimeJobSubsystem
opens RuntimeJobRepository at control-plane.sqlite3, the failing test's database.
Its fresh standard manifest records runtime 0→6 and remains byte-identical across
independent ingress 9→10 upgrade/reopen. The separate store lineage is unchanged.
Historical populated runtime-v5 source/backup assertions remain version 5. Current
runtime tests check exact provenance-column types, nullable state and no fabricated
EOF default; backup hashes, run/lease/binding identities and malformed-schema
rejection remain tested.

The corrected exact four-case selection passed all four without failures/skips,
terminal zero in 6.846 seconds, complete 3,279-byte output, all 439 stable inputs,
unforced cleanup and no owned survivors (receipt
`afbb529dfa3556102a735bed187df7eb1a0314c9e235675b23e7eed0ff284be6`,
`candidate-probes/runtime-v6-adjacent-lineage-focused-v2/`). It includes the three
failed migration paths and
`RuntimeExecutionJobTests/testVersion5OutputRowsMigrateWithoutInventingProducerEOF`,
preserving both historical output rows and unknown producer state after migration
and reopen. The failed v11 and first focused receipts remain NONPASS.

Final unfiltered full v12 returned zero in **714.013 seconds**: **2,286 actual
cases selected, 2,273 passed, 13 explicitly skipped and zero failed** (receipt
`a3e6ed12581f7faa58934ab162632c7ad96cae639d8dc441d8a6498783c186d2`,
raw `a7de8fc02fffb33c39f832d73ccbde616dcaee81bdcd42bcfb4311487eb23149`,
`candidate-probes/full-source-classifier-v12/`). Its complete 684,787-byte merged
stdout/stderr output, actual identities, all 439 unchanged inputs, unforced cleanup
and absence of owned survivors were reconciled. This completes normal source
regression for those inputs; the 13 skips remain unperformed checks. The subsequent
native v7 and priority-repair results below retain their separate source identities.
The source/resource/test graph is unchanged.

Canonical native v7 Debug and Release builds returned zero in 57.008 and 152.384
seconds, with full 512,934-byte and 538,526-byte output, all 439 stable inputs and
unforced cleanup. Build receipts are
`01224658883c90bd764acc4faa08fbdf5d0074f2c87c56e43367c79522547226` and
`ea19247a2ece602bd11498a76c8a4516ba42ed7a90eed78a9d6ff4b2313c3bbb`
in `candidate-probes/canonical-native-closeout-v7/`. Four native settings queries
and 30 read-only signature/metadata/entitlement controls completed with native
zero/full streams. All five roles passed in both configurations (identity
receipts `606a69fe909b0a0460c1f80364f6c4916fd54557c1cb9a06da9be3b0747f6e59`
and `79c85f36b2401f1b2f61878dc2e7dadf24d6180d5632139a4c18ecf8420cf61b`).
Release retains Developer ID, hardened runtime and no debug task entitlement;
Debug retains Apple Development. These retained builds use source manifest
`38f9e463d7ba26fcfb3f62bea601b6256646fe367ec079d7bb4d153355f746a2`.

The native v7 selection executed exactly 26 cases: all passed, none skipped or
failed, terminal zero in 108.984 seconds, complete 717,350-byte output, all 439
stable inputs and unforced cleanup. Receipt
`4694644c646dee23bd3c9afd8fb4c8eca265cc1009510cd05a4a952e55e991b1`;
raw `348625fec58f25b237015dfd48fbb85eb0c0037a31be5b081e5cfc4e66bc3176`.
Its Thread Performance Checker warning names `RuntimeJobSubsystem.swift:256`:
a User-initiated caller waited on a Default worker during
`XcodeCLIIntegrationTests/testTypedCompletionRejectsUnknownReadErrorAndForcedProducerEnds`.
That passing test and warning establish a priority mismatch, without a hang,
leak or lost receipt claim. The original warning remains retained.

A later actual ordinary Manager attempt saved limit 3 through the normal settings
API while preserving all other fields, default budget policy and the actual
`qwen/qwen3.8-27b` provider's 262,144-token capacity. Root's owned live readback
observed exactly three completed predecessor fs_read calls, the reason
`Automatic rollover at saved tool-call threshold (count=3, threshold=3)`, and a
requested/fulfilled rollover. Retained operation and provider ledgers record
handoff and accepted acknowledgement `d649db6d-c9d2-42fd-89eb-c88c45b6fbe2`,
state `predecessorSealed` and one issued continuation. This adds observed saved-count
trigger and supported V2 lifecycle transitions without ordinary LM Studio GUI
session-automation or crash recovery proof.

The whole actual-model receipt remains **NONPASS**:
`166382e3556ce120fe50b4f7d8d60774227aa668a22a191e6ed2c51ba2107418`,
`candidate-probes/managed-saved-count3-actual-model-controller-prepared-v2/run-root-admitted-one-attempt/`.
No fourth successor marker read or feedback occurred before the bounded deadline.
The canonical handoff/replay/paused proof was not reached (`reference: null`).
Normalized automatic and ordinary successor responses had no tools/messages;
recorded output usage 4,095 does not establish token exhaustion or a provider
termination cause. Forge's normalized `stop` comes from its empty-call mapping,
without retained raw wire termination metadata. The separate public GET captures
returned an unsupported-route error despite HTTP 200 and supply no such metadata.
Manager exit was zero, with complete empty stdout/192-byte stderr, no forced
signals or cleanup errors. Settings were restored to 200; root verified API/disk,
all 439 source inputs, five v7 candidate binaries, registration and nine original
process identities. `after_inventory` remains null: no post-run provider inventory
is claimed. The earlier private identity admission rejected mode 0644 before
launch; a byte-identical 0600 copy satisfied the unchanged guard. The original
nonpass and empty-response cause remain unresolved.

Two direct source controls then reproduced lost effective priority in
`RuntimeJobSynchronousToolPack.wait`: a user-initiated GCD caller outside a Swift
task and an explicit high-priority Swift task each observed caller `.high` and
worker `.medium`. Both selected cases failed, terminal one, complete 5,971-byte
output, all 439 stable inputs and unforced cleanup (receipt
`134e861f8091f3affac0d56be99614fd4a246859aeaa9469486415d6795e311e`,
raw `2847ec05680d48d34c677af984087037e8ba46ca76c96033c8f430673f864b2a`).
The one-line repair snapshots `Task.currentPriority` in the caller before detached
worker creation. Worker ownership, semaphore/result delivery, bounded deadline,
cancellation and committed-receipt precedence remain unchanged. The fixture's
async-unavailable Thread.isMainThread warnings were corrected with the inspected
Darwin `pthread_main_np()` API, preserving the off-main assertion.

The repaired exact eight-case selection passed all eight without skips/failures,
terminal zero in 12.424 seconds, complete 3,903-byte output (receipt
`12fdfd136f021d8c65da6db0a8cbc2b94c4ea317f0da6f634af4963dd2b914a4`,
raw `08379f1b8143448ca9d81443873be58e0bcd130aa35fcf8757a601f951ef0a49`).
It includes both effective-priority/off-main controls plus deadline, cancellation
and commit-before-return parity. Normal Runtime selected 123 cases: 122 passed,
one absent-PowerShell check was skipped and none failed, terminal zero in 48.909
seconds, complete 36,275-byte output (receipt
`92f5f81cb2e11f4a54a9a27154e2baacd61fb9b8a0e4df9503c06b1f114d27e5`,
raw `77ee68fb35ceab539d97cb6df1cf39087a3767adf376e6821ccfcaada25d4ba0`).
Normal Xcode passed all 41 cases without skips/failures, terminal zero in 22.982
seconds, complete 13,136-byte output (receipt
`4c6bf9f0d22b9627959745afa42dd273265880059192c4949fb77d893dc83e3f`,
raw `71a73b0d5c3ff1e41b3e8c2ef4586a3b3e82d2afacb0706c014ce0543e6d882a`).
All three captures retained full EOF, all 439 unchanged inputs, unforced cleanup
and no owned survivors. These are filtered source-area checks, not an unfiltered
full suite or signed native priority/TPC repeat. The PowerShell skip stays
unperformed. Both baseline failures and the native warning remain retained.

The priority repair changes only existing RuntimeJobSubsystem and RuntimeExecutionJobTests
inputs after full v12/native v7. Their current hashes are
`7559cf62d5464d2ece8047b38544f47fae1df4f3c002ab35fd5be8c05f5dd2d0` and
`41001ac75a724653eb016063dec295dbacdccc700d4e7e024663129a864f32c5`;
canonical membership remains present and project graph SHA
`a6c85ff538223a7111fc5e8e7db96cf03dddef98fa083e3bccbb3fac05822240` is unchanged.
Fresh current canonical/native priority checks, actual-model successor completion,
full artifact acceptance, simulator and crash/ordinary GUI recovery remain open.

### Provider terminal metadata — source checkpoint

Accepted LM Studio responses now persist optional bounded `terminal_metadata`
in the private durable receipt, bound to the exact accepted response ID and
`completed` status. It records output item/type counts, text/argument byte counts,
reasoning-token availability and parsed/streamed measurements.
`streamEOFObserved` is set only after successful URLSession completion and the
existing HTTP/decoder/completed-response checks. It is provider transport evidence,
separate from native `producer_end_reason` and retained artifact-page EOF. Missing
or null legacy metadata stays unknown. Malformed optional fields remain unknown
without changing acceptance or the public normalized turn; incomplete, failed or
lost-transport responses remain rejected. No new actual provider attempt has
established the earlier empty-continuation cause.

The seven focused fixture controls passed in **11.781 seconds**, native zero,
complete **3,902-byte** capture output; the ordinary contract-fixture class passed
all **31** cases in **2.797 seconds**, native zero, complete **10,082-byte** output.
Both had zero failures/skips, all 439 inputs unchanged and unforced cleanup.
Receipts in `candidate-probes/provider-terminal-metadata-source-capture-prepared-v1/`:
`focused-capture/capture-receipt.json`, SHA-256
`bbf228fd01db7d78756309c5c4079d0e2f427ed4100ecb02c6d775cc623a5ffd`;
`normal-capture/capture-receipt.json`, SHA-256
`3796e06e3dbe828646fd9baaa1b188f1d46e933e3b4919ee1c24939b1b4659b0`.
These are source fixture checks at manifest
`9af62722e85eaa4fb73b9dbef2f511cedcdde34c4876352c4aa74085829576d4`.

### Full source v13 and canonical native v8 — current checkpoint

All paths below are relative to `candidate-probes/`. The final source manifest
is `c1805d1aefdee2bf5039db3332a74a4bd577339571ff1dceaa3109f627b3b37f`;
all 439 before/after inputs match in every capture. The full v13 suite retained
all 2,286 prior case identities and added QoS2/provider-metadata7/catalog2.
Independent reconciliation verified all 2,297 exact case statuses, every class
and both bundle counts: 2,284 passes, 13 explicit skips, zero failures. The 13
skips remain unavailable checks, not passes. CLI/app output is incremental
Swift compilation evidence, not signed native/runtime evidence.

| Capture | Receipt SHA-256 | Actual result |
| --- | --- | --- |
| `full-source-classifier-v13` | `e67bed14e5897c0c577ffee5abf5342f70cde91c62cf30bd90d91dca90596c77` | Native0; 2,297 executed / 2,284 passed / 13 skipped / 0 failed; 715.678s; full 688,301-byte EOF; unforced |
| `source-cli-build-v13` | `7bda9ef9eeee8a50ecd187c2bfbbd790728bedbba565a0027923c04e3e62a2dd` | Native0; Swift CLI compilation; 0.992s; full 53-byte EOF; unforced |
| `source-app-build-v13` | `2736d6725abc71f02751aae813eb6aefe098600586e696ca492334a913fe614d` | Native0; Swift app compilation; 1.005s; full 98-byte EOF; unforced |
| `canonical-native-closeout-v8/debug-build-capture` | `18d8bbab3907fbbac85f643b7a468d4519a0a51830deaba77b1b6f6446903cbc` | xcodebuild0 / one build-success marker / full 512,934-byte EOF / 57.345s; outer NONPASS at forced cleanup |
| `canonical-native-closeout-v8/release-build-capture` | `fbf5a91c6208747eb4e3923c7de3cbc7f7c6729045828b5a1404feef981a4ef7` | Native0 / one build-success marker / full 538,533-byte EOF / 151.458s; unforced compilation pass |

The full source log SHA-256 is
`fee82de19b461791acd45b0b6b34965ce18b45ddb5cf69ca43e969d3ecdd5329`.
Root's separate exact-suite reconciliation is retained at
`full-source-classifier-v13/root-exact-suite-reconciliation.json` (SHA-256
`5bce37c2c4a9dab5152fbaa6a160ed8690e8b6236d64065abf93bde294590741`).
Debug raw output SHA-256 is
`c0013dfb3daed4fe6a119bda41f9f6b247f9cb9132423bc734dbe6818552ed31`;
Release raw output SHA-256 is
`4b931f17334d26dcd360117e5febb0116fbcae51fb4e6e2851a0f9cbe88d057d`.

Debug's native terminal result and output were complete, but the capture sent
**SIGINT** to tracked PID **52101**, PPID1/PGID52101, start
`Tue Oct 6 11:48:12 2026`, command SHA-256
`0c247e899ac79e2adc5e98c40158c6c5a4c9497e61d125d3c8f767b399fd6a82`.
No tracked/ambiguous survivor remained afterward. The receipt lacks first-ancestry
and executable-path observations for that process, so its origin and relevance
remain unknown; this is not evidence of a Forge leak or hang. The negative
receipt is retained, not reclassified from xcodebuild's zero exit. Release had
no cleanup signal or remaining owned process. No signing or compilation override
was supplied in either build.

A proposed v9 observation adds bounded measurement before the existing cleanup
stages. It remains closed preparation: no executed outcome, process exemption,
weakened qualification predicate or production patch is claimed. Native37,
fresh five-role identity/effective settings and actual current provider/typed
Xcode/simulator XCTest/ordinary GUI/crash/installed/artifact acceptance remain
separate open gates. The canonical project graph remains
`a6c85ff538223a7111fc5e8e7db96cf03dddef98fa083e3bccbb3fac05822240`.
All earlier negative and positive receipts below keep their original scope.

### Policy source catalog shutdown — source checkpoint

The retained-app control kept `ForgeApp` and its public catalog reader alive
through completed shutdown. The valid physical-identity baseline observed the
same **three** database/WAL/SHM descriptors before and afterward, and a subsequent
read did not throw: one case failed **two assertions**, native one. This reproduced
the catalog connection surviving its graph shutdown boundary. The earlier
path-string observer missed `/var` versus `/private/var` aliases of the same files;
its one-case/two-assertion NONPASS remains retained. The first physical observer
then failed compilation because `Darwin.stat` resolved to the imported struct;
**zero tests executed**. Using `Darwin.lstat` on the resolved target path enabled
the valid baseline. Original before-present/after-absent assertions remain; the
same pre-shutdown device/inode identities are reused afterward, including
unlinked originals, without restating changed paths as new identities.

`StjornarvaldPolicySourceCatalog.close()` now serializes with catalog operations,
checks `sqlite3_close`, and clears its handle only on success. `ForgeApp.shutdown()`
closes its concrete catalog owner before reporting completion. A failed close
keeps the live handle, emits diagnostics after unlocking and leaves shutdown
incomplete; that SQLite-busy branch was not fault-injected. The public reading
protocol and ordinary policy detection/notice authority are unchanged. The
repaired retained-app descriptor control and explicit close control passed **2**
cases in **18.440 seconds**, native zero, complete **2,892-byte** output. They
assert descriptor release while owners remain retained, exact closed errors,
idempotence and durable source/order/revision/artifact/segment/progress/request
replay after reopen. The ordinary catalog class passed all **11** cases in
**2.322 seconds**, native zero, complete **4,619-byte** output. Both had zero
failures/skips, unchanged 439 inputs and unforced cleanup.

Retained receipts below are relative to `candidate-probes/`:

| Scope | Receipt SHA-256 | Result |
| --- | --- | --- |
| `policy-source-catalog-shutdown-source-capture-prepared-v1/baseline-capture` | `39af38df36b9b58a785e003957557e7962f603b8f1de1ead40a8f1e8ea5d62bc` | Initial path observer: one failure/two assertions; 2,431-byte full output |
| `policy-catalog-descriptor-physical-source-capture-prepared-v1/physical-baseline-capture` | `faddf1ca6347fbe30ba0df20de586a4861d107f11d1d45f933a085a758272810` | Compiler NONPASS; zero executed tests; 10,590-byte full output |
| `policy-catalog-descriptor-lstat-source-capture-root-v1/physical-lstat-baseline-capture` | `a89b0896979cfa9f9221b7d55f33239e27995746e78621ae379b310adb4d5842` | Valid physical baseline: one failure/two assertions; 4,915-byte full output |
| `policy-source-catalog-shutdown-post-source-capture-prepared-v2/focused-capture` | `63da0d383263db1613d82e616a2744af4e32c6e1f1bbcd46dac8fdc2eb6e7d58` | Two passed; no skips/failures |
| `policy-source-catalog-shutdown-post-source-capture-prepared-v2/normal-capture` | `e6340f5a47616ddc8227dda3de0bbc340ce44bb310b9b8671490ee4c8b4d62d3` | Eleven passed; no skips/failures |

Final source manifest is
`c1805d1aefdee2bf5039db3332a74a4bd577339571ff1dceaa3109f627b3b37f`.
Exactly eight inputs differ from the v7 `38f9e463…` freeze; the other 431 match.
The project graph remains
`a6c85ff538223a7111fc5e8e7db96cf03dddef98fa083e3bccbb3fac05822240`.
Full source/CLI/app v13 subsequently passed. Canonical v8 Release compilation
passed, while Debug remains NONPASS at forced cleanup. Native37 and current
identity/settings/runtime qualification remain pending; preparation supplies no
executed evidence. Current-source actual
provider continuation, typed Xcode completion, ordinary GUI rollover, crash
recovery and installed/artifact acceptance remain open.

### Owned Simulator startup — retained diagnostic NONPASS

A later direct owned iOS 26.5/iPhone 17 Pro startup completed in **24.096 seconds**.
Its 100-second-budget `bootstatus` returned zero with terminal elapsed **17 seconds**;
`com.apple.addressbook.migrator` logged success in **0.059794 seconds**. All **13**
native commands returned zero with complete producer EOF and no read errno; all
439 source inputs stayed unchanged and cleanup was unforced. Exact new-device
deletion preserved all **32** original semantic identities/states/paths and
keyset. The retained before/after inventory bytes also match; no general
`dataPathSize` equality is assumed.

Receipt `candidate-probes/simulator-owned-wrapper-spindump-disproof-prepared-v2/run-direct-root-spindump-v1/capture/receipt.json`, SHA-256
`a02e7f4483f0630ff5647a9c07e140f3a6d725f0bf7f6bbf8564586c6217de49`;
boot output is **7,246 bytes**, SHA-256
`67fab432e64910f3932a7e3f67d2dec72f41090b49b274beae7dcd6a24890f7d`.
This run retains source manifest
`5c56f390c5eaafe746785d20380cd45af825d3354a3c3928aeb110962d71538d`.

This proves startup for that owned device only. The observer joined before the
sampling window, with zero namespace snapshots and no sample attempt. The whole
targeted diagnostic remains **NONPASS** (`startup_verified: true`,
`diagnostic_capture_complete: false`, `qualified: false`). No runtime PID was
observed, so known-runtime absence and absence of all unobserved runtime processes
are unestablished. Retained guards report ten original processes and registration
preserved. **No XCTest ran**; no earlier stall cause, Forge repair, retroactive
diagnostic qualification or simulator XCTest acceptance follows.

The current signed **native policy v6 control passed** in 10.707 seconds.
Receipt `stjornarvald-assessment/native-candidate-v6/summary.json`, SHA-256
`5943ddbaa91f73ed99be553c3146a860957dce065e8d3c61c8f878f443286b18`,
records Python membership violation confidence 0.99, ordinary MCP notice
presentation and same-identity correction confidence 0.98. A second project and
deployment produced resource-only JavaScript review confidence 0.45; source/copy
aliases produced confidence 0.99, and genuine membership removal corrected the
same violation. Temporarily unavailable graph input produced zero findings and
zero detector faults, preserved its open violation, both historical event row
hashes and the event count of two, then restored exact graph bytes.
Manager and both distinct stdio clients exited zero with complete EOF and no
forced shutdown. All 439 source inputs and candidate hashes remained unchanged.
Root readback verified all nine original protected identities and the MCP
registration, and all three owned PIDs were absent. This covers the executable
`RFD-NATIVE-001` rule, project/client scoping and native transport; model notice
comprehension retains its preceding v6 receipt and was not rerun here.
The coverage response explicitly states that the other 14 indexed rules remain
guidance and that unavailable membership is not compliance. No fixtures were
built or executed as interpreted application components.
The external evidence controller also received local exact-output admission and
nonblocking bounded MCP writes after read-only review found two inherited guard
gaps. Its shared helper and production source were unchanged; the root-admitted
controller digest is `deb6fe79bb5d5af20affb374def10138eab01f6615d8ac32a5ed1ce6ed494db2`.




The retained full v9 source regression is a non-pass: terminal one in 695.156
seconds, 2,261 actual cases selected, 2,247 passed, 13 explicit skips and one
failed case with four assertions. All 29 newly added repair cases passed.
Full raw EOF, all 439 unchanged inputs and unforced cleanup were verified.
Receipt `candidate-probes/full-source-classifier-v9/capture-receipt.json`, SHA-256
`6d6076055983824c27c26beebcb87a1863e7fe9060036c68c058392e63a00206`;
raw log `fef470fce2b3ef9db7c9fb22224519ae0924f9690bc125910482728f98e577d2`.
The existing shared-diagnostic bootstrap cancellation test fails before
cancellation. A failure-message-only diagnostic reproduces
`ForgeBootstrapError.diagnosticHomeMismatch` at `application_graph`, rather than
a published graph. That focused run failed one case/four assertions with terminal
one, full EOF and unforced cleanup; receipt
`c526c887499c805dae391c1900076f3afab0efa7b834e75d80e8fce43fa13058`.
A temporary bounded repeat of 30 original cancellation/retry flows reproduced
the same mismatch twice: equal paths and path hashes, both file URLs, diagnostic
directory flag false and bootstrap flag true. The measurement case failed eight
assertions with native one in 43.057 seconds; its complete 5,719-byte log and
stable 439-input receipt are retained under
`candidate-probes/bootstrap-guard-operands-bounded-repeat-v3/added-run1/`, receipt
`aa7ddeb09d1775fd72f702d6967d181e77661a2bb7ec92173c9dc1f02e045ae0`.
All temporary production instrumentation and the repeat method were removed.
`ForgeApp.bootstrap` now appends an empty directory component to both already
standardized URLs before equality comparison. This corrects the observed hint
difference locally; `AppPaths`, physical path resolution, shared log ownership,
cancellation and layout admission stay unchanged. A new same-home hint control,
file-authority isolation, storage-created-home and existing rejection/cancellation
controls are preserved. All 16 affected source cases passed, native zero/full
EOF/unforced cleanup; receipt
`0635aa833cd1b2f94ab6f22bf8fe121e5b5b7ab0d4585a00d752dc57ea657ba4`.
The same bounded30 original flows then passed in one actual measurement XCTest,
native zero/full EOF/unforced cleanup; receipt
`c454287d5857353b2d2fa939ab91335caa684a95f8961be1a147fd9f2b90f3a8`.
A prior new-fixture baseline returned an unexpected Cocoa remove error at line0,
not the expected guard error; its origin remains unknown and it is not guard
baseline credit. The first authority fixture also used an incorrect unstandardized
`host` expectation; its retained failure did not involve the isolation assertion.
The corrected fixture verifies the prior standardized URL plus only a trailing
directory slash, and actual rejection before layout. Current full v10 passed as recorded above;
CLI/app compilation both returned zero. The final439 source manifest is
`e22caaf308e1eb575ac07102c85af464535cefd9995a5d7f75ec8529f3dcf407`:24 changed
from old-v4,415 unchanged, with unchanged canonical graph membership.
Finishing diagnostic
storage creation before same-home bootstrap passes, as does the existing
different-home rejection. The control capture expected a failure and therefore
remains a diagnostic non-pass despite native zero/two actual passed cases;
receipt `665b9e0871a9abbafc7a90e0b297d301dbdef05e053e1d8cd26e4b3358df8e12`.
That historical control predates the directory-hint repair above.

The strict SecurityAgent command and previous PID 55952 were absent in the fresh
11:37 UTC observation. One bounded signed owned C LLDB control subsequently
passed in 0.714 seconds: native zero, complete 1,551-byte output, breakpoint stop,
main backtrace, fixture marker and target zero exit. The exact fixture and all
439 inputs remained unchanged, with no forced cleanup or authorization changes.
Evidence: `candidate-probes/lldb-signed-owned-hostchange-control-prepared-v1/run1/`,
receipt SHA-256 `d7f08063b15514e6af30714f2b013f0bf80702fb212082745c0b3fc2efef28d0`,
raw `335bd2cdfb52b5a88aa910e3f1a10701b1b965a7abc98f4a524aaf314bf8b8ab`.
The host change's cause is unknown. This qualifies the direct signed C control;
refreshed Forge typed debugger execution remains pending. Earlier timeout
receipts are unchanged.

The latest owned model-to-native Xcode version flow passed in 66.462 seconds.
LM Studio issued one `xcode.discover`, one `job.status` and two
`job.read_output` calls across five completed provider turns. The native job
exited zero; the model consumed complete 33-byte stdout and empty stderr and
returned the exact output in its completion summary. Manager shutdown exited
zero without forced cleanup. All 439 source inputs, five binaries, 13 original
process identities and MCP registration remained unchanged. The independent
root audit is
`candidate-probes/owned-managed-xcode-version-design-v1/run-native-v1/root-independent-model-native-byte-audit-v1.json`,
SHA-256 `58019c3e815a0739bc980700447c34d8e9fe97233e4d8f7201e8ea45ae74e410`.
This version-only proof adds no model-driven build/XCTest/debug/simulator or
ordinary GUI rollover acceptance.

The same-home ordinary successor restart remains a non-pass. In 49.795 seconds
it completed the exact retained automatic turn, then its one model-selected
`fs_read` returned `not_found` for `/home/project/successor-only.txt`; the handoff
specified relative `successor-only.txt`. The controller paused immediately after
the completed turn/read, before allowing tool-error feedback, and failed its
exact-one-marker verifier. Stable replay did not execute. Owned SIGTERM cleanup
returned Manager zero with complete 0/192-byte streams and no cleanup errors.
The receipt is
`candidate-probes/managed-continuation-sigterm-restart-controller-v1/run-native-v5-sigterm-restart1/receipt.json`.
This neither establishes a Forge context defect nor qualifies the missed
SIGKILL boundary.

A separate 200.469-second ordinary resume completed the original error-feedback
turn on attempt two, preserving its exact 487-byte input SHA and previous
response. The model then successfully read the exact owned marker by absolute
path; independent reconciliation matched the actual provider call, durable
result/hash, file inode/content and exact H/ACK/seal. The original failed read
remained unchanged: two durable reads total, one failure and one success.
The diagnostic nevertheless remains a non-pass because its verifier required
a relative path, although production `fs_read` permits the observed absolute
path. It stopped before pause/replay; a later feedback intent is ambiguous and
the run remains recovering. Manager exited zero after bounded SIGTERM, with
complete 0/192-byte streams. No configuration, SQL, receipt ledger or lease was
written by the controller. Evidence:
`candidate-probes/managed-continuation-ordinary-resume-controller-v1/run-native-v5-ordinary-resume1/independent-owned-resume-reconciliation-v1.json`,
SHA-256 `02b0636202ae859e2ed10d3978294e2835d3ea2b791c36298227c1eb2dca1d96`.
This supports owned error-feedback recovery and one successful marker read;
final comprehension, SIGKILL and ordinary GUI remain unverified at that cut.

A separate native two-launch paused replay passed in 12.636 seconds. The exact
authenticated pause preserved the original completed feedback and both reads;
the fourth feedback turn remained ambiguous without a new accepted response.
Both Managers exited zero with complete 0/192-byte streams and no signals or
cleanup errors. The second launch preserved the scoped state for 10.134 seconds,
including handoff/ACK/seal, two tool rows, four turn identities and unchanged
native/provider ledgers. Original non-passes remain unchanged. Root independent
cut/stream audit:
`candidate-probes/managed-continuation-paused-replay-controller-v1/run-native-v5-paused-replay1/root-independent-paused-cut-stream-audit-v1.json`,
SHA-256 `40e6afc5ab268b2f11eba9d99a83d65a32b6af0b7d465976f01135c976b8812a`.
This is ordinary paused restart proof for the retained owned home.

The actual model-to-one-XCTest diagnostic ran
`ForgeConductorAppTests/RuneForgeAppTests/testNewerPolicyReorderSurvivesOlderLateSuccess`
once, passing in 0.170 seconds. The typed test and xcresult jobs both exited zero;
the model consumed all four complete streams and returned the actual job IDs,
selector and xcresult counts: one selected/pass, zero failures/skips. The whole
managed-run diagnostic remains a non-pass after its 900-second limit. Durable
events 72/73 and 92/93 recorded parsed completion requests rejected for
`project-build` and `project-tests`. The test-without-building action supplied no
new build, and the then-current
`InstalledNativeGateRegistry.EvidenceAccumulator.consume` recognized only
shell-based build/test evidence. The subsequent typed Xcode repair preserves
both obligations; its source evidence is recorded below. Current signed native
and actual-model completion checks remain pending. Independent native-byte and
completion reconciliation:
`candidate-probes/owned-managed-one-xctest-design-v1/independent-completion-gate-observation-v1/native-completion-reconciliation.json`,
SHA-256 `00567a29a443ae159ae4be038bde86e53dac2557cfadfab663aea1bebbc4fec6`.

## Reproduced defects

- **E0 typed Xcode completion:** two descriptor regressions failed before repair
  while existing schema/discovery controls passed. Both passed after repair.
  The broker now persists bounded typed intent before admission; the existing
  runtime command summary carries the actual command fingerprint. The gate
  verifies project/generation/run, terminal native zero, complete retained
  streams and exact native command identity. A passing xcresult summary requires
  positive integer counts, all tests passed and no failures/skips/expected
  failures, bound to its actual test producer and the latest result-bundle
  writer. Distinct successful jobs at the same whole-second timestamp remain
  ambiguous; same-job replay is idempotent. Build and test actions satisfy
  separate obligations. Legacy replay remains available without manufacturing
  typed completion authority. All 78 actual Xcode/Queue source cases passed,
  zero failures/skips, terminal zero, full EOF, unforced cleanup and all 439
  inputs unchanged. Evidence:
  `candidate-probes/typed-xcode-completion-source-capture-repaired-v2/classes-run1/`,
  receipt SHA-256
  `24528682ddff85cc25e933fb0a73b265dbf744dfb7591d12c7fae959bd65340b`,
  raw log `186af952f94f6fc55a9d169d7cdcf944373bb2f2434709bcb13770c6dd8af872`.
  The initial 78-case run failed two new fixture lifecycle expectations: native
  exit 65 is a failed job, and queued-to-completed is not a valid transition.
  Those fixtures were corrected to the existing contract; production lifecycle
  rules and original tests were preserved. Five existing production inputs and
  the existing Xcode test file changed; canonical membership is unchanged.
  These fixture-driven source tests establish neither actual Apple XCTest
  execution inside the fixture nor current signed/native/model completion.
- **E0 Manager settings reload:** two real configuration owners reproduced
  stale typed/dictionary settings: a separate owner saved a limit of 3 while
  the Manager still returned 200. Two negative cases failed six assertions;
  the malformed/missing cached-recovery control passed. `settingsModel` now
  calls the existing `refreshIfChanged` inside its existing error boundary
  before reading the budget policy. It preserves staged shell opt-out, cached
  complete-model recovery and unchanged malformed/missing files. All three
  focused cases passed afterward. `ManagerTests|ContinuityTests` then selected
  290 actual cases: 288 passed, two explicitly skipped, zero failed, terminal
  zero/full EOF, no cleanup signals or survivors. The skips remain unperformed
  external-lock/live-provider checks. All 439 inputs were unchanged during
  each capture; the two existing source/test files need no graph edit. Evidence:
  `candidate-probes/manager-continuity-settings-source-capture-prepared-v1/`,
  baseline receipt `0141724938cedf68d9509995f205ed26beaae75c88db700114d0f9e725d5c75f`,
  focused receipt `3e952d7f3c75b8aef272ca165f4785213ea1cefcac4cf8a65c8b97c2af03a727`,
  class receipt `8612b2fce5664ac538c657bdb4bc2c9ae2b2ba4564e20e513f06fc8346963007`.
  These inputs postdate the retained native v5 artifacts; native validation
  remains pending.
- **E0 failed-tool continuity progress:** a six-case baseline selected three
  negative cases and three success/historical controls. All three negative
  cases failed (four assertions); all controls passed, with zero skips and
  terminal one. The executor described a failed invocation as successful and
  advanced its ordered cursor; the handoff builder included it in completed
  work. The repair persists `managed_last_tool_outcome`, retains the open
  action on failure, and excludes failed invocations from completed work.
  Complete legacy JSON with Boolean `ok=false` is recognized within 4 KiB;
  numeric zero, missing and indeterminate historical outcomes preserve their
  previous presentation. Queued Xcode receipts remain submission evidence.
  All 14 added cases then passed, followed by all 33 actual cases in
  `ManagedProjectRunStepExecutorTests|ManagedContinuityWorkerTests`, with no
  skips/failures, terminal zero, lossless EOF and no cleanup signals. All 439
  pinned inputs were unchanged during each capture. Evidence:
  `candidate-probes/managed-failed-tool-source-capture-prepared-v3/`, baseline
  receipt SHA-256 `2a5c968c87641268ebd85a425318a111c36fa09a30577e587144a4309458e1b9`,
  added receipt `56e6188d0acb29765bf77c5ea17a883bdb5d268f01f1435e341d43635c7b0877`,
  class receipt `c5f4f89d1a8728a0532dea102bc5558b5e695773d99e2dbb20c62a52627da4d5`.
  Carried old-v4 comparison fields describe the earlier parent freeze, not these
  current captures. The immutable receipts' actual before/after maps are
  reconciled in `root-old-v4-comparison-correction-v1.json`, SHA-256
  `d34d760040a71c6c9b50b9d325088a7b68af59a5eced5f0af36ceb8d7e67e2a6`:
  baseline differs in 11 paths with 428 unchanged; repaired selections differ
  in 13 paths with 426 unchanged. Case outcomes and current-input guards stand.
  Four source/test inputs changed after the v8/native v5 freeze; the workspace
  graph remains unchanged. Refreshed native validation is pending. This does
  not attribute the earlier model-selected wrong path to this defect.
- **E0 SSE event budget:** the bounded native v3 Manager attempt failed its
  initial provider turn with `lmstudio_limit_exceeded` / SSE event count, before
  any continuity operation or SIGKILL cut. Its raw stream was not retained, so
  its event makeup and validity remain unknown. Independently, the real REST
  client rejected a coherent fixture containing 4,096 text deltas plus lifecycle
  and DONE frames: 4,104 counted frames, 799,609 body bytes and 4,096 text bytes.
  The same fixture passed after the finite Responses event-budget repair.
- **E0/E1 continuity:** the installed ordinary chat reported progress zero after
  runtime work and showed no resume-ready handoff. `ContinuityAutomation` used
  per-process counters, excluded direct runtime/job tools, and initialized the
  first elapsed-handoff baseline only after a handoff. Its 200-call threshold
  was fixed in source. Primary, fallback and CLU processes share a deployment
  identity but previously did not share durable progress.
- **E0/E1 policy:** the live read-only database held 710 observations and 710
  committed evaluations, zero detector faults and zero violations. All lacked
  `details.nativeTarget`, which the sole registered detector requires. Fifteen
  active Raven rules were indexed; fourteen had no executable detector. The
  interactive notice cache also failed to refresh when a new notice arrived
  after an empty initial fetch in the same scope.
- **E0 Xcode:** the original signed Forge helper's direct `build-for-testing`
  job returned native exit 65 with a crashed Xcode build service. The same
  original source and command outside Forge returned native exit zero. NOFILE
  256 alone passed. FSIZE 1 GiB alone failed. Installed `llvm-cas` plus the
  installed Xcode CAS plugin returned `File too large` at 1 GiB and exit zero
  at 32 GiB. During the passing 32 GiB test build, CAS files had logical sizes
  12 GiB and 24 GiB but physical allocations of 1 MiB each. The original CPU,
  descriptor and core limits were retained in that passing build. This was a
  **test build**, not executed XCTest evidence.
- **E0/E1 telemetry/readiness:** idle MCP helpers started recurring GUI telemetry
  collectors. The current continuity readiness view selected historical paused
  runs from an older project generation and labeled them monitoring.
- **E0 continuity polling:** unchanged polls of an owned, running native sleep
  job triggered an identical-call handoff on call four and a block on call nine.
  That guard could interrupt legitimate waiting before the configured total
  tool-call budget. Successful nonterminal `job.status` polls now break the
  identical-call fingerprint while still counting toward the total budget.
  Output streams become readable only after job completion; unavailable-output
  attempts retain their original error and repetition protection.
- **E0 continuity project transition:** an actual router test saved a project A
  handoff, archived A through the public generation-validated API, bound the
  same client to B, and made four identical B reads. The loop guard reused A's
  handoff identity/root and changed A's canonical packet. The selected case
  returned exit one with four assertion failures. The remaining client-only
  `budgetAutoCheckpoint` lookup now uses the exact trusted runtime scope and
  root. Packet, progress pointer and hard block commit atomically, with an
  expected-epoch fence. Open current checkpoints retain their identity;
  finalized history remains immutable. The four-call soft and nine-call hard
  thresholds are unchanged. The reproducer and five adjacent recovery,
  concurrency, capacity, epoch and metadata cases passed in the full Swift run.

Evidence is retained at
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-05-functional-repair`.
The baseline source is `f0dd195636117c210356621ee844b24a9af46fe2`.
Native commands, resource limits, stdout/stderr and terminal receipts remain
under `baseline/` and `research/`; the installed CAS reproduction and original
32 GiB test-build control are separate from candidate verification.

## Implemented surfaces under validation

Manager → Settings exposes **Rollover after tool calls**, with a default of 200
and range 1–10,000. **Save settings** saves `sessions.continuity_rollover_tool_calls`;
existing configuration files default to 200. Running MCP helpers refresh the
saved setting at eligible tool boundaries. Successful and failed eligible progress
calls both count toward the selected limit. Existing successful and failed
count fields remain separate for compatibility and diagnostics. Ordinary MCP
retains the two-hour guard and checkpoints at the smaller of 50 and the chosen
rollover limit. Model checkpoints do not reset the handoff budget.

Managed runs refresh the same saved limit at result boundaries and count unique
eligible invocations with committed results for the exact run, project, generation
and active provider session. Returned tool errors count; interrupted or ambiguous
effects do not. Replay reuses completed journal entries and restores retained
result feedback before count rollover. Managed runs retain measured-capacity
evaluation and the existing 32 provider-tool-round safeguard, which can request
an earlier rollover.
The built-in test, debug and implement agents retain their existing tools and
now also receive the five typed Xcode tools and existing job inspection tools.
Their instructions require terminal job state and actual xcresult outcomes.
Custom agent overrides and other role grants remain unchanged.

Debug and Docs instructions previously advertised `python_exec`/`python_info`,
and the precommit role advertised `search_files`; none was registered or had a
historical implementation in this repository. The instructions now name
existing `runtime.capabilities`, durable `python.run`, and `fs_glob` tools.
Docs receives the existing job controls required to observe Python completion.
Filename-search discovery now describes the handler's existing optional
`pattern`/`path` parameters. No implemented tool API is removed. New exhaustive
resource/fallback grant parity and ordinary replacement-tool admission tests
passed in the full Swift run's 14-case catalog class. The native glob fixture
compares the canonical existing path, preserving the handler's `/private/var`
normalization and exact single-result assertion.

Ordinary LM Studio MCP progress is keyed to trusted project, generation and
deployment client, using durable logical epochs because the external chat does
not expose a supported individual chat-context identity or context-usage value.
Forge-owned runs and provider sessions retain their own capacity evaluators;
their calls do not enter an unrelated ordinary chat budget. Automatic packet/progress writes are
atomic and restart recoverable. The manager rejects reset-fenced packet scopes;
an acknowledged exact handoff clears the predecessor block. Historical packets
and project data remain available. Open automatic checkpoint identity and
runtime history are bounded to 1,024 progress scopes and 10,000 runtime packets;
capacity failures remain visible rather than silently deleting history.

Five additive native Xcode tools preserve existing shell/process tools and
use explicit argument vectors through the existing durable job service:

| Tool | Capability |
| --- | --- |
| `xcode.discover` | Xcode version, SDKs, schemes, destinations, build settings, test plans |
| `xcode.run` | Build, test, analyze, archive, build-for-testing, test-without-building |
| `xcode.result` | Native xcresult JSON build results and test evidence |
| `xcode.debug` | Explicit owner-authorized LLDB batch commands |
| `xcode.simulator` | Read-only simulator device/runtime/type inventory |

Submission is not completion. Read `job.status` to a terminal state and inspect
`job.read_output`; native exit, truncation and timeout remain distinct. Actual
test execution requires xcresult counts and outcomes. `xcode.run` requires an
explicit project or workspace, scheme, destination, Derived Data and result
bundle. `only_testing` selects tests for `test`, `test-without-building`, or
`build-for-testing`; the last action prepares a test build and does not execute
XCTest. Archives require an explicit candidate path. Shipping, provisioning
and signing overrides are not added. Forge Conductor is a macOS app and is
validated on **My Mac**; simulator destinations apply to compatible projects.

By default, the typed tools and the original direct `process.run` Xcode path receive a
finite **32 GiB per-process file-size allowance** for native CAS sparse files.
The direct path recognizes canonical Apple-signed native `xcodebuild`, the
Apple `/usr/bin/xcodebuild` shim, or `/usr/bin/xcrun` executing `xcodebuild`.
For the shim and `xcrun`, a native `xcrun --find` lookup has a two-second deadline
and `PATH_MAX` output cap; it uses the job's sanitized environment and inspected
SDK, toolchain and cache options. The resolved executable must satisfy the Apple
anchor and `com.apple.dt.xcodebuild` identifier. The original executable and
argument vector are preserved. Unresolved lookups, other tools, lookup-only
requests and fake executable names retain the generic policy. Source:
[`ExecutionJobService.effectiveFileSizeProfile`, `isVerifiedNativeXcodebuild`
and `buildPlan`](../Sources/ForgeConductorCore/Application/ExecutionJobService.swift).

The generic default remains **1 GiB**. Shell, Bash, Python and PowerShell
programs retain that default even when their program text mentions Xcode.
Omitting `maximumFileBytesPerProcess` selects the generic 1 GiB default and
the native Xcode 32 GiB allowance. An explicit valid cap applies to every
profile, including Xcode: explicitly configuring 1 GiB retains 1 GiB for
Xcode too. The existing explicit-cap range remains 1 byte–16 GiB. Source:
[`RuntimeJobLimits`](../Sources/ForgeConductorCore/Domain/RuntimeJobModels.swift)
and the service's limits validation. The
[`native launcher`](../Sources/ForgeRuntimeLauncher/main.swift) accepts at most
32 GiB and also respects the inherited hard limit. The ceiling bounds logical
file growth; the observed CAS mappings occupied 1 MiB each. CPU, descriptor,
core, descendant, timeout, output, cleanup and signing policies retain their
existing bounds; the selected non-generic profile and effective requested byte
cap are persisted in the durable job's `commandSummary` and retained receipts.
No MCP flag or caller environment variable selects the internal profile.

Typed Xcode idempotency keys include canonical command, working directory,
timeout, output budget and profile version. Broker reconciliation returns the
existing job's submission receipt and fences its run identity. The adapter now
checks a committed row's project, generation and run before emitting a successful
receipt: a foreign run winning a duplicate-key admission stores
`runtime_job_scope_mismatch` instead. Project-owner contexts without a run retain
their existing access. Source:
[`XcodeCLIService.observePersistence`](../Sources/ForgeConductorCore/Application/XcodeCLIService.swift)
and [`ProductionToolInvocationReconciler`](../Sources/ForgeConductorCore/Application/ToolInvocationBroker.swift).
The added deterministic test exercises the repository's existing-row COMMIT
observer and passed in attempts eight and nine. Native proof of the original raw launch recognized the bounded sparse-CAS
profile. Its default Xcode parallelism then exceeded the existing 16-descendant
budget; the retained job reports `runtime_descendant_limit_exceeded`. Repeating
the same build-for-testing flow with explicit `-jobs 2` completed with native
exit zero and full output. `xcode.result` reports a successful build action with
zero errors. This is build-for-testing proof, not XCTest execution, and no
descendant protection or raw command semantics changed.

Stjornarvald now refreshes same-scope notices on the bounded asynchronous cache
worker, retaining one current refresh and one replaceable request. In-flight
receipt suppression prevents an earlier database read from republishing an
already presented notice; admission is bounded to 64 receipts and 512 notice
identifiers. Graph deduplication commits only after confirmed outbox persistence;
failed or unknown submission retries on a later call. A producer on the existing
serial observation worker collects declared source/resource/copy membership
from root-listed production targets
for the selected project and generation. Conventional copied directories
include hidden resources. Test targets and build-script phases are excluded;
unknown synchronized membership, unresolved embedded products, and unsupported,
changing or oversized graphs produce incomplete activity. Binary runtime
contents are not inspected. Non-regular graph files are rejected without
waiting for a pipe writer. Ordinary MCP work can reach the existing
native-stack detector; the other 14 Raven rules remain indexed policy guidance
without executable detectors. Rune Forge exposes this coverage beside its
violation count, so zero does not establish universal compliance. Attempt nine
passed all 9 notice cases and all 13 integration qualification cases, including
the receipt/read race, outbox-full recovery, browser-asset parity and the ordinary
MCP violation/correction/notice control.

The declared-source heuristic also flags the canonical
`TelemetryStatic/app.js` and `tools-catalog.js` resources. These bytes are served
by native `TelemetryService.loadStatic` and `DashboardServer` HTTP routes;
`index.html` loads `app.js` in the optional external-browser dashboard. The
native operator GUI uses SwiftUI `RigDashboardView` and `AppTelemetryBinding`.
`ManagerNode.openDashboardBrowser` launches Chrome or the default browser with
`/usr/bin/open`; the inspected native app has no embedded JavaScript engine or
browser-shell consumer. This finding does not prove binary interpreter execution.
The pinned RFD-NATIVE-001 statement governs native application architecture but
does not explicitly resolve optional external-browser diagnostic assets, so
this remains a classification limitation and false-positive risk. No resource
exemption or policy weakening is added. A thirteenth
integration case preserves the canonical findings, worker/frontend findings and
unchanged native HTTP asset serving; it passed in attempt nine. Full policy
architecture compliance remains open.

The later optional `declaredPathRoles` observation field records bounded graph
roles and preserves legacy decoding. Complete resource-only JS/MJS membership
now produces a 0.45-confidence review assessment with assumptions and
alternatives. It remains a violation under the existing condition identity,
keeps the prior immutable event bytes and can deliver an advisory notice;
uncertainty grants no exemption or correction. The role metadata is not
producer-authenticity, resource-consumer or binary-runtime proof. Python and
source/copy/synchronized script membership, plus legacy evidence without roles,
retain conservative 0.99 positive findings. Malformed role metadata is rejected
at observation intake; incomplete or transport-overflow activity cannot clear
a known violation.

The **October 5 source checkpoint** in
`runtime-affected-classes-final-review-v2.log` executed 23 integration and 9 notice
cases with zero failures/skips, including the original resource-only certainty
reproducer, alias-role union, legacy/invalid/positive controls, bounded metadata
overflow and retained history/advisory presentation. This is source regression
evidence. It does not relabel the earlier signed native v3 Python-resource flow,
qualify the final candidate or prove model comprehension; final review remains
in progress.

## Verification state

### October 6 SSE transport and refreshed source/native checkpoint

`LMStudioRESTClient` now uses a private finite **5,120-event** budget: the
4,096-frame content allowance plus 1,024 lifecycle reserve. This is a numeric
work bound, not a universal token-to-event guarantee. The public
`LMStudioSSEDecoder.maximumEvents` and its original initializer retain **4,096**.
The default independent bounds remain 64 KiB per line, 256 KiB per event,
2 MiB total response, 512 KiB text and 256 KiB arguments; configured output-token
and connection/first-byte/idle/total-time limits are unchanged. Completed
response, exact handoff acknowledgement and sealing checks remain required.

The original focused baseline executed four cases: three passed and the valid
REST fixture failed exactly at SSE event count. After repair, five focused cases
passed without skips/failures. The normal transport/adapter selection passed
56 of 57 cases, with one disabled live-provider skip and no failures. Exact
5,120 acceptance / 5,121 rejection, legacy 4,096 decoder behavior and independent
byte bounds passed. The original native v3 initial-provider failure remains in
`candidate-probes/managed-bootstrap-sigkill-observable-v3`; it establishes no
accepted provider response, rollover, ACK or process-death recovery. Its original
raw-stream validity remains unknown.

Full source v8 returned **terminal zero** with **2,232 actual cases**:
**2,219 passed**, **13 explicitly skipped**, **zero failed**. Core selected
2,202 cases (2,189 passes / 13 skips), and all 30 filesystem cases passed.
All 439 source/resource/test/graph inputs remained unchanged; complete raw EOF
and exact case reconciliation were verified, with no cleanup signals or owned
survivors. The receipt is
`candidate-probes/full-source-classifier-v8/capture-receipt.json`, SHA-256
`455d8bc72a41ee775cb3e4e27a44d2bd98a4fc788f35da5fbf02599cad5ea5df`.

Refreshed canonical native v5 Debug/Release builds returned zero with complete
output, unchanged 439 inputs and five-role strict verification/metadata/
entitlement controls. The signed Debug CLI's typed `xcode.run` executed exactly
**five SSE tests**, all passed, with **zero skips/failures**, native/serve exits
**zero**, and lossless **696,801 stdout / 1,280 stderr bytes**. Exact named
starts/passes were verified in
`candidate-probes/native-sse-event-xctest-v5/native-case-inventory-review.json`,
SHA-256 `2330bb3f2b50f494fdd1840c0277d9d3cfe5b773392ac588f17a4b147b210047`.
This source/scoped-native checkpoint establishes no ordinary GUI rollover,
SIGKILL matrix, installed-build, simulator, debugger or shipment acceptance.
The direct native v5 Manager attempt is a retained **non-pass**. It completed
its initial provider turn with reported usage 9,584 input / 1,401 output /
10,985 total tokens at capacity 262,144. The provider-exact after-turn rollover
observation matches the operation's budget observation; the operation reached
`successorRequested`. The evidence probe then failed `canonical H integrity
mismatch`, before a sampled cut or SIGKILL, after 85.160 seconds. Exact owned
SIGTERM cleanup ended Manager at zero with complete 0-byte stdout / 192-byte
stderr, no cleanup errors, and all 13 freshly pinned original process identities,
registration, source inputs and candidate hashes unchanged. There is no crash
recovery pass from this attempt.

Native Foundation independently verified the probe encoding defect against
the exact retained handoff (**E0**). The probe hashed persisted JSON member
bytes, including 12 escaped slashes, instead of the sorted-key,
`withoutEscapingSlashes` encoding owned by `ForgeJSONCanonicalizationV1`.
Foundation's 28,476-byte canonical digest matches both SQL and embedded
integrity. The production integrity contract was preserved. The evidence-only
probe now uses the pinned Foundation helper; a changed stored digest is still
rejected. The original v3 stream's validity remains unknown, and the v5
response's frame count was not observed. The proof is
`candidate-probes/handoff-foundation-canonicalization-v1/root-actual-Foundation-comparison-v1.json`,
SHA-256 `03bc422df6d932e8a4d4786f32b51cd1f55c6b6b8037b780c9822e8bbd42bf4a`.

Corrected probe v6 used the same native v5 candidate and verified the new
handoff's canonical digest with the pinned helper (native exit zero, complete
303-byte stdout / zero stderr). Its single 60-second observation window ended
without an accepted durable adapter receipt after 1,007 samples. Its initial
provider root completed with reported usage 9,581 input / 2,484 output /
12,065 total tokens at capacity 262,144; the matching provider-exact observation
triggered rollover in the owned low-budget fixture. Final ledger state was
`retryable_failure` / `owner_interrupted`, with no successor receipt, ACK or
continuation. The 60-second window was shorter than the configured 600-second
transport deadline; exact provider progress remained unknown. The attempt
returned one after 190.259 seconds and remains a **non-pass**. No SIGKILL or
recovery phase ran. One exact owned SIGTERM cleanup ended Manager at zero with
complete zero-byte stdout / 192-byte stderr and no cleanup errors. This miss
establishes no successor failure cause or crash-recovery pass. Its receipt is
`candidate-probes/managed-bootstrap-sigkill-observable-v6-prepared/run-native-v5-attempt1/receipt.json`.
The original v5 non-pass remains retained separately.

The later v7 probe extended only the observation window to 600 seconds and its
sample bound, preserving the same candidate and acknowledgement guards. Its
initial provider root reported 9,580 input / 503 output / 10,083 total tokens;
the matching exact observation crossed the owned fixture's rollover threshold.
One actual V2 bootstrap acknowledgement matched the operation, project,
generation, run, handoff, canonical digest and nonce. SQL durably accepted one
successor, marked the predecessor sealed/inactive and issued one automatic
continuation intent (**E0**). Durable predecessor fencing at sequence 20 preceded
successor acceptance at 22. There were no tool invocations; the continuation
remained `intent`, attempt zero, with no provider response.

The probe missed its planned pre-SQL crash boundary: 1,204 samples ended in
`predecessorSealed` after the prior `successorRequested` sample. It returned one
after 117.894 seconds, with no SIGKILL. Exact owned SIGTERM cleanup ended Manager
at zero with complete zero-byte stdout / 192-byte stderr and no cleanup errors.
All 439 source inputs, candidate/helper hashes, 13 protected process identities
and the MCP registration remained unchanged. Post-provider inventory was not
captured, so loaded-model before/after parity remains unverified. Ordinary
restart/replay, actual continuation work, SIGKILL recovery and LM Studio GUI
succession remain separate gates. The frozen independent audit is
`candidate-probes/managed-bootstrap-v7-independent-audit-v1/audit.json`, SHA-256
`c0dab6db49965f0de982d1c205e05ca63ccece6d24af0b41e092760d09116d0e`.

### Completed full Swift v3 source checkpoint

`swift-full-regression-atomic-ack-budget-v3.log` returned terminal zero. Core
started **2,181 cases**: **2,168 passed**, **13 explicitly skipped**, **zero
failed**. Filesystem qualification separately passed **30 actual cases** with
zero skips/failures. `swift-full-regression-atomic-ack-budget-v3-verification.json`
records every case count, all 13 skip names/reasons, tested source hashes and the
413-input graph. The skips cover two native-job autonomy fixtures, five live
provider/rollover/preparation cases, an external-process relink helper, a native
gate-effect helper, two signed candidate/peer cases, a disposable Keychain case
and unavailable PowerShell. None is a pass.

The earlier v2 full run was prematurely stopped with exit 143 after log flushing
was misread. Its corrected stop receipt records the suspected case passing in
0.073 seconds; no hang was established. That interrupted run is unqualified and
is not the v3 result.

Four built-in playbook guidance bodies were edited **after** this full source
snapshot to describe paired job cursors, byte offsets, base64 recovery and partial
output evidence. Tool help already contained that guidance. Their affected
catalog rerun, `runtime-job-agent-guidance-catalog-v1.log`, selected **14 cases**:
**one passed**, **13 failed** with native signature-gate status `-67054`, and none
were skipped; terminal exit was one. The outer XCTest resource seal retained
six obsolete hashes after SwiftPM copied four updated playbooks and the nested
resource signature files. That actual stale seal produced `-67054`; it did not
require a production trust alias or a test/signing-policy patch.

The fresh scratch rebuild, `runtime-job-agent-guidance-catalog-fresh-v2.log`,
passed **14 actual catalog cases** with zero skips/failures and terminal zero;
strict deep verification of that XCTest bundle also returned zero. The retained
`runtime-job-agent-guidance-catalog-fresh-v2-verification.json` records the source
inputs and both subsequent Swift product builds returning zero. Later genuine
status-regression compilation legitimately relinked/resealed the default XCTest
bundle, which also passed strict verification; no package clean or manual
re-signing was used. The original failure and six-hash evidence remain in
`candidate-probes/canonical-native-closeout-v1/swiftpm-stale-resource-seal-and-rebuild-receipt.json`.

### Later persisted-settings status and storage-owner repair

The saved-limit status reproducer executed once with five assertion failures:
both status views retained old limits after another settings owner saved a new
one. The exact case then passed with the existing helper/staging control. Status
now refreshes saved settings before capturing both limit views, preserving
counters, pending editor values and cancellation/deadline handling. Missing or
malformed configuration keeps cached status recovery readable and adds only the
failure diagnostic `configuration_refresh`: `state: failed`,
`using_cached_settings: true` and an error bounded to 256 Unicode scalars. Healthy
status omits that field.

Three direct Audit/Queue fixtures then reproduced 11 assertion failures:
storage initialization recreated a missing configuration and replaced cached
shell opt-out. Only Audit JSONL mirror and Queue constructor now use the internal
storage-only layout. The same directories and 0700 permissions remain; full
bootstrap still creates its existing defaults. SQLite-first audit/JSONL parity,
cancellation/deadline audit paths, cold directories, shell opt-out, queue storage
and snapshots remain covered. This makes no claim about every other layout caller
or missing/malformed-config successor ACK/seal.

The same three storage cases plus three status cases passed: **six actual cases**,
zero skips/failures, terminal zero. Normal seven-class validation then passed
**300 actual cases**, zero skips/failures, terminal zero: AppConfig 23, Budget 3,
Continuity 138, Core 58, Legacy cancellation 26, Queue 38 and Catalog 14.
`candidate-probes/runtime-storage-config-focused-v2-verification.json` retains
original/repaired cases; `candidate-probes/runtime-storage-config-affected-v3-verification.json`
retains the 300-case result and its frozen source inputs. Full plain Swift v4,
`swift-full-regression-status-storage-v4.log`, then returned terminal zero: Core
started **2,187 cases**, with **2,174 passes**, **13 explicit skips** and **zero
failures**; filesystem qualification passed **30 actual cases** without skips.
`swift-full-regression-status-storage-v4-verification.json` records all skipped
names/reasons and verifies all **439 frozen product/test/graph inputs** remained
unchanged after the run. The 13 skips remain unqualified capabilities. This is
source regression evidence; the separate scoped native v2 controls below do
not turn the skipped source cases into passes. Ordinary GUI and general model
behavior remain unqualified.

Post-guidance canonical Debug/Release **v1** builds returned zero, and all five
roles per configuration passed strict signature/metadata/effective-settings
checks. Both preserved copies retain matching five-role binary and app/Core
metadata hashes. These receipts
under `candidate-probes/canonical-native-closeout-v1/` predate the status/storage
fixes and establish platform identity/settings only. They remain dated receipts
and are not relabeled as current v2 proof. The earlier 505-case and 34-case
checkpoints below retain their dated inputs and explicit skips.

### Retained native v2 checkpoint — predates semantic classifier repair

At this checkpoint, canonical Debug and Release builds returned terminal zero
against the same **439 frozen inputs**. All **five roles per configuration** passed
strict signature/metadata/effective-settings checks; exact current and earlier
binary identities are retained in
`candidate-probes/canonical-native-closeout-v1/fresh-native-build-identity-v2-verification.json`.
These build/identity receipts alone establish no GUI or runtime result.

Both configurations then exercised compiled CLI discovery and a native Xcode
version job through Core/runtime-launcher admission: native job exit zero,
serve exit zero, and lossless reconstructed stdout reporting `Xcode 27.0` and
`Build version 27A266a`, with empty stderr.
`native-runtime-version-v2-verification.json` records those separate native
runtime boundaries; it does not qualify the filesystem daemon or simulator.

The exact native app-hosted selection
`ForgeConductorAppTests/RuneForgeAppTests/testZeroViolationsRetainsExplicitEvaluationCoverageAndUnknownFallback`
executed **one actual case**, zero skips/failures. Its native job and result
command returned zero, and the xcresult summary reports **Passed**, total one.
`rune-native-v2-verification.json` retains that result and both serve exits zero.
This is coverage/unknown-state presentation proof, not every Rune control or
policy detector. The v2 owned Debug/Release identity/version-drift fixture
`ProductPathReliabilityTests/testNativeCandidateBundlesPreserveIdentityAndRejectVersionDrift`
also passed **one actual case**, zero skips/failures, terminal zero;
`native-product-fixture-v2-verification.json` records exact metadata, five-role
signatures, payload exclusions and drift rejection. All four verification
receipts are under `candidate-probes/canonical-native-closeout-v1/`; their **v2**
names distinguish those tested artifacts from the retained v1 checkpoint.

Native policy v5 passed the owned declared-membership/MCP controls described
below. A separate model v6 historical-notice interpretation and retained-v9
compatibility v3 also passed within their owned scopes, described below.
Ordinary GUI rollover/threshold acceptance and overlap, general future model
behavior, LLDB, Compute occlusion and simulator XCTest remain unqualified. No
installed-build or shipment proof is claimed.

### Owned live threshold fixture — scoped managed API v7 passed

The full-v4 source run and retained native v2 artifacts above retain their dated
439-input identities. The first later fixture correction changed two arguments in
`LiveLMStudioManagedAutonomyTests`: its unknown configuration-owned completion
gate was replaced by `ProjectInstructionQueueStore.builtInCompletionGate`.
Assertions, production code and the other **438 frozen inputs** were unchanged.
`candidate-probes/live-managed-v3-input-review.json` and
`live-managed-fixture-admission-two-lines.patch` retain that boundary. The exact
ownership control
`ManagerTests/testInlinePreparationRejectsConfigurationOwnedUnknownCompletionGate`
passed **one actual case**, zero skips/failures, terminal zero. No later full
source pass is claimed for the changed fixture. Through the v7 test freeze,
subsequent bounded diagnostics and opt-in cutoff changes were confined to that same test file; production, the graph and the
other 438 inputs stayed unchanged.

The retained owned runner attempts are under
`candidate-probes/live-managed-gui-preservation-v1/`:

- **native-v1:** process-classification rejection before launching the test;
  zero cases executed. This is a runner rejection, not a product test result.
- **native-v2:** terminal one, **one actual failed case**, zero skips. The
  preparation assertion reported `needsChoice` instead of `ready` because the
  custom configuration gate was not owned by the prepared instruction source.
  The same case also reported a caught `CancellationError()` at
  `StjornarvaldManagerCoordinator.swift:775`.
- **native-v3:** after the two-argument fixture correction, terminal one,
  **one actual failed case**, zero passes/skips, **4.533 seconds**. The gate
  admission assertion was absent; the sole reported error remained the caught
  `CancellationError()` at the same coordinator location.
- **native-v4 / native-v5:** each returned terminal one with **one failed case**,
  zero passes/skips, in **4.569 / 4.637 seconds**. Both logs again reported only
  the caught cancellation. Bounded phase diagnostics were added without changing
  the original assertions; v5 also retained selected threshold numbers.
- **native-v6:** terminal one, **one actual failed case**, zero passes/skips,
  **670.805 seconds**. Normal initial admission and actual provider-exact rollover
  were observed, but successor bootstrap did not complete. The test log again
  reported the caught coordinator cancellation; its attribution remains unknown.

The exact selected case was
`LiveLMStudioManagedAutonomyTests/testRealProviderAutomaticThresholdCrashRecoveryPreservesRunningInstalledGUIAndMCPRegistration`.
All five executed attempts retained the **14 original protected processes** and
the original MCP registration, with no owned process left. Their preservation
receipts record only the baseline phase completed, not the full three-phase
threshold/recovery flow. The native-v3
runner receipt and full 2,012-byte `swift-test.log` retain its failed result.
The cancellation's runtime origin remains **unknown**; its reported coordinator
location does not establish a policy, provider or lifecycle root cause. No
product/lifecycle patch or suppressed assertion is claimed.

The v5 `managed-threshold.interrupted-phase.json` establishes a separate fixture
mistake: at `threshold_observation_contract`, action was `rollover`, source
`serialized_estimate`, trigger `before_provider_turn`, capacity **262,144**, used
**5,970** and fixed reserve **20,480**. The admitted total was **26,450**, already
above the fixture's old **10,240** rollover cutoff. Remaining capacity was
**235,694**, below the stored rollover threshold **251,904**; the checkpoint
threshold was **253,952**, emergency threshold **13,107**, and projected next
turn **5,971**. `ContextBudgetSupervisor` compares remaining capacity to those
thresholds, so this requested rollover before any provider turn and could not
satisfy the fixture's required `providerExact` / `afterProviderTurn` control.
The receipt says the test task was not cancelled; this does not explain how
XCTest reported the separately caught coordinator sleep cancellation.

The opt-in coexisting-GUI fixture now uses admitted checkpoint/rollover totals
**27,648 / 28,672**, both above the observed 26,450. It adds initial `normal` and
checkpoint-headroom assertions. The optional phase diagnostic defaults to nil,
retains only bounded stage/numeric fields and rejects encoded data above **8 KiB**.
Original actual-usage, ACK identity, crash/recovery, continuation marker, successor
tool, 14-process GUI/MCP preservation assertions remain; recovery/replay use the
default production policy. Installed settings/model capacity are unchanged.
`candidate-probes/live-managed-v5-input-review.json` and
`live-managed-v6-input-review.json` retain the fixture/input/runner boundaries;
the v6 runner changed only the fresh output directory.

The actual v6 phase receipt records initial `serialized_estimate` /
`before_provider_turn` action **normal**, then `provider_exact` /
`after_provider_turn` action **rollover**, used **10,093**, remaining **231,571**,
fixed reserve **20,480**, capacity **262,144**. The completed initial turn's
retained numeric usage was input **9,582**, output **511**, total **10,093**;
that is not bootstrap usage. The successor ledger retained **one attempt**,
`blocked_failure` / `response_truncated`, with no receipt, and the run became
`failed_recoverable` / `lmstudio_response_truncated`. No successor ACK, intended
bootstrap crash, recovery or full pass was obtained. The incomplete response's
reason/usage was not retained; the classification does **not** prove exhaustion
of the fixture's 512-token limit. The selected numeric state, read-only bootstrap
review, final phase/preservation receipts and failed test log remain under
`native-v6/`. All **14 original process identities** and the MCP registration
were preserved; no owned process survived. The terminal test failure is separate
from the partially exercised admission/rollover path.

The v7 test-only fixture selects provider output cap **4096** through
a parameter whose legacy/default value remains **512**. A settled unexpected
quiescent failure now reaches the existing bounded failure diagnostic and strict
injected-crash assertions instead of waiting through the full deadline; this
does not accept that failure as success. A count assertion verifies that the
32-observation page contains the complete initial-observation history. Original
usage/ACK/crash/recovery/marker/preservation controls remain.

At **03:44:42 UTC**, the normal full `LiveLMStudioManagedAutonomyTests` class
compiled and returned terminal zero with the seven live variables unset:
**five selected cases, three actual passes, two explicit disabled live skips,
zero failures**, **0.323 seconds**. This is source-only evidence, not a live
provider pass. `candidate-probes/live-managed-v7-input-review.json` records the
439-input freeze, with production and the other **438 full-v4 inputs unchanged**
and only the live test file changed. The v7 runner changes only its fresh output
directory. The separate **live v7** then returned terminal zero at
**03:53:14.371 UTC**: **one actual case passed**, zero skips/failures,
**487.293 seconds** (runner **489.574 seconds**). Its retained
`native-v7/managed-threshold.json` is **8,931 bytes**, SHA256
`5dfaabb8a2496aff12b128bd1c0878f729896deefc5c945286976a69ac1acc0f`;
the phase, failure diagnostic, preservation and final runner/test receipts
corroborate the result.

The normal initial estimate was followed by actual `provider_exact` /
`after_provider_turn` rollover at capacity **262,144**: initial-turn input
**9,580**, output **1,970**, total **11,550**. The real provider bootstrap response
accepted the exact **V2** project/generation/run/operation/handoff/digest ACK.
Handoff `b6bcb025-7cf5-4fc9-865e-c3d0531e7aa2`, digest
`ff9df8c2879bba867a74d95009c43d9c14ba3a11610d59637e3a37f97719ea6b`,
and operation `3361212f-494f-b2af-37c0-e33acd3c9c60` match throughout the receipt.
The injected interruption was an **in-process post-commit error** at
`providerBootstrapResponse`. Recovery accepted exactly one active successor,
sealed the predecessor and denied predecessor invocation authority. Automatic
continuation completed with the bootstrap response as its predecessor, and
one successor-only `fs_read` returned the marker. Stable paused replay retained
the same operation, successor, receipt, provider turn and tool invocation with
no additional effect.

All initial/recovery/stable-replay Manager instances were hosted in the **same
SwiftPM XCTest process, PID 19076**. This was a real LM Studio **owned managed API
fixture**, not three OS processes, an ordinary GUI chat rollover, deployment or
the compiled native v2 app's execution. The **SIGKILL matrix was not executed**;
the other listed real-provider interruption points remain uncovered. The
4096 output allowance and threshold override applied only to the owned
interrupted predecessor; legacy/default 512 and recovery/replay production
policy remain. Bounded duplicate inference remains possible per retry; no
exactly-once inference claim is made.

The preservation receipt records all three phase calls returned and all **14
original protected process identities** plus the original MCP registration
unchanged; no owned process survived. Earlier v1–v6 failures remain retained:
the cancellation attribution and v6 bootstrap incomplete reason are unknown,
and v7's success does not establish 512-token exhaustion. There is no
product/lifecycle patch or later full source pass claimed for the v7 checkpoint.
Ordinary LM Studio GUI rollover/overlap, LLDB, Compute foreground and simulator
XCTest remain separate unqualified gates.

### Subsequent semantic classifier repair — source and native checkpoints

After live v7, the original plugin source `772061d02705…` executed four semantic
regressions: **four failed cases, 39 assertion failures, zero skips**, terminal
one, **0.683 seconds**. Unrelated configuration/quoted response text was being
matched as overflow/truncation evidence, concealing typed HTTP/retry results or
the explicit incomplete reason. The narrow 24-line source-local repair inspects
valid JSON's `incomplete_details.reason` and `error.code/type/message` failure
fields; plaintext fallback, 64 KiB Data boundary, typed status/retry fallback,
incomplete-response rejection, ACK and signing/trust contracts remain.

The unchanged four regression methods passed against source `9ef24779abf3…`:
**four actual passes, zero skips/failures**, terminal zero, **0.020 seconds**,
at **03:55:34.986 UTC**. Original and repaired terminal output is retained under
`candidate-probes/lmstudio-signal-classifier-semantic-v1/`. Normal validation of
`LMStudioContractFixtureTests` / `NativeSessionHostPluginTests` then returned
terminal zero at **03:56:41.039 UTC**: **52 selected, 51 actual passes, one explicit
live skip, zero failures**, **1.019 seconds**. The transport class passed all
**19** cases; the session class selected **33**, with **32 passes** and one disabled
`testLiveLMStudioFreshRootAcknowledgementAndAutomaticContinuation` skip. The
`normal-two-classes-terminal-v1.json` receipt retains that boundary. It precedes
the full-v5 and native-v3 checks below; the skip is not a live pass.

This is later than live v7 and the retained native v2 artifacts. Relative to the
full-v4 freeze, **four paths changed, 435 inputs unchanged**: the live test file,
`LMStudioContractFixtureTests.swift`, `LMStudioContractFixtureServer.swift`, and
`ForgeNativeSessionHostPlugin.swift`. The v7 executed freeze retains its separate
one-test/438-unchanged identity. Since v6's failed bootstrap response body was
not retained, the classifier defect cannot be assigned as its cause; output-cap
exhaustion likewise remains unproved. These four source tests alone establish
neither native execution nor full-feature acceptance.

### Later full-v5 failure and descendant fixture correction

The unfiltered full-v5 run returned **terminal one**: **2,191 Core cases selected,
2,177 passed, 13 explicitly skipped and one failed**, plus **30 filesystem
qualification passes without skips**. All 439 inputs remained unchanged; raw
output was lossless. The sole failure was
`testForkTreeExceedingPerJobDescendantBudgetIsTerminated`: its shell PID file
contained two entries, failing the `>2` assertion at line 391. State/error and
listed-PID cleanup assertions did not fail. The unchanged focused retry passed
one case in **0.409 seconds**. These observations retain no kernel/file witness
from the original failing interleaving and establish no production regression.
`full-source-classifier-v5/root-failed-full-and-focused-observation-v1.json`
retains the failed gate and separately observed retry.

The additive controlled-gap test subsequently passed one actual case in
**0.543 seconds**, without skips/failures. Its first-SIGTERM witness verified
**three exact kernel child identities with two shell PID entries**, while
forwarding the real Darwin controller and checking cleanup of both sets. This
proves that controlled fork-to-record gap, not the unrecovered original timing.
Only the original test fixture was corrected: count unique identity-validated
children before SIGTERM, preserve the limit-two threshold, state/error, unchanged
eight-sleep script and every final shell-PID cleanup assertion, add exact-identity
cleanup and close on error. No production process control, limits or graph changed.
The corrected focused case passed in **0.500 seconds**. Normal
`RuntimeExecutionJobTests` returned **terminal zero: 113 selected, 112 passed,
one explicit unavailable-PowerShell skip, zero failures**, **46.539 seconds**;
the controlled and corrected cases passed in **0.408/0.382 seconds**.
`descendant-budget-shell-witness-source-review-v1/root-focused-and-normal-observations-v1.json`
retains actual parent tool-result observations; no raw log was reconstructed.

The full-v6 439-input freeze had **five changed full-v4 paths, 434 unchanged**:
the four semantic/live-fixture paths above plus `RuntimeExecutionJobTests.swift`.
On October 6, the unfiltered **full-v6 run returned terminal zero**: **2,192 Core
cases selected, 2,179 passed, 13 explicitly skipped, zero failed**, plus **30
filesystem qualification cases passed without skips/failures**. All **439 frozen
inputs matched before/after**; the capture retained complete EOF with no signals,
parser failures or owned survivors. The run elapsed **699.618 seconds**.
`full-source-classifier-v6/capture-receipt.json` has SHA-256
`7400d8d9cd522bd6feaac8dcb8adc33473d5fc6e5252e0da27c3f3ff5b7f5cee`;
`root-terminal-and-case-verification-v1.json` independently matches all **2,222**
case start/end lines and the **2,209 passes / 13 skips / zero failures**. The failed
v5 receipt remains intact. Skips are unqualified capabilities; this is a source
checkpoint, not ordinary GUI, SIGKILL, debugger, simulator or shipment acceptance.

### Canonical native v3 and four classifier XCTests

Canonical Debug/Release v3 builds returned **terminal zero** in
**60.309/153.358 seconds**, with **all 439 inputs unchanged**. Each configuration
passed all five roles' strict signature/metadata/entitlement controls (**15 native
controls each**) and effective scheme/all-target settings checks; the existing
signing settings were preserved. Release recorded **one owned post-build SIGINT**,
so its cleanup is not described as unforced. The independent audit receipts are
`debug-v3-independent-audit-v1/receipt.json` (`2ac3757d450c…`) and
`release-v3-independent-audit-v1/receipt.json` (`2c1ab9ac6b45…`).

The signed v3 Debug CLI admitted a native Xcode job that compiled and ran
**four classifier XCTests: four passed, zero skips/failures**, **0.028 seconds**.
The native job and serve process both exited **zero**. Output was lossless:
**706,826 stdout bytes and 1,280 stderr bytes**, with EOF and matching retained/
reconstructed hashes. `native-classifier-xctest-v3/probe-summary.json` and
`root-source-equality-before-fixture-addition-v1.json` retain this scope. Its
Test-DerivedData is separate from the application build. Subsequent typed
`xcode.result` summary/inventory jobs both exited **zero**, with lossless stdout
of **713/2,689 bytes**, empty stderr and clean serve exit. Readback verified
**exactly the same four named cases, all Passed**, with no extra cases, failures,
skips or expected failures. The reconnect retained the owned home/context/
deployment and configuration bytes. The receipt is
`candidate-probes/native-classifier-xctest-v3-result-reader-prepared/reader-native-v1/read/root-exact-inventory-verification-v1.json`,
SHA-256 `f34d6130a923687cdf2ef53d1e885fecf58bf633dcd3f166b9839e7dafc4d724`.
These v3 builds/cases predate the later Runtime/Queue test fixtures and Rune
reorder repair. Retained native v2 artifacts and the preceding live v7 proof keep
their own identities.

Ordinary LM Studio GUI rollover/overlap, SIGKILL recovery, Compute foreground,
LLDB, simulator XCTest and owner-signing gates remain open. The later direct
simulator startup control reproduced the same migration wait outside Forge and
timed out before XCTest, as recorded below; its underlying cause remains unknown.

### October 6 Queue actor ownership and Rune reorder checkpoint

Typed `xcode.result` build-results inspection of the successful four-classifier
native job exposed **five AppKit actor-isolation warnings** in the synchronous
mixed-format Queue test (`NSTextView` frame/string/PDF/bounds access). The narrow
repair adds only `@MainActor` to that existing test; its assertions and production
behavior remain unchanged. The focused case passed in **0.304 seconds**, and the
normal Queue class passed **38 cases without skips/failures** in **1.676 seconds**.
Fresh isolated native `xcode.run` job
`6bce9511-aec2-4431-8e44-48d3f60676f2` compiled and executed exactly that case:
**one pass, zero skips/failures, 0.321 seconds**, native job and serve exits **zero**.
`candidate-probes/native-appkit-actor-xctest-v1/probe-summary.json` retains lossless
EOF for **702,639 stdout / 1,279 stderr bytes**. This scoped test proof does not
qualify the full native application or its foreground GUI gates.
Subsequent typed `xcode.result` **build_results**, **test_summary** and **tests**
readback returned native exit **zero** from all three jobs, complete EOF/hash
reconstruction (**446/712/1,204 stdout bytes**, empty stderr) and serve exit
**zero**. Summary and exact inventory both confirm the sole mixed-format Queue
case **Passed**, **one total**, **zero failures/skips/expected failures**, with
configuration bytes unchanged. The receipt is
`candidate-probes/native-appkit-actor-xctest-v1-result-reader-prepared/reader-native-v1/read/receipt.json`,
SHA-256 `d1c22785199ca2405bcc05d34f593bce3132c97f2ac433fd9deccad9778021b5`.
This qualifies the exact case and result-reader boundary; no general warning-free
application, simulator or foreground GUI claim follows.

The Rune baseline used the real client protocol with at most two controlled
requests: the newer reorder completed first, then the older request returned
success, cancellation or ordinary error. **Three cases failed four assertions**.
A command UUID now owns publication at all three completion paths, preserving
the newer order and notice. Two positive controls preserve current-request
cancellation/failure rollback. **Five focused cases passed**, then the normal
Rune class passed **15 actual cases without skips/failures**, **0.854 seconds**,
terminal zero (parent session `88252`, tool chunk `757dd9`, 05:15:29 UTC).
The repair changes no public protocol, policy ordering format, detector or history.
`candidate-probes/docs-queue-actor-rune-reorder-checkpoint-v1/root-observed-checkpoint-v1.json`
records these actual parent tool-result observations separately from the retained
native files; it does not reconstruct a missing raw source-test log. Full v6 and
native v3 retain their earlier identities. The refreshed native v4 builds below
cover these later inputs; full Swift v7 and corrected native Rune v5 completed
as recorded below. No live GUI overlap is inferred from the fixtures.
The two test-only Continuity hygiene cleanups removed an unreachable fixture
branch and stale preparation comments. Its focused case passed in 0.444 seconds;
the normal class returned terminal zero with 138 cases and zero failures in
46.916 seconds. The middle tool output was truncated, so no new per-case inventory
is claimed from it; the later full v7 retains the complete source-case inventory.

### Refreshed canonical native v4 — platform identity scope

Canonical Debug/Release v4 builds returned **terminal zero** in
**60.369906/158.787937 seconds**, with **all 439 inputs unchanged** during both
runs. Both raw build streams reached complete EOF without truncation or output
bound failure: **512,935 Debug bytes / 538,530 Release bytes**. Debug required
**no cleanup signals**. Release required **two exact owned post-build SIGINT
signals**; both runs retained **no owned survivors**, with no signing or
compilation overrides. The build receipts and raw logs are under
`candidate-probes/canonical-native-closeout-v4/debug-build-capture/` and
`release-build-capture/`.

All five roles in both configurations passed strict platform signature,
metadata, entitlements and effective scheme/all-target settings controls. The
independent retained-evidence audit passed **579/579 checks**; its ten exact
binary hashes and four built Info.plist hashes match the captured identities.
Debug retains automatic Apple Development signing. Release retains manual
Developer ID signing, no `get-task-allow`, no `DEBUG` or
`FORGE_DEVELOPMENT_SIGNING`, disabled testability and disabled base-entitlement
injection. The audit receipt is
`candidate-probes/canonical-native-closeout-v4-independent-audit-v1/receipt.json`,
SHA-256 `2839225b43ba278d613aee6011461e792667a2a109aab239f7935d535439c90d`.
The audit ran no fresh native commands; it independently verified the retained
native captures. This is platform identity/settings proof, not compiled runtime
peer execution, installed behavior, notarization or shipment acceptance.

The signed v4 Debug CLI's initial Rune fence job used the `ForgeConductor`
scheme and five `ForgeConductorTests/RuneForgeAppTests/…` selectors. The canonical
project places `RuneForgeAppTests.swift` in **ForgeConductorAppTests**, whose
existing app-hosted scheme selects that bundle. The raw v4 output contains
**two `Executed 0 tests` lines** and **`TEST SUCCEEDED`**. Native and serve exits
were zero, but **no selected XCTest executed**. The helper's success flags record
transport/native completion only; **v4 is a non-pass for Rune test acceptance**.
`candidate-probes/native-rune-fence-xctest-v4/probe-summary.json`,
`stdio-transcript.json` and `native-stdout.bin` retain this attempt. The corrected
app-hosted v5 selection and full Swift v7 completed below. The five focused and
15 normal source Rune passes retain their source-test scope.

### Completed full Swift v7 and corrected native Rune v5

The unfiltered direct **full Swift v7** returned **terminal zero** in
**706.243774 seconds**. Core selected **2,197 cases: 2,184 passed, 13 explicitly
skipped, zero failed**; filesystem qualification passed **all 30 cases**, with
zero skips/failures. The independent raw-case audit reconciled **2,227 unique
actual start/terminal pairs: 2,214 passed, 13 skipped, zero failed**. The two
zero-test Swift Testing runs were excluded from that actual XCTest count.
The complete **667,794-byte** raw stream reached EOF without truncation,
SHA-256 `7ec16d7829aad6c5240dbd1f4d0b83e85f139cb6da26a33063b60f8ec65d771e`.
All **439 inputs remained unchanged** before/after; cleanup recorded no signals,
errors, survivors or ambiguous process identities. The receipt is
`candidate-probes/full-source-classifier-v7/capture-receipt.json`, SHA-256
`fad60eeee971f2134b08becc0a73459980af7fbc270943448583d08eb10f8a88`.
The independent audit is
`candidate-probes/full-source-classifier-v7/root-offline-case-input-cleanup-audit-v1.json`,
SHA-256 `91b9b4893fe2d92274cb2669e3026197b98d323f36e0c83b1cc26026a9979ae9`.
This completes the normal source suite for these inputs; the **13 skips remain
unqualified capabilities**, and earlier failed runs remain retained.

The signed v4 Debug CLI's corrected **native Rune v5** job used the existing
**ForgeConductorAppTests** scheme and five selectors in that app-hosted bundle,
without source or graph edits. It executed exactly the three older-late
success/cancellation/failure cases and two current-request rollback controls:
**five actual passes, zero skips/failures**, **0.246 (0.248) seconds**. The native
job and serve process both exited **zero**. **581,183 stdout / 590 stderr bytes**
were reconstructed losslessly with EOF and matching retained hashes. All five
exact named starts/passes and three matching five-test execution summaries were
independently verified; all 439 pinned inputs were unchanged. The inventory
receipt is
`candidate-probes/native-rune-fence-xctest-v5/native-case-inventory-review.json`,
SHA-256 `d0141f35e9a3c773ec7ba3143f4ba7f894c5b54ea16ff5b7790c8e535d1b9162`.
Rune v4 remains a **zero-test non-pass**; the corrected v5 proves these five
native controls. These source and scoped native results establish no ordinary
GUI rollover, SIGKILL recovery, installed, full-runtime or shipment acceptance.

The first bounded managed-bootstrap **SIGKILL attempt stopped at preparation**:
its guard still expected the historical 14 process identities, while the fresh
read-only baseline contained **13**. **No candidate Manager launched**, and no
SIGKILL phase proof was produced. The retained read-only audit is
`candidate-probes/managed-bootstrap-sigkill-observable-v1/root-current-baseline-after-preparation-failure-v1.json`,
SHA-256 `99720e7be7d85f4fed16c3a497706ccff8594675fba59f2cab79a47a386aaca5`.
The cause of the historical helper absences remains unknown. This failed
preparation is not a recovery result; the **SIGKILL gate remains pending**.

### October 5 atomic rollover and result-budget source checkpoint

`atomic-budget-native-ack-focused-v1.log` executed **19 tests**, with zero skips
and failures, and returned terminal zero. The normal affected-class run,
`atomic-budget-native-ack-affected-classes-v2.log`, selected **505 cases**:
**499 passed**, **six were explicitly skipped**, and **zero failed**; terminal
exit was zero. `atomic-budget-native-ack-verification-v1.json` validates the
actual test starts and final totals. The affected-class breakdown is:

| Source test class | Selected | Explicit skips |
| --- | ---: | ---: |
| Continuity | 135 | 0 |
| Manager | 149 | 2 |
| Runtime execution jobs | 112 | 1 |
| Xcode CLI integration | 28 | 0 |
| Native session host | 30 | 1 |
| Stjornarvald integration | 23 | 0 |
| Policy notices | 9 | 0 |
| Tool catalog | 14 | 0 |
| Live managed autonomy | 5 | 2 |

The skipped real managed threshold/recovery cases, live fresh-root adapter and
provider-probe cases, external-process helper and unavailable PowerShell case
remain unqualified by this run. Full feature acceptance remains open.

The verified changes preserve these contracts:

- An eligible rollover request remains sticky while a live checkpoint claim is
  prepared. The original claim is unchanged. The transaction consumes the
  request and commits the actual handoff packet, successful/failed counts,
  progress pointers and hard block together. Rollback retains the request for
  restart recovery. Authored task content/custom seed and preparation/epoch
  fences remain intact. A projection-file failure reports a warning while
  returning the committed SQL handoff and actual outcome.
- The native adapter checks the content digest before acknowledgement reuse.
  Changed content under the same acknowledged ID is refused before reuse/sealing;
  unchanged retries and a fresh handoff ID retain their positive controls.
- Xcode receipt ceilings include the full canonical durable-result wrapper,
  states, exit values, replay flags and escaped paths before job admission.
  Native exit 65 remains a failed job; exact same-intent replay remains available.
- `job.list` returns complete rows within the same wrapped byte budget and an
  optional `next_cursor` with paired `before_created_at` and `before_job_id`
  arguments. The timestamp/UUID order preserves every equal-timestamp row;
  legacy timestamp-only cursors keep their exclusive semantics. Existing
  byte-paged `job.read_output`, exact offsets and base64 byte recovery retain
  their prior proof and contracts.

This is a **source checkpoint**. The earlier 2,135-case full Swift run below
belongs to its dated input snapshot. The subsequent adapter protocol checkpoint
below resolves the reproduced bootstrap races in source fixtures; the later
dated full source and scoped retained native v2 checkpoints are recorded above.
Guidance verification and the full v4 source regression completed as recorded
above; those results do not establish the remaining live workflow gates.
Ordinary GUI rollover and threshold acceptance, and LLDB execution remain open.
Documentation-only updates preserve the canonical graph; the tested graph
receipt `graph-audit/membership-atomic-budget-native-ack-v1.json` records 413
inputs, five additive memberships and no removed/missing/unexpected inputs.

The retained native policy **v4 is unqualified**: first-project alignment,
Python 0.99 notice/job completion, same-ID resource-only JS 0.45 review/history
and genuine 0.98 correction completed, but the second-project initialization
failed with `project_scope_mismatch` after reusing the first client's durable
context. Manager and serve both exited zero. The failed receipt remains at
`stjornarvald-assessment/native-candidate-v4/summary.json`.

The revised **native v5 passed** against the current signed Debug CLI/Core
identities. Its second project used a distinct deployment/stdio client, after
the first serve process completed EOF/reap.
`stjornarvald-assessment/native-candidate-v5/summary.json` records
`qualified: true`, both control groups complete and **Manager, serve A and
serve B exit zero**. The fixture exercised Swift alignment without a violation,
Python resource membership opening a 0.99 violation and actual ordinary MCP
notice, then a resource-only JS 0.45 review on the same violation with original
history unchanged. It retained the notice quiet interval and corrected the same
violation only after genuine removal from complete declared membership. A
fresh renamed resource-only JS declaration produced a 0.45 still-violation;
a source/resource alias retained the conservative 0.99 finding, followed by a
genuine 0.98 removal correction. The ordinary native job completed with exit
zero.

This is signed native **declared source/resource/copy membership**, durable
policy history and serialized MCP notice proof in owned fixtures. It is not
fixture binary inspection, browser-resource policy applicability, GUI control
proof, model comprehension or evaluation of the other fourteen rules. The
separate model-notice v5 API probe returned terminal one, `qualified: false`,
with `timed out` after 26.194 seconds and no completed response. Its retained
`stjornarvald-assessment/model-notice-v5/summary.json` is a failed model-probe
receipt, separate from the successful native fixture. The timeout cause is not
established and does not diagnose a Forge or model defect. That failed v5
receipt is retained separately from the successful v6 control.

The bounded **model-notice v6 passed**: terminal zero, `qualified: true`, a
completed Responses result after **26.944 seconds** and an exact match to the
authentic native-v5 retained notice. The forwarded notice hash matches the
retained native notice hash. Actual loaded Qwen context was **262144** before
and after. The interpretation retained confidence **0.45**, `requires_review:
true`, `compliance_proven: false`, `execution_blocked: false` and
`correction_verified: false`, plus the exact review action, source revision
and violation ID. `stjornarvald-assessment/model-notice-v6/summary.json` records
the completed response and provider usage. This proves **one historical notice
interpretation**, not future model comprehension, a still-open fixture after
its separate correction, verified correction, full policy compliance, GUI
rollover or an exemption. No existing GUI chat, registration or Forge tool/ACK
was used.

The request specified `parallel_tool_calls: false` and `max_tool_calls: 1`, but
the completed provider response echoed `parallel_tool_calls: true` and
`max_tool_calls: null`. Exactly **one** interpretation function output was
observed; enforcement of the requested parallel/tool-call limits is **not
proven**. The two inventory reads returned HTTP 200 with identical byte counts
and hashes, and the receipt retains selected decoded loaded-model/context
fields. Their raw inventory response bodies were not retained, so the complete
inventory cannot be independently replayed from this receipt. These limits do
not broaden the single historical interpretation claim.

### Retained pre-seal v9 native compatibility — owned fixture

`candidate-probes/retained-v9-column-compatibility-v3/summary.json` records
terminal zero, `qualified: true`, strict old/new signature checks zero and
**three native CLI serve exits zero**: new-create, retained-old-edit and
new-reopen. Exact startup owner/packet/progress state and native readback were
checked across captured windows, allowing only generated pointer timestamps
within the actual startup bounds. Signed artifact identities, migration
lineage, database inode and unrelated owner memory remained preserved. The
retained writer edited the same packet ID: write sequence advanced **2→3**,
while historical seal **2** remained and the current helper read the edited
payload/owned note without replacing the packet.

The seal marker was set only in the stopped owned fixture. It is **synthetic
compatibility data**, not a successor acknowledgement or model-driven sealing.
This qualifies the actual retained schema-v9/native round trip; it does not
qualify v8/live recovery, installation, Manager rollover, GUI or release.
The earlier v1 `KeyError: id` and v2 pre-existing-row assertion failures remain
unqualified in their retained summaries; they are not silently relabeled as
passes. No GUI, installed-build or shipment qualification is claimed.

### Subsequent native-adapter protocol concurrency checkpoint

`native-ack-concurrency-cancel-original-v1.log` selected four actual protocol
cases and returned terminal one with ten assertion failures. The two V1
regressions demonstrated an ACK for revision A persisting revision B's digest,
and a late matching ACK reviving an explicitly cancelled operation. The two
unchanged V2 cancellation-order controls passed.

`native-ack-concurrency-cancel-repaired-v2.log` subsequently selected **34
cases**, with **33 actual passes**, **one explicit live-provider skip** and
**zero failures**, returning terminal zero. This consists of 33 native-plugin
cases, including the skip, and one Manager ACK-revision case. The skipped live
fresh-root model case provides no runtime proof in this run.

The V1 adapter now owns a bounded per-instance set of active bootstrap sessions
(at most `maximumRecords`), released on every exit. It rejects a duplicate
same-session bootstrap before replacing durable intent. After the transport
await, it reacquires the current row and checks operation/project/provider/
predecessor ownership, status, exact handoff ID/digest and cancellation before
persisting acknowledgement. The cold interruption/restart positive retries
the same session, handoff and digest through `LocalLogicalSessionTransport`;
durable `bootstrapping` status alone does not block recovery. Existing V2
contracts and the ledger/schema/public fields are unchanged. V1 cancellation
after an already committed acknowledgement retains its prior behavior.

These executable protocol fixtures are **E0 adapter evidence**. Reachability
of the same overlap in an actual LM Studio GUI flow remains **E2**; ordinary
GUI rollover is still unverified. This later checkpoint does not change the
earlier 505-case totals or qualify signed-native, model, installed-build or
shipment gates. The later full source checkpoint is recorded above.

The original canonical Debug app build passed with strict deep signing at
0.17.0 (27), before edits. Attempts one, two, four and five failed during test
compilation and ran no cases; their missing fixture arguments were corrected.
Attempt three ran 54 Core cases, with four fixture failures. Attempt six ran
161 cases with four assertion failures in three cases. Attempt seven failed
during compilation and ran no cases. Attempt eight ran 169 cases with two
assertion failures; its graph preflight and catalog parity corrections passed
in attempt nine. Attempt nine expanded selection to the complete continuity
class: 245 Core cases and 7 qualification-isolation cases executed, with 40
assertion failures across two empty-output polling cases and one bootstrap
deadline case. The empty-output cases had assumed an unsupported live-tail
contract; corrected tests preserve actual unavailable-output errors and verify
their repetition and total-budget behavior. The bootstrap case exposed an
ancillary continuity lookup regression; only an invalid binding-owner error is
excluded from that lookup, preserving strict required-tool admission and the
existing committed-result test. No pass is claimed for attempt nine. All 25 Xcode integration cases,
10 telemetry cases, 10 catalog cases, 13 policy integration cases and 9 notice
cases passed. The scoped/legacy handoff fairness, stale desktop authority and
runtime-tool availability cases also passed.

Attempt ten executed **253 cases** (246 Core and 7 qualification isolation),
with **zero failures and zero skips**, and returned terminal exit zero. This
includes the complete 105-case continuity class, the unchanged bootstrap fault
test, 25 Xcode cases, 10 catalog cases, 10 telemetry cases, 13 policy integration
cases and 9 policy notice cases. Canonical graph audit passed: five additive
file memberships, no removed memberships, unchanged workspace/schemes and
signing/deployment/embedding settings. The five agent instruction resources
change intentionally; all existing resources remain members.

Attempt eleven returned terminal exit zero with **27 policy cases** (18
integration and 9 notice), zero failures and zero skips. Five added regressions
exercise repeated/shared graph traversal budgets, malformed mandatory graph
arrays, and preservation of a known finding during incomplete observations.
The producer now counts visits before deduplication and stops the enclosing
traversal when its work or time budget expires. Missing or wrongly typed
mandatory graph arrays produce incomplete evidence rather than an apparently
complete empty target.

The explicit Swift CLI and app product builds returned exit zero. The refreshed
ordinary canonical Debug candidate build, `ordinary-candidate-current-build.log`,
returned exit zero with all production changes. Strict deep signing passed;
`ordinary-candidate/artifact-identity-current.json` records six binary hashes.
The main executable SHA-256 is `ef46462a17388dadc82dfa6198a23cfb8f370c2e2d7bf30aea8069473209fa6b`.
The earlier signed native MCP Xcode-version job completed with exit zero and
complete output, under its separately retained earlier identity.

The first full Swift regression returned exit one: **2,113 cases**, **13 explicit
environment/fixture skips**, and **one failure**. The 111 continuity and 14 catalog
cases passed. The sole failure was the unchanged protected-service source test's
obsolete `Section` locator; history `08bb81f` and the synchronized baseline both
show that the view had already changed to named content properties. Only the two
locators changed; every security, ordering and operation-gate assertion remains.
The affected 29-case class rerun returned exit zero with zero failures and two
explicit native-candidate setup skips. Skipped capabilities are not qualified by
that run. The initial full-suite failure remains recorded.

The later complete `swift test` returned terminal exit zero in
`swift-full-regression-final.log`: Core selected **2,135 cases**, with **seven
explicit skips** and **zero failures**, in 770 seconds; the separate filesystem
qualification target executed **30 cases**, zero failures/skips. The real API
fresh-root adapter case executed during this run. Skips cover two opt-in native
autonomy fixtures, the real managed automatic context-threshold case, two
parent-only helper cases, disposable Keychain qualification and unavailable
PowerShell. No skipped capability is qualified. The source checkpoint manifest
`graph-audit/membership-full-swift-pass-v1.json` has SHA-256
`13fbe1d8bc32c35910844fe3b6bd51fccdbc1e97dcd8f84036d8d29520fcd966`:
413 canonical inputs, five additive memberships, zero removed/unresolved inputs,
unchanged workspace/schemes and no unintended signing/build changes. Repository
hygiene and `git diff --check` passed. These results apply to that input snapshot;
later fixes require affected verification. Additional source-review risks in
raw job receipt ownership and continuity dispatch/history remain under
investigation, not qualified repairs.

Six focused `ProductPathReliabilityTests` cases passed with zero failures and
zero skips (`product-path-native-guard-focused.log`): four exercise native
artifact metadata boundaries and two parse exact signing requirements through
Security. The private fixture contract now requires canonical Debug Apple
Development and Release Developer ID certificate classes separately for all
five roles. The archived version-command dependency is replaced by a private
native helper; version drift still identifies the exact component path. A true
current canonical Release fixture had not yet been built at that checkpoint,
so those six source checks did not qualify the complete signed Debug/Release or
older-peer fixtures.

The later canonical Debug and Release candidate builds both returned terminal
exit zero. `canonical-release-candidate-v1.log` and
`candidate-probes/native-product-identity-v1/release-native-identity-v1.json`
record Release 0.18.0 (28) with strict Developer ID Application verification for
all five roles, including the certificate's `1.2.840.113635.100.6.1.13` marker.
Resolved target settings retain manual signing, hardened runtime, no `DEBUG`
condition, `ENABLE_TESTABILITY=NO` and
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`. The complete
`ProductPathReliabilityTests` class subsequently executed **35 tests**, with
zero failures and zero skips, using the fresh Debug/Release and older-peer
fixtures (`product-path-native-fixtures-final.log`). This is candidate identity
and compatibility evidence; installation and distribution remain separate.

The Release helper also executed an owned `xcode.discover` version request over
ordinary native stdio. Its durable Xcode job ended completed with exit zero,
complete untruncated output and normal serve exit zero
(`candidate-probes/release-native-version-v1/summary.json`). The helper SHA-256
is `f94dfa379ab6408db3c623bce44019cec47989efd0ede8cb402da5befe780f3d`.
This exercises the Release peer policy and that tool flow; it does not qualify
the Release GUI, debugger execution or every tool.

The first full native app-hosted test attempt was interrupted with exit 75
after an activation failure stalled asynchronous XCTest teardown. It is not a
pass. The test fixture now throws on the same failed activation predicate,
preserving its deadline and rendering assertions. An isolated native settings
test completed with exit 65 and exposed a production binding defect: semantic
accessibility actions could decrement 1 to 0 or increment 10,000 to 10,001.
The production binding now clamps through the existing configured range. The
unchanged regression rerun returned terminal exit zero: one actual native case,
zero failures and zero skips, including text entry, both stepper actions and
range saturation (`native-settings-controls-fixed.xcresult`).

An actual isolated-home GUI flow edited 200 to 1,234, saved it, staged 777, and
reloaded 1,234. The value survived both GUI and Manager restarts; disk and API
captures agreed at each boundary. Rune Forge displayed the exact 1-of-15 coverage
description beside zero violations. With its own Manager stopped, it displayed
the connection failure and unavailable evaluation coverage. CUA observations and
all zero-exit owned process receipts are retained under
`candidate-probes/gui-settings-v1`.

The signed native stdio continuity-role probe passed (`continuity-roles-current`):
primary and fallback accumulated one durable scope across helper restarts; CLU
retained its restricted grant. Both metadata views reported threshold three.
Failed eligible work counted, wrong handoff/nonce acknowledgements could not
clear the block, exact acknowledgements advanced the epoch, and replay could not
clear later work. Historical packet bytes were preserved. Six serve processes
exited zero. This is wire/persistence proof, not GUI-hosted successor or sealing
proof.

A separate owned blank-chat control selected only the primary Forge integration,
pressed LM Studio's **New chat**, and observed the successor inherit that same
selection. Both owned chats had zero messages at capture; no messages were sent.
`candidate-probes/owned-chat-inheritance-v1.json` records this selective
inheritance. The original `mcp.json` SHA-256 remained
`58b4185f82a426232115abba77e44499f55e64e10bf3383cd2ee09e8a2552397`.
This proves one per-chat integration transition, not candidate rollover,
handoff consumption, acknowledgement or predecessor sealing.

The first signed native policy probe returned failure because its evidence
assertion required zero findings for an aligned baseline. The inspected adapter
deliberately emits a correction finding for aligned input: the retained native
database has one finding, zero detector faults, zero violations and zero events.
The corrected harness independently verifies pinned detector authority and exact
evaluation receipts, plus scoped absence of violations, events and notices.
The failed v2 probe is retained. **v3 passed** through the signed current native
candidate: ordinary work captured a deliberately declared Python production
resource, opened RFD-NATIVE-001, returned and durably recorded its MCP policy
notice, then corrected the same violation after removing the resource from
declared membership. The ordinary native job remained successful. Manager and
serve both exited zero. This proves that detector and side-channel flow; it does
not prove model comprehension, binary contents or the other fourteen rules.

The same signed candidate's `xcode.run` executed the actual Settings and Rune
native tests through the canonical workspace. Its durable job ended completed
with native exit zero and complete stdout/stderr. `xcode.result` inspected the
returned result bundle: **two passed, zero failed, zero skipped** on My Mac.
The retained command summary records the native sparse-CAS profile and
34,359,738,368-byte limit. Receipts are in `typed-app-tests-current` and
`test-summary-current`; submission alone was not treated as completion.

## Live bootstrap incident

At approximately 22:11 UTC, asking the computer-use tool for an accessibility
snapshot after quitting the candidate relaunched it without the isolated home.
The process was stopped within approximately 15 seconds; the installed app
remains running. The live store's completed migration manifest records **8→9 at
2026-10-05T22:11:06Z**, with migration identity
`c1dd1e3964750d4976e14497460c5e289a7fed1f84c9aa9eaf472560d61fdbac` and
pre-migration backup SHA-256
`fa94d68909965a3aa18a2af625a8d0e2cc192a35244923ee6d95abf69662588d`.
This was a live durable mutation. The actual installed 0.17 helper rejected a
schema-9 owned copy, then completed MCP initialization and owned memory read/write
on the same lineage with only its version marker restored to 8. The guarded live
repair subsequently committed that single metadata row under the native migration
lock and `BEGIN IMMEDIATE`; every non-version table hash matched inside the write
transaction, the inode remained 873317, and both manifests and the immutable backup
remained byte-identical. An independent read-only check found schema 8, empty new
progress, no scoped handoffs, `quick_check=ok`, the original migration receipt, and
all nine original installed processes alive. Evidence is retained under
`unexpected-live-bootstrap/live-recovery-applied-v1` and
`runtime-health-20261005T221904Z/independent-post-recovery-20261005T223525Z.json`.
No historical database restore or process restart occurred. Pre-incident derived
projection-file bytes were not captured, so those files are not claimed unchanged.
Later Quit inspections use app inventory, avoiding the terminated app binding's
relaunch behavior; candidate launches remain explicitly isolated.

The outbox-full reproducer now verifies that graph digest caching occurs only
after confirmed observation persistence and that the same graph retries after
capacity becomes available. Its attempt-eight and attempt-nine executions passed.
The complete app-hosted suite, signed-candidate MCP build/test/debug tools,
live-host qualification remain open. The compatibility incident is recovered;
this does not qualify installation or release.

No current-source all-feature, installed-build, deployment, distribution or
shipment pass is claimed. Earlier UI receipts retain their tested identities.

The native gauge activation regression also passed through `xcode.run` with one
actual case and zero failures/skips, confirmed by `xcode.result`. The separate
compute-chip occlusion case failed again: both the fixture and its opaque cover
reported visible occlusion state. The original assertion is preserved while the
WindowServer ordering/fixture path is investigated. Evidence is retained under
`candidate-probes/native-functional-v1`.

The signed idle-helper comparison completed all three roles with normal serve
shutdown. Baseline helpers measured 30.49%, 28.07% and 25.82% CPU; the current
candidate had no measurable CPU in each 12-second idle window. These bounded
observations do not establish leak freedom or zero CPU for every workload.

At the earlier inventory checkpoint, the native simulator tool returned valid
JSON with 32 available devices across five installed runtime groups; no
simulator had been booted or project run at that checkpoint. Current simulator
**v3** then completed build and boot commands with exit zero, but `bootstatus`
timed out at its **300-second** limit with exit **143** while stdout reported
waiting on Apple AddressBook migration. **No XCTest executed.** The exact owned
device was shut down/deleted with exit zero; all **32 baseline device states
remained unchanged**, the owned device was absent afterward and serve exited
zero. The retained
`candidate-probes/simulator-xctest-fixture-v1/run-native-v3/simulator-v3-terminal-root-verification.json`
records `qualified: false` and lossless output. This does not establish a Forge
product defect or simulator test pass.

The alternate **iOS 26.5 / iPhone 17 Pro v4** control also completed build and
boot commands with exit zero. Its owned `bootstatus` job ran from **03:03:20 to
03:08:20 UTC**, reached the **300-second** limit and ended `timed_out`, exit
**143**, while stdout reported the same `AddressBookLegacy.migrator` wait.
**No XCTest executed.** Exact owned-device shutdown/delete completed exit zero,
all **32 baseline device rows** remained unchanged, the owned device was absent
afterward, all jobs were terminal and serve exited zero. Every captured stream
was reconstructed losslessly with EOF/hash verification.
`candidate-probes/simulator-xctest-fixture-v1/run-native-v4/simulator-v4-terminal-root-verification.json`
records `qualified: false`. Both v3 and v4 failures remain retained. The
underlying Apple migration wait is **unknown**; neither the wait text nor these
owned controls establishes a Forge or host diagnostic cause.

The later **direct native startup control**, outside Forge, returned terminal
**one** after its owned `bootstatus` command reached the **300-second** limit,
exit **-15**, with **64,706 stdout bytes**, complete EOF and no truncation. It
reported the same `AddressBookLegacy.migrator` wait. CPU and file-size limits
were inherited unlimited; the inherited soft file-descriptor limit was
**1,048,575**. Thus Forge launch and its resource limits are **not necessary**
for this observed wait; the exact cause remains unknown. **No XCTest executed.**
Exact owned-device shutdown/delete exited zero, the owned device was absent and
all **32 baseline rows** remained identical. The attempted owned `log help show`
command returned **64**, retaining **2,246 usage bytes** on stderr; no scoped
unified-log `show` query was performed. The receipt is
`candidate-probes/simulator-owned-startup-diagnostic-v1/run-direct-native-v1/capture/receipt.json`,
SHA-256 `14784e5731f375cf95c62ed01518ca709b07e95550be4c556fa4d67b9170b999`.

The subsequent **owned iOS 26.5 / iPhone 17 Pro namespace diagnostic** also
timed out at **300 seconds**, native exit **-15**, with complete untruncated
**64,552-byte** bootstatus output and **no XCTest execution**. Actual owned
namespace snapshots at **60/120/240 seconds** retained datamigrator PID
**40906** and migration-plugin-wrapper PID **41000**. Queries using the locally
documented predicate fields `processIdentifier` and `composedMessage` completed
with native exit **zero** and complete EOF. Their exact-PID bounded results
retained **213** datamigrator AddressBook events (**211** recurring duration
updates), **five** wrapper AddressBook events and **127** default wrapper events.
The wrapper records the owned-device AddressBook database path and an
Allowed/Entitled `kTCCServiceAddressBook` request. That simulator authorization
establishes **no host debugger/SecurityAgent authorization outcome**. Its last
default log reports **two pending XPC transactions**; the owner call/stack and
migration cause remain **unknown**.

The earlier query v1/v2 attempts exceeded their output bound and retained
incomplete JSON, so they remain **non-passes**. The exact-wrapper sample timed
out after **10 seconds**, overlapped owned shutdown/deletion and produced no
sample file; it supplies **no stack or cause proof**. Exact owned shutdown/delete
exited **zero**, the owned device was absent afterward, and **all 32 baseline
device bytes were exact before/after**. The independent retained-evidence
receipt is
`candidate-probes/simulator-owned-namespace-diagnostic-v1/run-direct-native-v1/independent-retained-review-v1/receipt.json`,
SHA-256 `bcd04fb349705b50d582ddde61da29deeeb9a13b9bf9492a2a4a166d342f4c26`.
This narrows the observed migration activity but establishes no migration root
cause, Forge defect, host authorization result or simulator XCTest acceptance.

The subsequent **early owned migration-stack diagnostic** verified fresh same-
owner runtime identities for datamigrator PID 65110 and wrapper PID 65226 before
and after the sample. The native sample began near the first 60-second namespace
snapshot, timed out at **30 seconds**, exited **-15**, and produced no report.
It ended **before** shutdown/delete, removing cleanup overlap from this attempt;
no stack or host authorization cause was established. Startup still reached its
**300-second** deadline, exit **-15**, retaining the AddressBookLegacy wait in
**64,310 stdout bytes**, zero stderr. The controller returned **one** after
304.665 seconds. All **24 native commands** were reaped with complete lossless
streams; the two timeout controls remain failures. Exact owned shutdown/delete
returned zero and preserved all **32 baseline device rows**, with the owned
device absent. **No XCTest ran.** The root raw-byte/hash/terminal audit is
`candidate-probes/simulator-owned-migration-stack-diagnostic-v1/run-direct-native-v1/root-offline-terminal-stream-audit-v1.json`,
SHA-256 `f399c6fedad6ec27b4de9a5a985825fdebcd77e8ac8a93d1362338a9ca288185`.
One further exact historical datamigrator error/fault query completed native
exit zero with complete EOF and returned **zero events** for the bounded window.
The retained post-capture parser error was corrected offline without rerunning
the native query; `root-exact-datamigrator-error-fault-v5/offline-parser-correction-v1.json`
has SHA-256 `2b9b0ac62e609a77daabbea25af0985c8ed1f9e81fb61d395be6fbc89c8f7cb3`.
This adds no cause, stack or XCTest evidence.

The actual LLDB target-run probe reached its breakpoint
setup but timed out at `run`; its owned processes were reaped. Direct host
controls are being exercised before attributing that failure to Forge.

A further actual-router regression exposed a foreign deployment writing the
owner's exact GUI acknowledgement while its runtime budget remained blocked.
The original case failed two assertions. Non-legacy receipt admission now checks
the durable scope and holds the native binding/generation fence while re-reading
the exact persisted packet before writing. The later complete continuity run
executed all 122 cases with zero failures or skips, including stale generation,
replay, cancellation, legacy nonce compatibility and scoped packet reads.
The ordinary Debug workspace build and strict deep signature check passed for
these inputs; an actual model-driven GUI rollover remains unverified.

The separate native-session adapter regression
`native-gui-foreign-receipt-original.log` executed one case and failed two
assertions: a foreign deployment's GUI receipt acknowledged the successor and
left it acknowledged. The unchanged reproducer and five adjacent cases passed
after the repair (`native-gui-scoped-receipt-fixed.log`). The native-host and
provider class run, together with continuity, reported 167 tests with zero
failures and one explicit live-provider skip. That skip is not live-provider
acceptance. Persisted deployment ownership reaches the real GUI receipt reader
and alternate-driver boundary without changing receipt or ledger schemas.

The previously skipped live-provider case was then exercised separately against
the real LM Studio API with `qwen/qwen3.8-27b`: one actual
`NativeSessionHostPluginTests/testLiveLMStudioFreshRootAcknowledgementAndAutomaticContinuation`
case passed in 57.926 seconds, with zero failures or skips
(`live-managed-root-v1.log`). The receipt
`candidate-probes/live-managed-root-v1.json` records a fresh provider response
root, validated exact handoff acknowledgement, a continuation linked to that
bootstrap response, the required `FORGE_CONTINUATION_READY` marker, and
provider-exact usage at a 262,144-token capacity. This Swift test exercised the
managed API adapter and its automatic-continuation input against the provider;
it did not create an ordinary LM Studio GUI chat or prove that chat's automatic
rollover trigger, handoff consumption or predecessor sealing. The ordinary GUI
rollover remains unverified while the pending SecurityAgent handoff is unresolved.

A separate actual-router reader case failed ten assertions: a project-bound
caller could retrieve another project's scoped packet through exact, latest and
list context reads, and through resume status. The unchanged reproducer and
original reconnect tests passed after scoped metadata selection and current
project/root/generation checks. Sole-active-project read recovery preserves
explicit work admission and cannot acknowledge another deployment's epoch.
The original failure remains in `continuity-cross-project-read-original.log`;
the four focused cases and full 122-case run are in
`continuity-read-compatibility-final.log` and
`continuity-native-host-regression-final.log`.

The actual native cover-ordering diagnostic failed before comparing variants:
its XCTest-host window was visible and on the active space, but the application
and window did not become active and key within four seconds. Owned
WindowServer metadata was available. `compute-cover-ordering-native-v1.log`,
the xcresult and exported JSON retain this failure. This does not qualify
occlusion or identify a production renderer defect.

The v2 diagnostic added the native Gauge fixture's presentation sequence
(`activate`, `makeKeyAndOrderFront`, `orderFrontRegardless`) while preserving the
same four-second active/key/exposed predicate. It also failed before any cover
variant: one actual test reported two failures. The exported startup JSON records
activation policy 0 (regular), foreground PID 55952 and owned PID 68716, with the
owned application inactive and its visible window not key. A separate read-only
process and system-bundle metadata inspection identified PID 55952 as
`com.apple.SecurityAgent`. This is a foreground correlation; it does not prove
an authorization denial, dialog contents or the cause of the failed activation.
The owner was asked to inspect and handle any pending authorization dialog;
that handoff remains pending. Evidence is in
`compute-cover-ordering-native-v2.log`, its xcresult and
`compute-cover-ordering-native-v2-attachments/7E5CCCDA-7916-41CF-A714-E1C85AF9CA03.json`.
The separate process/plist receipt and computer-use refusal are retained in
`candidate-probes/debugger-security-agent-foreground-v1.json`; the dialog contents
and authorization result remain unknown.
The earlier active-host full-occlusion failure remains a separate unresolved
case; neither startup failure exercises that predicate.

The current 439-input v3 native ordering test also failed at startup: exactly
one test executed in 4.135 seconds, with two activation assertions, no skips,
native exit 65 and serve exit zero. Its complete streams retained 589,023 stdout
bytes and 832 stderr bytes without truncation or forced shutdown. The exported
startup snapshot records inactive/keyless owned PID 71246, regular activation
policy, foreground PID 55952 and an empty cover-outcomes array; no cover variant
ran. The initial root process lookup incorrectly matched `SecurityAgent.app`.
The corrected lookup confirms PID 55952 runs from `SecurityAgent.bundle`; the
earlier absence claim is invalid, and no host authorization change was proven.
Dialog contents, authorization outcome and activation cause remain unknown.
The failed preflight is preserved with its correction in
`candidate-probes/compute-cover-ordering-current-v3/root-current-source-stream-window-audit-v1.json`
(SHA-256 `36b65cd77d07d30652ece2d51215c11ce39d229d06cb8c6569e7782f935d9df5`).
All 439 inputs, 13 then-existing processes and registration remained unchanged;
the test retains its assertions and remains a non-pass.

Direct LLDB controls reproduced the `run` stall outside Forge. The packet trace
completed the server handshake, then sent `vAttach` for the owned target PID and
logged no reply before the 45-second deadline. A separate control enabling ASLR
also timed out. These observations localize the wait without establishing the
reason for attachment failure. All owned processes were reaped; no debugger
qualification or host security change is claimed.

The direct v3 debugserver control retained a 662-byte log whose last operation is
`about to task_for_pid(61147)`. It reached the 45-second deadline without a
breakpoint stop, target marker or zero target exit; all owned processes were
reaped. Evidence is in
`candidate-probes/lldb-direct-controls/debugserver-log-v3`.
Read-only authorization diagnostics reported developer mode disabled and
recorded the current `system.privilege.taskport` right. Empty scoped logs and
current rights do not prove a denial or establish the cause of that wait;
`authorization-status-v1` and `authorization-status-v2` preserve those limits.

The v4 control repeated the wait with a separately Apple Development-signed
owned fixture that passed strict signature verification. Its debugserver log
again stopped at `task_for_pid`, now for PID 64461; the 45-second control timed
out and reaped all owned processes. Evidence is in
`development-debugserver-log-v4` and `lldb-owned-development-fixture-v1`.
Debugger qualification remains open; neither control changed host security.
