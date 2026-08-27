# FC-RELEASE-001 decision and change summary

FC-RELEASE-001 is not passed. The compact command ledger mirrors all 41 raw
FC-RELEASE-001 records in their original order, from
`CMD-20260826T231108Z-1f8c4815f5` through
`CMD-20260827T103455Z-4b3944647c`. Related runtime, real-provider, UI, and
performance commands remain in their owning work-package ledgers and are referenced by
identifier rather than copied.

The final current-source strict SwiftPM suites both pass with warnings treated as errors.
Debug command `CMD-20260827T103327Z-5d0a028f3d` executed 447 tests with three skips
and no failures. Release command `CMD-20260827T103455Z-4b3944647c` executed 447 tests
with four skips and no failures. Both commands explicitly unset the live LM Studio
variables, so the real-provider system test skipped. The other shared skips cover the
absent LM Studio Projects folder and unavailable PowerShell. Release additionally skipped
the valid-team-signature preservation test because no local team-signed Forge app fixture
was available.

The two 09:54 commands are retained as failed evidence. Each compiled and executed 444
tests with three skips, seven assertion failures, no unexpected failures, and three failed
test cases. Those cases used the test home as both the manager-owned runtime output root
and the child-writable project root, so the durable-output isolation invariant correctly
rejected them. The fixtures were moved to distinct project workspaces and an adversarial
non-overlap regression was added. Debug command
`CMD-20260827T100050Z-5dbe9ae0e1` and Release command
`CMD-20260827T100219Z-ff6e44637c` then each passed 445 tests with three skips. Those
passes were subsequently superseded by the managed-continuation changes, which received
the final 447-test passes above.

The earlier locked-session failure cascade is resolved rather than an open blocker. The
console diagnostic recorded `CGSSessionScreenIsLocked=Yes`, and macOS denied reopening
complete-file-protected registry fixtures. File protection was not weakened; the full
Debug and Release suites passed after the console was unlocked.

Earlier project-local app build/run verification, Xcode helper identity/build evidence,
the focused Xcode runtime suite, and the real LM Studio rollover scenario remain useful
historical evidence, but they predate the final source changes and require current-source
refresh. The prior 395-check package validation, prohibited-attribution scan, secret scan,
and nonzero completion-verifier result also predate those final changes and are not
presented as current-source release qualification.

Sanitizer gates remain blocked before product test execution. Address Sanitizer stalls in
shadow-memory initialization in both SwiftPM and Xcode; Thread Sanitizer is rejected by
platform policy in SwiftPM and its Xcode worker exits before establishing an XCTest
connection. Retained samples diagnose those host/toolchain failures but are not sanitizer
passes. UI automation remains blocked by Developer Mode/signing and automation-session
prerequisites. Instruments remains blocked by task-inspection authorization, and its
partial trace is not gate proof.

Release closure still requires current-source Xcode and project-local packaging proof,
successful separate sanitizer runs, UI/accessibility and profiling evidence, memgraph and
hidden-view quiescence, 8-hour idle and 4-hour active soaks, representative lower-memory
hardware, signed app and LaunchAgent lifecycle proof, notarized package behavior,
current-source real-provider and complete feature/protocol/migration qualification, final
release-content and prohibited-transport scans, refreshed integrity scans, and a zero exit
from `verify_completion.py`. No release-complete state is asserted.
