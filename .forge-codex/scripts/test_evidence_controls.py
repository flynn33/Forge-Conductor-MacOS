#!/usr/bin/env python3
"""Deterministic regression tests for the evidence recorder and source manifest."""

from __future__ import annotations

import ast
import json
import hashlib
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import unittest

from evidence_support import source_manifest
from check_p10_protocol_compatibility import (
    CompatibilityError,
    MAXIMUM_MCP_MESSAGE_BYTES,
    MCPProcess,
)


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
RECORDER = SCRIPT_ROOT / "record_command.py"
COMPLETION_CHECKER = SCRIPT_ROOT / "check_p10_completion.py"
DOCTOR = SCRIPT_ROOT / "doctor.sh"
STATECTL = SCRIPT_ROOT / "statectl.py"
PRIVILEGED_FILESYSTEM_QUALIFICATION = (
    SCRIPT_ROOT.parent / "docs/PRIVILEGED_FILESYSTEM_QUALIFICATION.md"
)
PRIVILEGED_FILESYSTEM_SCHEMA = (
    SCRIPT_ROOT.parent / "schemas/p10-privileged-filesystem-qualification-report.schema.json"
)
PRIVILEGED_FILESYSTEM_TEMPLATE = (
    SCRIPT_ROOT.parent / "templates/p10-privileged-filesystem-qualification-report.json"
)


class EvidenceControlTests(unittest.TestCase):
    def write_json(self, path: pathlib.Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def install_fixture_evidence(
        self,
        root: pathlib.Path,
        *,
        evidence_id: str = "EVID-fixture-qualification",
        evidence_kind: str = "p10-privileged-filesystem-qualification",
    ) -> dict[str, str]:
        schema_path = (
            root
            / ".forge-codex/schemas/p10-privileged-filesystem-qualification-report.schema.json"
        )
        schema_path.parent.mkdir(parents=True, exist_ok=True)
        schema_path.write_bytes(PRIVILEGED_FILESYSTEM_SCHEMA.read_bytes())
        artifact_path = root / f".forge-codex/evidence/{evidence_id}.txt"
        artifact_path.parent.mkdir(parents=True, exist_ok=True)
        artifact_data = f"signed qualification fixture: {evidence_id}\n".encode()
        artifact_path.write_bytes(artifact_data)
        artifact_hash = hashlib.sha256(artifact_data).hexdigest()
        manifest = source_manifest(root)
        relative_path = artifact_path.relative_to(root).as_posix()
        self.write_json(
            root / f".forge-codex/evidence/{evidence_id}.json",
            {
                "schema_version": 2,
                "id": evidence_id,
                "kind": evidence_kind,
                "command": "python3 signed_privileged_filesystem_qualification.py",
                "related_gates": ["G10"],
                "related_findings": ["FC-FILESYSTEM-PATH-TOCTOU-001"],
                "exit_code": 0,
                "timed_out": False,
                "stream_limit_exceeded": False,
                "artifact_capture_errors": [],
                "source_manifest": manifest,
                "source_manifest_after": manifest,
                "source_manifest_changed": False,
                "ledger_reference": {"status": "recorded", "exit_code": 0},
                "artifacts": [
                    {
                        "path": relative_path,
                        "bytes": len(artifact_data),
                        "sha256": artifact_hash,
                        "storage": "evidence-id-specific-copy",
                    }
                ],
            },
        )
        run_state_path = root / ".forge-codex/state/run-state.json"
        run_state = json.loads(run_state_path.read_text(encoding="utf-8"))
        run_state["evidence"] = [
            *run_state.get("evidence", []),
            evidence_id,
        ]
        run_state["issues"] = [
            {
                "id": "FC-FILESYSTEM-PATH-TOCTOU-001",
                "status": "resolved",
            }
        ]
        self.write_json(run_state_path, run_state)
        return {
            "evidence_id": evidence_id,
            "path": relative_path,
            "sha256": artifact_hash,
        }

    def populate_passing_filesystem_case(
        self,
        name: str,
        case: dict[str, object],
        artifact_reference: dict[str, str],
    ) -> None:
        mount_cases = {
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
        crash_cases = {
            "crash_at_every_durable_phase",
            "daemon_restart_and_idempotent_recovery",
            "manager_restart_and_idempotent_recovery",
            "terminal_outcome_retained_until_acknowledged",
            "acknowledgement_crash_cleanup_matrix",
            "caller_ledger_restart_and_scope_fencing",
            "broker_interruption_requires_transaction_recovery",
            "upgrade_unregister_reregister",
        }
        case["status"] = "passed"
        case["raw_artifact_references"] = [artifact_reference]
        case["iterations"] = {
            "planned": 1,
            "executed": 1,
            "conclusive": 1,
            "barrier_hits": 1,
            "barrier_misses": 0,
        }
        case["barrier_evidence"] = [
            {
                "name": "fixture-barrier",
                "status": "reached",
                "iteration": 1,
                "monotonic_timestamp_ns": 1,
                "raw_artifact_reference": artifact_reference,
            }
        ]
        case["process_identities"] = [
            {
                "role": "helper",
                "pid": 123,
                "effective_uid": 0,
                "executable_path": str(pathlib.Path(sys.executable).resolve()),
            }
        ]
        case["signing_identities"] = [
            {
                "role": "helper",
                "certificate_common_name": "Developer ID Application: Example Corp",
                "team_identifier": "ABCDE12345",
                "signing_identifier": "com.example.signed-helper",
                "code_directory_hash": hashlib.sha256(b"signed-helper").hexdigest(),
                "designated_requirement": "identifier com.example.signed-helper",
            }
        ]
        fixture = {
            "label": "outside-root-sentinel",
            "present": True,
            "device": 1,
            "inode": 2,
            "entry_type": "regular",
            "sha256": hashlib.sha256(b"outside-root-sentinel").hexdigest(),
            "acl_sha256": hashlib.sha256(b"owner-only-acl").hexdigest(),
            "bsd_flags": 0,
        }
        case["fixture_digests"] = {
            "before": [fixture],
            "after": [dict(fixture)],
        }
        if name in mount_cases:
            case["mount_facts"] = {
                "applicable": True,
                "filesystem_type": "apfs",
                "mount_path": "/",
                "device_identifier": "disk9s1",
                "volume_uuid": "00000000-1111-2222-3333-444444444444",
                "mount_flags": ["local", "writable", "ownership-enabled"],
                "local": True,
                "removable": False,
                "network": False,
                "ownership_enabled": True,
                "raw_artifact_reference": artifact_reference,
            }
            if name == "network_volume_rejected":
                case["mount_facts"]["local"] = False
                case["mount_facts"]["network"] = True
            elif name == "removable_volume_rejected":
                case["mount_facts"]["removable"] = True
            elif name == "ignore_ownership_volume_rejected":
                case["mount_facts"]["ownership_enabled"] = False
        if name in crash_cases:
            case["crash_point"] = {
                "applicable": True,
                "phase": "durable-quarantine-receipt",
                "timing": "after",
                "signal": "SIGKILL",
                "restart_observed": True,
                "raw_artifact_reference": artifact_reference,
            }
        case["observed_result"] = "Signed qualification completed conclusively."

    def privileged_filesystem_report(
        self,
        root: pathlib.Path,
        matrix: dict[str, object],
        formal_artifact_reference: dict[str, str],
    ) -> dict[str, object]:
        report = json.loads(PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8"))
        report.update(
            {
                "status": "passed",
                "ok": True,
                "source_manifest": source_manifest(root),
                "captured_at": "2026-08-30T00:00:00Z",
                "repository": {
                    "branch": "fixture",
                    "head_sha": "a" * 40,
                    "base_branch": "origin/main",
                },
                "test_environment": {
                    "macos_build": "fixture-build",
                    "machine_identifier": "fixture-machine",
                },
                "test_processes": {
                    "separately_signed": True,
                    "helper_effective_uid": 0,
                },
                "matrix": matrix,
                "same_uid_fallback": "absent",
                "same_uid_threat_model": "in_scope",
                "residual_risk": {
                    "disposition": "qualified_boundary_with_explicit_nonclaims",
                    "remaining_race": "Fixture residual nonclaim.",
                    "maximum_race_impact": "Fixture maximum impact.",
                },
                "remaining_requirements": [],
            }
        )
        formal_closure = report["formal_closure"]
        self.assertIsInstance(formal_closure, dict)
        for key in formal_closure:
            if key != "formal_argument_artifact_references":
                formal_closure[key] = True
        formal_closure["formal_argument_artifact_references"] = [
            formal_artifact_reference
        ]
        return report

    def run_completion_checker(
        self,
        root: pathlib.Path,
        report: dict[str, object],
    ) -> subprocess.CompletedProcess[str]:
        self.write_json(
            root
            / ".forge-codex/evidence/P10-privileged-filesystem-qualification-report.json",
            report,
        )
        return subprocess.run(
            [sys.executable, str(COMPLETION_CHECKER)],
            env={**os.environ, "FORGE_P10_REPOSITORY": str(root)},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_completion_requires_full_filesystem_security_matrix(self) -> None:
        checker = COMPLETION_CHECKER.read_text(encoding="utf-8")
        required = (
            "testCaptureFirstCoordinatorCommitsOnlyAfterCapturedVerification",
            "testCaptureFirstCoordinatorQuarantinesMismatchWithoutCommit",
            "testCaptureFirstCoordinatorDoesNotVerifyOrCommitAfterCaptureFailure",
            "testMutationRequestRequiresContractSpecificExpectedIdentity",
            "testMutationRequestDigestCanonicalizesUUIDCaseAndBindsContract",
            "testMutationRequestSecureDecodingRejectsDigestBoundFieldTamper",
            "testQuarantinedTransactionStatusIsDurableTerminalAndNotAcknowledgable",
            "testQuarantinedTransactionStatusRejectsContradictoryFlagsAndSuccessCode",
            "testProductionDeleteDispatchUsesCurrentEntryContractAndCanonicalDigest",
            "testDurableQuarantineFailurePreservesTypedFailureAndRecoveryAuthority",
            "testQuarantinedQuerySurfacesTerminalRecoveryStateAndRetainsAuthority",
            "testPrivilegedDaemonUsesDistinctCaptureIdentityAndPhaseReceipts",
            "testPrivilegedDaemonBindsPersistedDigestAndLegacyRollbackIdentity",
            "testConflictedTransactionStatusIsDurableTerminalAndAcknowledgable",
            "testRecursiveDeletePreservesLeafSwappedAfterVerification",
            "testSameVolumeMoveDoesNotPublishLeafSwappedAfterVerification",
            "testSameVolumeNamespaceInstabilityWithUnconfirmedDurabilityRetainsRecoveryReceipt",
            "testCrossVolumeInstallDoesNotPublishStagingLeafSwappedAfterVerification",
            "testCrossVolumeNamespaceInstabilityWithUnconfirmedDurabilityRetainsRecoveryReceipt",
            "testCrossVolumeNamespaceInstabilityMergesInstallAndStagingRecoveryReceipts",
            "testCrossVolumeSourceRemovalPreservesLeafSwappedAfterVerification",
            "testRollbackRefusesSubstitutedQuarantineOccupant",
            "testDeleteQuarantineIsGloballyBoundedAndRecoveredAcrossRestart",
            "testPostUnlinkReceiptSyncFailureDoesNotClaimMissingRecoveryPath",
            "testReceiptRemovalFailureRetainsTerminalRecoveryPath",
            "testPostPublicationStagingFailurePreservesRecoveryAndUnknownPresence",
            "testRetainedStagingRecoveryDoesNotClaimAbsentStagingPathNeedsCleanup",
        )
        self.assertIn("REQUIRED_FILESYSTEM_SECURITY_TESTS", checker)
        self.assertIn("for test_name in REQUIRED_FILESYSTEM_SECURITY_TESTS", checker)
        for test_name in required:
            self.assertIn(f'"{test_name}"', checker)

    def test_privileged_filesystem_matrix_keys_match_all_authorities(self) -> None:
        document = PRIVILEGED_FILESYSTEM_QUALIFICATION.read_text(encoding="utf-8")
        required_cases = document.split("## Required cases", 1)[1].split(
            "## macOS filesystem API capability analysis", 1
        )[0]
        document_keys = set(re.findall(r"^\| `([^`]+)` \|", required_cases, re.MULTILINE))

        checker_tree = ast.parse(COMPLETION_CHECKER.read_text(encoding="utf-8"))
        checker_keys: set[str] | None = None
        for node in checker_tree.body:
            if not isinstance(node, ast.Assign):
                continue
            if any(
                isinstance(target, ast.Name)
                and target.id == "REQUIRED_PRIVILEGED_FILESYSTEM_MATRIX"
                for target in node.targets
            ):
                checker_keys = set(ast.literal_eval(node.value))
                break

        schema = json.loads(PRIVILEGED_FILESYSTEM_SCHEMA.read_text(encoding="utf-8"))
        template = json.loads(PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8"))
        schema_matrix = schema["properties"]["matrix"]
        schema_keys = set(schema_matrix["properties"])
        schema_required_keys = set(schema_matrix["required"])
        template_keys = set(template["matrix"])

        self.assertIsNotNone(checker_keys)
        self.assertEqual(len(document_keys), 57)
        self.assertEqual(document_keys, checker_keys)
        self.assertEqual(document_keys, schema_keys)
        self.assertEqual(document_keys, schema_required_keys)
        self.assertEqual(document_keys, template_keys)

    def test_privileged_filesystem_schema_rejects_boolean_only_matrix(self) -> None:
        from jsonschema import Draft202012Validator

        schema = json.loads(PRIVILEGED_FILESYSTEM_SCHEMA.read_text(encoding="utf-8"))
        template = json.loads(PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema)
        self.assertEqual(list(validator.iter_errors(template)), [])

        boolean_only_report = dict(template)
        boolean_only_report["matrix"] = {key: True for key in template["matrix"]}
        errors = list(validator.iter_errors(boolean_only_report))
        self.assertTrue(errors)
        self.assertTrue(
            all(list(error.absolute_path)[:1] == ["matrix"] for error in errors),
            errors,
        )

    def test_completion_checker_rejects_boolean_only_filesystem_matrix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            template = json.loads(
                PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
            )
            self.write_json(
                root
                / ".forge-codex/evidence/P10-privileged-filesystem-qualification-report.json",
                {
                    "status": "passed",
                    "ok": True,
                    "source_manifest": source_manifest(root),
                    "matrix": {key: True for key in template["matrix"]},
                    "test_processes": {
                        "separately_signed": True,
                        "helper_effective_uid": 0,
                    },
                    "same_uid_fallback": "absent",
                    "same_uid_threat_model": "in_scope",
                    "residual_risk": {
                        "disposition": "qualified_boundary_with_explicit_nonclaims",
                        "remaining_race": "fixture residual",
                        "maximum_race_impact": "fixture impact",
                    },
                    "remaining_requirements": [],
                },
            )
            result = subprocess.run(
                [sys.executable, str(COMPLETION_CHECKER)],
                env={**os.environ, "FORGE_P10_REPOSITORY": str(root)},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "privileged filesystem signed adversarial/crash/volume/lifecycle matrix is incomplete",
                result.stdout,
            )

    def test_privileged_filesystem_case_schema_requires_raw_execution_facts(self) -> None:
        from jsonschema import Draft202012Validator

        schema = json.loads(PRIVILEGED_FILESYSTEM_SCHEMA.read_text(encoding="utf-8"))
        template = json.loads(PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8"))
        case_schema = schema["$defs"]["qualificationCase"]
        self.assertEqual(
            set(case_schema["required"]),
            {
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
            },
        )
        self.assertIn("inconclusive", case_schema["properties"]["status"]["enum"])
        contracts = case_schema["properties"]["contracts_exercised"]
        self.assertEqual(contracts["type"], "array")
        self.assertEqual(contracts["minItems"], 1)
        self.assertTrue(contracts["uniqueItems"])
        self.assertEqual(
            contracts["items"]["enum"],
            ["currentEntry", "namespaceVersionExact", "contentVersionExact"],
        )

        required_contracts = {
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
        for key, expected in required_contracts.items():
            self.assertTrue(expected <= set(template["matrix"][key]["contracts_exercised"]))

        insufficient = json.loads(json.dumps(template))
        insufficient["matrix"]["atomic_swap_source_leaf_before_capture"][
            "contracts_exercised"
        ] = ["currentEntry"]
        self.assertTrue(list(Draft202012Validator(schema).iter_errors(insufficient)))

    def test_completion_checker_enforces_required_contract_subsets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            artifact_reference = self.install_fixture_evidence(root)
            formal_artifact_reference = self.install_fixture_evidence(
                root,
                evidence_id="EVID-fixture-formal-argument",
                evidence_kind="p10-privileged-filesystem-formal-argument",
            )
            template = json.loads(
                PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
            )
            matrix = json.loads(json.dumps(template["matrix"]))
            for name, case in matrix.items():
                self.populate_passing_filesystem_case(name, case, artifact_reference)

            report = self.privileged_filesystem_report(
                root,
                matrix,
                formal_artifact_reference,
            )
            complete_contracts = self.run_completion_checker(root, report)
            self.assertNotIn(
                "privileged filesystem signed adversarial/crash/volume/lifecycle matrix is incomplete",
                complete_contracts.stdout,
            )

            matrix["hard_link_behavior"]["contracts_exercised"] = [
                "contentVersionExact"
            ]
            missing_namespace_contract = self.run_completion_checker(root, report)
            self.assertIn(
                "privileged filesystem signed adversarial/crash/volume/lifecycle matrix is incomplete",
                missing_namespace_contract.stdout,
            )

    def test_completion_checker_rejects_placeholder_artifact_facts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            artifact_reference = self.install_fixture_evidence(root)
            formal_artifact_reference = self.install_fixture_evidence(
                root,
                evidence_id="EVID-fixture-formal-argument",
                evidence_kind="p10-privileged-filesystem-formal-argument",
            )
            template = json.loads(
                PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
            )
            matrix = json.loads(json.dumps(template["matrix"]))
            for name, case in matrix.items():
                self.populate_passing_filesystem_case(name, case, artifact_reference)
            matrix["signed_debug_bundle"]["raw_artifact_references"] = [{}]
            report = self.privileged_filesystem_report(
                root,
                matrix,
                formal_artifact_reference,
            )

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "privileged filesystem qualification schema error at "
                "matrix.signed_debug_bundle.raw_artifact_references.0",
                result.stdout,
            )
            self.assertIn(
                "privileged filesystem signed adversarial/crash/volume/lifecycle matrix is incomplete",
                result.stdout,
            )

    def test_completion_checker_rejects_missing_and_hash_mismatched_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            artifact_reference = self.install_fixture_evidence(root)
            formal_artifact_reference = self.install_fixture_evidence(
                root,
                evidence_id="EVID-fixture-formal-argument",
                evidence_kind="p10-privileged-filesystem-formal-argument",
            )
            template = json.loads(
                PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
            )
            matrix = json.loads(json.dumps(template["matrix"]))
            for name, case in matrix.items():
                self.populate_passing_filesystem_case(name, case, artifact_reference)
            report = self.privileged_filesystem_report(
                root,
                matrix,
                formal_artifact_reference,
            )

            matrix["signed_release_bundle"]["raw_artifact_references"] = [
                {
                    "evidence_id": "EVID-missing-qualification",
                    "path": ".forge-codex/evidence/missing-qualification.txt",
                    "sha256": "d" * 64,
                }
            ]
            missing = self.run_completion_checker(root, report)
            self.assertIn(
                "privileged filesystem case signed_release_bundle raw artifact 0 "
                "evidence record is unavailable: EVID-missing-qualification",
                missing.stdout,
            )
            self.assertIn(
                "privileged filesystem signed adversarial/crash/volume/lifecycle matrix is incomplete",
                missing.stdout,
            )

            mismatched_reference = dict(artifact_reference)
            mismatched_reference["sha256"] = "e" * 64
            matrix["signed_release_bundle"]["raw_artifact_references"] = [
                mismatched_reference
            ]
            mismatched = self.run_completion_checker(root, report)
            self.assertIn(
                "privileged filesystem case signed_release_bundle raw artifact 0 "
                "does not identify exactly one artifact in its evidence record",
                mismatched.stdout,
            )
            self.assertIn(
                "privileged filesystem signed adversarial/crash/volume/lifecycle matrix is incomplete",
                mismatched.stdout,
            )

    def test_completion_checker_rejects_required_mount_and_crash_nonapplicability(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            artifact_reference = self.install_fixture_evidence(root)
            formal_artifact_reference = self.install_fixture_evidence(
                root,
                evidence_id="EVID-fixture-formal-argument",
                evidence_kind="p10-privileged-filesystem-formal-argument",
            )
            template = json.loads(
                PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
            )
            matrix = json.loads(json.dumps(template["matrix"]))
            for name, case in matrix.items():
                self.populate_passing_filesystem_case(name, case, artifact_reference)
            matrix["network_volume_rejected"]["mount_facts"] = json.loads(
                json.dumps(template["matrix"]["network_volume_rejected"]["mount_facts"])
            )
            matrix["crash_at_every_durable_phase"]["crash_point"] = json.loads(
                json.dumps(
                    template["matrix"]["crash_at_every_durable_phase"]["crash_point"]
                )
            )
            report = self.privileged_filesystem_report(
                root,
                matrix,
                formal_artifact_reference,
            )

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "privileged filesystem case network_volume_rejected requires applicable mount facts",
                result.stdout,
            )
            self.assertIn(
                "privileged filesystem case crash_at_every_durable_phase requires applicable crash facts",
                result.stdout,
            )
            self.assertIn(
                "privileged filesystem signed adversarial/crash/volume/lifecycle matrix is incomplete",
                result.stdout,
            )

    def test_formal_closure_schema_keeps_residual_nonclaims_explicit(self) -> None:
        from jsonschema import Draft202012Validator

        schema = json.loads(PRIVILEGED_FILESYSTEM_SCHEMA.read_text(encoding="utf-8"))
        template = json.loads(PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8"))
        checker = COMPLETION_CHECKER.read_text(encoding="utf-8")
        formal_boolean_keys = {
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
        residual_dispositions = schema["properties"]["residual_risk"]["properties"][
            "disposition"
        ]["enum"]
        self.assertEqual(
            residual_dispositions,
            [
                "open_release_blocker",
                "mitigated_open",
                "qualified_boundary_with_explicit_nonclaims",
            ],
        )
        self.assertNotIn("eliminated", residual_dispositions)
        self.assertNotIn('disposition") == "eliminated"', checker)
        self.assertIn("formal_closure", schema["required"])
        self.assertEqual(template["residual_risk"]["disposition"], "open_release_blocker")
        self.assertEqual(
            set(template["formal_closure"]),
            formal_boolean_keys | {"formal_argument_artifact_references"},
        )
        self.assertTrue(
            all(template["formal_closure"][key] is False for key in formal_boolean_keys)
        )
        self.assertEqual(
            template["formal_closure"]["formal_argument_artifact_references"], []
        )

        candidate = json.loads(json.dumps(template))
        candidate["status"] = "passed"
        candidate["ok"] = True
        candidate["source_manifest"] = "0" * 64
        candidate["captured_at"] = "2026-08-30T00:00:00Z"
        candidate["same_uid_fallback"] = "absent"
        candidate["residual_risk"] = {
            "disposition": "qualified_boundary_with_explicit_nonclaims",
            "remaining_race": "A bounded authorization-metadata race remains.",
            "maximum_race_impact": "One captured eligible entry per operation.",
        }
        candidate["remaining_requirements"] = []
        candidate["formal_closure"]["formal_argument_artifact_references"] = [
            {"evidence_id": "EVID-fixture", "path": "fixture.json", "sha256": "0" * 64}
        ]
        errors = list(Draft202012Validator(schema).iter_errors(candidate))
        self.assertTrue(errors)
        self.assertTrue(
            any(list(error.absolute_path)[:1] == ["formal_closure"] for error in errors),
            errors,
        )

    def test_completion_checker_rejects_missing_and_false_formal_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            report_path = (
                root
                / ".forge-codex/evidence/P10-privileged-filesystem-qualification-report.json"
            )
            report = {
                "status": "partial",
                "ok": False,
                "source_manifest": source_manifest(root),
                "matrix": {},
                "test_processes": {
                    "separately_signed": False,
                    "helper_effective_uid": None,
                },
                "same_uid_fallback": "unverified",
                "same_uid_threat_model": "in_scope",
                "residual_risk": {
                    "disposition": "open_release_blocker",
                    "remaining_race": "fixture residual",
                    "maximum_race_impact": "fixture impact",
                },
                "remaining_requirements": ["fixture requirement"],
            }
            self.write_json(report_path, report)

            def run_checker() -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [sys.executable, str(COMPLETION_CHECKER)],
                    env={**os.environ, "FORGE_P10_REPOSITORY": str(root)},
                    capture_output=True,
                    text=True,
                    check=False,
                )

            missing = run_checker()
            self.assertIn(
                "privileged filesystem formal boundary closure is incomplete",
                missing.stdout,
            )

            report["formal_closure"] = {
                "capture_linearization": False,
                "source_parent_containment_and_authority": False,
                "protected_namespace_denial": False,
                "current_entry_contract": False,
                "namespace_exact_no_mismatch_disposal": False,
                "content_exact_fail_closed": False,
                "final_authorization_metadata_race_closure": False,
                "quarantine_disposition_qualification": False,
                "startup_recovery_fence": False,
                "caller_generation_fence": False,
                "volume_behavior_qualification": False,
                "equivalent_identity_conditional_boundary_proof": False,
                "formal_argument_artifact_references": [],
            }
            self.write_json(report_path, report)
            false_closure = run_checker()
            self.assertIn(
                "privileged filesystem formal boundary closure is incomplete",
                false_closure.stdout,
            )

    def test_doctor_reports_open_issues_and_nonpassing_hard_gates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            script = root / ".forge-codex/scripts/doctor.sh"
            script.parent.mkdir(parents=True)
            script.write_text(DOCTOR.read_text(encoding="utf-8"), encoding="utf-8")
            self.write_json(
                root / ".forge-codex/state/run-state.json",
                {
                    "status": "active",
                    "current_work": "P10",
                    "repository": {"branch": "fixture", "commit": "abc123", "dirty": True},
                    "issues": [
                        {"id": "RESOLVED", "status": "resolved", "severity": "High"},
                        {
                            "id": "OPEN-E2",
                            "title": "Residual race",
                            "status": "deferred",
                            "severity": "High",
                            "evidence_class": "E2",
                            "notes": "mitigation remains incomplete",
                        },
                    ],
                    "gates": {
                        "G09": {"status": "blocked_dependency"},
                        "G10": {"status": "blocked_environment"},
                        "G12": {"status": "not_started"},
                    },
                },
            )
            self.write_json(
                root / ".forge-codex/plans/gates.json",
                {
                    "gates": [
                        {"id": "G09", "type": "hard"},
                        {"id": "G10", "type": "hard"},
                        {"id": "G12", "type": "hard"},
                        {"id": "INFO", "type": "informational"},
                    ]
                },
            )

            result = subprocess.run(
                ["bash", str(script)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["current_work"], "P10")
            self.assertEqual([item["id"] for item in report["open_issues"]], ["OPEN-E2"])
            self.assertEqual(
                [item["id"] for item in report["nonpassing_hard_gates"]],
                ["G09", "G10", "G12"],
            )
            environment = json.loads(
                (root / ".forge-codex/state/environment.json").read_text(encoding="utf-8")
            )
            self.assertTrue(environment["execution_state"]["available"])
            self.assertEqual(environment["execution_state"]["current_work"], "P10")

    def test_statectl_issue_event_preserves_residual_details(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            scripts = root / ".forge-codex/scripts"
            scripts.mkdir(parents=True)
            statectl = scripts / "statectl.py"
            statectl.write_text(STATECTL.read_text(encoding="utf-8"), encoding="utf-8")
            statectl.chmod(0o755)
            self.write_json(root / ".forge-codex/plans/phases.json", {"phases": []})
            self.write_json(root / ".forge-codex/plans/gates.json", {"gates": []})

            initialize = subprocess.run(
                [sys.executable, str(statectl), "--repo", str(root), "init"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(initialize.returncode, 0, initialize.stdout + initialize.stderr)
            update = subprocess.run(
                [
                    sys.executable,
                    str(statectl),
                    "--repo",
                    str(root),
                    "issue",
                    "RESIDUAL-E2",
                    "--title",
                    "Residual race",
                    "--status",
                    "deferred",
                    "--severity",
                    "High",
                    "--evidence-class",
                    "E2",
                    "--path",
                    "Sources/Mutation.swift",
                    "--notes",
                    "Mitigation does not eliminate the race.",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(update.returncode, 0, update.stdout + update.stderr)
            event = json.loads(
                (root / ".forge-codex/state/events.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()[-1]
            )
            self.assertEqual(event["type"], "issue_updated")
            self.assertEqual(
                event["payload"],
                {
                    "id": "RESIDUAL-E2",
                    "title": "Residual race",
                    "status": "deferred",
                    "severity": "High",
                    "evidence_class": "E2",
                    "path": "Sources/Mutation.swift",
                    "notes": "Mitigation does not eliminate the race.",
                },
            )

    def make_repository(self, root: pathlib.Path, *, ledger_exit: int = 0) -> None:
        (root / "Sources").mkdir(parents=True)
        (root / "Tests").mkdir()
        (root / ".forge-codex/scripts").mkdir(parents=True)
        (root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
        (root / "Sources/App.swift").write_text("struct App {}\n", encoding="utf-8")
        (root / "Tests/AppTests.swift").write_text("struct AppTests {}\n", encoding="utf-8")
        state_directory = root / ".forge-codex/state"
        state_directory.mkdir()
        (state_directory / "run-state.json").write_text(
            json.dumps({"evidence": []}) + "\n",
            encoding="utf-8",
        )
        statectl = root / ".forge-codex/scripts/statectl.py"
        if ledger_exit:
            program = f"#!/usr/bin/env python3\nimport sys\nsys.exit({ledger_exit})\n"
        else:
            program = """#!/usr/bin/env python3
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[sys.argv.index("--repo") + 1])
path = root / ".forge-codex/state/run-state.json"
value = json.loads(path.read_text(encoding="utf-8"))
value["evidence"].append(sys.argv[-1])
path.write_text(json.dumps(value) + "\\n", encoding="utf-8")
"""
        statectl.write_text(program, encoding="utf-8")
        statectl.chmod(0o755)

    def records(self, root: pathlib.Path) -> list[pathlib.Path]:
        return sorted(
            path
            for path in (root / ".forge-codex/evidence").glob("EVID-*.json")
            if ".artifact-" not in path.name
        )

    def test_manifest_tracks_source_and_ignores_generated_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            initial = source_manifest(root)
            (root / ".forge-codex/evidence").mkdir()
            (root / ".forge-codex/evidence/generated.txt").write_text("ignored", encoding="utf-8")
            self.assertEqual(initial, source_manifest(root))
            (root / "Sources/App.swift").write_text("struct Changed {}\n", encoding="utf-8")
            self.assertNotEqual(initial, source_manifest(root))

            schema = (
                root
                / ".forge-codex/schemas/p10-privileged-filesystem-qualification-report.schema.json"
            )
            schema.parent.mkdir(parents=True)
            schema.write_text('{"schema":"qualification-v1"}\n', encoding="utf-8")
            schema_manifest = source_manifest(root)
            schema.write_text('{"schema":"qualification-v2"}\n', encoding="utf-8")
            self.assertNotEqual(schema_manifest, source_manifest(root))

    def test_recorder_preserves_bounded_repository_artifact_and_external_reference(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as external_root:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            artifact = root / "result.json"
            artifact.write_text('{"ok":true}\n', encoding="utf-8")
            external = pathlib.Path(external_root) / "trace.txt"
            external.write_text("external trace\n", encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(RECORDER),
                    "--repo",
                    str(root),
                    "--kind",
                    "fixture",
                    "--related-gate",
                    "G10",
                    "--artifact",
                    "result.json",
                    "--external-artifact",
                    str(external),
                    "--",
                    sys.executable,
                    "-c",
                    "print('passed')",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            record = json.loads(self.records(root)[0].read_text(encoding="utf-8"))
            self.assertEqual(record["schema_version"], 2)
            self.assertEqual(record["ledger_reference"]["status"], "recorded")
            ledger = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(encoding="utf-8")
            )
            self.assertIn(record["id"], ledger["evidence"])
            self.assertFalse(record["source_manifest_changed"])
            copies = [item for item in record["artifacts"] if item.get("storage") == "evidence-id-specific-copy"]
            references = [item for item in record["artifacts"] if item.get("storage") == "external-hash-only"]
            self.assertEqual(len(copies), 1)
            self.assertEqual(len(references), 1)
            self.assertFalse(pathlib.Path(copies[0]["path"]).is_absolute())
            copy_path = root / copies[0]["path"]
            self.assertEqual(stat.S_IMODE(copy_path.stat().st_mode), 0o444)
            self.assertEqual(stat.S_IMODE(self.records(root)[0].stat().st_mode), 0o444)

    def test_recorder_rejects_outside_copy_and_ledger_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as outside_root:
            root = pathlib.Path(temporary)
            self.make_repository(root, ledger_exit=9)
            outside = pathlib.Path(outside_root) / "private.txt"
            outside.write_text("private\n", encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(RECORDER),
                    "--repo",
                    str(root),
                    "--kind",
                    "fixture",
                    "--artifact",
                    str(outside),
                    "--",
                    sys.executable,
                    "-c",
                    "print('passed')",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 125)
            record = json.loads(self.records(root)[0].read_text(encoding="utf-8"))
            self.assertEqual(record["command_exit_code"], 0)
            self.assertEqual(record["ledger_reference"]["status"], "failed")
            self.assertTrue(record["artifact_capture_errors"])

    def test_recorder_invalidates_command_that_changes_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            result = subprocess.run(
                [
                    sys.executable,
                    str(RECORDER),
                    "--repo",
                    str(root),
                    "--kind",
                    "fixture",
                    "--related-gate",
                    "G10",
                    "--",
                    sys.executable,
                    "-c",
                    "from pathlib import Path; Path('Sources/App.swift').write_text('changed\\n')",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 126)
            record = json.loads(self.records(root)[0].read_text(encoding="utf-8"))
            self.assertTrue(record["source_manifest_changed"])
            self.assertNotEqual(record["source_manifest"], record["source_manifest_after"])

    def test_recorder_terminates_output_that_exceeds_the_stream_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            result = subprocess.run(
                [
                    sys.executable,
                    str(RECORDER),
                    "--repo",
                    str(root),
                    "--kind",
                    "fixture",
                    "--related-gate",
                    "G10",
                    "--maximum-stream-bytes",
                    "64",
                    "--",
                    sys.executable,
                    "-c",
                    "import sys; sys.stdout.write('x' * 4096); sys.stdout.flush()",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 127, result.stdout + result.stderr)
            record = json.loads(self.records(root)[0].read_text(encoding="utf-8"))
            self.assertTrue(record["stream_limit_exceeded"])
            self.assertEqual(record["maximum_stream_bytes"], 64)
            stream = next(
                item
                for item in record["artifacts"]
                if item.get("storage") == "evidence-id-specific-stream"
                and item["path"].endswith(".stdout.txt")
            )
            self.assertEqual(stream["bytes"], 64)
            self.assertEqual(record["ledger_reference"]["status"], "recorded")

    def test_recorder_timeout_kills_descendant_that_ignores_term_and_holds_pipe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            descendant = "\n".join(
                (
                    "import os, signal, sys, time",
                    "read_fd, write_fd = os.pipe()",
                    "pid = os.fork()",
                    "if pid == 0:",
                    "    os.close(read_fd)",
                    "    signal.signal(signal.SIGTERM, signal.SIG_IGN)",
                    "    os.write(write_fd, b'ready')",
                    "    os.close(write_fd)",
                    "    while True: time.sleep(1)",
                    "os.close(write_fd)",
                    "os.read(read_fd, 5)",
                    "os.close(read_fd)",
                    "sys.exit(0)",
                )
            )
            started = time.monotonic()
            result = subprocess.run(
                [
                    sys.executable,
                    str(RECORDER),
                    "--repo",
                    str(root),
                    "--kind",
                    "fixture",
                    "--related-gate",
                    "G10",
                    "--timeout",
                    "1",
                    "--",
                    sys.executable,
                    "-c",
                    descendant,
                ],
                capture_output=True,
                text=True,
                timeout=8,
                check=False,
            )
            self.assertLess(time.monotonic() - started, 6)
            self.assertEqual(result.returncode, 124, result.stderr)
            record = json.loads(self.records(root)[0].read_text(encoding="utf-8"))
            self.assertTrue(record["timed_out"])
            self.assertEqual(record["exit_code"], 124)
            self.assertEqual(record["ledger_reference"]["status"], "recorded")

    def test_recorder_timeout_still_applies_after_command_closes_output_pipes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            started = time.monotonic()
            result = subprocess.run(
                [
                    sys.executable,
                    str(RECORDER),
                    "--repo",
                    str(root),
                    "--kind",
                    "fixture",
                    "--related-gate",
                    "G10",
                    "--timeout",
                    "1",
                    "--",
                    sys.executable,
                    "-c",
                    "import os,time; os.close(1); os.close(2); time.sleep(10)",
                ],
                capture_output=True,
                text=True,
                timeout=8,
                check=False,
            )
            self.assertLess(time.monotonic() - started, 6)
            self.assertEqual(result.returncode, 124, result.stderr)
            record = json.loads(self.records(root)[0].read_text(encoding="utf-8"))
            self.assertTrue(record["timed_out"])
            self.assertEqual(record["exit_code"], 124)
            self.assertEqual(record["ledger_reference"]["status"], "recorded")

    def test_completion_rejects_superficial_manager_and_ui_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            project = root / "ForgeConductor.xcodeproj/project.pbxproj"
            project.parent.mkdir()
            project.write_text(
                "\n".join(
                    (
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
                    )
                ),
                encoding="utf-8",
            )
            self.write_json(
                root / ".forge-codex/state/feature-baseline.json",
                {
                    "features": [
                        {"id": f"feature-{index}", "parity_status": "preserved", "evidence": ["source"], "tests": ["test"]}
                        for index in range(66)
                    ]
                },
            )
            manifest = source_manifest(root)
            manager_relative = ".forge-codex/evidence/P10-manager-http-compatibility-report.json"
            ui_relative = ".forge-codex/evidence/P10-native-ui-qualification-report.json"
            manager_id = "EVID-manager-fixture"
            ui_id = "EVID-ui-fixture"
            manager_report = {
                "status": "passed",
                "ok": True,
                "g10_compatibility_eligible": True,
                "source_manifest": manifest,
                "runtime": {
                    "manager": {
                        "success_semantics": {
                            "coverage_status": "complete",
                            "full_g10_compatibility_claimed": True,
                            "expected_count": 17,
                            "exercised_count": 14,
                            "baseline_expected_count": 8,
                            "baseline_exercised": list(range(8)),
                            "baseline_complete": True,
                            "uncovered": [],
                        }
                    }
                },
            }
            ui_report = {
                "status": "passed",
                "ok": True,
                "source_manifest": manifest,
                "xctest": {"attempts": 1, "passing_attempts": 1, "executed": 1, "failures": 0},
                "authorization": {
                    "developer_mode_enabled": True,
                    "signing_identity_usable": True,
                    "automation_authorized": True,
                },
                "checks": {"commands": True, "settings": True, "accessibility": True, "reconnect": True},
            }
            self.write_json(root / manager_relative, manager_report)
            self.write_json(root / ui_relative, ui_report)

            def evidence(evidence_id: str, kind: str, command: str, report_relative: str) -> None:
                report = root / report_relative
                copy_relative = f".forge-codex/evidence/{evidence_id}.artifact-000-{report.name}"
                stream_relative = f".forge-codex/evidence/{evidence_id}.stdout.txt"
                copy = root / copy_relative
                stream = root / stream_relative
                copy.write_bytes(report.read_bytes())
                stream.write_text("fixture\n", encoding="utf-8")

                def metadata(path: pathlib.Path, relative: str, storage: str) -> dict[str, object]:
                    data = path.read_bytes()
                    return {
                        "path": relative,
                        "bytes": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "storage": storage,
                    }

                preserved = metadata(copy, copy_relative, "evidence-id-specific-copy")
                preserved["source_path"] = report_relative
                self.write_json(
                    root / f".forge-codex/evidence/{evidence_id}.json",
                    {
                        "schema_version": 2,
                        "id": evidence_id,
                        "kind": kind,
                        "command": command,
                        "exit_code": 0,
                        "timed_out": False,
                        "source_manifest": manifest,
                        "source_manifest_after": manifest,
                        "source_manifest_changed": False,
                        "artifact_capture_errors": [],
                        "ledger_reference": {"status": "recorded", "exit_code": 0},
                        "related_gates": ["G10"],
                        "artifacts": [preserved, metadata(stream, stream_relative, "evidence-id-specific-stream")],
                    },
                )

            evidence(
                manager_id,
                "p10-manager-http-compatibility",
                "python3 check_p10_manager_http_compatibility.py --report report.json",
                manager_relative,
            )
            evidence(
                ui_id,
                "p10-native-ui-qualification",
                "xcodebuild test -only-testing:ForgeConductorUITests",
                ui_relative,
            )
            self.write_json(root / ".forge-codex/state/run-state.json", {"evidence": [manager_id, ui_id]})
            fixtures = [
                "config-v1-to-v2",
                "global-sqlite-v2-to-v5",
                "global-sqlite-v3-to-v5",
                "project-memory-v1-to-v2",
                "legacy-continuity-v1-import",
                "legacy-continuity-v2-import",
                "native-ledger-v1-to-v2",
                "runtime-job-v2-to-v5",
            ]
            self.write_json(
                root / ".forge-codex/evidence/P10-migration-report.json",
                {
                    "status": "passed",
                    "source_manifest": manifest,
                    "strict_suites": {
                        "debug": {"evidence_id": "EVID-missing-debug", "executed": 1, "skipped": 0, "failures": 0},
                        "release": {"evidence_id": "EVID-missing-release", "executed": 1, "skipped": 0, "failures": 0},
                    },
                    "fixtures": [{"id": item, "status": "passed"} for item in fixtures],
                    "backup_qualification": {"status": "passed"},
                    "remaining_requirements": [],
                },
            )
            self.write_json(root / ".forge-codex/evidence/P10-cli-compatibility-report.json", {"status": "partial"})
            self.write_json(root / ".forge-codex/evidence/P10-protocol-compatibility-report.json", {"status": "partial"})
            self.write_json(
                root / ".forge-codex/evidence/P10-parity-report.json",
                {
                    "status": "passed",
                    "source_manifest": manifest,
                    "removed": [],
                    "unknown": [],
                    "untested": [],
                    "remaining_requirements": [],
                    "current_automated_results": {
                        "manager_http_compatibility": {
                            "status": "passed",
                            "uncovered": [],
                            "evidence_id": manager_id,
                            "report_path": manager_relative,
                        },
                        "cli_compatibility": {},
                        "mcp_compatibility": {},
                    },
                    "ui": {"behavioral_status": "passed", "evidence_id": ui_id, "report_path": ui_relative},
                },
            )
            result = subprocess.run(
                [sys.executable, str(COMPLETION_CHECKER)],
                env={**os.environ, "FORGE_P10_REPOSITORY": str(root)},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("manager current success matrix is not exactly 17 of 17", result.stdout)
            self.assertIn(
                "native UI command/settings/accessibility/reconnect/redaction matrix is incomplete",
                result.stdout,
            )
            self.assertIn(
                "debug strict suite has no passing shell compatibility proof: "
                "testShellPolicyAndCompatibilitySurviveManagerAndAppRestart",
                result.stdout,
            )
            self.assertIn(
                "release strict suite has no passing shell compatibility proof: "
                "testBootstrapRouterLegacyShellExecUsesBoundProjectAndCompatibilityContract",
                result.stdout,
            )
            self.assertIn(
                "native UI qualification has no passing shell Settings proof: "
                "testManagerSettingsControlsAndPersistsProjectShellPolicy",
                result.stdout,
            )


class ProtocolReaderTests(unittest.TestCase):
    def make_server(self, root: pathlib.Path, program: str) -> pathlib.Path:
        server = root / "fixture-server"
        server.write_text("#!/usr/bin/env python3\n" + program, encoding="utf-8")
        server.chmod(0o755)
        return server

    def test_partial_line_without_newline_respects_response_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            partial = b'{"jsonrpc":"2.0","id":1'
            server = self.make_server(
                root,
                "import os, time\n"
                f"os.write(1, {partial!r})\n"
                "time.sleep(10)\n",
            )
            process = MCPProcess(server, root, "partial-line")
            started = time.monotonic()
            try:
                with self.assertRaisesRegex(CompatibilityError, "timed out waiting"):
                    process.receive(1, "partial response", 0.2)
                self.assertEqual(bytes(process._stdout_buffer), partial)
                self.assertLess(time.monotonic() - started, 1.0)
            finally:
                process.abort()

    def test_oversized_line_without_newline_is_rejected_at_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            server = self.make_server(
                root,
                "import os, time\n"
                f"payload = b'x' * {MAXIMUM_MCP_MESSAGE_BYTES + 1}\n"
                "offset = 0\n"
                "while offset < len(payload):\n"
                "    offset += os.write(1, payload[offset:])\n"
                "time.sleep(10)\n",
            )
            process = MCPProcess(server, root, "oversized-line")
            started = time.monotonic()
            try:
                with self.assertRaisesRegex(
                    CompatibilityError,
                    f"exceeded {MAXIMUM_MCP_MESSAGE_BYTES} bytes",
                ):
                    process.receive(1, "oversized response", 5.0)
                self.assertEqual(len(process._stdout_buffer), MAXIMUM_MCP_MESSAGE_BYTES + 1)
                self.assertLess(time.monotonic() - started, 2.0)
            finally:
                process.abort()


if __name__ == "__main__":
    unittest.main()
