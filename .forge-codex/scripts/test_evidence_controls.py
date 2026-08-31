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
from unittest import mock

from evidence_support import (
    EVIDENCE_CONTEXT_SCHEMA_VERSION,
    EvidenceSupportError,
    QUALIFICATION_ARTIFACT_BINDING_SCHEMA_VERSION,
    canonical_json_sha256,
    load_qualification_artifact,
    source_manifest,
)
from check_p10_protocol_compatibility import (
    CompatibilityError,
    MAXIMUM_MCP_MESSAGE_BYTES,
    MCPProcess,
)
from record_command import execution_provenance


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
PRIVILEGED_FILESYSTEM_ARTIFACT_SCHEMA = (
    SCRIPT_ROOT.parent
    / "schemas/p10-privileged-filesystem-artifact-binding.schema.json"
)
PRIVILEGED_FILESYSTEM_TEMPLATE = (
    SCRIPT_ROOT.parent / "templates/p10-privileged-filesystem-qualification-report.json"
)


class EvidenceControlTests(unittest.TestCase):
    def write_json(self, path: pathlib.Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def install_scoped_evidence(
        self,
        root: pathlib.Path,
        *,
        evidence_id: str,
        evidence_kind: str = "p10-privileged-filesystem-qualification",
        bindings: dict[str, tuple[dict[str, object], object]],
    ) -> dict[str, dict[str, str]]:
        schema_path = (
            root
            / ".forge-codex/schemas/p10-privileged-filesystem-qualification-report.schema.json"
        )
        schema_path.parent.mkdir(parents=True, exist_ok=True)
        schema_path.write_bytes(PRIVILEGED_FILESYSTEM_SCHEMA.read_bytes())
        artifact_schema_path = (
            root
            / ".forge-codex/schemas/p10-privileged-filesystem-artifact-binding.schema.json"
        )
        artifact_schema_path.write_bytes(PRIVILEGED_FILESYSTEM_ARTIFACT_SCHEMA.read_bytes())
        manifest = source_manifest(root)
        provenance = execution_provenance(root.resolve())
        evidence_directory = root / ".forge-codex/evidence"
        evidence_directory.mkdir(parents=True, exist_ok=True)
        artifact_records: list[dict[str, object]] = []
        references: dict[str, dict[str, str]] = {}
        for index, (token, (scope, fact)) in enumerate(bindings.items()):
            self.assertRegex(token, r"^[a-z0-9-]+$")
            artifact_path = (
                evidence_directory
                / f"{evidence_id}.artifact-{index:03d}-{token}.json"
            )
            self.write_json(
                artifact_path,
                {
                    "schema_version": QUALIFICATION_ARTIFACT_BINDING_SCHEMA_VERSION,
                    "qualification": "p10-privileged-filesystem",
                    "evidence_id": evidence_id,
                    "source_manifest": manifest,
                    "scope": scope,
                    "fact_sha256": canonical_json_sha256(fact),
                    "claim": "Signed qualification fact binding.",
                },
            )
            artifact_path.chmod(0o444)
            artifact_data = artifact_path.read_bytes()
            artifact_hash = hashlib.sha256(artifact_data).hexdigest()
            relative_path = artifact_path.relative_to(root).as_posix()
            artifact_records.append(
                {
                    "path": relative_path,
                    "source_path": f"qualification-artifacts/{token}.json",
                    "bytes": len(artifact_data),
                    "sha256": artifact_hash,
                    "storage": "evidence-id-specific-copy",
                }
            )
            references[token] = {
                "evidence_id": evidence_id,
                "path": relative_path,
                "sha256": artifact_hash,
            }
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
                "started_at": "2026-08-29T23:59:59+00:00",
                "ended_at": "2026-08-30T00:00:01+00:00",
                "environment": {
                    "platform": provenance["test_environment"]["platform"],
                    "architecture": provenance["test_environment"]["architecture"],
                    "macos_build": provenance["test_environment"]["macos_build"],
                    "machine_identifier": provenance["test_environment"][
                        "machine_identifier"
                    ],
                    "cwd": provenance["repository"]["repository_path"],
                },
                "execution_provenance": provenance,
                "source_manifest": manifest,
                "source_manifest_after": manifest,
                "source_manifest_changed": False,
                "child_evidence_context": {
                    "schema_version": EVIDENCE_CONTEXT_SCHEMA_VERSION,
                    "binding_schema_version": QUALIFICATION_ARTIFACT_BINDING_SCHEMA_VERSION,
                    "evidence_id": evidence_id,
                    "source_manifest": manifest,
                    "repository": provenance["repository"],
                    "test_environment": provenance["test_environment"],
                    "qualification": "p10-privileged-filesystem",
                },
                "ledger_reference": {"status": "recorded", "exit_code": 0},
                "artifacts": artifact_records,
            },
        )
        run_state_path = root / ".forge-codex/state/run-state.json"
        run_state = json.loads(run_state_path.read_text(encoding="utf-8"))
        run_state["evidence"] = list(
            dict.fromkeys([*run_state.get("evidence", []), evidence_id])
        )
        run_state["issues"] = [
            {
                "id": "FC-FILESYSTEM-PATH-TOCTOU-001",
                "status": "resolved",
            }
        ]
        self.write_json(run_state_path, run_state)
        return references

    def replace_scoped_artifact(
        self,
        root: pathlib.Path,
        reference: dict[str, str],
        value: dict[str, object],
    ) -> dict[str, str]:
        artifact_path = root / reference["path"]
        artifact_path.chmod(0o644)
        self.write_json(artifact_path, value)
        artifact_path.chmod(0o444)
        artifact_data = artifact_path.read_bytes()
        artifact_hash = hashlib.sha256(artifact_data).hexdigest()
        evidence_record_path = (
            root / f".forge-codex/evidence/{reference['evidence_id']}.json"
        )
        evidence_record = json.loads(
            evidence_record_path.read_text(encoding="utf-8")
        )
        matches = [
            artifact
            for artifact in evidence_record["artifacts"]
            if artifact["path"] == reference["path"]
        ]
        self.assertEqual(len(matches), 1)
        matches[0]["bytes"] = len(artifact_data)
        matches[0]["sha256"] = artifact_hash
        self.write_json(evidence_record_path, evidence_record)
        return {
            "evidence_id": reference["evidence_id"],
            "path": reference["path"],
            "sha256": artifact_hash,
        }

    def populate_passing_filesystem_case(
        self,
        root: pathlib.Path,
        name: str,
        case: dict[str, object],
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
        case["raw_artifact_references"] = []
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
                "raw_artifact_reference": None,
            }
        ]
        case["process_identities"] = [
            {
                "role": "helper",
                "pid": 123,
                "effective_uid": 0,
                "executable_path": str(pathlib.Path(sys.executable).resolve()),
                "raw_artifact_reference": None,
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
                "raw_artifact_reference": None,
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
            "raw_artifact_reference": None,
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
                "raw_artifact_reference": None,
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
                "raw_artifact_reference": None,
            }
        case["observed_result"] = "Signed qualification completed conclusively."

        barrier = case["barrier_evidence"][0]
        process = case["process_identities"][0]
        signing = case["signing_identities"][0]
        before_fixture = case["fixture_digests"]["before"][0]
        after_fixture = case["fixture_digests"]["after"][0]

        def fact_without_reference(value: dict[str, object]) -> dict[str, object]:
            return {
                key: item
                for key, item in value.items()
                if key != "raw_artifact_reference"
            }

        bindings: dict[str, tuple[dict[str, object], object]] = {
            "case-result-1": (
                {
                    "case_id": name,
                    "role": "case_result",
                    "iteration": 1,
                    "subject": None,
                    "predicate": None,
                },
                {
                    "contracts_exercised": case["contracts_exercised"],
                    "status": case["status"],
                    "iterations": case["iterations"],
                    "observed_result": case["observed_result"],
                },
            ),
            "barrier-1": (
                {
                    "case_id": name,
                    "role": "barrier",
                    "iteration": 1,
                    "subject": barrier["name"],
                    "predicate": None,
                },
                fact_without_reference(barrier),
            ),
            "process-helper": (
                {
                    "case_id": name,
                    "role": "process_identity",
                    "iteration": None,
                    "subject": process["role"],
                    "predicate": None,
                },
                fact_without_reference(process),
            ),
            "signing-helper": (
                {
                    "case_id": name,
                    "role": "signing_identity",
                    "iteration": None,
                    "subject": signing["role"],
                    "predicate": None,
                },
                fact_without_reference(signing),
            ),
            "fixture-before": (
                {
                    "case_id": name,
                    "role": "fixture_before",
                    "iteration": None,
                    "subject": before_fixture["label"],
                    "predicate": None,
                },
                fact_without_reference(before_fixture),
            ),
            "fixture-after": (
                {
                    "case_id": name,
                    "role": "fixture_after",
                    "iteration": None,
                    "subject": after_fixture["label"],
                    "predicate": None,
                },
                fact_without_reference(after_fixture),
            ),
        }
        if case["mount_facts"]["applicable"] is True:
            bindings["mount"] = (
                {
                    "case_id": name,
                    "role": "mount",
                    "iteration": None,
                    "subject": None,
                    "predicate": None,
                },
                fact_without_reference(case["mount_facts"]),
            )
        if case["crash_point"]["applicable"] is True:
            bindings["crash"] = (
                {
                    "case_id": name,
                    "role": "crash",
                    "iteration": None,
                    "subject": None,
                    "predicate": None,
                },
                fact_without_reference(case["crash_point"]),
            )
        references = self.install_scoped_evidence(
            root,
            evidence_id=f"EVID-fixture-case-{name}",
            bindings=bindings,
        )
        case["raw_artifact_references"] = [references["case-result-1"]]
        barrier["raw_artifact_reference"] = references["barrier-1"]
        process["raw_artifact_reference"] = references["process-helper"]
        signing["raw_artifact_reference"] = references["signing-helper"]
        before_fixture["raw_artifact_reference"] = references["fixture-before"]
        after_fixture["raw_artifact_reference"] = references["fixture-after"]
        if "mount" in references:
            case["mount_facts"]["raw_artifact_reference"] = references["mount"]
        if "crash" in references:
            case["crash_point"]["raw_artifact_reference"] = references["crash"]

    def privileged_filesystem_report(
        self,
        root: pathlib.Path,
        matrix: dict[str, object],
    ) -> dict[str, object]:
        report = json.loads(PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8"))
        provenance = execution_provenance(root.resolve())
        report.update(
            {
                "status": "passed",
                "ok": True,
                "source_manifest": source_manifest(root),
                "captured_at": "2026-08-30T00:00:00Z",
                "repository": provenance["repository"],
                "test_environment": provenance["test_environment"],
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
        qualification_context = {
            "captured_at": report["captured_at"],
            "repository": report["repository"],
            "test_environment": report["test_environment"],
            "test_processes": report["test_processes"],
            "same_uid_fallback": report["same_uid_fallback"],
            "same_uid_threat_model": report["same_uid_threat_model"],
        }
        context_references = self.install_scoped_evidence(
            root,
            evidence_id="EVID-fixture-qualification-context",
            bindings={
                "qualification-context": (
                    {
                        "case_id": None,
                        "role": "qualification_context",
                        "iteration": None,
                        "subject": None,
                        "predicate": None,
                    },
                    qualification_context,
                )
            },
        )
        report["qualification_context_artifact_reference"] = context_references[
            "qualification-context"
        ]
        formal_closure = report["formal_closure"]
        self.assertIsInstance(formal_closure, dict)
        predicates = sorted(
            key
            for key in formal_closure
            if key != "formal_argument_artifact_references"
        )
        formal_bindings: dict[str, tuple[dict[str, object], object]] = {}
        for index, predicate in enumerate(predicates):
            formal_closure[predicate] = True
            formal_bindings[f"formal-{index:02d}"] = (
                {
                    "case_id": None,
                    "role": "formal_argument",
                    "iteration": None,
                    "subject": None,
                    "predicate": predicate,
                },
                {"predicate": predicate, "value": True},
            )
        formal_references = self.install_scoped_evidence(
            root,
            evidence_id="EVID-fixture-formal-arguments",
            evidence_kind="p10-privileged-filesystem-formal-argument",
            bindings=formal_bindings,
        )
        formal_closure["formal_argument_artifact_references"] = [
            formal_references[f"formal-{index:02d}"]
            for index in range(len(predicates))
        ]
        return report

    def filesystem_fixture(
        self,
        root: pathlib.Path,
        case_names: tuple[str, ...] | None = None,
    ) -> tuple[dict[str, object], dict[str, object]]:
        template = json.loads(
            PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
        )
        matrix = json.loads(json.dumps(template["matrix"]))
        selected = set(matrix) if case_names is None else set(case_names)
        for name in selected:
            self.populate_passing_filesystem_case(root, name, matrix[name])
        return matrix, self.privileged_filesystem_report(root, matrix)

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

    def test_privileged_filesystem_artifact_binding_schema_is_role_scoped(self) -> None:
        from jsonschema import Draft202012Validator

        schema = json.loads(
            PRIVILEGED_FILESYSTEM_ARTIFACT_SCHEMA.read_text(encoding="utf-8")
        )
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema)
        artifact = {
            "schema_version": QUALIFICATION_ARTIFACT_BINDING_SCHEMA_VERSION,
            "qualification": "p10-privileged-filesystem",
            "evidence_id": "EVID-schema-fixture",
            "source_manifest": {
                "schema_version": 1,
                "sha256": hashlib.sha256(b"manifest").hexdigest(),
                "file_count": 1,
                "bytes": 1,
            },
            "scope": {
                "case_id": "signed_debug_bundle",
                "role": "barrier",
                "iteration": 1,
                "subject": "capture-complete",
                "predicate": None,
            },
            "fact_sha256": hashlib.sha256(b"fact").hexdigest(),
            "claim": "The signed barrier was reached.",
        }
        self.assertEqual(list(validator.iter_errors(artifact)), [])

        qualification_context = json.loads(json.dumps(artifact))
        qualification_context["scope"] = {
            "case_id": None,
            "role": "qualification_context",
            "iteration": None,
            "subject": None,
            "predicate": None,
        }
        self.assertEqual(list(validator.iter_errors(qualification_context)), [])

        invalid_roles = []
        missing_barrier_subject = json.loads(json.dumps(artifact))
        missing_barrier_subject["scope"]["subject"] = None
        invalid_roles.append(missing_barrier_subject)
        process_with_iteration = json.loads(json.dumps(artifact))
        process_with_iteration["scope"].update({
            "role": "process_identity",
            "iteration": 1,
            "subject": "helper",
        })
        invalid_roles.append(process_with_iteration)
        formal_with_case_scope = json.loads(json.dumps(artifact))
        formal_with_case_scope["scope"].update({
            "role": "formal_argument",
            "iteration": None,
            "subject": None,
            "predicate": "capture_linearization",
        })
        invalid_roles.append(formal_with_case_scope)
        context_with_case_scope = json.loads(json.dumps(qualification_context))
        context_with_case_scope["scope"]["case_id"] = "signed_debug_bundle"
        invalid_roles.append(context_with_case_scope)
        for candidate in invalid_roles:
            self.assertTrue(list(validator.iter_errors(candidate)), candidate)

    def test_partial_template_keeps_all_release_authority_unclaimed(self) -> None:
        template = json.loads(
            PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
        )
        self.assertEqual(template["status"], "partial")
        self.assertFalse(template["ok"])
        self.assertIsNone(template["qualification_context_artifact_reference"])
        self.assertEqual(len(template["matrix"]), 57)
        self.assertTrue(
            all(case["status"] == "not_run" for case in template["matrix"].values())
        )
        formal = template["formal_closure"]
        formal_values = [
            value
            for key, value in formal.items()
            if key != "formal_argument_artifact_references"
        ]
        self.assertEqual(len(formal_values), 12)
        self.assertTrue(all(value is False for value in formal_values))
        self.assertEqual(formal["formal_argument_artifact_references"], [])

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
            template = json.loads(
                PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
            )
            matrix = json.loads(json.dumps(template["matrix"]))
            for name, case in matrix.items():
                self.populate_passing_filesystem_case(root, name, case)

            report = self.privileged_filesystem_report(root, matrix)
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
            template = json.loads(
                PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
            )
            matrix = json.loads(json.dumps(template["matrix"]))
            for name, case in matrix.items():
                self.populate_passing_filesystem_case(root, name, case)
            matrix["signed_debug_bundle"]["raw_artifact_references"] = [{}]
            report = self.privileged_filesystem_report(root, matrix)

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
            template = json.loads(
                PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
            )
            matrix = json.loads(json.dumps(template["matrix"]))
            for name, case in matrix.items():
                self.populate_passing_filesystem_case(root, name, case)
            report = self.privileged_filesystem_report(root, matrix)
            artifact_reference = dict(
                matrix["signed_release_bundle"]["raw_artifact_references"][0]
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

    def test_completion_checker_rejects_cross_case_artifact_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            matrix, report = self.filesystem_fixture(
                root,
                case_names=("signed_debug_bundle", "signed_release_bundle"),
            )
            debug_reference = dict(
                matrix["signed_debug_bundle"]["raw_artifact_references"][0]
            )
            matrix["signed_release_bundle"]["raw_artifact_references"] = [
                debug_reference
            ]

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "privileged filesystem case signed_release_bundle raw artifact 0 "
                "semantic artifact does not bind case_id='signed_release_bundle'",
                result.stdout,
            )
            self.assertIn(
                "artifact is reused across case or role scopes",
                result.stdout,
            )

    def test_completion_checker_rejects_case_result_artifact_across_roles(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            case_name = "crash_at_every_durable_phase"
            matrix, report = self.filesystem_fixture(root, case_names=(case_name,))
            case = matrix[case_name]
            case_result_reference = dict(case["raw_artifact_references"][0])
            case["barrier_evidence"][0]["raw_artifact_reference"] = dict(
                case_result_reference
            )
            case["process_identities"][0]["raw_artifact_reference"] = dict(
                case_result_reference
            )
            case["signing_identities"][0]["raw_artifact_reference"] = dict(
                case_result_reference
            )
            case["fixture_digests"]["before"][0]["raw_artifact_reference"] = dict(
                case_result_reference
            )
            case["fixture_digests"]["after"][0]["raw_artifact_reference"] = dict(
                case_result_reference
            )
            case["mount_facts"]["raw_artifact_reference"] = dict(
                case_result_reference
            )
            case["crash_point"]["raw_artifact_reference"] = dict(
                case_result_reference
            )

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            for role in (
                "barrier",
                "process_identity",
                "signing_identity",
                "fixture_before",
                "fixture_after",
                "mount",
                "crash",
            ):
                self.assertIn(
                    f"semantic artifact does not bind role='{role}'",
                    result.stdout,
                )
            self.assertIn(
                "artifact is reused across case or role scopes",
                result.stdout,
            )

    def test_completion_checker_rejects_formal_artifact_reused_for_two_predicates(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            formal_references = report["formal_closure"][
                "formal_argument_artifact_references"
            ]
            reused_predicate = json.loads(
                (root / formal_references[0]["path"]).read_text(encoding="utf-8")
            )["scope"]["predicate"]
            formal_references[1] = dict(formal_references[0])

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                f"privileged filesystem formal predicate {reused_predicate} reuses evidence",
                result.stdout,
            )
            self.assertIn(
                "privileged filesystem formal boundary closure is incomplete",
                result.stdout,
            )

    def test_completion_checker_rejects_stale_scoped_source_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            matrix, report = self.filesystem_fixture(
                root,
                case_names=("signed_debug_bundle",),
            )
            reference = dict(
                matrix["signed_debug_bundle"]["raw_artifact_references"][0]
            )
            artifact = json.loads(
                (root / reference["path"]).read_text(encoding="utf-8")
            )
            artifact["source_manifest"]["sha256"] = hashlib.sha256(
                b"stale manifest"
            ).hexdigest()
            matrix["signed_debug_bundle"]["raw_artifact_references"] = [
                self.replace_scoped_artifact(root, reference, artifact)
            ]

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "privileged filesystem case signed_debug_bundle raw artifact 0 "
                "semantic artifact is stale for the current source manifest",
                result.stdout,
            )

    def test_completion_checker_rejects_mismatched_recorder_child_context(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            matrix, report = self.filesystem_fixture(
                root,
                case_names=("signed_debug_bundle",),
            )
            reference = matrix["signed_debug_bundle"]["raw_artifact_references"][0]
            record_path = (
                root / f".forge-codex/evidence/{reference['evidence_id']}.json"
            )
            record = json.loads(record_path.read_text(encoding="utf-8"))
            record["child_evidence_context"]["evidence_id"] = "EVID-wrong-context"
            self.write_json(record_path, record)

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "privileged filesystem case signed_debug_bundle raw artifact 0 "
                "evidence record has no exact recorder-owned child context",
                result.stdout,
            )

    def test_completion_checker_rejects_mismatched_recorder_base_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            reference = report["qualification_context_artifact_reference"]
            record_path = (
                root / f".forge-codex/evidence/{reference['evidence_id']}.json"
            )
            record = json.loads(record_path.read_text(encoding="utf-8"))
            record["child_evidence_context"]["repository"]["base_sha"] = "f" * 40
            record["execution_provenance"]["repository"]["base_sha"] = "e" * 40
            self.write_json(record_path, record)

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "evidence record has no exact recorder-owned child context",
                result.stdout,
            )
            self.assertIn(
                "evidence record has no exact recorder-owned execution provenance",
                result.stdout,
            )

    def test_passed_report_rejects_null_qualification_identity_fields(self) -> None:
        cases = (
            (("repository", "branch"), "repository branch is empty"),
            (("repository", "head_sha"), "repository HEAD is invalid"),
            (("repository", "base_branch"), "repository base branch is empty"),
            (("repository", "base_sha"), "repository base SHA is invalid"),
            (("repository", "repository_path"), "repository path is empty"),
            (("test_environment", "macos_build"), "macOS build is empty"),
            (
                ("test_environment", "machine_identifier"),
                "machine identifier is empty",
            ),
            (("test_environment", "platform"), "platform is empty"),
            (("test_environment", "architecture"), "architecture is empty"),
        )
        for path, expected in cases:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                self.make_repository(root)
                _, report = self.filesystem_fixture(root, case_names=())
                report[path[0]][path[1]] = None

                result = self.run_completion_checker(root, report)

                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stdout)

    def test_passed_report_rejects_git_identity_and_base_mismatch(self) -> None:
        cases = (
            (
                ("repository", "branch"),
                "different-branch",
                "repository branch does not match current Git",
            ),
            (
                ("repository", "head_sha"),
                "b" * 40,
                "reported execution HEAD does not resolve",
            ),
            (
                ("repository", "base_branch"),
                "origin/main",
                "base branch is not canonical main",
            ),
            (
                ("repository", "base_sha"),
                None,
                "base SHA does not match refs/remotes/origin/main",
            ),
            (
                ("repository", "repository_path"),
                "/private/tmp/not-the-evaluator-repository",
                "repository path does not match the evaluator repository",
            ),
        )
        for path, value, expected in cases:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                self.make_repository(root)
                _, report = self.filesystem_fixture(root, case_names=())
                if path == ("repository", "base_sha"):
                    value = report["repository"]["head_sha"]
                report[path[0]][path[1]] = value

                result = self.run_completion_checker(root, report)

                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stdout)

    def test_passed_report_rejects_live_host_identity_mismatch(self) -> None:
        cases = (
            ("macos_build", "bogus-build"),
            ("machine_identifier", "bogus-machine"),
            ("platform", "bogus-platform"),
            ("architecture", "bogus-architecture"),
        )
        for field, value in cases:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                self.make_repository(root)
                _, report = self.filesystem_fixture(root, case_names=())
                report["test_environment"][field] = value

                result = self.run_completion_checker(root, report)

                self.assertEqual(result.returncode, 1)
                self.assertIn(
                    "qualification test environment does not match the evaluator host",
                    result.stdout,
                )

    def test_passed_report_rejects_missing_origin_main_base_ref(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            result = subprocess.run(
                ["git", "update-ref", "-d", "refs/remotes/origin/main"],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            checked = self.run_completion_checker(root, report)

            self.assertEqual(checked.returncode, 1)
            self.assertIn(
                "evaluator provenance is unavailable: origin main Git commit command failed",
                checked.stdout,
            )

    def test_passed_report_rejects_same_manifest_unrelated_execution_head(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            tree = subprocess.run(
                ["git", "rev-parse", "HEAD^{tree}"],
                cwd=root,
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            unrelated_head = subprocess.run(
                ["git", "commit-tree", tree, "-m", "Unrelated same-tree execution"],
                cwd=root,
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            self.assertRegex(unrelated_head, r"^[0-9a-f]{40}$")
            self.assertEqual(report["source_manifest"], source_manifest(root))
            report["repository"]["head_sha"] = unrelated_head
            reference = dict(report["qualification_context_artifact_reference"])
            artifact = json.loads(
                (root / reference["path"]).read_text(encoding="utf-8")
            )
            context_fact = {
                "captured_at": report["captured_at"],
                "repository": report["repository"],
                "test_environment": report["test_environment"],
                "test_processes": report["test_processes"],
                "same_uid_fallback": report["same_uid_fallback"],
                "same_uid_threat_model": report["same_uid_threat_model"],
            }
            artifact["fact_sha256"] = canonical_json_sha256(context_fact)
            report["qualification_context_artifact_reference"] = (
                self.replace_scoped_artifact(root, reference, artifact)
            )

            checked = self.run_completion_checker(root, report)

            self.assertEqual(checked.returncode, 1)
            self.assertIn(
                "origin main is not an ancestor of the reported execution HEAD",
                checked.stdout,
            )
            self.assertIn(
                "reported execution HEAD is not an ancestor of current Git HEAD",
                checked.stdout,
            )

    def test_passed_report_rejects_same_manifest_older_ancestor_without_recorder_binding(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            report["repository"]["head_sha"] = report["repository"]["base_sha"]
            self.assertEqual(report["source_manifest"], source_manifest(root))
            reference = dict(report["qualification_context_artifact_reference"])
            artifact = json.loads(
                (root / reference["path"]).read_text(encoding="utf-8")
            )
            context_fact = {
                "captured_at": report["captured_at"],
                "repository": report["repository"],
                "test_environment": report["test_environment"],
                "test_processes": report["test_processes"],
                "same_uid_fallback": report["same_uid_fallback"],
                "same_uid_threat_model": report["same_uid_threat_model"],
            }
            artifact["fact_sha256"] = canonical_json_sha256(context_fact)
            report["qualification_context_artifact_reference"] = (
                self.replace_scoped_artifact(root, reference, artifact)
            )

            checked = self.run_completion_checker(root, report)

            self.assertEqual(checked.returncode, 1)
            self.assertNotIn(
                "origin main is not an ancestor of the reported execution HEAD",
                checked.stdout,
            )
            self.assertNotIn(
                "reported execution HEAD is not an ancestor of current Git HEAD",
                checked.stdout,
            )
            self.assertNotIn(
                "committed transport changed a non-state/non-evidence path",
                checked.stdout,
            )
            self.assertIn(
                "evidence record has no exact recorder-owned child context",
                checked.stdout,
            )
            self.assertIn(
                "evidence record has no exact recorder-owned execution provenance",
                checked.stdout,
            )

    def test_passed_report_accepts_state_and_evidence_only_transport_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            execution_head = report["repository"]["head_sha"]
            marker = root / ".forge-codex/state/transport-marker.json"
            self.write_json(marker, {"execution_head": execution_head})
            evidence_marker = root / ".forge-codex/evidence/transport-marker.json"
            self.write_json(evidence_marker, {"execution_head": execution_head})
            for index in range(96):
                self.write_json(
                    root
                    / ".forge-codex/evidence/"
                    f"transport-marker-{index:03d}-bounded-qualification-copy.json",
                    {"index": index},
                )
            for command in (
                [
                    "git",
                    "add",
                    ".forge-codex/state/transport-marker.json",
                    ".forge-codex/evidence",
                ],
                ["git", "commit", "-m", "Record transport marker"],
            ):
                result = subprocess.run(
                    command,
                    cwd=root,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            checked = self.run_completion_checker(root, report)

            self.assertNotIn("reported execution HEAD does not resolve", checked.stdout)
            self.assertNotIn(
                "reported execution HEAD is not an ancestor of current Git HEAD",
                checked.stdout,
            )
            self.assertNotIn(
                "committed transport changed a non-state/non-evidence path",
                checked.stdout,
            )
            self.assertNotIn("exceeds its read bound", checked.stdout)

    def test_passed_report_rejects_source_change_after_execution_head(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            (root / "Sources/App.swift").write_text(
                "struct ChangedAfterQualification {}\n",
                encoding="utf-8",
            )
            for command in (
                ["git", "add", "Sources/App.swift"],
                ["git", "commit", "-m", "Change qualification source"],
            ):
                result = subprocess.run(
                    command,
                    cwd=root,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            checked = self.run_completion_checker(root, report)

            self.assertEqual(checked.returncode, 1)
            self.assertIn(
                "privileged filesystem qualification committed transport changed "
                "a non-state/non-evidence path: Sources/App.swift",
                checked.stdout,
            )

    def test_passed_report_rejects_seal_script_change_after_execution_head(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            seal_script = root / "script/seal_filesystem_daemon_identity.sh"
            seal_script.write_text("#!/bin/sh\nexit 7\n", encoding="utf-8")
            for command in (
                ["git", "add", "script/seal_filesystem_daemon_identity.sh"],
                ["git", "commit", "-m", "Change identity seal script"],
            ):
                result = subprocess.run(
                    command,
                    cwd=root,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            checked = self.run_completion_checker(root, report)

            self.assertEqual(checked.returncode, 1)
            self.assertIn(
                "committed transport changed a non-state/non-evidence path: "
                "script/seal_filesystem_daemon_identity.sh",
                checked.stdout,
            )

    def test_passed_report_rejects_seal_script_change_then_revert_history(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            seal_script = root / "script/seal_filesystem_daemon_identity.sh"
            original = seal_script.read_bytes()
            seal_script.write_text("#!/bin/sh\nexit 9\n", encoding="utf-8")
            commands = (
                ["git", "add", "script/seal_filesystem_daemon_identity.sh"],
                ["git", "commit", "-m", "Temporarily change identity seal script"],
            )
            for command in commands:
                result = subprocess.run(
                    command,
                    cwd=root,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            seal_script.write_bytes(original)
            for command in (
                ["git", "add", "script/seal_filesystem_daemon_identity.sh"],
                ["git", "commit", "-m", "Restore identity seal script"],
            ):
                result = subprocess.run(
                    command,
                    cwd=root,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(report["source_manifest"], source_manifest(root))

            checked = self.run_completion_checker(root, report)

            self.assertEqual(checked.returncode, 1)
            self.assertIn(
                "committed transport changed a non-state/non-evidence path: "
                "script/seal_filesystem_daemon_identity.sh",
                checked.stdout,
            )

    def test_passed_report_rejects_arbitrary_committed_transport_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            (root / "README.md").write_text("post-execution source\n", encoding="utf-8")
            for command in (
                ["git", "add", "README.md"],
                ["git", "commit", "-m", "Add unrelated post-execution file"],
            ):
                result = subprocess.run(
                    command,
                    cwd=root,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            checked = self.run_completion_checker(root, report)

            self.assertEqual(checked.returncode, 1)
            self.assertIn(
                "committed transport changed a non-state/non-evidence path: README.md",
                checked.stdout,
            )

    def test_passed_report_rejects_dirty_manifest_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            (root / "script/seal_filesystem_daemon_identity.sh").write_text(
                "#!/bin/sh\nexit 5\n",
                encoding="utf-8",
            )

            checked = self.run_completion_checker(root, report)

            self.assertEqual(checked.returncode, 1)
            self.assertIn(
                "privileged filesystem manifest targets have uncommitted changes",
                checked.stdout,
            )

    def test_passed_report_rejects_missing_and_mismatched_context_binding(self) -> None:
        for mode in ("missing", "mismatched"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                self.make_repository(root)
                _, report = self.filesystem_fixture(root, case_names=())
                if mode == "missing":
                    report["qualification_context_artifact_reference"] = None
                    expected = "qualification context artifact is not an exact artifact reference"
                else:
                    report["captured_at"] = "2026-08-30T00:00:00.500000Z"
                    expected = (
                        "qualification context artifact semantic artifact does not "
                        "bind the exact report fact"
                    )

                result = self.run_completion_checker(root, report)

                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stdout)

    def test_context_binding_rejects_captured_at_outside_evidence_interval(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            _, report = self.filesystem_fixture(root, case_names=())
            report["captured_at"] = "2026-08-30T00:00:02Z"
            reference = dict(report["qualification_context_artifact_reference"])
            artifact = json.loads(
                (root / reference["path"]).read_text(encoding="utf-8")
            )
            context_fact = {
                "captured_at": report["captured_at"],
                "repository": report["repository"],
                "test_environment": report["test_environment"],
                "test_processes": report["test_processes"],
                "same_uid_fallback": report["same_uid_fallback"],
                "same_uid_threat_model": report["same_uid_threat_model"],
            }
            artifact["fact_sha256"] = canonical_json_sha256(context_fact)
            report["qualification_context_artifact_reference"] = (
                self.replace_scoped_artifact(root, reference, artifact)
            )

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "qualification context artifact does not contain the report "
                "captured_at timestamp",
                result.stdout,
            )

    def test_semantic_evidence_rejects_incomplete_timing_and_environment(self) -> None:
        cases = (
            "missing-start",
            "invalid-ended",
            "reversed-time",
            "missing-environment",
            "wrong-cwd",
        )
        for mode in cases:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                self.make_repository(root)
                _, report = self.filesystem_fixture(root, case_names=())
                reference = report["qualification_context_artifact_reference"]
                record_path = (
                    root
                    / f".forge-codex/evidence/{reference['evidence_id']}.json"
                )
                record = json.loads(record_path.read_text(encoding="utf-8"))
                if mode == "missing-start":
                    record.pop("started_at")
                    expected = "evidence started_at is empty"
                elif mode == "invalid-ended":
                    record["ended_at"] = "not-a-timestamp"
                    expected = "evidence ended_at is not a valid ISO-8601 timestamp"
                elif mode == "reversed-time":
                    record["started_at"] = "2026-08-30T00:00:02Z"
                    expected = "evidence timestamps are reversed"
                elif mode == "missing-environment":
                    record["environment"].pop("architecture")
                    expected = "evidence environment field set is not exact"
                else:
                    record["environment"]["cwd"] = "/private/tmp/not-the-repository"
                    expected = (
                        "evidence environment does not match the evaluator host "
                        "and repository"
                    )
                self.write_json(record_path, record)

                result = self.run_completion_checker(root, report)

                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stdout)

    def test_semantic_binding_rejects_external_and_stream_storage(self) -> None:
        for storage in ("external-hash-only", "evidence-id-specific-stream"):
            with self.subTest(storage=storage), tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as external_temporary:
                root = pathlib.Path(temporary)
                self.make_repository(root)
                _, report = self.filesystem_fixture(root, case_names=())
                reference = dict(report["qualification_context_artifact_reference"])
                record_path = (
                    root
                    / f".forge-codex/evidence/{reference['evidence_id']}.json"
                )
                record = json.loads(record_path.read_text(encoding="utf-8"))
                matches = [
                    artifact
                    for artifact in record["artifacts"]
                    if artifact["path"] == reference["path"]
                ]
                self.assertEqual(len(matches), 1)
                artifact = matches[0]
                artifact["storage"] = storage
                if storage == "external-hash-only":
                    external_path = pathlib.Path(external_temporary) / "context.json"
                    external_path.write_bytes((root / reference["path"]).read_bytes())
                    artifact["path"] = str(external_path)
                    artifact["portability"] = "origin-host-required"
                    artifact.pop("source_path", None)
                    reference["path"] = str(external_path)
                self.write_json(record_path, record)
                report["qualification_context_artifact_reference"] = reference

                result = self.run_completion_checker(root, report)

                self.assertEqual(result.returncode, 1)
                self.assertIn(
                    "semantic artifact is not a recorder-preserved "
                    "evidence-id-specific copy inside the repository",
                    result.stdout,
                )

    def test_semantic_binding_rejects_noncanonical_source_path(self) -> None:
        cases = (
            "/tmp/context.json",
            "qualification-artifacts/../context.json",
            "qualification-artifacts//context.json",
            "qualification-artifacts\\context.json",
            "a" * 4097,
        )
        for source_path in cases:
            with self.subTest(source_path=source_path[:80]), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                self.make_repository(root)
                _, report = self.filesystem_fixture(root, case_names=())
                reference = report["qualification_context_artifact_reference"]
                record_path = (
                    root / f".forge-codex/evidence/{reference['evidence_id']}.json"
                )
                record = json.loads(record_path.read_text(encoding="utf-8"))
                match = next(
                    artifact
                    for artifact in record["artifacts"]
                    if artifact["path"] == reference["path"]
                )
                match["source_path"] = source_path
                self.write_json(record_path, record)

                result = self.run_completion_checker(root, report)

                self.assertEqual(result.returncode, 1)
                self.assertIn(
                    "semantic artifact is not a recorder-preserved "
                    "evidence-id-specific copy inside the repository",
                    result.stdout,
                )

    def test_completion_checker_rejects_placeholder_claim_and_scope(self) -> None:
        for field in ("claim", "scope"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                self.make_repository(root)
                matrix, report = self.filesystem_fixture(
                    root,
                    case_names=("signed_debug_bundle",),
                )
                case = matrix["signed_debug_bundle"]
                if field == "claim":
                    reference = dict(case["raw_artifact_references"][0])
                    artifact = json.loads(
                        (root / reference["path"]).read_text(encoding="utf-8")
                    )
                    artifact["claim"] = "placeholder"
                    case["raw_artifact_references"] = [
                        self.replace_scoped_artifact(root, reference, artifact)
                    ]
                    expected = "qualification artifact schema error at claim"
                else:
                    process = case["process_identities"][0]
                    reference = dict(process["raw_artifact_reference"])
                    artifact = json.loads(
                        (root / reference["path"]).read_text(encoding="utf-8")
                    )
                    artifact["scope"]["subject"] = "placeholder"
                    process["raw_artifact_reference"] = self.replace_scoped_artifact(
                        root,
                        reference,
                        artifact,
                    )
                    expected = "qualification artifact schema error at scope.subject"

                result = self.run_completion_checker(root, report)

                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stdout)

    def test_completion_checker_rejects_mismatched_scoped_fact_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            matrix, report = self.filesystem_fixture(
                root,
                case_names=("signed_debug_bundle",),
            )
            reference = dict(
                matrix["signed_debug_bundle"]["raw_artifact_references"][0]
            )
            artifact = json.loads(
                (root / reference["path"]).read_text(encoding="utf-8")
            )
            artifact["fact_sha256"] = canonical_json_sha256({"different": True})
            matrix["signed_debug_bundle"]["raw_artifact_references"] = [
                self.replace_scoped_artifact(root, reference, artifact)
            ]

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "privileged filesystem case signed_debug_bundle raw artifact 0 "
                "semantic artifact does not bind the exact report fact",
                result.stdout,
            )

    def test_completion_checker_rejects_binding_changed_after_reference_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            matrix, report = self.filesystem_fixture(
                root,
                case_names=("signed_debug_bundle",),
            )
            reference = dict(
                matrix["signed_debug_bundle"]["raw_artifact_references"][0]
            )
            artifact_path = root / reference["path"]
            artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
            original_claim = artifact["claim"]
            artifact["claim"] = "X" + original_claim[1:]
            artifact_path.chmod(0o644)
            self.write_json(artifact_path, artifact)
            artifact_path.chmod(0o444)

            result = self.run_completion_checker(root, report)

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "qualification artifact bytes do not match the referenced SHA-256",
                result.stdout,
            )

    def test_qualification_artifact_loader_rejects_read_time_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            references = self.install_scoped_evidence(
                root,
                evidence_id="EVID-read-time-mutation",
                bindings={
                    "case-result-1": (
                        {
                            "case_id": "signed_debug_bundle",
                            "role": "case_result",
                            "iteration": 1,
                            "subject": None,
                            "predicate": None,
                        },
                        {"status": "passed"},
                    )
                },
            )
            reference = references["case-result-1"]
            artifact_path = root.resolve() / reference["path"]
            schema_path = (
                root
                / ".forge-codex/schemas/p10-privileged-filesystem-artifact-binding.schema.json"
            )
            real_read = os.read
            mutated = False

            def mutate_after_first_read(descriptor: int, byte_count: int) -> bytes:
                nonlocal mutated
                block = real_read(descriptor, byte_count)
                if not mutated:
                    mutated = True
                    artifact_path.chmod(0o644)
                    with artifact_path.open("ab") as stream:
                        stream.write(b" ")
                        stream.flush()
                        os.fsync(stream.fileno())
                return block

            with mock.patch(
                "evidence_support.os.read",
                side_effect=mutate_after_first_read,
            ):
                with self.assertRaisesRegex(
                    EvidenceSupportError,
                    "changed during its bounded read",
                ):
                    load_qualification_artifact(
                        artifact_path,
                        expected_sha256=reference["sha256"],
                        expected_bytes=artifact_path.stat().st_size,
                        repository_root=root.resolve(),
                        schema_path=schema_path,
                    )
            self.assertTrue(mutated)

    def test_qualification_artifact_loader_rejects_same_inode_rewrite_before_path_verification(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            references = self.install_scoped_evidence(
                root,
                evidence_id="EVID-same-inode-rewrite",
                bindings={
                    "case-result-1": (
                        {
                            "case_id": "signed_debug_bundle",
                            "role": "case_result",
                            "iteration": 1,
                            "subject": None,
                            "predicate": None,
                        },
                        {"status": "passed"},
                    )
                },
            )
            reference = references["case-result-1"]
            artifact_path = root.resolve() / reference["path"]
            original_bytes = artifact_path.read_bytes()
            original = json.loads(original_bytes)
            replacement = dict(original)
            claim = replacement["claim"]
            replacement["claim"] = ("X" if claim[0] != "X" else "Y") + claim[1:]
            replacement_bytes = (
                json.dumps(replacement, indent=2, sort_keys=True) + "\n"
            ).encode("utf-8")
            self.assertEqual(len(replacement_bytes), len(original_bytes))
            schema_path = (
                root
                / ".forge-codex/schemas/"
                "p10-privileged-filesystem-artifact-binding.schema.json"
            )
            original_stat = artifact_path.stat()
            original_inode = original_stat.st_ino
            real_fstat = os.fstat
            descriptor_fstats = 0
            mutated = False

            def rewrite_after_post_read_fstat(descriptor: int) -> os.stat_result:
                nonlocal descriptor_fstats, mutated
                metadata = real_fstat(descriptor)
                descriptor_fstats += 1
                if descriptor_fstats == 2:
                    artifact_path.chmod(0o644)
                    with artifact_path.open("r+b") as stream:
                        stream.seek(0)
                        stream.write(replacement_bytes)
                        stream.truncate()
                        stream.flush()
                        os.fsync(stream.fileno())
                    os.utime(
                        artifact_path,
                        ns=(
                            original_stat.st_atime_ns,
                            original_stat.st_mtime_ns + 2_000_000_000,
                        ),
                    )
                    artifact_path.chmod(0o444)
                    rewritten_stat = artifact_path.stat()
                    self.assertEqual(rewritten_stat.st_ino, original_inode)
                    self.assertEqual(rewritten_stat.st_size, len(original_bytes))
                    self.assertEqual(stat.S_IMODE(rewritten_stat.st_mode), 0o444)
                    mutated = True
                return metadata

            with mock.patch(
                "evidence_support.os.fstat",
                side_effect=rewrite_after_post_read_fstat,
            ):
                with self.assertRaisesRegex(
                    EvidenceSupportError,
                    "pathname no longer names the opened file",
                ):
                    load_qualification_artifact(
                        artifact_path,
                        expected_sha256=reference["sha256"],
                        expected_bytes=len(original_bytes),
                        repository_root=root.resolve(),
                        schema_path=schema_path,
                    )
            self.assertTrue(mutated)
            self.assertEqual(artifact_path.stat().st_ino, original_inode)
            self.assertEqual(stat.S_IMODE(artifact_path.stat().st_mode), 0o444)
            self.assertEqual(artifact_path.read_bytes(), replacement_bytes)
            self.assertNotEqual(artifact_path.read_bytes(), original_bytes)

    def test_qualification_artifact_loader_rejects_unsafe_copy_postconditions(
        self,
    ) -> None:
        cases = (
            ("mode", "mode is not exactly 0444"),
            ("owner", "not owned by the current effective user"),
            ("hard-link", "does not have exactly one hard link"),
            ("final-symlink", "unavailable or contains a symlink"),
            ("intermediate-symlink", "unavailable or contains a symlink"),
            ("oversized", "recorded byte count is invalid or exceeds"),
        )
        for mode, expected in cases:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                self.make_repository(root)
                references = self.install_scoped_evidence(
                    root,
                    evidence_id=f"EVID-unsafe-{mode}",
                    bindings={
                        "case-result-1": (
                            {
                                "case_id": "signed_debug_bundle",
                                "role": "case_result",
                                "iteration": 1,
                                "subject": None,
                                "predicate": None,
                            },
                            {"status": "passed"},
                        )
                    },
                )
                reference = references["case-result-1"]
                artifact_path = root.resolve() / reference["path"]
                expected_bytes = artifact_path.stat().st_size
                expected_sha256 = reference["sha256"]
                fstat_patch = None
                if mode == "mode":
                    artifact_path.chmod(0o644)
                elif mode == "owner":
                    actual = os.stat(artifact_path)
                    forged = mock.Mock(
                        st_mode=actual.st_mode,
                        st_uid=os.geteuid() + 1,
                    )
                    fstat_patch = mock.patch(
                        "evidence_support.os.fstat",
                        return_value=forged,
                    )
                elif mode == "hard-link":
                    os.link(artifact_path, artifact_path.with_name("second-link.json"))
                elif mode == "final-symlink":
                    target = artifact_path.with_name("binding-target.json")
                    artifact_path.rename(target)
                    artifact_path.symlink_to(target.name)
                elif mode == "intermediate-symlink":
                    evidence_directory = artifact_path.parent
                    target_directory = evidence_directory.with_name("captured-evidence")
                    evidence_directory.rename(target_directory)
                    evidence_directory.symlink_to(target_directory.name)
                else:
                    artifact_path.chmod(0o644)
                    with artifact_path.open("ab") as stream:
                        stream.write(b"x" * (1024 * 1024 + 1 - expected_bytes))
                    artifact_path.chmod(0o444)
                    raw = artifact_path.read_bytes()
                    expected_bytes = len(raw)
                    expected_sha256 = hashlib.sha256(raw).hexdigest()

                context = fstat_patch if fstat_patch is not None else mock.patch.object(
                    os,
                    "fstat",
                    wraps=os.fstat,
                )
                with context:
                    with self.assertRaisesRegex(EvidenceSupportError, expected):
                        load_qualification_artifact(
                            artifact_path,
                            expected_sha256=expected_sha256,
                            expected_bytes=expected_bytes,
                            repository_root=root.resolve(),
                            schema_path=(
                                root
                                / ".forge-codex/schemas/"
                                "p10-privileged-filesystem-artifact-binding.schema.json"
                            ),
                        )

    def test_qualification_artifact_loader_cannot_be_redirected_after_open(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            references = self.install_scoped_evidence(
                root,
                evidence_id="EVID-opened-inode-substitution",
                bindings={
                    "case-result-1": (
                        {
                            "case_id": "signed_debug_bundle",
                            "role": "case_result",
                            "iteration": 1,
                            "subject": None,
                            "predicate": None,
                        },
                        {"status": "passed"},
                    )
                },
            )
            reference = references["case-result-1"]
            artifact_path = root.resolve() / reference["path"]
            original = json.loads(artifact_path.read_text(encoding="utf-8"))
            replacement = dict(original)
            replacement["claim"] = "Replacement content must never redirect the opened descriptor."
            replacement_path = artifact_path.with_name("replacement-binding.json")
            self.write_json(replacement_path, replacement)
            replacement_path.chmod(0o444)
            schema_path = (
                root
                / ".forge-codex/schemas/p10-privileged-filesystem-artifact-binding.schema.json"
            )
            real_open = os.open
            real_fstat = os.fstat
            opened = False
            substituted = False
            descriptor_fstats = 0

            def substitute_after_open(
                raw_path: os.PathLike[str] | str,
                flags: int,
                mode: int = 0o777,
                *,
                dir_fd: int | None = None,
            ) -> int:
                nonlocal opened
                if dir_fd is None:
                    descriptor = real_open(raw_path, flags, mode)
                else:
                    descriptor = real_open(raw_path, flags, mode, dir_fd=dir_fd)
                if pathlib.Path(raw_path).name == artifact_path.name:
                    opened = True
                return descriptor

            def substitute_after_stable_descriptor_read(descriptor: int) -> os.stat_result:
                nonlocal descriptor_fstats, substituted
                metadata = real_fstat(descriptor)
                if opened:
                    descriptor_fstats += 1
                if descriptor_fstats == 2 and not substituted:
                    substituted = True
                    os.replace(replacement_path, artifact_path)
                return metadata

            with mock.patch(
                "evidence_support.os.open",
                side_effect=substitute_after_open,
            ), mock.patch(
                "evidence_support.os.fstat",
                side_effect=substitute_after_stable_descriptor_read,
            ):
                with self.assertRaisesRegex(
                    EvidenceSupportError,
                    "pathname no longer names the opened file",
                ):
                    load_qualification_artifact(
                        artifact_path,
                        expected_sha256=reference["sha256"],
                        expected_bytes=artifact_path.stat().st_size,
                        repository_root=root.resolve(),
                        schema_path=schema_path,
                    )
            self.assertTrue(substituted)
            self.assertEqual(
                json.loads(artifact_path.read_text(encoding="utf-8"))["claim"],
                replacement["claim"],
            )

    def test_completion_checker_rejects_required_mount_and_crash_nonapplicability(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            template = json.loads(
                PRIVILEGED_FILESYSTEM_TEMPLATE.read_text(encoding="utf-8")
            )
            matrix = json.loads(json.dumps(template["matrix"]))
            for name, case in matrix.items():
                self.populate_passing_filesystem_case(root, name, case)
            matrix["network_volume_rejected"]["mount_facts"] = json.loads(
                json.dumps(template["matrix"]["network_volume_rejected"]["mount_facts"])
            )
            matrix["crash_at_every_durable_phase"]["crash_point"] = json.loads(
                json.dumps(
                    template["matrix"]["crash_at_every_durable_phase"]["crash_point"]
                )
            )
            report = self.privileged_filesystem_report(root, matrix)

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
        (root / "script").mkdir()
        (root / ".forge-codex/scripts").mkdir(parents=True)
        schema_directory = root / ".forge-codex/schemas"
        schema_directory.mkdir(parents=True)
        (
            schema_directory
            / "p10-privileged-filesystem-qualification-report.schema.json"
        ).write_bytes(PRIVILEGED_FILESYSTEM_SCHEMA.read_bytes())
        (
            schema_directory
            / "p10-privileged-filesystem-artifact-binding.schema.json"
        ).write_bytes(PRIVILEGED_FILESYSTEM_ARTIFACT_SCHEMA.read_bytes())
        (root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
        (root / "Sources/App.swift").write_text("struct App {}\n", encoding="utf-8")
        (root / "Tests/AppTests.swift").write_text("struct AppTests {}\n", encoding="utf-8")
        (root / "script/seal_filesystem_daemon_identity.sh").write_text(
            "#!/bin/sh\nexit 0\n",
            encoding="utf-8",
        )
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
        for command in (
            ["git", "init", "-b", "main"],
            ["git", "config", "user.name", "Fixture User"],
            ["git", "config", "user.email", "fixture@example.invalid"],
            [
                "git",
                "add",
                "Package.swift",
                "Sources",
                "Tests",
                "script",
                ".forge-codex",
            ],
            ["git", "commit", "-m", "Create fixture baseline"],
            ["git", "update-ref", "refs/remotes/origin/main", "HEAD"],
            ["git", "switch", "-c", "security-validation"],
            ["git", "commit", "--allow-empty", "-m", "Create validation branch"],
        ):
            result = subprocess.run(
                command,
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

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
            schema.parent.mkdir(parents=True, exist_ok=True)
            schema.write_text('{"schema":"qualification-v1"}\n', encoding="utf-8")
            schema_manifest = source_manifest(root)
            schema.write_text('{"schema":"qualification-v2"}\n', encoding="utf-8")
            self.assertNotEqual(schema_manifest, source_manifest(root))

            binding_schema = (
                root
                / ".forge-codex/schemas/p10-privileged-filesystem-artifact-binding.schema.json"
            )
            binding_schema.write_text(
                '{"schema":"binding-v1"}\n',
                encoding="utf-8",
            )
            binding_manifest = source_manifest(root)
            binding_schema.write_text(
                '{"schema":"binding-v2"}\n',
                encoding="utf-8",
            )
            self.assertNotEqual(binding_manifest, source_manifest(root))

            seal_script = root / "script/seal_filesystem_daemon_identity.sh"
            seal_manifest = source_manifest(root)
            seal_script.write_text("#!/bin/sh\nexit 4\n", encoding="utf-8")
            self.assertNotEqual(seal_manifest, source_manifest(root))

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

    def test_recorder_refuses_to_launch_without_origin_main_base_ref(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            result = subprocess.run(
                ["git", "update-ref", "-d", "refs/remotes/origin/main"],
                cwd=root,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            marker = root / "child-launched.txt"
            child_program = (
                "import pathlib; "
                f"pathlib.Path({str(marker)!r}).write_text('launched', encoding='utf-8')"
            )

            recorded = subprocess.run(
                [
                    sys.executable,
                    str(RECORDER),
                    "--repo",
                    str(root),
                    "--kind",
                    "fixture",
                    "--",
                    sys.executable,
                    "-c",
                    child_program,
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(recorded.returncode, 0)
            self.assertIn("origin main Git commit command failed", recorded.stderr)
            self.assertFalse(marker.exists())
            self.assertEqual(self.records(root), [])

    def test_recorder_child_emits_checker_valid_scoped_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            matrix, report = self.filesystem_fixture(
                root,
                case_names=("signed_debug_bundle",),
            )
            case = matrix["signed_debug_bundle"]
            fact = {
                "contracts_exercised": case["contracts_exercised"],
                "status": case["status"],
                "iterations": case["iterations"],
                "observed_result": case["observed_result"],
            }
            expected_child_provenance = {
                "repository": report["repository"],
                "test_environment": report["test_environment"],
            }
            child_program = "\n".join((
                "import json, os, pathlib",
                "manifest = json.loads(os.environ['FORGE_EVIDENCE_SOURCE_MANIFEST_JSON'])",
                f"expected_repository = {report['repository']!r}",
                f"expected_environment = {report['test_environment']!r}",
                "actual_repository = {",
                "  'branch': os.environ['FORGE_EVIDENCE_REPOSITORY_BRANCH'],",
                "  'head_sha': os.environ['FORGE_EVIDENCE_REPOSITORY_HEAD_SHA'],",
                "  'base_branch': os.environ['FORGE_EVIDENCE_BASE_BRANCH'],",
                "  'base_sha': os.environ['FORGE_EVIDENCE_BASE_SHA'],",
                "  'repository_path': os.environ['FORGE_EVIDENCE_REPOSITORY_PATH'],",
                "}",
                "actual_environment = {",
                "  'macos_build': os.environ['FORGE_EVIDENCE_MACOS_BUILD'],",
                "  'machine_identifier': os.environ['FORGE_EVIDENCE_MACHINE_IDENTIFIER'],",
                "  'platform': os.environ['FORGE_EVIDENCE_PLATFORM'],",
                "  'architecture': os.environ['FORGE_EVIDENCE_ARCHITECTURE'],",
                "}",
                "assert actual_repository == expected_repository",
                "assert actual_environment == expected_environment",
                "payload = {",
                "  'schema_version': int(os.environ['FORGE_EVIDENCE_BINDING_SCHEMA_VERSION']),",
                "  'qualification': os.environ['FORGE_EVIDENCE_QUALIFICATION'],",
                "  'evidence_id': os.environ['FORGE_EVIDENCE_ID'],",
                "  'source_manifest': manifest,",
                "  'scope': {'case_id': 'signed_debug_bundle', 'role': 'case_result', 'iteration': 1, 'subject': None, 'predicate': None},",
                f"  'fact_sha256': {canonical_json_sha256(fact)!r},",
                "  'claim': 'The signed debug qualification case completed conclusively.',",
                "}",
                "pathlib.Path('scoped.json').write_text(json.dumps(payload, sort_keys=True) + '\\n', encoding='utf-8')",
            ))
            result = subprocess.run(
                [
                    sys.executable,
                    str(RECORDER),
                    "--repo",
                    str(root),
                    "--kind",
                    "p10-privileged-filesystem-qualification",
                    "--related-gate",
                    "G10",
                    "--related-finding",
                    "FC-FILESYSTEM-PATH-TOCTOU-001",
                    "--artifact",
                    "scoped.json",
                    "--",
                    sys.executable,
                    "-c",
                    child_program,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            record = json.loads(result.stdout)
            self.assertEqual(
                record["kind"],
                "p10-privileged-filesystem-qualification",
            )
            preserved = next(
                artifact
                for artifact in record["artifacts"]
                if artifact.get("source_path") == "scoped.json"
            )
            reference = {
                "evidence_id": record["id"],
                "path": preserved["path"],
                "sha256": preserved["sha256"],
            }
            envelope = load_qualification_artifact(
                root.resolve() / preserved["path"],
                expected_sha256=preserved["sha256"],
                expected_bytes=preserved["bytes"],
                repository_root=root.resolve(),
                schema_path=(
                    root
                    / ".forge-codex/schemas/p10-privileged-filesystem-artifact-binding.schema.json"
                ),
            )
            self.assertEqual(envelope["evidence_id"], record["id"])
            self.assertEqual(envelope["source_manifest"], record["source_manifest"])
            self.assertEqual(
                record["child_evidence_context"],
                {
                    "schema_version": 1,
                    "binding_schema_version": 1,
                    "evidence_id": record["id"],
                    "source_manifest": record["source_manifest"],
                    "repository": report["repository"],
                    "test_environment": report["test_environment"],
                    "qualification": "p10-privileged-filesystem",
                },
            )
            self.assertEqual(record["execution_provenance"], expected_child_provenance)
            self.assertEqual(
                record["environment"],
                {
                    "platform": report["test_environment"]["platform"],
                    "architecture": report["test_environment"]["architecture"],
                    "macos_build": report["test_environment"]["macos_build"],
                    "machine_identifier": report["test_environment"][
                        "machine_identifier"
                    ],
                    "cwd": report["repository"]["repository_path"],
                },
            )

            case["raw_artifact_references"] = [reference]
            checked = self.run_completion_checker(root, report)
            self.assertEqual(checked.returncode, 1)
            self.assertNotIn(
                "privileged filesystem case signed_debug_bundle raw artifact 0 ",
                checked.stdout,
            )

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
            ready = root / "partial-ready"
            server = self.make_server(
                root,
                "import os, pathlib, time\n"
                f"os.write(1, {partial!r})\n"
                f"pathlib.Path({str(ready)!r}).write_text('ready', encoding='utf-8')\n"
                "time.sleep(10)\n",
            )
            process = MCPProcess(server, root, "partial-line")
            try:
                ready_deadline = time.monotonic() + 2.0
                while not ready.exists() and time.monotonic() < ready_deadline:
                    time.sleep(0.005)
                self.assertTrue(ready.exists(), "fixture did not publish readiness")
                started = time.monotonic()
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
