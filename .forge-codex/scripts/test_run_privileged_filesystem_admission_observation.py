#!/usr/bin/env python3
"""Focused regressions for the non-mutating admission observation recorder."""

from __future__ import annotations

import argparse
import copy
import pathlib
import sys
import unittest


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_ROOT.parents[1]
sys.path.insert(0, str(SCRIPT_ROOT))

import run_privileged_filesystem_admission_observation as runner  # noqa: E402


HASH_A = "a" * 40
HASH_B = "b" * 40
CLIENT_HASH = "c" * 40
RUN_ID = "11111111-1111-1111-1111-111111111111"
SESSION_ID = "22222222-2222-2222-2222-222222222222"


def health(event: str, *, session_id: str = SESSION_ID, code_hash: str = HASH_A) -> dict:
    return {
        "schema_version": 1,
        "event": event,
        "session_id": session_id,
        "ok": True,
        "code": "ok",
        "message": "Secure filesystem service is available",
        "service_identity_verified": True,
        "connection_reused": event == "post_health",
        "status_durability_confirmed": True,
        "hold_ms": 5000,
        "protocol_version": 5,
        "product_version": "0.9.0",
        "service_identifier": "com.forge-conductor.filesystem-daemon",
        "effective_uid": 0,
        "code_directory_hash": code_hash,
        "allowed_code_directory_hashes": [HASH_A, HASH_B],
    }


def adversary(event: str = "connection_invalidated") -> dict:
    combinations = {
        "connection_invalidated": (
            "candidate_connection_rejected_pending_authorized_control", "candidate_only"
        ),
        "connection_error": (
            "candidate_connection_rejected_pending_authorized_control", "candidate_only"
        ),
        "connection_interrupted": (
            "candidate_connection_rejected_pending_authorized_control", "candidate_only"
        ),
        "service_info_reply": ("unexpected_admission", "failed"),
        "deadline_expired": ("ambiguous_timeout", "ambiguous"),
    }
    outcome, status = combinations[event]
    return {
        "schema_version": 1,
        "operation": "admission-probe",
        "run_id": RUN_ID,
        "case_id": "unauthorized_same_uid_client",
        "role": "adversary",
        "process_id": 123,
        "effective_user_id": 501,
        "bundle_identifier": "com.forge-conductor.qualification-adversary",
        "client_code_directory_hash": CLIENT_HASH,
        "daemon_code_directory_hashes": [HASH_A, HASH_B],
        "daemon_signing_requirement_sha256": "d" * 64,
        "deadline_milliseconds": 2000,
        "elapsed_monotonic_nanoseconds": 10,
        "terminal_event": event,
        "outcome": outcome,
        "authorized_same_connection_control_observed": False,
        "daemon_reachability_confirmed": False,
        "unauthorized_client_rejection_confirmed": False,
        "production_mutation_exercised": False,
        "qualification_status": status,
        "rows_updated": 0,
        "formal_predicates_updated": 0,
        "completion_claims": {
            "e2": False, "p10": False, "g10": False, "g12": False, "release": False
        },
    }


class AdmissionObservationTests(unittest.TestCase):
    def test_only_explicit_invalidation_with_nonzero_exit_is_candidate_observation(self) -> None:
        self.assertEqual(
            runner.classify_adversary(adversary("connection_invalidated"), 1),
            "candidate_invalidation_observed",
        )
        self.assertEqual(
            runner.classify_adversary(adversary("connection_invalidated"), 0),
            "suspicious_adversary_exit",
        )

    def test_generic_error_interruption_admission_and_timeout_remain_blocked(self) -> None:
        expected = {
            "connection_error": "adversary_connection_error",
            "connection_interrupted": "adversary_interrupted",
            "service_info_reply": "adversary_admitted",
            "deadline_expired": "adversary_timeout",
        }
        for event, classification in expected.items():
            with self.subTest(event=event):
                self.assertEqual(runner.classify_adversary(adversary(event), 1), classification)

    def test_adversary_validation_binds_uid_pid_hashes_deadline_and_exact_combination(self) -> None:
        value = adversary()
        self.assertEqual(
            runner.validate_adversary(
                value,
                run_id=RUN_ID,
                daemon_hashes=[HASH_A, HASH_B],
                requirement_sha256="d" * 64,
                expected_cdhash=CLIENT_HASH,
                expected_pid=123,
                expected_effective_uid=501,
            ),
            value,
        )
        mutations = []
        wrong_elapsed = copy.deepcopy(value); wrong_elapsed["elapsed_monotonic_nanoseconds"] = 2_000_000_001; mutations.append(wrong_elapsed)
        wrong_uid = copy.deepcopy(value); wrong_uid["effective_user_id"] = True; mutations.append(wrong_uid)
        wrong_claim = copy.deepcopy(value); wrong_claim["completion_claims"]["e2"] = 0; mutations.append(wrong_claim)
        wrong_combo = copy.deepcopy(value); wrong_combo["terminal_event"] = "connection_error"; wrong_combo["outcome"] = "unexpected_admission"; mutations.append(wrong_combo)
        for invalid in mutations:
            with self.assertRaises(runner.ObservationError):
                runner.validate_adversary(
                    invalid,
                    run_id=RUN_ID,
                    daemon_hashes=[HASH_A, HASH_B],
                    requirement_sha256="d" * 64,
                    expected_cdhash=CLIENT_HASH,
                    expected_pid=123,
                    expected_effective_uid=501,
                )

    def test_health_requires_strict_root_service_facts_and_exact_hash_membership(self) -> None:
        value = health("pre_health")
        self.assertEqual(
            runner.validate_health(
                value, event="pre_health", hold_ms=5000, daemon_hashes=[HASH_A, HASH_B]
            ),
            value,
        )
        for key, replacement in (
            ("schema_version", True),
            ("effective_uid", False),
            ("code_directory_hash", CLIENT_HASH),
            ("allowed_code_directory_hashes", [HASH_A]),
        ):
            invalid = copy.deepcopy(value); invalid[key] = replacement
            with self.assertRaises(runner.ObservationError):
                runner.validate_health(
                    invalid, event="pre_health", hold_ms=5000,
                    daemon_hashes=[HASH_A, HASH_B],
                )

    def test_failed_pre_health_allows_empty_unavailable_peer_hash_set(self) -> None:
        value = {
            "schema_version": 1,
            "event": "pre_health",
            "session_id": SESSION_ID,
            "ok": False,
            "code": "secure_filesystem_helper_unavailable",
            "message": "Secure filesystem service is unavailable",
            "service_identity_verified": False,
            "connection_reused": False,
            "status_durability_confirmed": False,
            "hold_ms": 5000,
            "allowed_code_directory_hashes": [],
        }
        self.assertEqual(
            runner.validate_health(
                value, event="pre_health", hold_ms=5000,
                daemon_hashes=[HASH_A, HASH_B],
            ),
            value,
        )
        args = argparse.Namespace(
            cli=pathlib.Path("/tmp/cli"), adversary=pathlib.Path("/tmp/adversary"),
            expected_team="9AQ2C2838M", daemon_cdhash=[HASH_A, HASH_B], hold_ms=5000,
            command_timeout=18.0, output=pathlib.Path("/tmp/report.json"), execute=True,
        )
        report = runner.initial_report(args)
        report["classification"] = "authorized_daemon_unavailable"
        report["observations"]["authorized_pre_health"] = value
        runner.validate_schema(report)

    def test_pair_requires_same_session_reused_connection_and_same_exact_daemon(self) -> None:
        pre, post = health("pre_health"), health("post_health")
        self.assertTrue(all(runner.validate_pair(pre, post, [HASH_A, HASH_B]).values()))
        changed_session = copy.deepcopy(post); changed_session["session_id"] = RUN_ID
        self.assertFalse(runner.validate_pair(pre, changed_session, [HASH_A, HASH_B])["same_session_id"])
        changed_hash = copy.deepcopy(post); changed_hash["code_directory_hash"] = HASH_B
        facts = runner.validate_pair(pre, changed_hash, [HASH_A, HASH_B])
        self.assertFalse(facts["daemon_code_directory_hash_equal"])
        self.assertTrue(facts["daemon_hash_in_exact_context"])
        changed_seal = copy.deepcopy(post); changed_seal["allowed_code_directory_hashes"] = [HASH_A]
        self.assertFalse(
            runner.validate_pair(pre, changed_seal, [HASH_A, HASH_B])[
                "caller_sealed_hash_set_equal"
            ]
        )

    def test_hash_inputs_are_canonical_unique_and_sorted(self) -> None:
        self.assertEqual(runner.normalize_hashes([HASH_A, HASH_B]), [HASH_A, HASH_B])
        for invalid in ([HASH_B, HASH_A], [HASH_A, HASH_A], [HASH_A.upper()], ["g" * 40], []):
            with self.assertRaises(runner.ObservationError):
                runner.normalize_hashes(list(invalid))

    def test_schema_rejects_unbound_observed_status_and_extra_fields(self) -> None:
        args = argparse.Namespace(
            cli=pathlib.Path("/tmp/cli"), adversary=pathlib.Path("/tmp/adversary"),
            expected_team="9AQ2C2838M", daemon_cdhash=[HASH_A], hold_ms=5000,
            command_timeout=18.0, output=pathlib.Path("/tmp/report.json"), execute=True,
        )
        report = runner.initial_report(args)
        runner.validate_schema(report)
        promoted = copy.deepcopy(report)
        promoted["overall_status"] = "observed"
        promoted["classification"] = "candidate_invalidation_observed"
        with self.assertRaises(runner.ObservationError):
            runner.validate_schema(promoted)
        extra = copy.deepcopy(report); extra["unexpected"] = True
        with self.assertRaises(runner.ObservationError):
            runner.validate_schema(extra)

    def test_fully_bound_observed_candidate_satisfies_schema_and_semantics(self) -> None:
        args = argparse.Namespace(
            cli=pathlib.Path("/tmp/cli"), adversary=pathlib.Path("/tmp/adversary"),
            expected_team="9AQ2C2838M", daemon_cdhash=[HASH_A, HASH_B], hold_ms=5000,
            command_timeout=18.0, output=pathlib.Path("/tmp/report.json"), execute=True,
        )
        report = runner.initial_report(args)
        report["run_id"] = RUN_ID
        report["overall_status"] = "observed"
        report["classification"] = "candidate_invalidation_observed"
        report["repository"] = {
            "path": "/repo", "branch": "repair/e2", "head": "1" * 40,
            "base_branch": "main", "base_sha": "2" * 40,
        }
        report["source_manifest"] = {
            "schema_version": 1, "sha256": "3" * 64, "file_count": 1, "bytes": 1,
        }
        report["recorder_evidence_context"] = {
            "schema_version": 1, "binding_schema_version": 1,
            "evidence_id": "EVID-test", "source_manifest": report["source_manifest"],
            "repository": {
                "branch": "repair/e2", "head_sha": "1" * 40,
                "base_branch": "main", "base_sha": "2" * 40,
                "repository_path": "/repo",
            },
            "test_environment": {
                "macos_build": "25A", "machine_identifier": "Mac", "platform": "macOS",
                "architecture": "arm64",
            },
            "qualification_context_present": False,
        }
        report["canonical_qualification_template"] = {
            "matrix_rows_required": 57, "matrix_rows_executed": 0,
            "formal_predicates_required": 12, "formal_predicates_proven": 0,
            "status": "partial", "ok": False,
            "residual_disposition": "open_release_blocker",
            "before_sha256": "4" * 64, "after_sha256": "4" * 64,
            "byte_stable": True,
        }
        report["inputs"]["daemon_signing_requirement_sha256"] = "d" * 64
        def signature(path: str, identifier: str, cdhash: str, admitted: bool) -> dict:
            return {
                "path": path, "sha256": "5" * 64, "size": 1, "device": 1,
                "inode": 1, "change_time_ns": 1, "identifier": identifier,
                "team_identifier": "9AQ2C2838M", "code_directory_hash": cdhash,
                "hardened_runtime": True, "exact_identity_requirement_satisfied": True,
                "daemon_client_requirement_satisfied": admitted,
            }
        report["signatures"] = {
            "cli": signature("/tmp/cli", "com.forge-conductor.cli", "e" * 40, True),
            "adversary": signature(
                "/tmp/adversary", "com.forge-conductor.qualification-adversary",
                CLIENT_HASH, False,
            ),
        }
        pre, post, probe = health("pre_health"), health("post_health"), adversary()
        report["observations"] = {
            "authorized_pre_health": pre, "adversary": probe,
            "authorized_post_health": post,
        }
        report["correlation"] = runner.validate_pair(pre, post, [HASH_A, HASH_B])
        empty_digest = runner.sha256_bytes(b"")
        report["commands"] = [
            {
                "label": "signed_authorized_same_connection_health",
                "arguments": ["/tmp/cli", "qualification-filesystem-health", "--hold-ms", "5000"],
                "process_id": 122, "return_code": 0, "timed_out": False,
                "stdout_bytes": len(runner.canonical_line(pre) + runner.canonical_line(post)),
                "stderr_bytes": 0,
                "stdout_sha256": runner.sha256_bytes(
                    runner.canonical_line(pre) + runner.canonical_line(post)
                ),
                "stderr_sha256": empty_digest, "process_group_cleanup": "already_empty",
                "live_code_directory_hash": "e" * 40,
            },
            {
                "label": "signed_wrong_identifier_admission_probe",
                "arguments": ["/tmp/adversary", "admission-probe"],
                "process_id": 123, "return_code": 1, "timed_out": False,
                "stdout_bytes": len(runner.canonical_line(probe)), "stderr_bytes": 0,
                "stdout_sha256": runner.sha256_bytes(runner.canonical_line(probe)),
                "stderr_sha256": empty_digest, "process_group_cleanup": "already_empty",
                "live_code_directory_hash": CLIENT_HASH,
            },
        ]
        runner.validate_schema(report)

    def test_output_guard_rejects_protected_inputs(self) -> None:
        with self.assertRaises(runner.h0.H0Error):
            runner.h0.validate_output_path(
                runner.SCHEMA_PATH,
                protected_paths=[runner.SCHEMA_PATH, runner.h0.PROTOCOL_SOURCE],
            )

    def test_authorized_cli_barrier_precedes_xpc_and_invalid_args_precede_barrier(self) -> None:
        source = (
            REPOSITORY_ROOT / "Sources/ForgeConductorCLI/ForgeConductorMain.swift"
        ).read_text(encoding="utf-8")
        start = source.index("static func cmdQualificationFilesystemHealth")
        end = source.index("private static func writeQualificationJSON", start)
        command = source[start:end]
        invalid = command.index("secure_filesystem_health_invalid_arguments")
        barrier = command.index("qualificationFilesystemHealthStartSuspendedEnvironmentKey")
        xpc = command.index("SecureFilesystemQualificationHealthSession()")
        self.assertLess(invalid, barrier)
        self.assertLess(barrier, xpc)
        self.assertIn("Darwin.raise(SIGSTOP)", command)
        self.assertIn("Expected --hold-ms with an integer from 500 through 10000", command)
        self.assertIn("exit(2)", command[:barrier])

    def test_internal_health_command_stays_out_of_public_help(self) -> None:
        source = (
            REPOSITORY_ROOT / "Sources/ForgeConductorCLI/ForgeConductorMain.swift"
        ).read_text(encoding="utf-8")
        start = source.index("static func printHelp()")
        end = source.index("static func homeOverride", start)
        self.assertNotIn("qualification-filesystem-health", source[start:end])

    def test_adversary_barrier_precedes_live_probe_dispatch(self) -> None:
        source = (
            REPOSITORY_ROOT
            / "Sources/ForgeFilesystemQualificationSupport/QualificationReadiness.swift"
        ).read_text(encoding="utf-8")
        start = source.index("static func prepareRoute")
        end = source.index("return try ForgeFilesystemAdmissionProbeContract.shouldRoute", start)
        routing = source[start:end]
        self.assertLess(routing.index("suspensionBarrier()"), len(routing))
        self.assertIn("suspensionBarrier: { raise(SIGSTOP) }", source)


if __name__ == "__main__":
    unittest.main()
