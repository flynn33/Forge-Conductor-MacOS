# Diagnostic capture contract for the source correction

This table maps sections A–H of the October 2 installed-alpha analysis to the
source writer and a test that exercises the boundary. It describes the source
tree only. The prior source tests did not qualify the later installed 0.16.4 signing path.
The 0.16.5 startup/export correction is recorded below.

| Report section | Writer and captured distinction | Regression test |
| --- | --- | --- |
| A — record identity and capture state | `DiagnosticLog.log` assigns a record and process-instance ID, timestamp, version/build, role, component and category; `DiagnosticEnvelope.asDictionary` exports them. `DiagnosticLog.log` marks redacted, unavailable and truncated values separately. `DiagnosticLog.loadPersisted` preserves an existing redaction marker. | `MCPProtocolAndDiagnosticsTests.testDiagnosticErrorIdentitySurvivesPersistenceAndExport`; `testDiagnosticLogRedactsPrivateFieldsBeforePersistenceAndExport` |
| B — call and error correlation | `MCPServer.handle` writes `mcp_tools_call`; `ToolRouter.recordAndReturn` writes the result with the same invocation ID and start/finish times. `ToolRouter.call` writes `tool_exception` for a thrown error; `resultDiagnosticFields` labels a returned unsuccessful result `returned_failure` rather than substituting an exception. | `MCPProtocolAndDiagnosticsTests.testMCPToolRequestAndRouterResultShareInvocationIdentity`; `CoreTests.testThrownToolKeepsExceptionDistinctFromReturnedFailure`; `MCPProtocolAndDiagnosticsTests.testFailedToolDiagnosticUsesReturnedExecutionFields` |
| C — filesystem read | `FilesystemToolPack.fsRead` uses `classifiedReadFailure` to retain the observed error domain/code and distinguish missing file, permission, nonregular file, invalid UTF-8, and unclassified failure. `ToolRouter.recordAndReturn` retains the returned code. | `CoreTests.testFsReadDistinguishesMissingFileFromUnreadableTarget` |
| D — search | `SearchToolPack.handle` returns the process outcome; `ToolRouter.resultDiagnosticFields` writes its exit code, timeout, stderr and truncation fields rather than the literal `error`. | `CoreTests.testFailedSearchDiagnosticRetainsReturnedProcessOutcome`; `MCPProtocolAndDiagnosticsTests.testFailedToolDiagnosticUsesReturnedExecutionFields` |
| E — shell and durable jobs | `RuntimeJobSynchronousToolPack.handleLegacyShell` writes `shell_job_terminal` with job ID, terminal state, exit code and invocation ID. It records whether a matching job was reused or a new one created; `ToolRouter.recordAndReturn` retains the same invocation ID. | `RuntimeExecutionJobTests.testFailedLegacyShellDiagnosticRetainsJobTerminalState`; `testLegacyShellReportsActualIdempotencyReuse` |
| F — continuity | `ContinuityAutomation.observe` writes checkpoint/handoff attempts and saved packet identities. `ContextContinuityService.autoPersist` records the candidate handoff ID if packet creation reached that point. `ContinuityIngressDeliveryService.drainOnce` records its pass ID, selected handoff, stage and retry state. `ManagerNode.processInteractiveContinuityOnce` records the exact interactive successor request before `createSession`, and the result or failure afterward. An unavailable marker is used only before the corresponding identifier exists. | `ContinuityTests.testRuntimeAutoCheckpointPersistsWithoutModelCall`; `testAutoCheckpointFailureRetainsPrecommitStageAndUnavailableHandoffID`; `ContinuityIngressDeliveryTests.testIngressFailureAfterClaimRetainsExactHandoffAndPassStage`; `testIngressRetryRecordDistinguishesScheduledFromStarted`; `ManagerTests.testInteractiveContinuityFailureKeepsSelectedHandoffAndStage`; `testInteractiveCreateFailureRetainsRequestedStageAndHandoff` |
| G — Dashboard | `DashboardServer.handle(connection:listenerEpoch:)` assigns a connection ID and records connection failures against it. `DashboardServer.listenerFailureFields` and `bindTimeoutFields` record listener/bind failures under their own scope without inventing a connection or request ID. | `DashboardTests.testConnectionFailureIdentityRemainsDistinctFromListenerAndBindFailure` |
| H — export boundary | `DiagnosticLog.export` records selected and JSON/Markdown counts. `renderMarkdown` prints an omission notice with total, rendered, omitted and first/last included record IDs. | `MCPProtocolAndDiagnosticsTests.testDiagnosticTimelineDisclosesItsLimit`; `testDiagnosticExportJSONAndMarkdown` |

The old archive cannot reveal the discarded exceptions behind R11618 or
R11636, R11458's exact failure cause, R11579's process exit, or R11640's
terminal job state. Those facts remain unknowable from that archive. The
source tests above do not establish an installed-alpha repair.

## Startup and export after failed bootstrap

`AppBootstrapOperation.start` creates a separately owned `DiagnosticLog` on its
existing background worker before constructing the application graph. It records
startup, cancellation, and failures with error identity and the observed stage.
`AppModel` owns this log across retries and uses it for Diagnostics preview
and both export actions while `app` is unavailable. The production graph reuses
the same log after startup and borrows its lifetime; graph shutdown drains it,
while AppModel closes it off the main actor after its background operations end.

Startup export does not require the full app directory layout. When the master
history cannot be read, its bounded sanitized live ring remains exportable to a
writable selected folder; JSON and Markdown explicitly disclose the omitted
persisted history. An unwritable destination still fails and permits retry.
Regression names and exact native candidate evidence are recorded in
[qualification status](QUALIFICATION-STATUS.md).

## Bounded audit-drain measurements

The .27.1/40 follow-up adds four test-only DiagnosticBoundaryTests cells for
utility/userInteractive requested caller QoS and flush/shutdown while one utility
persistence work item is held. Work and caller assert off-main execution; the
finite gate has a five-second escape. The held drain has a 50 ms allowance and
must return false below 500 ms. Release is followed by a bounded two-second flush
and shutdown, monotonically ordered timestamps, and refusal of later submission
with one dropped submission. This changes no production queue or QoS policy.

The initial focused source command selected all four cells and passed (normal exit 0,
5.792 s, log `8935660df12a836888d6709f5b8a1352fccbdb486618a65b43b3779da5e89ce4`).
The original whole native class is **NONPASS**: 12 started, 11 passed, 0 skipped,
exit 65 in 47.976 s, log
`9895ab99c0b5da9c6f9331581b2f054a11eb92a33a407d0c852b7adadd4c9efe`.
The existing application-shutdown method failed its second idempotency assertion
before the new cells; all four cells passed and three QoS warning blocks remain.
Its failed receipt is retained independently of the later repair.

All four actual native JSON attachments exported with normal termination/full EOF,
no forced cleanup. The strict 27-field reader passed; the payload total is 4,151
bytes. Each requested caller QoS label below uses utility persistence QoS.

| Requested caller / held operation | Held drain ms (returned false) | Flush after release ms | Final shutdown ms |
| --- | ---: | ---: | ---: |
| utility / flush | 52.018584 | 0.020375 | 0.002000 |
| userInteractive / flush | 52.012834 | 0.015709 | 0.000833 |
| utility / shutdown | 52.015667 | 0.014250 | 0.001500 |
| userInteractive / shutdown | 52.041416 | 2.002583 | 0.001666 |

Each attachment reports work admitted/completed, off-main caller/work, no gate
escape timeout, successful released flush/final shutdown, and post-shutdown
refusal and one drop. Extraction summary
`audit-drain-qos-r2-exported-measurements-0270/extraction-summary.json` has SHA
`7c23fcdc5130a81c4ad18487c707f8c648fc71fff21d58665130dcae91962dc9`.
These intervals include gate bookkeeping, queue completion and caller scheduling.
Effective OS QoS and the warning's sole cause remain unknown; these are fixture
measurements, not ordinary GUI inversion, production performance or leak proof.

The .27.1 subsystem repair subsequently passed the original application assertion,
all four cells and the other owning methods: source 211/native 211, zero failures/
skips on their current 450-input map. Native still retains three Thread Performance
Checker blocks (DiagnosticLog:75 application shutdown, the userInteractive flush
fixture at DiagnosticBoundaryTests:399, and DiagnosticLog:64 userInteractive shutdown)
and three XCTest warning mirrors. This fixes repeated subsystem completion reports,
not production audit QoS. See the
[shutdown contract](ORDINARY-RUNTIME-CONTINUATION.md#repeated-subsystem-shutdown).
