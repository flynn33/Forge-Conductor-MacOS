# FC-RELEASE-001 decision and change summary

FC-RELEASE-001 is not passed. The frozen compact command ledger mirrors all 35 raw
FC-RELEASE-001 records from `CMD-20260826T231108Z-1f8c4815f5` through
`CMD-20260827T030013Z-bf6e30761e`. Related runtime, real-provider, UI, and performance
commands remain in their owning work-package ledgers and are referenced by identifier.

The final current-source Debug and Release SwiftPM commands both compiled cleanly with
warnings treated as errors and executed 444 tests. Each reported three skips, 137 assertion
failures, and 42 unexpected failures, with an identical failed-test set. The failures are a
locked-session cascade: `registry.json` is intentionally written with complete file
protection and macOS returns Cocoa 257 with underlying `EPERM` when the locked session tries
to reopen it. The recorded host diagnostic confirms `CGSSessionScreenIsLocked=Yes`. File
protection was not weakened. Both full suites must be rerun after the console is unlocked.

The runtime surface was isolated from that boundary. Current-source strict SwiftPM and
ad-hoc-signed Xcode runs each executed 64 runtime tests with one PowerShell-host skip and no
failures. They exclude the two bootstrap-router tests whose temporary project registry hits
the protected-file condition. The project-local app entrypoint rebuilt the app and helper,
signed nested code before the enclosing app, passed deep/strict verification, launched the
bundle, and was stopped after verification.

Qualification exposed and repaired two late defects. Under Release load, a dead but
unreaped launcher briefly made exact identity lookup unavailable. Recovery now retries only
that transient result within persisted absolute TERM/KILL deadlines; mismatch, signal
failure, and deadline exhaustion still fail closed. Separately, Xcode's raw helper initially
carried a hash-derived signing identifier. The helper target now embeds its generated
Info.plist identity, yielding the exact `com.forge-conductor.runtime-launcher` identifier.
The final Xcode build-for-testing and 64-test runtime run pass with that identity enforced.

Earlier 395-test Debug/Release passes, the 373-test Xcode pass, and the real LM Studio
rollover scenario remain useful historical evidence, but they predate the final runtime,
security, packaging, and test changes and are not presented as current-source release
qualification.

Sanitizer gates remain blocked before product test execution. Address Sanitizer stalls in
shadow-memory initialization in both SwiftPM and Xcode; Thread Sanitizer is rejected by
platform policy in SwiftPM and its Xcode worker exits before establishing an XCTest
connection. Retained samples diagnose those host/toolchain failures but are not sanitizer
passes. UI automation remains blocked by disabled Developer Mode and unavailable signing;
Instruments remains blocked by task-inspection authorization, and its partial trace is not
gate proof.

Package validation completed 395 checks successfully, and the current-source prohibited-
attribution and secret scans pass. The final completion verifier is nonzero only for G09,
G10, G11, and their ledger dependency states.

Release closure still requires unlocked current-source full suites, successful separate
sanitizer runs, UI/accessibility and profiling evidence, memgraph and hidden-view quiescence,
8-hour idle and 4-hour active soaks, representative lower-memory hardware, signed app and
LaunchAgent lifecycle proof, notarized package behavior, current-source real-provider and
feature/protocol/migration qualification, final release-content and prohibited-transport
scans, and a zero exit from
`verify_completion.py`. No release-complete state is asserted.
