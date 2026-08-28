#!/usr/bin/env python3
"""Deterministic regression tests for the evidence recorder and source manifest."""

from __future__ import annotations

import json
import hashlib
import os
import pathlib
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


class EvidenceControlTests(unittest.TestCase):
    def write_json(self, path: pathlib.Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def test_completion_requires_full_filesystem_security_matrix(self) -> None:
        checker = COMPLETION_CHECKER.read_text(encoding="utf-8")
        required = (
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
