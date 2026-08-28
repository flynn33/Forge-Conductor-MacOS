# Decision Log

## DEC-0001 — Bound realtime telemetry before the main actor

- Date: 2026-08-23
- Problem: every telemetry update could enqueue additional main-actor work without a finite pending-work ceiling.
- Evidence: `.forge-codex/evidence/P03-bounded-telemetry-before-after.json`
- Constraints: preserve the existing telemetry contract and refresh controls.
- Feature IDs: `TEL-UI-BINDING`, `TEL-REALTIME-ENGINE`
- Selected option: one latest-value mailbox with one in-flight frame and one replaceable buffered frame.
- Ownership/lifetime impact: `AppTelemetryBinding` owns and cancels one consumer task; detach invalidates its generation and releases the application reference.
- Compatibility impact: no public telemetry fields or commands were removed.
- Resource impact: pending delivery is constant-space.
- Tests: `LatestValueMailboxTests`, `RealtimeStreamTests`, UI stress qualification.
- Rollback: restore the prior binding implementation and rerun G03-G05; this would reintroduce the original unbounded-work finding.

## DEC-0002 — Share Metal resources and draw on telemetry demand

- Date: 2026-08-23
- Problem: each gauge surface owned duplicate Metal setup and an independent recurring render cadence.
- Evidence: `.forge-codex/evidence/P04-metal-performance-report.json`, `.forge-codex/evidence/P11-profile-report.json`
- Constraints: preserve all gauge visuals and telemetry parity.
- Feature IDs: `TEL-METAL-GAUGES`, `UI-TAB-RIG`
- Selected option: process-wide device, command queue, and pipeline resources; surface-local capacity-growing vertex buffers; dirty-state drawing.
- Ownership/lifetime impact: renderers borrow shared immutable resources and dismantle their own buffers and delegates.
- Compatibility impact: gauge structure and displayed telemetry remain unchanged.
- Resource impact: no post-release RSS growth in the release stress profile; Metal allocation delta was 32 KiB.
- Tests: `RigParityTests`, release stress, Metal and Allocations traces, 100-cycle UI navigation.
- Rollback: revert the shared-resource renderer and rerun G04 and G11.

## DEC-0003 — Centralize tool authorization at canonical path boundaries

- Date: 2026-08-23
- Problem: filesystem, Git, and shell tools require a consistent confinement and session-mutation policy.
- Evidence: `.forge-codex/architecture/SECURITY_AND_PRIVACY.md`, `.forge-codex/evidence/P07-mcp-process-conformance.json`
- Constraints: preserve read-only inspection while preventing unbound mutation and symlink escapes.
- Feature IDs: `MCP-TOOL-FILESYSTEM`, `MCP-TOOL-GIT`, `MCP-TOOL-SHELL`
- Selected option: route tool calls through `ToolAuthorizationService`, canonicalize the deepest existing ancestor, protect root deletion/moves, and require an active session for shell and Git mutation.
- Ownership/lifetime impact: authorization state is application-owned and session-scoped.
- Compatibility impact: existing authorized tool contracts remain available.
- Resource impact: no additional long-lived worker or process is introduced.
- Tests: `CoreTests`, `ContinuityTests`, `ProcessRunnerTests`, P12 security scan.
- Rollback: revert authorization integration only with an equivalent confinement control and repeat security validation.

## DEC-0004 — Use the supported LM Studio managed adapter for rollover

- Date: 2026-08-23
- Problem: external chat creation is not available through a documented repository-owned host API.
- Evidence: `.forge-codex/evidence/P09-host-capability-report.json` and the exact-revision direct-adapter artifact for `52f8aca47463f88fa94276115fb5c2070ca683ef`; both are historical supporting evidence, not current autonomous-continuity release authority.
- Constraints: do not use private UI automation or claim unsupported external-host behavior.
- Feature IDs: `DATA-CONTEXT-HANDOFFS`
- Selected option: mode B, `forge.native-session-host` version 2, with configuration-gated `LMStudioManagedSessionTransport`; mode A remains memory-only handoff ready.
- Ownership/lifetime impact: the bounded v2 ledger owns hashed identities, acknowledgement receipts, provider usage, and rollover state but not transcripts or transport secrets.
- Compatibility impact: existing MCP handoffs remain supported; no undocumented external API is added.
- Resource impact: ledger, response chunks, retries, and cancellation records have explicit bounds.
- Tests: `NativeSessionHostPluginTests`, historical exact-revision Debug and Release suites, release plugin build, and a directly invoked real LM Studio adapter scenario that created a fresh provider root, acknowledged the handoff, and produced a linked continuation.
- Authority boundary: unit, synthetic-host, and direct-adapter evidence do not prove autonomous continuity. Current qualification still requires one manager-owned, threshold-forced real-provider rollover with exact successor acknowledgment, predecessor fencing and idempotent sealing, automatic continuation with the GUI closed, and recovery from every durable crash state.
- Rollback: disable the native adapter and retain memory-only handoffs.

## DEC-0005 — Quarantine and reverify filesystem entries before terminal mutation

- Date: 2026-08-28
- Problem: descriptor-relative identity checks and terminal `unlinkat` or `renameatx_np` calls are separate syscalls, so a same-user process can atomically replace the final-component binding after verification.
- Evidence: `.forge-codex/architecture/SECURITY_AND_PRIVACY.md`; the four atomic-`RENAME_SWAP` matrix tests; the post-quarantine substitution test; the combined namespace/durability recovery tests; and the bounded-ledger tests named below. Current-source Debug `EVID-20260828T124332Z-1e2a050c0e` and Release `EVID-20260828T124624Z-00a3dd27c2` each pass 657 tests with four expected host-dependent skips on source manifest `bc7b2f66d381d8fa4cd51b9e4da78b8c8486572385e05425c07d94922e8c3106`.
- Constraints: preserve filesystem tool names, no-overwrite move behavior, hard-link support, cancellation accounting, bounded recursive work, and explicit recovery after an irreversible namespace change.
- Feature IDs: `MCP-TOOL-FILESYSTEM`.
- Selected option: under pinned parents, verify the requested leaf; durably reserve one of 32 global immutable receipt slots; rename the current occupant exclusively to that slot's deterministic same-parent quarantine name; reverify the path identity, plus the bounded metadata/content fence on cross-volume source cleanup; and only then unlink or publish it. Terminal mutation and rollback stay inside a scoped ledger operation, and unsafe rollback retains a fixed recovery slot.
- Ownership/lifetime impact: directory descriptors remain operation-scoped. A per-Forge-home 32-slot receipt ledger, protected by a global lock with a two-second acquisition deadline, caps Forge-created retained quarantines across cooperating processes and ordinary crashes. A terminal namespace syscall or `fsync` already executing while that lock is held has no independent wall-time deadline. Corrupt receipts, unavailable or rebound parents, unconfirmed terminal durability, and failed rollback consume their slot until recovery; no random quarantine or receipt-temporary names are created. When receipt unlink succeeds but the following ledger-directory sync fails, Forge does not claim a nonexistent live recovery path; a stale receipt may conservatively reappear after a crash.
- Compatibility impact: existing delete and move contracts remain available; adversarial replacement fails closed at the exercised pre-quarantine windows, `RENAME_EXCL` continues to prevent destination overwrite, and unconfirmed terminal durability retains a bounded receipt. Boolean presence fields widen to JSON `null` only when inspection is unknown and pair with `*_presence_known=false`; cleanup requirements remain conservative Booleans. Command-level recovery-path reporting must remain command-backed and must not be inferred merely from receipt retention.
- Resource impact: recursive plans refuse more than 100,000 entries, and cross-volume move/reconciliation is capped at 300 seconds. These caps do not bound the bytes or descendants reachable through a single substituted entry.
- Residual security impact: mitigation does not eliminate `FC-FILESYSTEM-PATH-TOCTOU-001`. An adversary that discovers and swaps the quarantine name after final verification can redirect one terminal mutation per winning race. A substituted final-link file can contain unbounded bytes; a substituted directory can contain an unbounded subtree. One recursive call can reuse released slots across as many as 100,000 planned entries, so the 32-slot accumulation bound limits simultaneous cooperative recovery state, not cumulative adversarial wrong-object mutations. It does not protect against a same-UID adversary able to alter the owner-controlled ledger or move quarantine parents. Path anchoring, destination hierarchy construction, and hard-link ctime refresh also retain documented residuals, so the finding remains open as E2.
- Tests: `testRecursiveDeletePreservesLeafSwappedAfterVerification`, `testSameVolumeMoveDoesNotPublishLeafSwappedAfterVerification`, `testCrossVolumeInstallDoesNotPublishStagingLeafSwappedAfterVerification`, and `testCrossVolumeSourceRemovalPreservesLeafSwappedAfterVerification` cover the four atomic-`RENAME_SWAP` paths. `testRollbackRefusesSubstitutedQuarantineOccupant` covers the deterministic unsafe-rollback trace. `testSameVolumeNamespaceInstabilityWithUnconfirmedDurabilityRetainsRecoveryReceipt` and `testCrossVolumeNamespaceInstabilityWithUnconfirmedDurabilityRetainsRecoveryReceipt` prove live receipt reporting when publication commits but the requested namespace is unstable and terminal durability is unconfirmed; `testCrossVolumeNamespaceInstabilityMergesInstallAndStagingRecoveryReceipts` proves that a second retained staging-cleanup receipt is merged into the result. `testDeleteQuarantineIsGloballyBoundedAndRecoveredAcrossRestart`, `testCorruptQuarantineReceiptRemainsOccupiedAndRecoveryVisible`, `testPreexistingDeterministicQuarantineNameIsNotClaimed`, `testStaleQuarantineReservationCannotReleaseReusedSlot`, `testConcurrentQuarantineReservationsNeverExceedGlobalCapacity`, and `testRestartDoesNotTreatMissingNamesAsTerminalProof` cover fixed-capacity recovery. `testInitialQuarantineSyncFailureReportsRetainedTransitionWithoutRollback`, `testDeleteReportsUnknownPresenceWithoutFalseExistenceClaim`, `testUnavailableQuarantineLedgerFailsClosedBeforeNamespaceMutation`, `testPostUnlinkReceiptSyncFailureDoesNotClaimMissingRecoveryPath`, `testReceiptRemovalFailureRetainsTerminalRecoveryPath`, `testPostPublicationStagingFailurePreservesRecoveryAndUnknownPresence`, and `testRetainedStagingRecoveryDoesNotClaimAbsentStagingPathNeedsCleanup` cover truthful failure, recovery, and wire-presence contracts. The current-source strict evidence above passes these tests; it establishes behavior at the exercised windows, not unreachability of the remaining final verifier-to-terminal-syscall window.
- Rollback: revert quarantine-and-verify only if an equivalent identity-conditional terminal mutation or independent privilege boundary replaces it; keep E2 open and rerun the complete filesystem mutation/cancellation matrix.
