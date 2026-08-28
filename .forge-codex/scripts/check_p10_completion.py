#!/usr/bin/env python3
"""Fail-closed evaluator for P10 command-backed compatibility evidence."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
from typing import Any

from evidence_support import parse_xctest_summaries, source_manifest


ROOT = pathlib.Path(os.environ.get("FORGE_P10_REPOSITORY", pathlib.Path(__file__).resolve().parents[2])).resolve()
EXPECTED_MIGRATION_FIXTURES = {
    "config-v1-to-v2",
    "global-sqlite-v2-to-v5",
    "global-sqlite-v3-to-v5",
    "project-memory-v1-to-v2",
    "legacy-continuity-v1-import",
    "legacy-continuity-v2-import",
    "native-ledger-v1-to-v2",
    "runtime-job-v2-to-v5",
}
REQUIRED_UI_CHECKS = {"commands", "settings", "accessibility", "reconnect", "redaction"}
MIGRATION_FIXTURE_TESTS = {
    "config-v1-to-v2": (
        "testLegacyShellMigrationBackupReceiptAndExplicitDisableRemainValid",
        "testConcurrentLegacyConfigLoadsPerformOneMigration",
    ),
    "global-sqlite-v2-to-v5": (
        "testVersionTwoStoreMigratesPopulatedDataReopensAndRerunsIdempotently",
        "testSQLiteStorePreCommitGuardRejectsAtomicPathReplacementAndRollsBackMigration",
        "testRestoredChangedSQLiteSourceCreatesBoundedSecondMigrationLineage",
        "testSQLiteMigrationPromotesArchivedCompletionAfterPreparedManifestCrash",
    ),
    "global-sqlite-v3-to-v5": (
        "testVersionThreeStoreMigratesWithoutLosingHandoff",
        "testConcurrentVersionThreeMigrationIsIdempotent",
        "testSQLitePreparedMigrationRecoversAfterSIGKILLAndReleasesInterprocessLock",
        "testSQLiteCommittedMigrationRecoversAfterSIGKILLBeforeManifestCompletion",
    ),
    "project-memory-v1-to-v2": (
        "testVersionOneDatabaseMigratesPopulatedDataReopensAndRerunsIdempotently",
        "testVersionOneMigrationRejectsStablePathReplacementBeforeCommit",
        "testConcurrentInitializersSerializeVersionOneMigration",
    ),
    "legacy-continuity-v1-import": (
        "testLegacyMigrationImportsExactProjectReadOnlyAndQuarantinesAmbiguous",
        "testLegacyMigrationReceiptFailureRollsBackSideEffectsAndReplayRepairsProjection",
        "testConcurrentIdenticalLegacyMigrationsCommitOneUnsplittableReceipt",
        "testLegacyMigrationAliasesOnePayloadAcrossFilenamesAndReplaysAfterRestart",
        "testLegacyMigrationRejectsMalformedExactRowBeforeRecordingReceipt",
        "testLegacyMigrationRejectsReceiptCountAndHashCategoryTampering",
        "testLegacyMigrationReconcilesVerifiedVersionOneReceiptDetails",
    ),
    "legacy-continuity-v2-import": (
        "testLegacyLocationV2MigrationPreservesBindingAcrossRestartAndIdempotentReplay",
    ),
    "native-ledger-v1-to-v2": (
        "testV2BlockedCredentialFailureAndLegacySyntheticQuarantinePersist",
        "testNativeLedgerChangedRestoreUsesBoundedImmutableLineages",
    ),
    "runtime-job-v2-to-v5": (
        "testSchemaV2MigratesForwardWithProcessIdentityAndIdempotencyReceiptStorage",
        "testRuntimeVersionTwoMigrationRejectsStablePathReplacementBeforeCommit",
        "testConcurrentInitializersSerializeVersionTwoMigration",
        "testRegisteredRuntimeVersionTwoMigrationStillCreatesRecoveryManifest",
    ),
}
MIGRATION_SAFEGUARD_TESTS = (
    "testCoResidentControlPlaneRuntimeBootstrapCreatesVersionZeroRecoveryManifest",
    "testNonMutatingSQLitePreflightRejectsInterruptedJournalWithoutChangingBytes",
    "testNonMutatingSQLitePreflightReadsWALCloneWithoutChangingSourceFamily",
    "testVerifiedMigrationBackupCapturesWALAndRejectsTamperedReuse",
    "testVerifiedMigrationManifestReconcilesPreparedSQLiteCompletion",
    "testSQLitePreparedMigrationRecoversAfterSIGKILLAndReleasesInterprocessLock",
    "testSQLiteCommittedMigrationRecoversAfterSIGKILLBeforeManifestCompletion",
    "testSQLiteStoreDoesNotRecreateMissingSourceOwnedByManifest",
    "testSQLiteStoreRejectsSourceChangedAfterPreparedBackup",
    "testSQLiteStoreRejectsUnrelatedTargetWithoutMigrationReceipt",
    "testSQLiteMainFileMovedGuardRejectsStablePathnameReplacement",
    "testPrepareSQLiteMigrationRejectsMovedMainFileBeforeArtifacts",
    "testMigrationArtifactsRejectFIFOsWithoutBlockingAndRecoverStaleTemporaryFile",
    "testVerifiedMigrationManifestRejectsTamperedBackupAndLinkedManifest",
    "testVerifiedMigrationBackupEnforcesBoundsAndRejectsLinkedArtifacts",
    "testVerifiedMigrationLockIsBoundedAndOwnerOnly",
)
MIGRATION_PLATFORM_OBSERVATION_TESTS = (
    "testSQLiteMainFileMovedGuardRecordsRestoredPathCycleWithoutTrustClaim",
)
REQUIRED_SHELL_STRICT_TESTS = (
    "testFreshConfigUsesSchemaV2DefaultEnabledShellPolicy",
    "testLegacyShellMigrationBackupReceiptAndExplicitDisableRemainValid",
    "testCurrentSchemaShellPolicyPreservesExplicitUserOptOut",
    "testShellExecutesByDefaultInsideAuthorizedProjectWorkspace",
    "testMigratedLegacyConfigExecutesAuthorizedShellByDefault",
    "testExplicitShellDisableUsesDistinctAuthorizationReason",
    "testShellPolicyAndCompatibilitySurviveManagerAndAppRestart",
    "testLegacyBashLoginCompatibilityProfileIsExposedWithoutChangingShellToolPack",
    "testBootstrapDefaultRouterRegistersRuntimeSurfaceExactlyOnceAndMCPDescriptors",
    "testBootstrapRouterLegacyShellExecUsesBoundProjectAndCompatibilityContract",
    "testLegacyShellTimeoutSchemaRemainsCompatibleWithRuntimeClamping",
    "testInProcessMCPHandshakeToolsList",
)
REQUIRED_FILESYSTEM_SECURITY_TESTS = (
    "testRecursiveDeletePreservesLeafSwappedAfterVerification",
    "testSameVolumeMoveDoesNotPublishLeafSwappedAfterVerification",
    "testSameVolumeNamespaceInstabilityWithUnconfirmedDurabilityRetainsRecoveryReceipt",
    "testCrossVolumeInstallDoesNotPublishStagingLeafSwappedAfterVerification",
    "testCrossVolumeNamespaceInstabilityWithUnconfirmedDurabilityRetainsRecoveryReceipt",
    "testCrossVolumeNamespaceInstabilityMergesInstallAndStagingRecoveryReceipts",
    "testCrossVolumeSourceRemovalPreservesLeafSwappedAfterVerification",
    "testRollbackRefusesSubstitutedQuarantineOccupant",
    "testDeleteQuarantineIsGloballyBoundedAndRecoveredAcrossRestart",
    "testCorruptQuarantineReceiptRemainsOccupiedAndRecoveryVisible",
    "testPreexistingDeterministicQuarantineNameIsNotClaimed",
    "testStaleQuarantineReservationCannotReleaseReusedSlot",
    "testConcurrentQuarantineReservationsNeverExceedGlobalCapacity",
    "testRestartDoesNotTreatMissingNamesAsTerminalProof",
    "testInitialQuarantineSyncFailureReportsRetainedTransitionWithoutRollback",
    "testDeleteReportsUnknownPresenceWithoutFalseExistenceClaim",
    "testUnavailableQuarantineLedgerFailsClosedBeforeNamespaceMutation",
    "testPostUnlinkReceiptSyncFailureDoesNotClaimMissingRecoveryPath",
    "testReceiptRemovalFailureRetainsTerminalRecoveryPath",
    "testPostPublicationStagingFailurePreservesRecoveryAndUnknownPresence",
    "testRetainedStagingRecoveryDoesNotClaimAbsentStagingPathNeedsCleanup",
)
REQUIRED_SHELL_UI_TESTS = (
    "testManagerShowsProjectShellPolicyControls",
    "testManagerSettingsControlsAndPersistsProjectShellPolicy",
)
RESTORED_PATH_OBSERVATION_PREFIX = "FORGE_SQLITE_RESTORED_PATH_OBSERVATION="
RESTORED_PATH_OBSERVATION_VALUES = {
    "accepted_after_restore",
    "failed_closed_after_restore",
}
EXPECTED_PATHNAME_EXCLUSIONS = {
    "hostile_same_user_between_check_namespace_substitution",
    "hostile_same_user_direct_database_family_mutation",
}
EXPECTED_PATHNAME_BOUNDARY_REQUIREMENTS = {
    "custom_sqlite_vfs_for_database_family_identity",
    "independent_privilege_boundary_for_direct_mutation",
}
failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def load(relative: str) -> dict[str, Any]:
    path = ROOT / relative
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        failures.append(f"cannot read P10 input {relative}: {error}")
        return {}
    if not isinstance(value, dict):
        failures.append(f"P10 input is not an object: {relative}")
        return {}
    return value


def digest(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def artifact_path(artifact: dict[str, Any], label: str) -> pathlib.Path | None:
    raw_path = artifact.get("path")
    if not isinstance(raw_path, str) or not raw_path:
        failures.append(f"{label} artifact has no path")
        return None
    path = pathlib.Path(raw_path)
    storage = artifact.get("storage")
    if storage in {"evidence-id-specific-copy", "evidence-id-specific-stream"}:
        check(not path.is_absolute(), f"{label} committed artifact path is not repository-relative: {raw_path}")
    if not path.is_absolute():
        path = ROOT / path
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        failures.append(f"{label} artifact is missing: {raw_path}: {error}")
        return None
    if storage != "external-hash-only":
        try:
            resolved.relative_to(ROOT)
        except ValueError:
            failures.append(f"{label} artifact is outside the repository: {raw_path}")
            return None
    else:
        check(pathlib.Path(raw_path).is_absolute(), f"{label} external artifact path is not absolute")
        check(
            artifact.get("portability") == "origin-host-required",
            f"{label} external artifact has no explicit portability policy",
        )
    check(not path.is_symlink() and resolved.is_file(), f"{label} artifact is not a regular non-symlink file")
    expected_bytes = artifact.get("bytes")
    expected_hash = artifact.get("sha256")
    check(isinstance(expected_bytes, int) and not isinstance(expected_bytes, bool), f"{label} artifact byte count is invalid")
    check(isinstance(expected_hash, str) and len(expected_hash) == 64, f"{label} artifact SHA-256 is invalid")
    if isinstance(expected_bytes, int):
        check(resolved.stat().st_size == expected_bytes, f"{label} artifact byte mismatch: {raw_path}")
    if isinstance(expected_hash, str) and len(expected_hash) == 64:
        check(digest(resolved) == expected_hash, f"{label} artifact SHA-256 mismatch: {raw_path}")
    return resolved


CURRENT_MANIFEST = source_manifest(ROOT)
RUN_STATE = load(".forge-codex/state/run-state.json")
LEDGER_EVIDENCE_IDS = {
    item for item in RUN_STATE.get("evidence", []) if isinstance(item, str)
}


def evidence_record(
    evidence_id: Any,
    label: str,
    *,
    expected_kinds: set[str],
    command_fragments: tuple[str, ...],
    require_success: bool = True,
) -> dict[str, Any]:
    if not isinstance(evidence_id, str) or not evidence_id.startswith("EVID-"):
        failures.append(f"{label} has no evidence id")
        return {}
    record = load(f".forge-codex/evidence/{evidence_id}.json")
    check(record.get("schema_version") == 2, f"{label} evidence is not immutable schema v2: {evidence_id}")
    check(record.get("id") == evidence_id, f"{label} evidence id mismatch: {evidence_id}")
    check(record.get("kind") in expected_kinds, f"{label} evidence kind is unexpected: {record.get('kind')}")
    command = record.get("command")
    check(isinstance(command, str) and all(value in command for value in command_fragments), f"{label} command is unexpected")
    check("G10" in record.get("related_gates", []), f"{label} evidence is not bound to G10")
    if require_success:
        check(record.get("exit_code") == 0, f"{label} evidence did not exit zero")
    check(record.get("timed_out") is False, f"{label} evidence timed out")
    check(record.get("stream_limit_exceeded") is False, f"{label} evidence exceeded its stream limit")
    check(record.get("ledger_reference", {}).get("status") == "recorded", f"{label} evidence is absent from the ledger")
    check(evidence_id in LEDGER_EVIDENCE_IDS, f"{label} evidence id is not present in current run-state")
    check(record.get("source_manifest_changed") is False, f"{label} source changed during evidence collection")
    check(record.get("source_manifest") == CURRENT_MANIFEST, f"{label} evidence is stale for the current source manifest")
    check(record.get("source_manifest_after") == CURRENT_MANIFEST, f"{label} ending source manifest is stale")
    check(record.get("artifact_capture_errors") == [], f"{label} evidence has artifact capture errors")
    artifacts = record.get("artifacts")
    check(isinstance(artifacts, list) and bool(artifacts), f"{label} evidence has no artifacts")
    if isinstance(artifacts, list):
        for index, artifact in enumerate(artifacts):
            if isinstance(artifact, dict):
                artifact_path(artifact, f"{label} artifact {index}")
            else:
                failures.append(f"{label} artifact {index} is not an object")
    reconciliation = record.get("artifact_integrity_reconciliation")
    if isinstance(reconciliation, dict):
        check(reconciliation.get("unavailable_artifacts") in (None, []), f"{label} has unavailable historical artifacts")
    return record


def stdout_text(record: dict[str, Any], label: str) -> str:
    for artifact in record.get("artifacts", []):
        if isinstance(artifact, dict) and str(artifact.get("path", "")).endswith(".stdout.txt"):
            path = artifact_path(artifact, f"{label} stdout")
            if path is not None:
                try:
                    check(path.stat().st_size <= 16 * 1024 * 1024, f"{label} stdout exceeds parsing bound")
                    return path.read_text(encoding="utf-8", errors="replace")
                except OSError as error:
                    failures.append(f"{label} stdout cannot be read: {error}")
                    return ""
    failures.append(f"{label} evidence has no stdout artifact")
    return ""


def preserved_report(record: dict[str, Any], relative: str, label: str) -> None:
    report = ROOT / relative
    try:
        expected = (report.stat().st_size, digest(report))
    except OSError as error:
        failures.append(f"{label} report cannot be read: {error}")
        return
    matches = []
    for artifact in record.get("artifacts", []):
        if not isinstance(artifact, dict) or artifact.get("storage") != "evidence-id-specific-copy":
            continue
        if artifact.get("source_path") == relative and (artifact.get("bytes"), artifact.get("sha256")) == expected:
            matches.append(artifact)
    check(bool(matches), f"{label} report is not preserved by evidence-specific copy")


def manifest_report(report: dict[str, Any], label: str) -> None:
    check(report.get("source_manifest") == CURRENT_MANIFEST, f"{label} report is stale for the current source manifest")


baseline = load(".forge-codex/state/feature-baseline.json")
features = baseline.get("features")
check(isinstance(features, list) and len(features) == 66, "baseline feature inventory is not exactly 66 entries")
if isinstance(features, list):
    check(all(isinstance(item, dict) and item.get("parity_status") == "preserved" for item in features), "baseline feature inventory contains a non-preserved entry")
    check(all(isinstance(item, dict) and item.get("evidence") and item.get("tests") for item in features), "baseline feature inventory contains an entry without evidence or tests")

project_path = ROOT / "ForgeConductor.xcodeproj/project.pbxproj"
project = project_path.read_text(encoding="utf-8") if project_path.is_file() else ""
for source in (
    "ContinuityCoordinator.swift",
    "ForgeNativeSessionHostPlugin.swift",
    "MetalGaugeResources.swift",
    "ProjectMemoryRepository.swift",
    "RuntimeJobRepository.swift",
    "VerifiedMigrationBackup.swift",
    "FilesystemQuarantineLedger.swift",
    "ContinuityTests.swift",
    "NativeSessionHostPluginTests.swift",
    "ProjectMemoryTests.swift",
    "RuntimeExecutionJobTests.swift",
):
    check(source in project, f"Xcode project is missing P10 source or test: {source}")

parity = load(".forge-codex/evidence/P10-parity-report.json")
migration = load(".forge-codex/evidence/P10-migration-report.json")
protocol = load(".forge-codex/evidence/P10-protocol-compatibility-report.json")
cli = load(".forge-codex/evidence/P10-cli-compatibility-report.json")

check(parity.get("status") == "passed", "parity report is not passed")
check(parity.get("removed") == [], "parity report records removed features")
check(parity.get("unknown") == [], "parity report records unknown features")
check(parity.get("untested") == [], "parity report records untested features")
check(parity.get("remaining_requirements") == [], "parity report has remaining requirements")
if parity.get("status") == "passed":
    manifest_report(parity, "parity")

strict_suites = migration.get("strict_suites", {})
strict_records: dict[str, dict[str, Any]] = {}
strict_outputs: dict[str, str] = {}
for configuration, kinds in (
    ("debug", {"p10-full-debug", "p10-post-preflight-full-debug"}),
    ("release", {"p10-full-release", "p10-post-preflight-full-release"}),
):
    item = strict_suites.get(configuration, {}) if isinstance(strict_suites, dict) else {}
    record = evidence_record(item.get("evidence_id"), f"{configuration} strict suite", expected_kinds=kinds, command_fragments=("swift test",))
    strict_records[configuration] = record
    command = record.get("command", "")
    check("--filter" not in command, f"{configuration} strict suite is filtered")
    check(("-c release" in command) == (configuration == "release"), f"{configuration} strict suite configuration is wrong")
    strict_outputs[configuration] = stdout_text(record, f"{configuration} strict suite")
    summaries = parse_xctest_summaries(strict_outputs[configuration])
    passing = [value for value in summaries if value["failures"] == 0]
    check(bool(passing), f"{configuration} strict suite has no zero-failure XCTest summary")
    if passing:
        summary = max(passing, key=lambda value: value["executed"])
        check(summary["executed"] == item.get("executed"), f"{configuration} strict suite executed count does not match evidence")
        check(summary["skipped"] == item.get("skipped"), f"{configuration} strict suite skipped count does not match evidence")
        check(item.get("failures") == 0, f"{configuration} strict suite report has failures")
if all(strict_records.values()):
    debug_item = strict_suites.get("debug", {})
    release_item = strict_suites.get("release", {})
    check(debug_item.get("executed") == release_item.get("executed"), "Debug and Release strict suites disagree on test count")

check(migration.get("status") == "passed", "migration report is not passed")
fixtures = migration.get("fixtures")
check(isinstance(fixtures, list), "migration report has no fixture matrix")
if isinstance(fixtures, list):
    fixture_ids = {item.get("id") for item in fixtures if isinstance(item, dict)}
    check(fixture_ids == EXPECTED_MIGRATION_FIXTURES, "migration fixture inventory is incomplete or changed")
    check(all(isinstance(item, dict) and item.get("status") == "passed" for item in fixtures), "one or more migration fixtures are not fully passed")
for fixture_id, test_names in MIGRATION_FIXTURE_TESTS.items():
    for configuration, output in strict_outputs.items():
        for test_name in test_names:
            check(
                f"{test_name}]' passed" in output,
                f"{configuration} strict suite has no passing {fixture_id} proof: {test_name}",
            )
for configuration, output in strict_outputs.items():
    for test_name in MIGRATION_SAFEGUARD_TESTS:
        check(
            f"{test_name}]' passed" in output,
            f"{configuration} strict suite has no passing migration safeguard: {test_name}",
        )
    for test_name in MIGRATION_PLATFORM_OBSERVATION_TESTS:
        check(
            f"{test_name}]' passed" in output,
            f"{configuration} strict suite has no passing migration platform observation: {test_name}",
        )
    for test_name in REQUIRED_SHELL_STRICT_TESTS:
        check(
            f"{test_name}]' passed" in output,
            f"{configuration} strict suite has no passing shell compatibility proof: {test_name}",
        )
    for test_name in REQUIRED_FILESYSTEM_SECURITY_TESTS:
        check(
            f"{test_name}]' passed" in output,
            f"{configuration} strict suite has no passing filesystem security proof: {test_name}",
        )
restored_path_observations: dict[str, str | None] = {}
for configuration, output in strict_outputs.items():
    matches = {
        value
        for value in RESTORED_PATH_OBSERVATION_VALUES
        if f"{RESTORED_PATH_OBSERVATION_PREFIX}{value}" in output
    }
    check(
        len(matches) == 1,
        f"{configuration} strict suite has no unambiguous restored-path observation",
    )
    restored_path_observations[configuration] = next(iter(matches), None)
pathname_boundary = migration.get("pathname_trust_boundary", {})
check(
    pathname_boundary.get("status") == "qualified",
    "migration pathname trust boundary is not qualified",
)
check(
    pathname_boundary.get("stable_replacement") == "fails_closed",
    "stable SQLite pathname replacement is not fail-closed",
)
check(
    pathname_boundary.get("precommit_transaction")
    == "rolls_back_schema_and_receipts_with_prepared_recovery_artifacts_retained",
    "pre-COMMIT pathname replacement disposition is incomplete",
)
check(
    pathname_boundary.get("platform_observations") == restored_path_observations,
    "migration pathname platform observations do not match strict-suite output",
)
check(
    set(pathname_boundary.get("excluded_threats", [])) == EXPECTED_PATHNAME_EXCLUSIONS,
    "migration pathname trust-boundary exclusions are incomplete or changed",
)
check(
    set(pathname_boundary.get("requirements_to_broaden", []))
    == EXPECTED_PATHNAME_BOUNDARY_REQUIREMENTS,
    "migration pathname trust-boundary requirements are incomplete or changed",
)
check(migration.get("backup_qualification", {}).get("status") == "passed", "migration backup qualification is not passed")
check(migration.get("remaining_requirements") == [], "migration report has remaining requirements")
if migration.get("status") == "passed":
    manifest_report(migration, "migration")

check(cli.get("status") == "passed", "CLI compatibility report is not passed")
cli_item = parity.get("current_automated_results", {}).get("cli_compatibility", {})
if cli.get("status") == "passed":
    cli_record = evidence_record(cli_item.get("evidence_id"), "CLI compatibility", expected_kinds={"p10-cli-compatibility"}, command_fragments=("check_p10_cli_compatibility.py", "--report"))
    preserved_report(cli_record, ".forge-codex/evidence/P10-cli-compatibility-report.json", "CLI compatibility")
    manifest_report(cli, "CLI compatibility")
check(cli.get("runtime_case_count", 0) >= 16, "CLI compatibility runtime matrix is incomplete")
help_arguments = cli.get("preserved_help_arguments")
check(isinstance(help_arguments, list) and len(help_arguments) >= 9 and all(isinstance(item, dict) and item.get("present") is True for item in help_arguments), "CLI preserved option and argument proof is incomplete")

check(protocol.get("status") == "passed", "MCP protocol compatibility report is not passed")
check(protocol.get("ok") is True, "MCP protocol compatibility report is not eligible")
check(protocol.get("removed_tools") == [], "MCP protocol report records removed tools")
check(protocol.get("schema_breaks") == [], "MCP protocol report records schema breaks")
check(protocol.get("description_breaks") == [], "MCP protocol report records description breaks")
check(protocol.get("uncovered_checks") == [], "MCP protocol report has uncovered checks")
protocol_item = parity.get("current_automated_results", {}).get("mcp_compatibility", {})
if protocol.get("status") == "passed":
    protocol_record = evidence_record(protocol_item.get("evidence_id"), "MCP compatibility", expected_kinds={"p10-protocol-compatibility"}, command_fragments=("check_p10_protocol_compatibility.py", "--output", "--transcript-output"))
    preserved_report(protocol_record, ".forge-codex/evidence/P10-protocol-compatibility-report.json", "MCP compatibility")
    manifest_report(protocol, "MCP compatibility")
    for name, declared in protocol.get("artifacts", {}).items():
        if not isinstance(declared, dict):
            failures.append(f"MCP protocol report artifact {name} is malformed")
            continue
        declared_path = declared.get("path")
        matches = [artifact for artifact in protocol_record.get("artifacts", []) if isinstance(artifact, dict) and artifact.get("storage") == "evidence-id-specific-copy" and artifact.get("source_path") == declared_path and artifact.get("bytes") == declared.get("bytes") and artifact.get("sha256") == declared.get("sha256")]
        check(bool(matches), f"MCP protocol artifact {name} has no evidence-specific preserved copy")

manager_item = parity.get("current_automated_results", {}).get("manager_http_compatibility", {})
check(manager_item.get("status") == "passed", "manager HTTP compatibility is not passed")
check(manager_item.get("uncovered") == [], "manager HTTP compatibility has uncovered routes")
if manager_item.get("status") == "passed":
    manager_relative = manager_item.get("report_path")
    check(isinstance(manager_relative, str), "manager HTTP compatibility has no report path")
    manager_report = load(manager_relative) if isinstance(manager_relative, str) else {}
    manager_record = evidence_record(manager_item.get("evidence_id"), "manager HTTP compatibility", expected_kinds={"p10-manager-http-compatibility"}, command_fragments=("check_p10_manager_http_compatibility.py", "--report"))
    if isinstance(manager_relative, str):
        preserved_report(manager_record, manager_relative, "manager HTTP compatibility")
    manifest_report(manager_report, "manager HTTP compatibility")
    semantics = manager_report.get("runtime", {}).get("manager", {}).get("success_semantics", {})
    check(manager_report.get("status") == "passed" and manager_report.get("ok") is True and manager_report.get("g10_compatibility_eligible") is True, "manager report is not G10 eligible")
    check(semantics.get("coverage_status") == "complete" and semantics.get("full_g10_compatibility_claimed") is True, "manager success semantics are partial")
    check(semantics.get("expected_count") == 17 and semantics.get("exercised_count") == 17, "manager current success matrix is not exactly 17 of 17")
    check(semantics.get("baseline_expected_count") == 8 and len(semantics.get("baseline_exercised", [])) == 8 and semantics.get("baseline_complete") is True, "manager historical success matrix is not exactly 8 of 8")
    check(semantics.get("uncovered") == [], "manager report has uncovered success semantics")

ui = parity.get("ui", {})
check(ui.get("behavioral_status") == "passed", "native UI qualification is not passed")
if ui.get("behavioral_status") == "passed":
    ui_relative = ui.get("report_path")
    check(isinstance(ui_relative, str), "native UI qualification has no report path")
    ui_report = load(ui_relative) if isinstance(ui_relative, str) else {}
    ui_record = evidence_record(ui.get("evidence_id"), "native UI qualification", expected_kinds={"p10-native-ui-qualification"}, command_fragments=("xcodebuild", "ForgeConductorUITests"))
    if isinstance(ui_relative, str):
        preserved_report(ui_record, ui_relative, "native UI qualification")
    manifest_report(ui_report, "native UI qualification")
    ui_output = stdout_text(ui_record, "native UI qualification")
    check(ui_report.get("status") == "passed" and ui_report.get("ok") is True, "native UI report is not passed")
    xctest = ui_report.get("xctest", {})
    check(xctest.get("attempts", 0) >= 1 and xctest.get("passing_attempts", 0) >= 1 and xctest.get("executed", 0) > 0 and xctest.get("failures") == 0, "native UI XCTest semantics are incomplete")
    authorization = ui_report.get("authorization", {})
    check(authorization.get("developer_mode_enabled") is True and authorization.get("signing_identity_usable") is True and authorization.get("automation_authorized") is True, "native UI authorization prerequisites are not proven")
    checks = ui_report.get("checks", {})
    check(isinstance(checks, dict) and REQUIRED_UI_CHECKS == {key for key, value in checks.items() if value is True}, "native UI command/settings/accessibility/reconnect/redaction matrix is incomplete")
    for test_name in REQUIRED_SHELL_UI_TESTS:
        check(
            f"{test_name}]' passed" in ui_output,
            f"native UI qualification has no passing shell Settings proof: {test_name}",
        )

result = {
    "ok": not failures,
    "phase": "P10",
    "source_manifest": CURRENT_MANIFEST,
    "baseline_features": len(features) if isinstance(features, list) else 0,
    "migration_fixtures": len(fixtures) if isinstance(fixtures, list) else 0,
    "failures": failures,
}
print(json.dumps(result, indent=2, sort_keys=True))
raise SystemExit(0 if not failures else 1)
