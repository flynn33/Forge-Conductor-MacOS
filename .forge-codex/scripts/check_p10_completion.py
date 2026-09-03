#!/usr/bin/env python3
"""Fail-closed evaluator for P10 command-backed compatibility evidence."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
from datetime import datetime
from typing import Any

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:  # pragma: no cover - exercised only on an incomplete gate host
    Draft202012Validator = None
    FormatChecker = None

from evidence_support import (
    BoundedReadBudget,
    EVIDENCE_CONTEXT_SCHEMA_VERSION,
    EvidenceSupportError,
    MANIFEST_TARGETS,
    MAXIMUM_MANIFEST_FILE_BYTES,
    MAXIMUM_QUALIFICATION_ARTIFACT_BYTES,
    QUALIFICATION_ARTIFACT_BINDING_SCHEMA_VERSION,
    atomic_write,
    canonical_json_sha256,
    current_git_head,
    decode_strict_json_object,
    load_qualification_artifact,
    parse_xctest_summaries,
    read_bounded_repository_bytes,
    run_bounded_readonly_command,
    sha256_bounded_regular_file,
    source_manifest,
)
from record_command import (
    MAXIMUM_EXTERNAL_ARTIFACT_BYTES,
    MAXIMUM_PRESERVED_ARTIFACT_BYTES,
    execution_provenance,
)
from p10_feature_evidence import evaluate_p10_feature_evidence


ROOT = pathlib.Path(os.environ.get("FORGE_P10_REPOSITORY", pathlib.Path(__file__).resolve().parents[2])).resolve()
QUALIFICATION_ARTIFACT_SCHEMA = (
    ROOT
    / ".forge-codex/schemas/p10-privileged-filesystem-artifact-binding.schema.json"
)
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
    "testCapturedLeafRollbackPolicyNeverRestoresThroughRelocatableParent",
    "testCaptureFirstCoordinatorCommitsOnlyAfterCapturedVerification",
    "testCaptureFirstCoordinatorQuarantinesMismatchWithoutCommit",
    "testCaptureFirstCoordinatorDoesNotVerifyOrCommitAfterCaptureFailure",
    "testMutationRequestRequiresContractSpecificExpectedIdentity",
    "testMutationRequestDigestCanonicalizesUUIDCaseAndBindsContract",
    "testMutationRequestSecureDecodingRejectsDigestBoundFieldTamper",
    "testQuarantinedTransactionStatusIsDurableTerminalAndNotAcknowledgable",
    "testQuarantinedTransactionStatusRejectsContradictoryFlagsAndSuccessCode",
    "testConflictedTransactionStatusIsDurableTerminalAndAcknowledgable",
    "testProductionDeleteDispatchUsesCurrentEntryContractAndCanonicalDigest",
    "testDurableQuarantineFailurePreservesTypedFailureAndRecoveryAuthority",
    "testQuarantinedQuerySurfacesTerminalRecoveryStateAndRetainsAuthority",
    "testPrivilegedDaemonUsesDistinctCaptureIdentityAndPhaseReceipts",
    "testPrivilegedDaemonBindsPersistedDigestAndLegacyRollbackIdentity",
    "testInterruptedProtectedDeleteNeverReconcilesFromPathnameAbsence",
    "testSameUIDLedgerDirectoryRenameCausesBoundedRecoveryLossWithoutXPCDispatch",
    "testGenerationResetRejectsRetainedFilesystemRecoveryAuthority",
    "testGenerationResetCancelsWhenFilesystemRecoveryAppearsAfterBegin",
    "testGenerationResetSurfacesCancellationFailure",
    "testDeleteWaitingBehindGenerationResetCannotRetainOrDispatchStaleAuthority",
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
REQUIRED_PRIVILEGED_FILESYSTEM_MATRIX = {
    "signed_debug_bundle",
    "signed_release_bundle",
    "unauthorized_same_uid_client",
    "unauthorized_same_uid_namespace_access",
    "unauthorized_same_uid_ledger_mutation",
    "differently_signed_client",
    "unknown_protocol_and_malformed_messages",
    "outside_root_sentinel_preservation",
    "wrong_project_id",
    "stale_project_generation",
    "negative_project_generation_wire_rejected",
    "project_binding_hash_collision_resolution",
    "project_binding_lifecycle_exhaustion_and_revoke",
    "case_normalized_transaction_replay",
    "root_descriptor_identity_mismatch",
    "atomic_swap_source_leaf_before_capture",
    "atomic_swap_source_leaf_during_capture",
    "atomic_swap_source_leaf_after_capture",
    "atomic_swap_parent_before_capture",
    "atomic_swap_parent_after_capture",
    "parent_relocation_during_rollback",
    "atomic_swap_rollback_destination_occupied",
    "atomic_swap_special_leaf_before_descriptor_open",
    "authorization_metadata_change_after_final_check",
    "crash_at_every_durable_phase",
    "daemon_restart_and_idempotent_recovery",
    "manager_restart_and_idempotent_recovery",
    "query_is_strictly_nonmutating",
    "resume_after_reply_and_pathname_loss",
    "terminal_outcome_retained_until_acknowledged",
    "acknowledgement_authority_and_idempotency",
    "acknowledgement_crash_cleanup_matrix",
    "caller_ledger_precedes_xpc_submission",
    "caller_ledger_restart_and_scope_fencing",
    "broker_interruption_requires_transaction_recovery",
    "caller_ledger_same_uid_tamper",
    "caller_ledger_lock_replacement_during_retention",
    "project_generation_reset_with_retained_transaction",
    "local_ownership_enforced_apfs",
    "external_volume_rejected",
    "removable_volume_rejected",
    "network_volume_rejected",
    "ignore_ownership_volume_rejected",
    "cross_volume_destination_durable_before_source_destruction",
    "approval_and_denial",
    "upgrade_unregister_reregister",
    "same_connection_service_version_handshake",
    "caller_sealed_helper_code_identity",
    "app_manager_cli_helper_packaging",
    "settings_status_and_control",
    "tampered_or_wrong_signature",
    "authorized_app_and_manager_cli_identities",
    "source_leaf_substitution",
    "hard_link_behavior",
    "writable_file_descriptor_behavior",
    "no_same_uid_fallback",
    "shell_nonregression",
}
REQUIRED_PRIVILEGED_FILESYSTEM_CASE_FIELDS = {
    "contracts_exercised",
    "status",
    "raw_artifact_references",
    "iterations",
    "barrier_evidence",
    "process_identities",
    "signing_identities",
    "fixture_digests",
    "mount_facts",
    "crash_point",
    "observed_result",
}
PRIVILEGED_FILESYSTEM_CONTRACTS = {
    "currentEntry",
    "namespaceVersionExact",
    "contentVersionExact",
}
REQUIRED_PRIVILEGED_FILESYSTEM_CONTRACT_SUBSETS = {
    "atomic_swap_source_leaf_before_capture": {
        "currentEntry",
        "namespaceVersionExact",
    },
    "atomic_swap_source_leaf_during_capture": {
        "currentEntry",
        "namespaceVersionExact",
    },
    "source_leaf_substitution": {
        "currentEntry",
        "namespaceVersionExact",
    },
    "hard_link_behavior": {
        "namespaceVersionExact",
        "contentVersionExact",
    },
    "writable_file_descriptor_behavior": {
        "currentEntry",
        "contentVersionExact",
    },
}
REQUIRED_PRIVILEGED_FILESYSTEM_FORMAL_CLOSURE = {
    "capture_linearization",
    "source_parent_containment_and_authority",
    "protected_namespace_denial",
    "current_entry_contract",
    "namespace_exact_no_mismatch_disposal",
    "content_exact_fail_closed",
    "final_authorization_metadata_race_closure",
    "quarantine_disposition_qualification",
    "startup_recovery_fence",
    "caller_generation_fence",
    "volume_behavior_qualification",
    "equivalent_identity_conditional_boundary_proof",
}
REQUIRED_PRIVILEGED_FILESYSTEM_MOUNT_FACT_CASES = {
    "outside_root_sentinel_preservation",
    "root_descriptor_identity_mismatch",
    "atomic_swap_source_leaf_before_capture",
    "atomic_swap_source_leaf_during_capture",
    "atomic_swap_source_leaf_after_capture",
    "atomic_swap_parent_before_capture",
    "atomic_swap_parent_after_capture",
    "parent_relocation_during_rollback",
    "atomic_swap_rollback_destination_occupied",
    "atomic_swap_special_leaf_before_descriptor_open",
    "authorization_metadata_change_after_final_check",
    "crash_at_every_durable_phase",
    "daemon_restart_and_idempotent_recovery",
    "manager_restart_and_idempotent_recovery",
    "local_ownership_enforced_apfs",
    "external_volume_rejected",
    "removable_volume_rejected",
    "network_volume_rejected",
    "ignore_ownership_volume_rejected",
    "cross_volume_destination_durable_before_source_destruction",
    "source_leaf_substitution",
    "hard_link_behavior",
    "writable_file_descriptor_behavior",
}
REQUIRED_PRIVILEGED_FILESYSTEM_CRASH_FACT_CASES = {
    "crash_at_every_durable_phase",
    "daemon_restart_and_idempotent_recovery",
    "manager_restart_and_idempotent_recovery",
    "terminal_outcome_retained_until_acknowledged",
    "acknowledgement_crash_cleanup_matrix",
    "caller_ledger_restart_and_scope_fencing",
    "broker_interruption_requires_transaction_recovery",
    "upgrade_unregister_reregister",
}
PRIVILEGED_FILESYSTEM_EVIDENCE_KINDS = {
    "context": {"p10-privileged-filesystem-qualification"},
    "case": {"p10-privileged-filesystem-qualification"},
    "formal": {"p10-privileged-filesystem-formal-argument"},
}
PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS = {
    "fixture",
    "placeholder",
    "unknown",
    "unset",
    "not-set",
    "not set",
}
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
MAXIMUM_QUALIFICATION_TIMESTAMP_BYTES = 128
MAXIMUM_QUALIFICATION_PROVENANCE_BYTES = 4096
MAXIMUM_QUALIFICATION_TRANSPORT_PATH_BYTES = 1024 * 1024
MAXIMUM_QUALIFICATION_TRANSPORT_PATHS = 10_000
MAXIMUM_QUALIFICATION_EVIDENCE_SECONDS = 24 * 60 * 60
MAXIMUM_P10_JSON_INPUT_BYTES = MAXIMUM_QUALIFICATION_ARTIFACT_BYTES
MAXIMUM_P10_JSON_AGGREGATE_BYTES = MAXIMUM_PRESERVED_ARTIFACT_BYTES
MAXIMUM_P10_EVIDENCE_AGGREGATE_BYTES = 512 * 1024 * 1024
MAXIMUM_P10_PARSED_STDOUT_BYTES = 16 * 1024 * 1024
failures: list[str] = []
P10_JSON_READ_BUDGET = BoundedReadBudget(
    MAXIMUM_P10_JSON_AGGREGATE_BYTES,
    "P10 JSON/control input",
)
P10_EVIDENCE_READ_BUDGET = BoundedReadBudget(
    MAXIMUM_P10_EVIDENCE_AGGREGATE_BYTES,
    "P10 evidence input",
)
P10_LOADED_INPUT_BYTES: dict[str, bytes] = {}


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def bounded_nonplaceholder_text(value: Any, label: str, *, maximum_bytes: int) -> str | None:
    if not isinstance(value, str) or not value.strip():
        failures.append(f"{label} is empty")
        return None
    try:
        encoded_size = len(value.encode("utf-8"))
    except UnicodeEncodeError:
        failures.append(f"{label} is not valid UTF-8 text")
        return None
    if encoded_size > maximum_bytes:
        failures.append(f"{label} exceeds {maximum_bytes} bytes")
        return None
    normalized = " ".join(value.strip().lower().replace("_", " ").split())
    if (
        normalized in PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS
        or "placeholder" in normalized
        or "not executed" in normalized
    ):
        failures.append(f"{label} is a placeholder")
        return None
    return value


def bounded_timestamp(value: Any, label: str) -> datetime | None:
    text_value = bounded_nonplaceholder_text(
        value,
        label,
        maximum_bytes=MAXIMUM_QUALIFICATION_TIMESTAMP_BYTES,
    )
    if text_value is None:
        return None
    normalized = text_value[:-1] + "+00:00" if text_value.endswith("Z") else text_value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        failures.append(f"{label} is not a valid ISO-8601 timestamp")
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        failures.append(f"{label} has no timezone")
        return None
    return parsed


def git_predicate(label: str, *arguments: str) -> bool:
    try:
        return_code, _, _ = run_bounded_readonly_command(
            ROOT,
            label,
            ["git", *arguments],
            timeout_seconds=10,
            maximum_output_bytes=MAXIMUM_QUALIFICATION_PROVENANCE_BYTES,
        )
    except EvidenceSupportError as error:
        failures.append(str(error))
        return False
    if return_code != 0:
        failures.append(label)
        return False
    return True


def git_manifest_worktree_clean(label: str) -> bool:
    try:
        return_code, stdout, _ = run_bounded_readonly_command(
            ROOT,
            label,
            [
                "git",
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--",
                *MANIFEST_TARGETS,
            ],
            timeout_seconds=10,
            maximum_output_bytes=MAXIMUM_QUALIFICATION_PROVENANCE_BYTES,
        )
    except EvidenceSupportError as error:
        failures.append(str(error))
        return False
    clean = return_code == 0 and not stdout.strip()
    if not clean:
        failures.append(label)
    return clean


def git_transport_paths_valid(
    reported_head: str,
    current_head: str,
    label: str,
) -> bool:
    try:
        return_code, stdout, _ = run_bounded_readonly_command(
            ROOT,
            label,
            [
                "git",
                "log",
                "-m",
                "--ancestry-path",
                "--format=",
                "--name-only",
                "--no-renames",
                "-z",
                f"{reported_head}..{current_head}",
            ],
            timeout_seconds=10,
            maximum_output_bytes=MAXIMUM_QUALIFICATION_TRANSPORT_PATH_BYTES,
        )
    except EvidenceSupportError as error:
        failures.append(str(error))
        return False
    if return_code != 0:
        failures.append(f"{label} command failed")
        return False
    try:
        paths = [
            value.decode("utf-8", errors="strict")
            for value in stdout.split(b"\0")
            if value
        ]
    except UnicodeDecodeError:
        failures.append(f"{label} contains a non-UTF-8 path")
        return False
    if len(paths) > MAXIMUM_QUALIFICATION_TRANSPORT_PATHS:
        failures.append(f"{label} exceeds its path-count bound")
        return False
    valid = True
    for path in paths:
        pure = pathlib.PurePosixPath(path)
        allowed = (
            not pure.is_absolute()
            and ".." not in pure.parts
            and len(path.encode("utf-8"))
            <= MAXIMUM_QUALIFICATION_PROVENANCE_BYTES
            and (
                pure.parts[:2] == (".forge-codex", "state")
                or pure.parts[:2] == (".forge-codex", "evidence")
            )
        )
        if not allowed:
            failures.append(f"{label}: {path}")
            valid = False
    return valid


def load(relative: str) -> dict[str, Any]:
    try:
        raw = read_bounded_repository_bytes(
            ROOT,
            relative,
            label=f"P10 input {relative}",
            maximum_bytes=MAXIMUM_P10_JSON_INPUT_BYTES,
            budget=P10_JSON_READ_BUDGET,
        )
        value = decode_strict_json_object(
            raw,
            label=f"P10 input {relative}",
        )
    except EvidenceSupportError as error:
        failures.append(f"cannot read P10 input {relative}: {error}")
        return {}
    P10_LOADED_INPUT_BYTES[relative] = raw
    return value


def schema_errors(
    document: dict[str, Any],
    schema_relative: str,
    label: str,
) -> list[Any]:
    if Draft202012Validator is None or FormatChecker is None:
        failures.append(
            f"{label} schema cannot be enforced because the jsonschema runtime is unavailable"
        )
        return [None]
    schema = load(schema_relative)
    if not schema:
        failures.append(f"{label} schema is unavailable")
        return [None]
    try:
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        errors = sorted(
            validator.iter_errors(document),
            key=lambda error: tuple(str(part) for part in error.absolute_path),
        )
    except Exception as error:
        failures.append(f"{label} schema validation failed closed: {error}")
        return [None]
    if errors:
        failures.append(f"{label} does not conform to its exact JSON schema")
        for error in errors[:12]:
            location = ".".join(str(part) for part in error.absolute_path) or "<root>"
            failures.append(f"{label} schema error at {location}: {error.message}")
        if len(errors) > 12:
            failures.append(
                f"{label} schema has {len(errors) - 12} additional validation errors"
            )
    return errors


def artifact_path(artifact: dict[str, Any], label: str) -> pathlib.Path | None:
    before = len(failures)
    raw_path = artifact.get("path")
    if not isinstance(raw_path, str) or not raw_path:
        failures.append(f"{label} artifact has no path")
        return None
    storage = artifact.get("storage")
    if storage not in {
        "evidence-id-specific-copy",
        "evidence-id-specific-stream",
        "external-hash-only",
    }:
        failures.append(f"{label} artifact storage is unsupported")
        return None
    expected_bytes = artifact.get("bytes")
    expected_hash = artifact.get("sha256")
    check(
        isinstance(expected_bytes, int)
        and not isinstance(expected_bytes, bool)
        and expected_bytes >= 0,
        f"{label} artifact byte count is invalid",
    )
    check(
        isinstance(expected_hash, str)
        and re.fullmatch(r"[0-9a-f]{64}", expected_hash) is not None,
        f"{label} artifact SHA-256 is invalid",
    )
    maximum_bytes = (
        MAXIMUM_EXTERNAL_ARTIFACT_BYTES
        if storage == "external-hash-only"
        else MAXIMUM_PRESERVED_ARTIFACT_BYTES
    )
    if isinstance(expected_bytes, int) and not isinstance(expected_bytes, bool):
        check(
            0 <= expected_bytes <= maximum_bytes,
            f"{label} artifact exceeds its {maximum_bytes}-byte storage bound",
        )
    if len(failures) != before:
        return None

    if storage == "external-hash-only":
        try:
            encoded_path = raw_path.encode("utf-8", errors="strict")
        except UnicodeEncodeError:
            failures.append(f"{label} external artifact path is invalid")
            return None
        if b"\0" in encoded_path or len(encoded_path) > MAXIMUM_QUALIFICATION_PROVENANCE_BYTES:
            failures.append(f"{label} external artifact path is invalid")
            return None
        path = pathlib.Path(raw_path)
        check(path.is_absolute(), f"{label} external artifact path is not absolute")
        check(
            artifact.get("portability") == "origin-host-required",
            f"{label} external artifact has no explicit portability policy",
        )
        if len(failures) != before:
            return None
        try:
            actual_hash, actual_bytes = sha256_bounded_regular_file(
                path,
                label=f"{label} artifact",
                maximum_bytes=maximum_bytes,
                budget=P10_EVIDENCE_READ_BUDGET,
            )
        except EvidenceSupportError as error:
            failures.append(f"{label} artifact cannot be verified: {error}")
            return None
        resolved = path
    else:
        try:
            raw = read_bounded_repository_bytes(
                ROOT,
                raw_path,
                label=f"{label} artifact",
                maximum_bytes=maximum_bytes,
                budget=P10_EVIDENCE_READ_BUDGET,
            )
        except EvidenceSupportError as error:
            failures.append(f"{label} artifact cannot be verified: {error}")
            return None
        actual_bytes = len(raw)
        actual_hash = hashlib.sha256(raw).hexdigest()
        resolved = ROOT / pathlib.PurePosixPath(raw_path)

    check(actual_bytes == expected_bytes, f"{label} artifact byte mismatch: {raw_path}")
    check(actual_hash == expected_hash, f"{label} artifact SHA-256 mismatch: {raw_path}")
    return resolved if len(failures) == before else None


CURRENT_MANIFEST = source_manifest(ROOT)
RUN_STATE = load(".forge-codex/state/run-state.json")
E2_ISSUE = next(
    (
        issue
        for issue in RUN_STATE.get("issues", [])
        if isinstance(issue, dict)
        and issue.get("id") == "FC-FILESYSTEM-PATH-TOCTOU-001"
    ),
    {},
)
LEDGER_EVIDENCE_IDS = {
    item for item in RUN_STATE.get("evidence", []) if isinstance(item, str)
}
QUALIFICATION_ARTIFACT_BINDINGS: dict[
    tuple[str, str, str], tuple[object, ...]
] = {}
QUALIFICATION_REPOSITORY_CONTEXT: dict[str, Any] = {}
QUALIFICATION_TEST_ENVIRONMENT_CONTEXT: dict[str, Any] = {}


def artifact_reference_valid(
    reference: Any,
    label: str,
    *,
    purpose: str,
    expected_scope: dict[str, Any],
    expected_fact: Any | None,
    required_capture_time: datetime | None = None,
) -> dict[str, Any] | None:
    before = len(failures)
    expected_kinds = PRIVILEGED_FILESYSTEM_EVIDENCE_KINDS.get(purpose)
    if expected_kinds is None:
        failures.append(f"{label} has an unsupported qualification purpose")
        return None
    if not isinstance(reference, dict) or set(reference) != {
        "evidence_id",
        "path",
        "sha256",
    }:
        failures.append(f"{label} is not an exact artifact reference")
        return None

    evidence_id = reference.get("evidence_id")
    raw_path = reference.get("path")
    expected_hash = reference.get("sha256")
    if not isinstance(evidence_id, str) or re.fullmatch(
        r"EVID-[A-Za-z0-9][A-Za-z0-9._-]{0,250}", evidence_id
    ) is None:
        failures.append(f"{label} evidence id is invalid")
    if not isinstance(raw_path, str) or not raw_path:
        failures.append(f"{label} path is invalid")
    if not isinstance(expected_hash, str) or re.fullmatch(
        r"[0-9a-f]{64}", expected_hash
    ) is None:
        failures.append(f"{label} SHA-256 is invalid")
    if len(failures) != before:
        return None

    record = load(f".forge-codex/evidence/{evidence_id}.json")
    if not record:
        failures.append(f"{label} evidence record is unavailable: {evidence_id}")
        return None
    check(record.get("schema_version") == 2, f"{label} evidence is not recorded schema v2")
    check(record.get("id") == evidence_id, f"{label} evidence id does not match its record")
    check(
        record.get("kind") in expected_kinds,
        f"{label} evidence kind is not bound to {purpose} qualification",
    )
    check(
        isinstance(record.get("command"), str) and bool(record["command"].strip()),
        f"{label} evidence has no recorded qualification command",
    )
    related_gates = record.get("related_gates")
    related_findings = record.get("related_findings")
    ledger_reference = record.get("ledger_reference")
    check(
        isinstance(related_gates, list) and "G10" in related_gates,
        f"{label} evidence is not bound to G10",
    )
    check(
        isinstance(related_findings, list)
        and "FC-FILESYSTEM-PATH-TOCTOU-001" in related_findings,
        f"{label} evidence is not bound to FC-FILESYSTEM-PATH-TOCTOU-001",
    )
    check(
        isinstance(ledger_reference, dict)
        and ledger_reference.get("status") == "recorded",
        f"{label} evidence is absent from the ledger",
    )
    check(evidence_id in LEDGER_EVIDENCE_IDS, f"{label} evidence id is not in current run-state")
    check(record.get("exit_code") == 0, f"{label} evidence command did not exit zero")
    check(record.get("timed_out") is False, f"{label} evidence command timed out")
    check(
        record.get("stream_limit_exceeded") is False,
        f"{label} evidence exceeded its stream limit",
    )
    check(
        record.get("artifact_capture_errors") == [],
        f"{label} evidence has artifact capture errors",
    )
    started_at = bounded_timestamp(
        record.get("started_at"),
        f"{label} evidence started_at",
    )
    ended_at = bounded_timestamp(
        record.get("ended_at"),
        f"{label} evidence ended_at",
    )
    if started_at is not None and ended_at is not None:
        check(started_at <= ended_at, f"{label} evidence timestamps are reversed")
        check(
            (ended_at - started_at).total_seconds()
            <= MAXIMUM_QUALIFICATION_EVIDENCE_SECONDS,
            f"{label} evidence interval exceeds its 24-hour bound",
        )
        if required_capture_time is not None:
            check(
                started_at <= required_capture_time <= ended_at,
                f"{label} does not contain the report captured_at timestamp",
            )
    expected_environment = {
        "platform": QUALIFICATION_TEST_ENVIRONMENT_CONTEXT.get("platform"),
        "architecture": QUALIFICATION_TEST_ENVIRONMENT_CONTEXT.get("architecture"),
        "macos_build": QUALIFICATION_TEST_ENVIRONMENT_CONTEXT.get("macos_build"),
        "machine_identifier": QUALIFICATION_TEST_ENVIRONMENT_CONTEXT.get(
            "machine_identifier"
        ),
        "cwd": QUALIFICATION_REPOSITORY_CONTEXT.get("repository_path"),
    }
    environment = record.get("environment")
    check(
        isinstance(environment, dict) and set(environment) == set(expected_environment),
        f"{label} evidence environment field set is not exact",
    )
    if isinstance(environment, dict):
        for field, maximum_bytes in (
            ("platform", MAXIMUM_QUALIFICATION_PROVENANCE_BYTES),
            ("architecture", 256),
            ("macos_build", 256),
            ("machine_identifier", 256),
            ("cwd", MAXIMUM_QUALIFICATION_PROVENANCE_BYTES),
        ):
            bounded_nonplaceholder_text(
                environment.get(field),
                f"{label} evidence {field}",
                maximum_bytes=maximum_bytes,
            )
        check(
            environment == expected_environment,
            f"{label} evidence environment does not match the evaluator host and repository",
        )
    check(
        record.get("source_manifest_changed") is False,
        f"{label} evidence changed source during capture",
    )
    check(
        record.get("source_manifest") == CURRENT_MANIFEST,
        f"{label} evidence is stale for the current source manifest",
    )
    check(
        record.get("source_manifest_after") == CURRENT_MANIFEST,
        f"{label} ending source manifest is stale",
    )
    check(
        record.get("child_evidence_context")
        == {
            "schema_version": EVIDENCE_CONTEXT_SCHEMA_VERSION,
            "binding_schema_version": QUALIFICATION_ARTIFACT_BINDING_SCHEMA_VERSION,
            "evidence_id": evidence_id,
            "source_manifest": CURRENT_MANIFEST,
            "repository": QUALIFICATION_REPOSITORY_CONTEXT,
            "test_environment": QUALIFICATION_TEST_ENVIRONMENT_CONTEXT,
            "qualification": "p10-privileged-filesystem",
        },
        f"{label} evidence record has no exact recorder-owned child context",
    )
    check(
        record.get("execution_provenance")
        == {
            "repository": QUALIFICATION_REPOSITORY_CONTEXT,
            "test_environment": QUALIFICATION_TEST_ENVIRONMENT_CONTEXT,
        },
        f"{label} evidence record has no exact recorder-owned execution provenance",
    )

    artifacts = record.get("artifacts")
    matches = (
        [
            artifact
            for artifact in artifacts
            if isinstance(artifact, dict)
            and artifact.get("path") == raw_path
            and artifact.get("sha256") == expected_hash
        ]
        if isinstance(artifacts, list)
        else []
    )
    check(
        len(matches) == 1,
        f"{label} does not identify exactly one artifact in its evidence record",
    )
    binding_artifact: dict[str, Any] | None = None
    if len(matches) == 1:
        matched_artifact = matches[0]
        expected_path_pattern = re.compile(
            rf"^\.forge-codex/evidence/{re.escape(evidence_id)}"
            r"\.artifact-[0-9]{3}-[^/]+$"
        )
        source_path = matched_artifact.get("source_path")
        raw_path_parts = (
            pathlib.PurePosixPath(raw_path).parts
            if isinstance(raw_path, str)
            else ()
        )
        try:
            raw_path_size = (
                len(raw_path.encode("utf-8")) if isinstance(raw_path, str) else None
            )
        except UnicodeEncodeError:
            raw_path_size = None
        canonical_raw_path = (
            isinstance(raw_path, str)
            and bool(raw_path)
            and raw_path_size is not None
            and raw_path_size <= MAXIMUM_QUALIFICATION_PROVENANCE_BYTES
            and "\\" not in raw_path
            and not pathlib.PurePosixPath(raw_path).is_absolute()
            and pathlib.PurePosixPath(raw_path).as_posix() == raw_path
            and all(part not in {"", ".", ".."} for part in raw_path_parts)
        )
        source_path_parts = (
            pathlib.PurePosixPath(source_path).parts
            if isinstance(source_path, str)
            else ()
        )
        try:
            source_path_size = (
                len(source_path.encode("utf-8"))
                if isinstance(source_path, str)
                else None
            )
        except UnicodeEncodeError:
            source_path_size = None
        canonical_source_path = (
            isinstance(source_path, str)
            and bool(source_path)
            and source_path_size is not None
            and source_path_size <= MAXIMUM_QUALIFICATION_PROVENANCE_BYTES
            and "\\" not in source_path
            and not pathlib.PurePosixPath(source_path).is_absolute()
            and pathlib.PurePosixPath(source_path).as_posix() == source_path
            and all(part not in {"", ".", ".."} for part in source_path_parts)
        )
        recorder_copy = (
            set(matched_artifact)
            == {"path", "source_path", "sha256", "bytes", "storage"}
            and matched_artifact.get("storage") == "evidence-id-specific-copy"
            and canonical_raw_path
            and expected_path_pattern.fullmatch(raw_path) is not None
            and canonical_source_path
        )
        check(
            recorder_copy,
            f"{label} semantic artifact is not a recorder-preserved "
            "evidence-id-specific copy inside the repository",
        )
        if recorder_copy:
            resolved_artifact = ROOT / raw_path
            check(
                resolved_artifact.suffix.lower() == ".json",
                f"{label} semantic artifact is not JSON",
            )
            try:
                binding_artifact = load_qualification_artifact(
                    resolved_artifact,
                    expected_sha256=expected_hash,
                    expected_bytes=matched_artifact.get("bytes"),
                    repository_root=ROOT,
                    schema_path=QUALIFICATION_ARTIFACT_SCHEMA,
                    artifact_budget=P10_EVIDENCE_READ_BUDGET,
                    schema_budget=P10_JSON_READ_BUDGET,
                )
            except EvidenceSupportError as error:
                failures.append(f"{label} semantic artifact is invalid: {error}")

    if binding_artifact is not None:
        check(
            binding_artifact.get("evidence_id") == evidence_id,
            f"{label} semantic artifact evidence id does not match its record",
        )
        check(
            binding_artifact.get("source_manifest") == CURRENT_MANIFEST,
            f"{label} semantic artifact is stale for the current source manifest",
        )
        scope = binding_artifact.get("scope")
        if not isinstance(scope, dict):
            failures.append(f"{label} semantic artifact has no exact scope")
        else:
            allowed_scope_keys = {
                "case_id",
                "role",
                "iteration",
                "subject",
                "predicate",
            }
            if not set(expected_scope) <= allowed_scope_keys:
                failures.append(f"{label} evaluator requested an invalid semantic scope")
            for field, expected in expected_scope.items():
                check(
                    scope.get(field) == expected,
                    f"{label} semantic artifact does not bind {field}={expected!r}",
                )

            scope_order = (
                "case_id",
                "role",
                "iteration",
                "subject",
                "predicate",
            )
            semantic_use = tuple(
                expected_scope.get(field, scope.get(field)) for field in scope_order
            )
            reference_key = (evidence_id, raw_path, expected_hash)
            prior_use = QUALIFICATION_ARTIFACT_BINDINGS.get(reference_key)
            if prior_use is not None and prior_use != semantic_use:
                failures.append(
                    f"{label} artifact is reused across case or role scopes"
                )
            else:
                QUALIFICATION_ARTIFACT_BINDINGS[reference_key] = semantic_use

        if expected_fact is not None:
            try:
                expected_fact_hash = canonical_json_sha256(expected_fact)
            except EvidenceSupportError as error:
                failures.append(f"{label} expected fact is invalid: {error}")
            else:
                check(
                    binding_artifact.get("fact_sha256") == expected_fact_hash,
                    f"{label} semantic artifact does not bind the exact report fact",
                )

    valid = len(failures) == before
    return binding_artifact if valid else None


def evidence_record(
    evidence_id: Any,
    label: str,
    *,
    expected_kinds: set[str],
    command_fragments: tuple[str, ...],
    require_success: bool = True,
) -> dict[str, Any]:
    if not isinstance(evidence_id, str) or re.fullmatch(
        r"EVID-[A-Za-z0-9][A-Za-z0-9._-]{0,250}", evidence_id
    ) is None:
        failures.append(f"{label} has no evidence id")
        return {}
    record = load(f".forge-codex/evidence/{evidence_id}.json")
    check(record.get("schema_version") == 2, f"{label} evidence is not recorded schema v2: {evidence_id}")
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
            declared_bytes = artifact.get("bytes")
            if (
                not isinstance(declared_bytes, int)
                or isinstance(declared_bytes, bool)
                or declared_bytes < 0
                or declared_bytes > MAXIMUM_P10_PARSED_STDOUT_BYTES
            ):
                failures.append(f"{label} stdout exceeds parsing bound")
                return ""
            path = artifact_path(artifact, f"{label} stdout")
            if path is not None:
                try:
                    relative = pathlib.PurePosixPath(path.relative_to(ROOT).as_posix())
                    raw = read_bounded_repository_bytes(
                        ROOT,
                        relative,
                        label=f"{label} stdout",
                        maximum_bytes=MAXIMUM_P10_PARSED_STDOUT_BYTES,
                        budget=P10_EVIDENCE_READ_BUDGET,
                    )
                    if (
                        len(raw) != declared_bytes
                        or hashlib.sha256(raw).hexdigest() != artifact.get("sha256")
                    ):
                        failures.append(
                            f"{label} stdout changed after artifact verification"
                        )
                        return ""
                    return raw.decode("utf-8", errors="replace")
                except (EvidenceSupportError, ValueError) as error:
                    failures.append(f"{label} stdout cannot be read: {error}")
                    return ""
    failures.append(f"{label} evidence has no stdout artifact")
    return ""


def preserved_report(record: dict[str, Any], relative: str, label: str) -> None:
    raw = P10_LOADED_INPUT_BYTES.get(relative)
    if raw is None:
        failures.append(
            f"{label} report has no exact bounded input snapshot: {relative}"
        )
        return
    expected = (len(raw), hashlib.sha256(raw).hexdigest())
    matches = []
    for artifact in record.get("artifacts", []):
        if not isinstance(artifact, dict) or artifact.get("storage") != "evidence-id-specific-copy":
            continue
        if artifact.get("source_path") == relative and (artifact.get("bytes"), artifact.get("sha256")) == expected:
            matches.append(artifact)
    check(bool(matches), f"{label} report is not preserved by evidence-specific copy")


def manifest_report(report: dict[str, Any], label: str) -> None:
    check(report.get("source_manifest") == CURRENT_MANIFEST, f"{label} report is stale for the current source manifest")


CURRENT_GIT_HEAD = current_git_head(ROOT)
if CURRENT_GIT_HEAD is None:
    failures.append("P10 current Git HEAD is unavailable")
P10_FEATURE_EVALUATION = evaluate_p10_feature_evidence(
    ROOT,
    current_manifest=CURRENT_MANIFEST,
    current_git_head=CURRENT_GIT_HEAD or "",
    ledger_evidence_ids=LEDGER_EVIDENCE_IDS,
)
baseline = P10_FEATURE_EVALUATION.baseline
features = baseline.get("features") if isinstance(baseline, dict) else None
failures.extend(P10_FEATURE_EVALUATION.failures)

try:
    project = read_bounded_repository_bytes(
        ROOT,
        "ForgeConductor.xcodeproj/project.pbxproj",
        label="Xcode project",
        maximum_bytes=MAXIMUM_MANIFEST_FILE_BYTES,
    ).decode("utf-8", errors="strict")
except (EvidenceSupportError, UnicodeError) as error:
    failures.append(f"Xcode project cannot be read: {error}")
    project = ""
for source in (
    "ContinuityCoordinator.swift",
    "ForgeNativeSessionHostPlugin.swift",
    "MetalGaugeResources.swift",
    "ProjectMemoryRepository.swift",
    "RuntimeJobRepository.swift",
    "VerifiedMigrationBackup.swift",
    "FilesystemQuarantineLedger.swift",
    "ForgeFilesystemProtocol.swift",
    "SecureFilesystemService.swift",
    "SecureFilesystemRecoveryLedger.swift",
    "PrivilegedLeafDeleteEngine.swift",
    "ForgeFilesystemProtocolTests.swift",
    "SecureFilesystemMutationTests.swift",
    "ProjectContextIntegrationTests.swift",
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
privileged_filesystem = load(
    ".forge-codex/evidence/P10-privileged-filesystem-qualification-report.json"
)
privileged_filesystem_schema_errors = schema_errors(
    privileged_filesystem,
    ".forge-codex/schemas/p10-privileged-filesystem-qualification-report.schema.json",
    "privileged filesystem qualification",
)
check(
    privileged_filesystem.get("artifact_binding_schema_version")
    == QUALIFICATION_ARTIFACT_BINDING_SCHEMA_VERSION,
    "privileged filesystem qualification artifact binding schema is unsupported",
)
PRIVILEGED_FILESYSTEM_SCHEMA_INVALID_CASES = {
    str(path[1])
    for error in privileged_filesystem_schema_errors
    if error is not None
    for path in [list(error.absolute_path)]
    if len(path) >= 2 and path[0] == "matrix"
}

privileged_filesystem_passed = (
    privileged_filesystem.get("status") == "passed"
    and privileged_filesystem.get("ok") is True
)
check(
    privileged_filesystem_passed,
    "privileged filesystem qualification is not passed",
)
check(
    privileged_filesystem.get("source_manifest") == CURRENT_MANIFEST,
    "privileged filesystem qualification is stale for the current source manifest",
)
if privileged_filesystem_passed:
    captured_at = bounded_timestamp(
        privileged_filesystem.get("captured_at"),
        "privileged filesystem qualification captured_at",
    )
    repository = privileged_filesystem.get("repository")
    if not isinstance(repository, dict) or set(repository) != {
        "branch",
        "head_sha",
        "base_branch",
        "base_sha",
        "repository_path",
    }:
        failures.append(
            "privileged filesystem qualification repository identity is not exact"
        )
        repository = {}
    report_branch = bounded_nonplaceholder_text(
        repository.get("branch"),
        "privileged filesystem qualification repository branch",
        maximum_bytes=256,
    )
    report_head = repository.get("head_sha")
    check(
        isinstance(report_head, str)
        and re.fullmatch(r"[0-9a-f]{40}", report_head) is not None,
        "privileged filesystem qualification repository HEAD is invalid",
    )
    report_base = bounded_nonplaceholder_text(
        repository.get("base_branch"),
        "privileged filesystem qualification repository base branch",
        maximum_bytes=256,
    )
    check(
        report_base == "main",
        "privileged filesystem qualification base branch is not canonical main",
    )
    report_base_sha = repository.get("base_sha")
    check(
        isinstance(report_base_sha, str)
        and re.fullmatch(r"[0-9a-f]{40}", report_base_sha) is not None,
        "privileged filesystem qualification repository base SHA is invalid",
    )
    report_repository_path = bounded_nonplaceholder_text(
        repository.get("repository_path"),
        "privileged filesystem qualification repository path",
        maximum_bytes=MAXIMUM_QUALIFICATION_PROVENANCE_BYTES,
    )
    check(
        report_repository_path == str(ROOT),
        "privileged filesystem qualification repository path does not match the evaluator repository",
    )

    test_environment = privileged_filesystem.get("test_environment")
    if not isinstance(test_environment, dict) or set(test_environment) != {
        "macos_build",
        "machine_identifier",
        "platform",
        "architecture",
    }:
        failures.append(
            "privileged filesystem qualification test environment is not exact"
        )
        test_environment = {}
    for field, display_name in (
        ("macos_build", "macOS build"),
        ("machine_identifier", "machine identifier"),
        ("platform", "platform"),
        ("architecture", "architecture"),
    ):
        bounded_nonplaceholder_text(
            test_environment.get(field),
            f"privileged filesystem qualification {display_name}",
            maximum_bytes=MAXIMUM_QUALIFICATION_PROVENANCE_BYTES,
        )

    QUALIFICATION_REPOSITORY_CONTEXT = repository
    QUALIFICATION_TEST_ENVIRONMENT_CONTEXT = test_environment
    try:
        live_provenance = execution_provenance(ROOT)
    except EvidenceSupportError as error:
        failures.append(
            "privileged filesystem evaluator provenance is unavailable: "
            f"{error}"
        )
        live_repository: dict[str, Any] = {}
        live_test_environment: dict[str, Any] = {}
    else:
        live_repository = live_provenance["repository"]
        live_test_environment = live_provenance["test_environment"]
    check(
        report_branch is not None
        and report_branch == live_repository.get("branch"),
        "privileged filesystem qualification repository branch does not match current Git",
    )
    check(
        report_base == live_repository.get("base_branch"),
        "privileged filesystem qualification base branch does not match current Git",
    )
    check(
        report_base_sha == live_repository.get("base_sha"),
        "privileged filesystem qualification base SHA does not match refs/remotes/origin/main",
    )
    check(
        report_repository_path == live_repository.get("repository_path"),
        "privileged filesystem qualification repository path does not match current Git",
    )
    check(
        test_environment == live_test_environment,
        "privileged filesystem qualification test environment does not match the evaluator host",
    )
    current_head = live_repository.get("head_sha")
    if (
        isinstance(report_head, str)
        and re.fullmatch(r"[0-9a-f]{40}", report_head)
        and isinstance(report_base_sha, str)
        and re.fullmatch(r"[0-9a-f]{40}", report_base_sha)
    ):
        git_predicate(
            "privileged filesystem qualification reported execution HEAD does not resolve",
            "cat-file",
            "-e",
            f"{report_head}^{{commit}}",
        )
        git_predicate(
            "privileged filesystem qualification origin main is not an ancestor of "
            "the reported execution HEAD",
            "merge-base",
            "--is-ancestor",
            report_base_sha,
            report_head,
        )
        if isinstance(current_head, str):
            git_predicate(
                "privileged filesystem qualification reported execution HEAD is not "
                "an ancestor of current Git HEAD",
                "merge-base",
                "--is-ancestor",
                report_head,
                current_head,
            )
            git_transport_paths_valid(
                report_head,
                current_head,
                "privileged filesystem qualification committed transport changed "
                "a non-state/non-evidence path",
            )
    git_manifest_worktree_clean(
        "privileged filesystem manifest targets have uncommitted changes"
    )

    qualification_context_fact = {
        "captured_at": privileged_filesystem.get("captured_at"),
        "repository": privileged_filesystem.get("repository"),
        "test_environment": privileged_filesystem.get("test_environment"),
        "test_processes": privileged_filesystem.get("test_processes"),
        "same_uid_fallback": privileged_filesystem.get("same_uid_fallback"),
        "same_uid_threat_model": privileged_filesystem.get("same_uid_threat_model"),
    }
    artifact_reference_valid(
        privileged_filesystem.get("qualification_context_artifact_reference"),
        "privileged filesystem qualification context artifact",
        purpose="context",
        expected_scope={
            "case_id": None,
            "role": "qualification_context",
            "iteration": None,
            "subject": None,
            "predicate": None,
        },
        expected_fact=qualification_context_fact,
        required_capture_time=captured_at,
    )
matrix = privileged_filesystem.get("matrix", {})
check(isinstance(matrix, dict), "privileged filesystem qualification has no matrix")
if isinstance(matrix, dict):
    check(
        set(matrix) == REQUIRED_PRIVILEGED_FILESYSTEM_MATRIX,
        "privileged filesystem qualification matrix key set is not exact",
    )

    def structured_passing_case(name: str, value: object) -> bool:
        if not isinstance(value, dict):
            return False
        if name in PRIVILEGED_FILESYSTEM_SCHEMA_INVALID_CASES:
            return False
        if set(value) != REQUIRED_PRIVILEGED_FILESYSTEM_CASE_FIELDS:
            return False
        contracts = value.get("contracts_exercised")
        if not isinstance(contracts, list) or not contracts:
            return False
        if any(not isinstance(contract, str) for contract in contracts):
            return False
        if len(contracts) != len(set(contracts)):
            return False
        contract_set = set(contracts)
        if not contract_set <= PRIVILEGED_FILESYSTEM_CONTRACTS:
            return False
        if not REQUIRED_PRIVILEGED_FILESYSTEM_CONTRACT_SUBSETS.get(name, set()) <= contract_set:
            return False
        if value.get("status") != "passed":
            return False
        artifacts = value.get("raw_artifact_references")
        iterations = value.get("iterations")
        barriers = value.get("barrier_evidence")
        processes = value.get("process_identities")
        signing = value.get("signing_identities")
        fixtures = value.get("fixture_digests")
        mount_facts = value.get("mount_facts")
        crash_point = value.get("crash_point")
        observed = value.get("observed_result")
        structurally_complete = (
            isinstance(artifacts, list)
            and bool(artifacts)
            and isinstance(iterations, dict)
            and isinstance(iterations.get("planned"), int)
            and not isinstance(iterations.get("planned"), bool)
            and isinstance(iterations.get("executed"), int)
            and not isinstance(iterations.get("executed"), bool)
            and iterations["executed"] > 0
            and isinstance(iterations.get("conclusive"), int)
            and not isinstance(iterations.get("conclusive"), bool)
            and iterations["conclusive"] > 0
            and isinstance(barriers, list)
            and bool(barriers)
            and isinstance(processes, list)
            and bool(processes)
            and isinstance(signing, list)
            and bool(signing)
            and isinstance(fixtures, dict)
            and isinstance(fixtures.get("before"), list)
            and bool(fixtures["before"])
            and isinstance(fixtures.get("after"), list)
            and bool(fixtures["after"])
            and isinstance(mount_facts, dict)
            and isinstance(mount_facts.get("applicable"), bool)
            and isinstance(crash_point, dict)
            and isinstance(crash_point.get("applicable"), bool)
            and isinstance(observed, str)
            and bool(observed.strip())
        )
        if not structurally_complete:
            return False

        valid = True

        def require(condition: bool, message: str) -> None:
            nonlocal valid
            if not condition:
                valid = False
                failures.append(message)

        planned = iterations["planned"]
        executed = iterations["executed"]
        conclusive = iterations["conclusive"]
        require(
            planned >= executed >= conclusive,
            f"privileged filesystem case {name} has inconsistent iteration counts",
        )

        reached_barriers = [
            barrier
            for barrier in barriers
            if isinstance(barrier, dict) and barrier.get("status") == "reached"
        ]
        missed_barriers = [
            barrier
            for barrier in barriers
            if isinstance(barrier, dict) and barrier.get("status") == "missed"
        ]
        require(
            bool(reached_barriers),
            f"privileged filesystem case {name} has no reached execution barrier",
        )
        require(
            iterations.get("barrier_hits") == len(reached_barriers)
            and iterations.get("barrier_misses") == len(missed_barriers),
            f"privileged filesystem case {name} barrier counts do not match observations",
        )
        barrier_keys: set[tuple[str, int]] = set()
        for index, barrier in enumerate(barriers):
            if not isinstance(barrier, dict):
                valid = False
                continue
            barrier_name = barrier.get("name")
            barrier_iteration = barrier.get("iteration")
            require(
                isinstance(barrier_name, str)
                and bool(barrier_name.strip())
                and barrier_name.strip().lower()
                not in PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS,
                f"privileged filesystem case {name} barrier {index} has a placeholder name",
            )
            require(
                isinstance(barrier_iteration, int)
                and not isinstance(barrier_iteration, bool)
                and 1 <= barrier_iteration <= executed,
                f"privileged filesystem case {name} barrier {index} has an invalid iteration",
            )
            if isinstance(barrier_name, str) and isinstance(barrier_iteration, int):
                barrier_key = (barrier_name, barrier_iteration)
                require(
                    barrier_key not in barrier_keys,
                    f"privileged filesystem case {name} has duplicate barrier evidence",
                )
                barrier_keys.add(barrier_key)
            if barrier.get("status") == "reached":
                require(
                    isinstance(barrier.get("monotonic_timestamp_ns"), int)
                    and not isinstance(barrier.get("monotonic_timestamp_ns"), bool)
                    and barrier["monotonic_timestamp_ns"] > 0,
                    f"privileged filesystem case {name} barrier {index} has no timestamp",
                )
                if not artifact_reference_valid(
                    barrier.get("raw_artifact_reference"),
                    f"privileged filesystem case {name} barrier {index} artifact",
                    purpose="case",
                    expected_scope={
                        "case_id": name,
                        "role": "barrier",
                        "iteration": barrier_iteration,
                        "subject": barrier_name,
                        "predicate": None,
                    },
                    expected_fact={
                        key: item
                        for key, item in barrier.items()
                        if key != "raw_artifact_reference"
                    },
                ):
                    valid = False
            elif barrier.get("raw_artifact_reference") is not None:
                if not artifact_reference_valid(
                    barrier.get("raw_artifact_reference"),
                    f"privileged filesystem case {name} barrier {index} artifact",
                    purpose="case",
                    expected_scope={
                        "case_id": name,
                        "role": "barrier",
                        "iteration": barrier_iteration,
                        "subject": barrier_name,
                        "predicate": None,
                    },
                    expected_fact={
                        key: item
                        for key, item in barrier.items()
                        if key != "raw_artifact_reference"
                    },
                ):
                    valid = False

        require(
            len(artifacts) == executed,
            f"privileged filesystem case {name} does not bind every executed iteration",
        )
        case_result_fact = {
            "contracts_exercised": contracts,
            "status": value.get("status"),
            "iterations": iterations,
            "observed_result": observed,
        }
        for index, reference in enumerate(artifacts, start=1):
            if not artifact_reference_valid(
                reference,
                f"privileged filesystem case {name} raw artifact {index - 1}",
                purpose="case",
                expected_scope={
                    "case_id": name,
                    "role": "case_result",
                    "iteration": index,
                    "subject": None,
                    "predicate": None,
                },
                expected_fact=case_result_fact,
            ):
                valid = False

        process_roles: set[str] = set()
        root_process_roles: set[str] = set()
        for index, process in enumerate(processes):
            if not isinstance(process, dict):
                valid = False
                continue
            role = process.get("role")
            executable = process.get("executable_path")
            role_valid = (
                isinstance(role, str)
                and bool(role.strip())
                and role.strip().lower()
                not in PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS
            )
            require(
                role_valid,
                f"privileged filesystem case {name} process {index} has a placeholder role",
            )
            require(
                isinstance(process.get("pid"), int)
                and not isinstance(process.get("pid"), bool)
                and process["pid"] > 0
                and isinstance(process.get("effective_uid"), int)
                and not isinstance(process.get("effective_uid"), bool)
                and process["effective_uid"] >= 0,
                f"privileged filesystem case {name} process {index} identity is incomplete",
            )
            require(
                isinstance(executable, str)
                and pathlib.Path(executable).is_absolute()
                and pathlib.Path(executable).is_file()
                and not any(
                    term in executable.lower()
                    for term in PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS
                ),
                f"privileged filesystem case {name} process {index} executable is unavailable",
            )
            if not artifact_reference_valid(
                process.get("raw_artifact_reference"),
                f"privileged filesystem case {name} process {index} artifact",
                purpose="case",
                expected_scope={
                    "case_id": name,
                    "role": "process_identity",
                    "iteration": None,
                    "subject": role,
                    "predicate": None,
                },
                expected_fact={
                    key: item
                    for key, item in process.items()
                    if key != "raw_artifact_reference"
                },
            ):
                valid = False
            if role_valid:
                require(
                    role not in process_roles,
                    f"privileged filesystem case {name} has duplicate process roles",
                )
                process_roles.add(role)
                if process.get("effective_uid") == 0:
                    root_process_roles.add(role)

        signing_roles: set[str] = set()
        for index, identity in enumerate(signing):
            if not isinstance(identity, dict):
                valid = False
                continue
            role = identity.get("role")
            certificate = identity.get("certificate_common_name")
            team = identity.get("team_identifier")
            signing_identifier = identity.get("signing_identifier")
            code_hash = identity.get("code_directory_hash")
            requirement = identity.get("designated_requirement")
            text_fields = (role, certificate, team, signing_identifier, requirement)
            require(
                all(isinstance(field, str) and bool(field.strip()) for field in text_fields)
                and not any(
                    term in field.lower()
                    for field in text_fields
                    if isinstance(field, str)
                    for term in PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS
                )
                and isinstance(team, str)
                and re.fullmatch(r"[A-Z0-9]{10}", team) is not None
                and isinstance(code_hash, str)
                and re.fullmatch(r"[0-9a-fA-F]{40,64}", code_hash) is not None
                and len(set(code_hash.lower())) > 1
                and isinstance(signing_identifier, str)
                and isinstance(requirement, str)
                and signing_identifier in requirement,
                f"privileged filesystem case {name} signing identity {index} is incomplete",
            )
            if not artifact_reference_valid(
                identity.get("raw_artifact_reference"),
                f"privileged filesystem case {name} signing identity {index} artifact",
                purpose="case",
                expected_scope={
                    "case_id": name,
                    "role": "signing_identity",
                    "iteration": None,
                    "subject": role,
                    "predicate": None,
                },
                expected_fact={
                    key: item
                    for key, item in identity.items()
                    if key != "raw_artifact_reference"
                },
            ):
                valid = False
            if isinstance(role, str) and bool(role.strip()):
                require(
                    role not in signing_roles,
                    f"privileged filesystem case {name} has duplicate signing roles",
                )
                signing_roles.add(role)
        require(
            bool(process_roles & signing_roles),
            f"privileged filesystem case {name} does not bind a process to signing facts",
        )
        require(
            bool(root_process_roles & signing_roles),
            f"privileged filesystem case {name} does not bind a root helper to signing facts",
        )

        before_labels: list[str] = []
        after_labels: list[str] = []
        for phase in ("before", "after"):
            labels = before_labels if phase == "before" else after_labels
            for index, fixture in enumerate(fixtures[phase]):
                if not isinstance(fixture, dict):
                    valid = False
                    continue
                fixture_label = fixture.get("label")
                require(
                    isinstance(fixture_label, str)
                    and bool(fixture_label.strip())
                    and fixture_label.strip().lower()
                    not in PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS,
                    f"privileged filesystem case {name} {phase} fixture {index} has a placeholder label",
                )
                if isinstance(fixture_label, str):
                    labels.append(fixture_label)
                if fixture.get("present") is True:
                    require(
                        isinstance(fixture.get("device"), int)
                        and not isinstance(fixture.get("device"), bool)
                        and fixture["device"] >= 0
                        and isinstance(fixture.get("inode"), int)
                        and not isinstance(fixture.get("inode"), bool)
                        and fixture["inode"] > 0
                        and isinstance(fixture.get("entry_type"), str)
                        and bool(fixture["entry_type"].strip())
                        and isinstance(fixture.get("sha256"), str)
                        and re.fullmatch(r"[0-9a-f]{64}", fixture["sha256"])
                        is not None
                        and len(set(fixture["sha256"])) > 1
                        and isinstance(fixture.get("acl_sha256"), str)
                        and re.fullmatch(r"[0-9a-f]{64}", fixture["acl_sha256"])
                        is not None
                        and len(set(fixture["acl_sha256"])) > 1
                        and isinstance(fixture.get("bsd_flags"), int)
                        and not isinstance(fixture.get("bsd_flags"), bool)
                        and fixture["bsd_flags"] >= 0,
                        f"privileged filesystem case {name} {phase} fixture {index} identity is incomplete",
                    )
                if not artifact_reference_valid(
                    fixture.get("raw_artifact_reference"),
                    f"privileged filesystem case {name} {phase} fixture {index} artifact",
                    purpose="case",
                    expected_scope={
                        "case_id": name,
                        "role": f"fixture_{phase}",
                        "iteration": None,
                        "subject": fixture_label,
                        "predicate": None,
                    },
                    expected_fact={
                        key: item
                        for key, item in fixture.items()
                        if key != "raw_artifact_reference"
                    },
                ):
                    valid = False
        require(
            len(before_labels) == len(set(before_labels))
            and len(after_labels) == len(set(after_labels))
            and set(before_labels) == set(after_labels),
            f"privileged filesystem case {name} before/after fixture labels do not match",
        )
        require(
            any(
                isinstance(fixture, dict) and fixture.get("present") is True
                for fixture in fixtures["before"]
            ),
            f"privileged filesystem case {name} has no present pre-operation fixture",
        )

        mount_required = name in REQUIRED_PRIVILEGED_FILESYSTEM_MOUNT_FACT_CASES
        require(
            not mount_required or mount_facts.get("applicable") is True,
            f"privileged filesystem case {name} requires applicable mount facts",
        )
        if mount_facts.get("applicable") is True:
            require(
                all(
                    isinstance(mount_facts.get(field), str)
                    and bool(mount_facts[field].strip())
                    for field in (
                        "filesystem_type",
                        "mount_path",
                        "device_identifier",
                        "volume_uuid",
                    )
                )
                and isinstance(mount_facts.get("mount_flags"), list)
                and bool(mount_facts["mount_flags"])
                and all(
                    isinstance(flag, str)
                    and bool(flag.strip())
                    and flag.strip().lower()
                    not in PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS
                    for flag in mount_facts["mount_flags"]
                )
                and len(mount_facts["mount_flags"])
                == len(set(mount_facts["mount_flags"]))
                and all(
                    isinstance(mount_facts.get(field), bool)
                    for field in ("local", "removable", "network", "ownership_enabled")
                ),
                f"privileged filesystem case {name} mount facts are incomplete",
            )
            if not artifact_reference_valid(
                mount_facts.get("raw_artifact_reference"),
                f"privileged filesystem case {name} mount artifact",
                purpose="case",
                expected_scope={
                    "case_id": name,
                    "role": "mount",
                    "iteration": None,
                    "subject": None,
                    "predicate": None,
                },
                expected_fact={
                    key: item
                    for key, item in mount_facts.items()
                    if key != "raw_artifact_reference"
                },
            ):
                valid = False
            if name == "local_ownership_enforced_apfs":
                require(
                    isinstance(mount_facts.get("filesystem_type"), str)
                    and mount_facts["filesystem_type"].lower() == "apfs"
                    and mount_facts.get("local") is True
                    and mount_facts.get("removable") is False
                    and mount_facts.get("network") is False
                    and mount_facts.get("ownership_enabled") is True,
                    f"privileged filesystem case {name} mount classification is inconsistent",
                )
            elif name == "network_volume_rejected":
                require(
                    mount_facts.get("network") is True,
                    f"privileged filesystem case {name} does not identify a network volume",
                )
            elif name == "removable_volume_rejected":
                require(
                    mount_facts.get("removable") is True,
                    f"privileged filesystem case {name} does not identify removable media",
                )
            elif name == "ignore_ownership_volume_rejected":
                require(
                    mount_facts.get("ownership_enabled") is False,
                    f"privileged filesystem case {name} does not identify disabled ownership",
                )

        crash_required = name in REQUIRED_PRIVILEGED_FILESYSTEM_CRASH_FACT_CASES
        require(
            not crash_required or crash_point.get("applicable") is True,
            f"privileged filesystem case {name} requires applicable crash facts",
        )
        if crash_point.get("applicable") is True:
            require(
                isinstance(crash_point.get("phase"), str)
                and bool(crash_point["phase"].strip())
                and crash_point.get("timing") in {"before", "during", "after"}
                and isinstance(crash_point.get("signal"), str)
                and bool(crash_point["signal"].strip())
                and crash_point["phase"].strip().lower()
                not in PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS
                and crash_point["signal"].strip().lower()
                not in PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS
                and crash_point.get("restart_observed") is True,
                f"privileged filesystem case {name} crash facts are incomplete",
            )
            if not artifact_reference_valid(
                crash_point.get("raw_artifact_reference"),
                f"privileged filesystem case {name} crash artifact",
                purpose="case",
                expected_scope={
                    "case_id": name,
                    "role": "crash",
                    "iteration": None,
                    "subject": None,
                    "predicate": None,
                },
                expected_fact={
                    key: item
                    for key, item in crash_point.items()
                    if key != "raw_artifact_reference"
                },
            ):
                valid = False

        require(
            observed.strip().lower()
            not in PRIVILEGED_FILESYSTEM_PLACEHOLDER_TERMS,
            f"privileged filesystem case {name} observed result is a placeholder",
        )

        return valid

    passing_matrix = {
        name for name, value in matrix.items() if structured_passing_case(name, value)
    }
    check(
        passing_matrix == REQUIRED_PRIVILEGED_FILESYSTEM_MATRIX,
        "privileged filesystem signed adversarial/crash/volume/lifecycle matrix is incomplete",
    )
check(
    privileged_filesystem.get("test_processes", {}).get("separately_signed") is True,
    "privileged filesystem adversarial tests are not separately signed processes",
)
check(
    privileged_filesystem.get("test_processes", {}).get("helper_effective_uid") == 0,
    "privileged filesystem helper did not run under its required identity",
)
check(
    privileged_filesystem.get("same_uid_fallback") == "absent",
    "privileged filesystem qualification permits a same-UID fallback",
)
check(
    privileged_filesystem.get("same_uid_threat_model") == "in_scope",
    "privileged filesystem qualification narrows the same-UID threat model",
)
residual = privileged_filesystem.get("residual_risk", {})
formal_closure = privileged_filesystem.get("formal_closure", {})
formal_references = (
    formal_closure.get("formal_argument_artifact_references", [])
    if isinstance(formal_closure, dict)
    else []
)
formal_references_valid = (
    isinstance(formal_references, list)
    and len(formal_references) == len(REQUIRED_PRIVILEGED_FILESYSTEM_FORMAL_CLOSURE)
)
formal_predicates_with_artifacts: set[str] = set()
if isinstance(formal_references, list):
    for index, reference in enumerate(formal_references):
        binding = artifact_reference_valid(
            reference,
            f"privileged filesystem formal argument artifact {index}",
            purpose="formal",
            expected_scope={
                "case_id": None,
                "role": "formal_argument",
                "iteration": None,
                "subject": None,
            },
            expected_fact=None,
        )
        if binding is None:
            formal_references_valid = False
            continue
        scope = binding.get("scope")
        predicate = scope.get("predicate") if isinstance(scope, dict) else None
        if predicate not in REQUIRED_PRIVILEGED_FILESYSTEM_FORMAL_CLOSURE:
            failures.append(
                f"privileged filesystem formal argument artifact {index} "
                "does not bind a required predicate"
            )
            formal_references_valid = False
            continue
        if predicate in formal_predicates_with_artifacts:
            failures.append(
                f"privileged filesystem formal predicate {predicate} reuses evidence"
            )
            formal_references_valid = False
            continue
        expected_formal_fact = {"predicate": predicate, "value": True}
        if binding.get("fact_sha256") != canonical_json_sha256(expected_formal_fact):
            failures.append(
                f"privileged filesystem formal predicate {predicate} artifact "
                "does not bind the exact formal claim"
            )
            formal_references_valid = False
            continue
        formal_predicates_with_artifacts.add(predicate)
formal_references_valid = (
    formal_references_valid
    and formal_predicates_with_artifacts
    == REQUIRED_PRIVILEGED_FILESYSTEM_FORMAL_CLOSURE
)
check(
    isinstance(formal_closure, dict)
    and set(formal_closure)
    == REQUIRED_PRIVILEGED_FILESYSTEM_FORMAL_CLOSURE
    | {"formal_argument_artifact_references"}
    and all(formal_closure.get(name) is True for name in REQUIRED_PRIVILEGED_FILESYSTEM_FORMAL_CLOSURE)
    and formal_references_valid,
    "privileged filesystem formal boundary closure is incomplete",
)
check(
    isinstance(residual, dict)
    and residual.get("disposition") == "qualified_boundary_with_explicit_nonclaims"
    and isinstance(residual.get("remaining_race"), str)
    and bool(residual["remaining_race"].strip())
    and isinstance(residual.get("maximum_race_impact"), str)
    and bool(residual["maximum_race_impact"].strip()),
    "privileged filesystem residual race and maximum impact nonclaims are incomplete",
)
check(
    privileged_filesystem.get("remaining_requirements") == [],
    "privileged filesystem qualification has remaining requirements",
)
check(
    E2_ISSUE.get("status") == "resolved",
    "FC-FILESYSTEM-PATH-TOCTOU-001 remains open and prevents P10 completion",
)

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
    "feature_evidence_binding": P10_FEATURE_EVALUATION.binding,
    "migration_fixtures": len(fixtures) if isinstance(fixtures, list) else 0,
    "failures": failures,
}
binding_output = os.environ.get("FORGE_P10_BINDING_OUTPUT")
if binding_output is not None:
    expected_binding_output = (
        ROOT / ".forge-codex/state/gate-results/G10.p10-feature-binding.json"
    )
    if binding_output != str(expected_binding_output):
        result["failures"].append("P10 binding output path is not canonical")
        result["ok"] = False
    elif result["ok"]:
        encoded_binding = (
            json.dumps(
                P10_FEATURE_EVALUATION.binding,
                indent=2,
                sort_keys=True,
            )
            + "\n"
        ).encode("utf-8")
        atomic_write(expected_binding_output, encoded_binding, final_mode=0o600)
print(json.dumps(result, indent=2, sort_keys=True))
raise SystemExit(0 if not failures else 1)
