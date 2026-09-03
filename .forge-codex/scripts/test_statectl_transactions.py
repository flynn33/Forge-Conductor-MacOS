#!/usr/bin/env python3
"""Regression tests for bounded and recoverable state-ledger transitions."""

from __future__ import annotations

import json
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from datetime import datetime, timezone
from unittest import mock

import statectl
from evidence_support import EvidenceSupportError, current_git_head, source_manifest
from p10_fixture_support import (
    FIXTURE_BASELINE,
    FIXTURE_EVIDENCE_ID,
    fixture_p10_binding,
    fixture_p10_module,
    fixture_python_command,
    install_fixture_p10_evaluator,
)


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
STATECTL = SCRIPT_ROOT / "statectl.py"


class StateTransactionTests(unittest.TestCase):
    G12_OPERATION_ID = "12121212-1212-4121-8121-121212121212"
    DIFFERENT_G12_OPERATION_ID = "34343434-3434-4343-8343-343434343434"

    def write_json(self, path: pathlib.Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def run_statectl(
        self,
        root: pathlib.Path,
        *arguments: str,
        timeout: float = 8,
    ) -> subprocess.CompletedProcess[str]:
        fixture_evaluator = (
            root / ".forge-codex/scripts/p10_feature_evidence.py"
        )
        command = (
            fixture_python_command(
                root,
                SCRIPT_ROOT,
                STATECTL,
                "--repo",
                str(root),
                *arguments,
            )
            if fixture_evaluator.is_file()
            else [
                sys.executable,
                str(STATECTL),
                "--repo",
                str(root),
                *arguments,
            ]
        )
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )

    def make_repository(self, root: pathlib.Path) -> None:
        self.write_json(root / ".forge-codex/plans/phases.json", {"phases": []})
        self.write_json(root / ".forge-codex/plans/gates.json", {"gates": []})
        initialized = self.run_statectl(root, "init")
        self.assertEqual(
            initialized.returncode,
            0,
            initialized.stdout + initialized.stderr,
        )

    def make_g12_repository(self, root: pathlib.Path) -> None:
        self.write_json(root / ".forge-codex/plans/phases.json", {"phases": []})
        install_fixture_p10_evaluator(root)
        gates = [
            {
                "id": f"G{index:02d}",
                "criteria": [f"criterion G{index:02d}"],
            }
            for index in range(13)
        ]
        self.write_json(
            root / ".forge-codex/plans/gates.json",
            {
                "completion_requires": [item["id"] for item in gates],
                "gates": gates,
            },
        )
        for item in gates:
            handler = (
                root
                / ".forge-codex/state/gate-handlers"
                / f"{item['id']}.sh"
            )
            handler.parent.mkdir(parents=True, exist_ok=True)
            handler.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            handler.chmod(0o755)
        self.write_json(
            root / ".forge-codex/state/feature-baseline.json",
            FIXTURE_BASELINE,
        )
        for command in (
            ["git", "init", "-q"],
            ["git", "config", "user.name", "Fixture"],
            ["git", "config", "user.email", "fixture@example.invalid"],
            ["git", "add", "."],
            ["git", "commit", "-qm", "fixture"],
        ):
            completed = subprocess.run(
                command,
                cwd=root,
                capture_output=True,
                text=True,
                timeout=8,
                check=False,
            )
            self.assertEqual(
                completed.returncode,
                0,
                completed.stdout + completed.stderr,
            )
        initialized = self.run_statectl(root, "init")
        self.assertEqual(
            initialized.returncode,
            0,
            initialized.stdout + initialized.stderr,
        )
        referenced = self.run_statectl(
            root,
            "reference",
            "evidence",
            FIXTURE_EVIDENCE_ID,
        )
        self.assertEqual(
            referenced.returncode,
            0,
            referenced.stdout + referenced.stderr,
        )

    def install_g12_pass(
        self,
        root: pathlib.Path,
        *,
        operation_id: str = G12_OPERATION_ID,
        finalized: bool = True,
        evaluator: pathlib.Path | None = None,
    ) -> pathlib.Path:
        result_directory = root / ".forge-codex/state/gate-results"
        result_directory.mkdir(parents=True, exist_ok=True)
        head = current_git_head(root)
        manifest = source_manifest(root)
        self.assertIsNotNone(head)
        prerequisite_bindings: list[dict[str, object]] = []

        def write_gate(
            gate_identifier: str,
            gate_operation_id: str,
            *,
            is_final: bool,
            criteria_extra: dict[str, object] | None = None,
        ) -> pathlib.Path:
            state_before = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            stdout_path = result_directory / f"{gate_identifier}.stdout.txt"
            stderr_path = result_directory / f"{gate_identifier}.stderr.txt"
            criteria_path = result_directory / f"{gate_identifier}.criteria.json"
            stdout_path.write_bytes(b"")
            stderr_path.write_bytes(b"")
            criterion = f"criterion {gate_identifier}"
            criteria_result = {
                "criterion": criterion,
                "passed": True,
                "evidence": (
                    criteria_extra["evidence"]
                    if isinstance(criteria_extra, dict)
                    else "fixture evidence"
                ),
            }
            criteria_document: dict[str, object] = {
                "criteria_results": [criteria_result],
            }
            if gate_identifier == "G10":
                criteria_document.update(
                    {
                        "valid": True,
                        "errors": [],
                        "p10_feature_binding": fixture_p10_binding(
                            root,
                            current_manifest=manifest,
                            current_git_head=head,
                            ledger_evidence_ids={
                                item
                                for item in state_before.get("evidence", [])
                                if isinstance(item, str)
                            },
                        ),
                    }
                )
            if criteria_extra:
                criteria_document.update(
                    {
                        key: value
                        for key, value in criteria_extra.items()
                        if not key.startswith("_") and key != "evidence"
                    }
                )
                criteria_document["criteria_results"] = [criteria_result]
            self.write_json(criteria_path, criteria_document)
            artifact_entries = []
            artifact_hashes = []
            for kind, path in (
                ("stdout", stdout_path),
                ("stderr", stderr_path),
                ("criteria", criteria_path),
            ):
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                artifact_hashes.append(digest)
                artifact_entries.append(
                    {"kind": kind, "path": str(path), "sha256": digest}
                )
            timestamp = datetime.now(timezone.utc).isoformat()
            started_timestamp = (
                criteria_extra.get("_started_at", timestamp)
                if isinstance(criteria_extra, dict)
                else timestamp
            )
            ended_timestamp = (
                criteria_extra.get("_ended_at", timestamp)
                if isinstance(criteria_extra, dict)
                else timestamp
            )
            result_path = result_directory / f"{gate_identifier}.json"
            self.write_json(
                result_path,
                {
                    "schema_version": 1,
                    "gate_id": gate_identifier,
                    "status": "passed",
                    "finalized": finalized if is_final else True,
                    "operation_id": gate_operation_id,
                    "source_head": head,
                    "source_manifest": manifest,
                    "state_sequence_before": state_before["last_event_sequence"],
                    "started_at": started_timestamp,
                    "ended_at": ended_timestamp,
                    "commands": [
                        {
                            "command": str(
                                root
                                / ".forge-codex/state/gate-handlers"
                                / f"{gate_identifier}.sh"
                            ),
                            "exit_code": 0,
                            "stdout_sha256": artifact_hashes[0],
                            "stderr_sha256": artifact_hashes[1],
                            "timed_out": False,
                        }
                    ],
                    "environment": {
                        "platform": "fixture-platform",
                        "machine": "fixture-machine",
                        "repository": str(root),
                    },
                    "artifacts": artifact_entries,
                    "evaluator": {
                        "name": "forge-gate-handler",
                        "version": "1",
                        "criteria_results": [criteria_result],
                    },
                    "notes": "",
                },
            )
            evaluator_path = (
                evaluator
                if is_final and evaluator is not None
                else result_path
            )
            command = [
                "gate",
                gate_identifier,
                "passed",
            ]
            for digest in artifact_hashes:
                command.extend(["--evidence", digest])
            command.extend(
                [
                    "--evaluator",
                    str(evaluator_path),
                    "--operation-id",
                    gate_operation_id,
                ]
            )
            transitioned = self.run_statectl(root, *command)
            self.assertEqual(
                transitioned.returncode,
                0,
                transitioned.stdout + transitioned.stderr,
            )
            return result_path

        for index in range(12):
            gate_identifier = f"G{index:02d}"
            gate_operation_id = str(uuid.uuid4())
            result_path = write_gate(
                gate_identifier,
                gate_operation_id,
                is_final=False,
            )
            raw = result_path.read_bytes()
            prerequisite_bindings.append(
                {
                    "gate_id": gate_identifier,
                    "operation_id": gate_operation_id,
                    "sha256": hashlib.sha256(raw).hexdigest(),
                    "bytes": len(raw),
                }
            )

        state_before_g12 = json.loads(
            (root / ".forge-codex/state/run-state.json").read_text(
                encoding="utf-8"
            )
        )
        g12_started_at = datetime.now(timezone.utc).isoformat()
        evaluated_at = datetime.now(timezone.utc).isoformat()
        required_checks = {
            "run-state-valid",
            "package-valid",
            "attribution-clean",
            "secret-scan-clean",
            "current-git-head-valid",
            "current-source-manifest-valid",
            "relevant-source-clean",
            "current-source-identity-stable",
            "source-identity-unchanged-through-evaluation",
            "completion-gate-plan-valid",
            "feature-baseline-valid",
            "g10-p10-feature-evidence-binding",
            "findings-resolution-structure",
            "run-state-issues-structure",
            "critical-high-findings-resolved",
            "critical-high-run-state-issues-resolved",
            "autonomous-rollover-mode-proven",
            "supported-api-only",
        }
        for index in range(12):
            gate_identifier = f"G{index:02d}"
            required_checks.update(
                {
                    f"gate-result-binding:{gate_identifier}",
                    f"gate-finalized-result:{gate_identifier}",
                    f"gate-operation-pair:{gate_identifier}",
                    f"gate-current-source-binding:{gate_identifier}",
                    f"gate-command-contract:{gate_identifier}",
                    f"gate-criteria-contract:{gate_identifier}",
                    f"gate-result-envelope:{gate_identifier}",
                    f"gate-artifacts:{gate_identifier}",
                }
            )
            if 2 <= index <= 11:
                required_checks.add(
                    f"gate-current-release-authority:{gate_identifier}"
                )
        report = {
            "schema_version": 2,
            "evaluated_at": evaluated_at,
            "repository": str(root),
            "passed": True,
            "checks": [
                {"name": name, "passed": True, "detail": "fixture"}
                for name in sorted(required_checks)
            ],
            "errors": [],
            "run_id": state_before_g12["run_id"],
            "commit": head,
            "admission_contract": {
                "schema_version": 1,
                "run_id": state_before_g12["run_id"],
                "repository": str(root),
                "source_head": head,
                "source_manifest": manifest,
                "state_sequence_before_g12": state_before_g12[
                    "last_event_sequence"
                ],
                "prerequisite_gates": [f"G{index:02d}" for index in range(12)],
                "gate_results": prerequisite_bindings,
            },
            "finalization_gate": {
                "gate_id": "G12",
                "status": "eligible_for_finalization",
                "reason": "fixture",
            },
        }
        completion_json = root / ".forge-codex/state/completion-report.json"
        completion_markdown = root / ".forge-codex/state/completion-report.md"
        self.write_json(completion_json, report)
        completion_markdown.write_text("# completion fixture\n", encoding="utf-8")
        report_bindings = [
            {
                "path": ".forge-codex/state/completion-report.json",
                "sha256": hashlib.sha256(completion_json.read_bytes()).hexdigest(),
                "bytes": len(completion_json.read_bytes()),
            },
            {
                "path": ".forge-codex/state/completion-report.md",
                "sha256": hashlib.sha256(completion_markdown.read_bytes()).hexdigest(),
                "bytes": len(completion_markdown.read_bytes()),
            },
        ]
        evidence = (
            ".forge-codex/state/completion-report.json sha256="
            f"{report_bindings[0]['sha256']}; "
            ".forge-codex/state/completion-report.md sha256="
            f"{report_bindings[1]['sha256']}"
        )
        g12_ended_at = datetime.now(timezone.utc).isoformat()
        return write_gate(
            "G12",
            operation_id,
            is_final=True,
            criteria_extra={
                "evidence": evidence,
                "valid": True,
                "errors": [],
                "report_bindings": report_bindings,
                "_started_at": g12_started_at,
                "_ended_at": g12_ended_at,
            },
        )

    def read_events(self, root: pathlib.Path) -> list[dict[str, object]]:
        return [
            json.loads(line)
            for line in (
                root / ".forge-codex/state/events.jsonl"
            ).read_text(encoding="utf-8").splitlines()
        ]

    def test_lock_acquisition_is_bounded_for_show_and_validate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)
            lock_path = root / ".forge-codex/state/.state.lock"
            holder = subprocess.Popen(
                [
                    sys.executable,
                    "-u",
                    "-c",
                    (
                        "import fcntl, pathlib, sys, time; "
                        "handle = pathlib.Path(sys.argv[1]).open('r+'); "
                        "fcntl.flock(handle.fileno(), fcntl.LOCK_EX); "
                        "print('locked', flush=True); time.sleep(30)"
                    ),
                    str(lock_path),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                assert holder.stdout is not None
                self.assertEqual(holder.stdout.readline().strip(), "locked")
                for command in ("show", "validate"):
                    with self.subTest(command=command):
                        started = time.monotonic()
                        result = self.run_statectl(root, command, timeout=5)
                        elapsed = time.monotonic() - started
                        self.assertEqual(result.returncode, 1)
                        self.assertIn("acquisition time bound", result.stderr)
                        self.assertLess(elapsed, 4)
            finally:
                holder.terminate()
                try:
                    holder.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    holder.kill()
                    holder.wait(timeout=2)
                if holder.stdout is not None:
                    holder.stdout.close()
                if holder.stderr is not None:
                    holder.stderr.close()

    def test_state_directory_symlink_cannot_redirect_initialization(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary).resolve()
            root = base / "repository"
            outside = base / "outside-state"
            outside.mkdir()
            self.write_json(root / ".forge-codex/plans/phases.json", {"phases": []})
            self.write_json(root / ".forge-codex/plans/gates.json", {"gates": []})
            (root / ".forge-codex/state").symlink_to(
                outside,
                target_is_directory=True,
            )

            result = self.run_statectl(root, "init")

            self.assertEqual(result.returncode, 1)
            self.assertIn("contains a symlink", result.stderr)
            self.assertEqual(list(outside.iterdir()), [])

    def test_hardlinked_ledger_is_rejected_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)
            event_path = root / ".forge-codex/state/events.jsonl"
            linked_path = root / "linked-ledger.jsonl"
            os.link(event_path, linked_path)
            before = event_path.read_bytes()

            result = self.run_statectl(root, "event", "fixture")

            self.assertEqual(result.returncode, 1)
            self.assertIn("multiple hard links", result.stderr)
            self.assertEqual(event_path.read_bytes(), before)
            self.assertEqual(linked_path.read_bytes(), before)
            self.assertFalse(
                (root / ".forge-codex/state/.state-transaction.json").exists()
            )

    def test_missing_terminal_newline_and_earlier_corruption_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)
            event_path = root / ".forge-codex/state/events.jsonl"
            event_path.write_bytes(event_path.read_bytes().rstrip(b"\n"))

            missing_newline = self.run_statectl(root, "event", "fixture")

            self.assertEqual(missing_newline.returncode, 1)
            self.assertIn("terminal newline", missing_newline.stderr)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)
            added = self.run_statectl(root, "event", "second")
            self.assertEqual(added.returncode, 0, added.stdout + added.stderr)
            event_path = root / ".forge-codex/state/events.jsonl"
            events = self.read_events(root)
            first = dict(events[0])
            first["payload"] = {"repository": "corrupted"}
            event_path.write_text(
                "\n".join(
                    [json.dumps(first, sort_keys=True), json.dumps(events[1], sort_keys=True)]
                )
                + "\n",
                encoding="utf-8",
            )

            corrupted = self.run_statectl(root, "event", "third")

            self.assertEqual(corrupted.returncode, 1)
            self.assertIn("hash mismatch at line 1", corrupted.stderr)
            self.assertFalse(
                (root / ".forge-codex/state/.state-transaction.json").exists()
            )

    def test_equal_size_path_replacement_is_detected_by_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)
            state_directory = root / ".forge-codex/state"
            with statectl.open_state_directory(root, create=False) as descriptor:
                ledger_descriptor, identity = statectl.open_regular_at(
                    descriptor,
                    statectl.EVENT_FILE_NAME,
                    label="state event ledger",
                    read_write=False,
                )
                os.close(ledger_descriptor)
                original = state_directory / statectl.EVENT_FILE_NAME
                replacement = state_directory / "replacement.jsonl"
                replacement.write_bytes(original.read_bytes())
                replacement.chmod(0o600)
                os.replace(replacement, original)

                with self.assertRaisesRegex(
                    EvidenceSupportError,
                    "pathname identity changed",
                ):
                    statectl.require_path_identity(
                        descriptor,
                        statectl.EVENT_FILE_NAME,
                        identity,
                        "state event ledger",
                    )

    def test_lock_and_state_directory_replacement_are_detected_on_exit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)
            state_directory = root / ".forge-codex/state"
            lock_path = state_directory / statectl.LOCK_FILE_NAME
            replacement = state_directory / "replacement.lock"
            replacement.write_bytes(lock_path.read_bytes())
            replacement.chmod(0o600)

            with self.assertRaisesRegex(
                EvidenceSupportError,
                "state lock pathname identity changed",
            ):
                with statectl.locked_state_directory(root, create=False):
                    os.replace(replacement, lock_path)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)
            package = root / ".forge-codex"
            state_directory = package / "state"
            moved = package / "moved-state"

            with self.assertRaisesRegex(
                EvidenceSupportError,
                "state directory pathname identity changed",
            ):
                with statectl.open_state_directory(root, create=False):
                    state_directory.rename(moved)
                    state_directory.mkdir(mode=0o700)

    def test_state_replace_failure_recovers_completed_event_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)
            original_atomic_json = statectl.atomic_json_at

            def fail_state_replace(
                directory_descriptor: int,
                final_name: str,
                staging_name: str,
                value: object,
                *,
                label: str,
                maximum_bytes: int,
            ) -> None:
                if final_name == statectl.STATE_FILE_NAME:
                    raise EvidenceSupportError("injected state replace failure")
                original_atomic_json(
                    directory_descriptor,
                    final_name,
                    staging_name,
                    value,
                    label=label,
                    maximum_bytes=maximum_bytes,
                )

            with mock.patch.object(
                statectl,
                "atomic_json_at",
                side_effect=fail_state_replace,
            ):
                with self.assertRaisesRegex(
                    EvidenceSupportError,
                    "injected state replace failure",
                ):
                    statectl.mutate(root, "recoverable", {"value": 1}, lambda state: None)

            transaction = root / ".forge-codex/state/.state-transaction.json"
            self.assertTrue(transaction.is_file())
            self.assertEqual(len(self.read_events(root)), 2)
            stale_state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(encoding="utf-8")
            )
            self.assertEqual(stale_state["last_event_sequence"], 1)

            recovered = self.run_statectl(root, "validate")

            self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
            self.assertFalse(transaction.exists())
            self.assertEqual(len(self.read_events(root)), 2)
            current_state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(encoding="utf-8")
            )
            self.assertEqual(current_state["last_event_sequence"], 2)
            self.assertEqual(self.read_events(root)[-1]["type"], "recoverable")

    def test_marker_written_before_append_recovers_event_and_state_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)

            with mock.patch.object(
                statectl,
                "append_event_line",
                side_effect=EvidenceSupportError(
                    "injected death after marker before append"
                ),
            ):
                with self.assertRaisesRegex(
                    EvidenceSupportError,
                    "injected death after marker before append",
                ):
                    statectl.mutate(
                        root,
                        "marker-only",
                        {"value": 3},
                        lambda state: None,
                    )

            transaction = root / ".forge-codex/state/.state-transaction.json"
            self.assertTrue(transaction.is_file())
            self.assertEqual(len(self.read_events(root)), 1)
            stale_state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(stale_state["last_event_sequence"], 1)

            recovered = self.run_statectl(root, "validate")

            self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
            self.assertFalse(transaction.exists())
            events = self.read_events(root)
            self.assertEqual(
                [event["type"] for event in events],
                ["run_initialized", "marker-only"],
            )
            current_state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(current_state["last_event_sequence"], 2)

    def test_state_published_before_marker_removal_recovers_without_duplication(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)
            original_unlink = statectl.unlink_secure_file_at

            def fail_transaction_removal(
                directory_descriptor: int,
                name: str,
                *,
                label: str,
                missing_ok: bool,
            ) -> None:
                if name == statectl.TRANSACTION_FILE_NAME:
                    raise EvidenceSupportError(
                        "injected death after state publication"
                    )
                original_unlink(
                    directory_descriptor,
                    name,
                    label=label,
                    missing_ok=missing_ok,
                )

            with mock.patch.object(
                statectl,
                "unlink_secure_file_at",
                side_effect=fail_transaction_removal,
            ):
                with self.assertRaisesRegex(
                    EvidenceSupportError,
                    "injected death after state publication",
                ):
                    statectl.mutate(
                        root,
                        "state-published",
                        {"value": 4},
                        lambda state: None,
                    )

            transaction = root / ".forge-codex/state/.state-transaction.json"
            self.assertTrue(transaction.is_file())
            self.assertEqual(
                [event["type"] for event in self.read_events(root)],
                ["run_initialized", "state-published"],
            )
            published_state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(published_state["last_event_sequence"], 2)

            recovered = self.run_statectl(root, "validate")

            self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
            self.assertFalse(transaction.exists())
            self.assertEqual(
                [event["type"] for event in self.read_events(root)],
                ["run_initialized", "state-published"],
            )
            current_state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(current_state["last_event_sequence"], 2)

    def test_partial_event_append_is_repaired_without_duplication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)

            def append_partial(
                state_descriptor: int,
                ledger_descriptor: int,
                path_identity: os.stat_result,
                prior_length: int,
                raw: bytes,
            ) -> None:
                statectl.require_path_identity(
                    state_descriptor,
                    statectl.EVENT_FILE_NAME,
                    path_identity,
                    "state event ledger",
                )
                os.lseek(ledger_descriptor, prior_length, os.SEEK_SET)
                os.write(ledger_descriptor, raw[: max(1, len(raw) // 2)])
                os.fsync(ledger_descriptor)
                raise EvidenceSupportError("injected partial event append")

            with mock.patch.object(
                statectl,
                "append_event_line",
                side_effect=append_partial,
            ):
                with self.assertRaisesRegex(
                    EvidenceSupportError,
                    "injected partial event append",
                ):
                    statectl.mutate(root, "partial", {"value": 2}, lambda state: None)

            transaction = root / ".forge-codex/state/.state-transaction.json"
            self.assertTrue(transaction.is_file())
            self.assertFalse(
                (root / ".forge-codex/state/events.jsonl").read_bytes().endswith(b"\n")
            )

            recovered = self.run_statectl(root, "validate")

            self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
            events = self.read_events(root)
            self.assertEqual([event["type"] for event in events], ["run_initialized", "partial"])
            self.assertFalse(transaction.exists())

    def test_full_event_write_is_synced_before_recovered_state_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)

            def append_full_without_sync(
                state_descriptor: int,
                ledger_descriptor: int,
                path_identity: os.stat_result,
                prior_length: int,
                raw: bytes,
            ) -> None:
                statectl.require_path_identity(
                    state_descriptor,
                    statectl.EVENT_FILE_NAME,
                    path_identity,
                    "state event ledger",
                )
                os.lseek(ledger_descriptor, prior_length, os.SEEK_SET)
                statectl.write_all(ledger_descriptor, raw, "state event ledger")
                raise EvidenceSupportError("injected death before ledger sync")

            with mock.patch.object(
                statectl,
                "append_event_line",
                side_effect=append_full_without_sync,
            ):
                with self.assertRaisesRegex(
                    EvidenceSupportError,
                    "injected death before ledger sync",
                ):
                    statectl.mutate(root, "full-unsynced", {}, lambda state: None)

            ledger_path = root / ".forge-codex/state/events.jsonl"
            ledger_identity = ledger_path.stat()
            ordering: list[str] = []
            original_fsync = statectl.os.fsync
            original_atomic_json = statectl.atomic_json_at

            def track_fsync(descriptor: int) -> None:
                metadata = os.fstat(descriptor)
                if (
                    metadata.st_dev,
                    metadata.st_ino,
                ) == (
                    ledger_identity.st_dev,
                    ledger_identity.st_ino,
                ):
                    ordering.append("ledger-sync")
                original_fsync(descriptor)

            def track_atomic_json(
                directory_descriptor: int,
                final_name: str,
                staging_name: str,
                value: object,
                *,
                label: str,
                maximum_bytes: int,
            ) -> None:
                if final_name == statectl.STATE_FILE_NAME:
                    ordering.append("state-publication")
                    self.assertIn("ledger-sync", ordering)
                original_atomic_json(
                    directory_descriptor,
                    final_name,
                    staging_name,
                    value,
                    label=label,
                    maximum_bytes=maximum_bytes,
                )

            with mock.patch.object(
                statectl.os,
                "fsync",
                side_effect=track_fsync,
            ), mock.patch.object(
                statectl,
                "atomic_json_at",
                side_effect=track_atomic_json,
            ):
                with statectl.locked_state_directory(root, create=False) as descriptor:
                    self.assertTrue(statectl.recover_transaction(descriptor))

            self.assertLess(
                ordering.index("ledger-sync"),
                ordering.index("state-publication"),
            )
            validated = self.run_statectl(root, "validate")
            self.assertEqual(validated.returncode, 0, validated.stdout + validated.stderr)
            self.assertEqual(
                [event["type"] for event in self.read_events(root)],
                ["run_initialized", "full-unsynced"],
            )

    def test_retry_operation_id_is_exactly_once_and_collision_safe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)
            command = (
                "attempt",
                "WORK",
                "progress",
                "--operation-id",
                "retry-operation-1",
            )

            first = self.run_statectl(root, *command)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            state_path = root / ".forge-codex/state/run-state.json"
            event_path = root / ".forge-codex/state/events.jsonl"
            state_after_first = state_path.read_bytes()
            events_after_first = event_path.read_bytes()

            retry = self.run_statectl(root, *command)

            self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
            self.assertEqual(state_path.read_bytes(), state_after_first)
            self.assertEqual(event_path.read_bytes(), events_after_first)
            state = json.loads(state_after_first)
            self.assertEqual(len(state["attempts"]), 1)
            self.assertEqual(state["attempts"][0]["operation_id"], "retry-operation-1")
            self.assertEqual(
                [
                    event.get("operation_id")
                    for event in self.read_events(root)
                    if event["type"] == "work_attempt"
                ],
                ["retry-operation-1"],
            )

            collision = self.run_statectl(
                root,
                "attempt",
                "DIFFERENT-WORK",
                "progress",
                "--operation-id",
                "retry-operation-1",
            )
            self.assertEqual(collision.returncode, 1)
            self.assertIn("collides with a different request", collision.stderr)
            self.assertEqual(state_path.read_bytes(), state_after_first)
            self.assertEqual(event_path.read_bytes(), events_after_first)

            second = self.run_statectl(
                root,
                "attempt",
                "DIFFERENT-WORK",
                "progress",
                "--operation-id",
                "retry-operation-2",
            )
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            events = self.read_events(root)
            later_collision = dict(events[-1])
            later_collision["operation_id"] = "retry-operation-1"
            unhashed = dict(later_collision)
            unhashed.pop("event_hash")
            later_collision["event_hash"] = statectl.event_hash(unhashed)
            events[-1] = later_collision
            event_path.write_text(
                "\n".join(json.dumps(event, sort_keys=True) for event in events) + "\n",
                encoding="utf-8",
            )

            full_scan_collision = self.run_statectl(root, *command)
            self.assertEqual(full_scan_collision.returncode, 1)
            self.assertIn(
                "collides with a different request",
                full_scan_collision.stderr,
            )

    def test_legacy_mutation_without_operation_id_remains_supported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)

            result = self.run_statectl(root, "event", "legacy-compatible")

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            event = self.read_events(root)[-1]
            self.assertEqual(event["type"], "legacy-compatible")
            self.assertRegex(
                event["operation_id"],
                r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            )

    def test_status_complete_requires_exact_g12_operation_and_canonical_result(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)

            missing_expected = self.run_statectl(
                root,
                "status",
                "complete",
                "--operation-id",
                "completion-missing-expected",
            )
            self.assertEqual(missing_expected.returncode, 1)
            self.assertIn(
                "requires --expected-g12-operation-id",
                missing_expected.stderr,
            )

            mismatched = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.DIFFERENT_G12_OPERATION_ID,
                "--operation-id",
                "completion-mismatched",
            )
            self.assertEqual(mismatched.returncode, 1)
            self.assertIn(
                "G12 gate result operation identifier does not match",
                mismatched.stderr,
            )

            completed = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
                "--operation-id",
                "completion-transition",
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(state["status"], "complete")
            event = self.read_events(root)[-1]
            self.assertEqual(event["operation_id"], "completion-transition")
            self.assertEqual(
                event["payload"]["expected_g12_operation_id"],
                self.G12_OPERATION_ID,
            )

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            noncanonical = root / "noncanonical-G12.json"
            self.install_g12_pass(root, evaluator=noncanonical)

            rejected = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("canonical finalized result", rejected.stderr)

    def test_status_complete_rejects_unfinalized_g12_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root, finalized=False)

            result = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("finalized current-source envelope", result.stderr)
            state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(state["status"], "active")

    def test_status_complete_rejects_stale_head_manifest_and_dirty_mode(self) -> None:
        mutations = ("head", "manifest", "mode")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                self.make_g12_repository(root)
                result_path = self.install_g12_pass(root)
                if mutation == "head":
                    payload = json.loads(result_path.read_text(encoding="utf-8"))
                    payload["source_head"] = "0" * 40
                    self.write_json(result_path, payload)
                elif mutation == "manifest":
                    plans = root / ".forge-codex/plans/phases.json"
                    plans.write_text('{"phases": [], "changed": true}\n', encoding="utf-8")
                else:
                    plans = root / ".forge-codex/plans/phases.json"
                    plans.chmod(plans.stat().st_mode | 0o111)

                rejected = self.run_statectl(
                    root,
                    "status",
                    "complete",
                    "--expected-g12-operation-id",
                    self.G12_OPERATION_ID,
                )

                self.assertEqual(rejected.returncode, 1)
                if mutation == "head":
                    self.assertIn("current-source envelope", rejected.stderr)
                elif mutation == "manifest":
                    self.assertIn("current-source envelope", rejected.stderr)
                else:
                    self.assertIn("source is dirty", rejected.stderr)

    def test_status_complete_rejects_an_intervening_state_transaction(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)
            changed = self.run_statectl(
                root,
                "reference",
                "decisions",
                "intervening-change",
                "--operation-id",
                "intervening-state-transaction",
            )
            self.assertEqual(changed.returncode, 0, changed.stdout + changed.stderr)

            rejected = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )

            self.assertEqual(rejected.returncode, 1)
            self.assertIn("state changed after the G12", rejected.stderr)

    def test_status_complete_rechecks_all_gates_and_release_blocking_issues(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)
            state_path = root / ".forge-codex/state/run-state.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            original_g00 = state["gates"]["G00"]
            state["gates"]["G00"] = {
                "status": "failed",
                "evidence_ids": [],
                "evaluator": None,
                "operation_id": "failed-gate-operation",
                "updated_at": None,
            }
            state_path.write_text(json.dumps(state) + "\n", encoding="utf-8")

            failed_gate = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )
            self.assertEqual(failed_gate.returncode, 1)
            self.assertIn("every gate to remain passed", failed_gate.stderr)

            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["gates"]["G00"] = original_g00
            state["issues"] = [
                {
                    "id": "release-blocker",
                    "severity": "High",
                    "status": "deferred",
                }
            ]
            state_path.write_text(json.dumps(state) + "\n", encoding="utf-8")
            blocked_issue = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )
            self.assertEqual(blocked_issue.returncode, 1)
            self.assertIn("unresolved Critical/High", blocked_issue.stderr)

            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["issues"] = [
                {"id": "duplicate", "severity": "Low", "status": "resolved"},
                {"id": "duplicate", "severity": "Low", "status": "resolved"},
            ]
            state_path.write_text(json.dumps(state) + "\n", encoding="utf-8")
            malformed_issue_ledger = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )
            self.assertEqual(malformed_issue_ledger.returncode, 1)
            self.assertIn("issue ledger is malformed", malformed_issue_ledger.stderr)

    def test_status_complete_rejects_symlinked_and_hardlinked_g12_result(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            result_path = self.install_g12_pass(root)
            outside = root / "outside-G12.json"
            outside.write_bytes(result_path.read_bytes())
            result_path.unlink()
            result_path.symlink_to(outside)

            symlinked = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )
            self.assertEqual(symlinked.returncode, 1)
            self.assertIn("G12 gate result is unavailable", symlinked.stderr)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            result_path = self.install_g12_pass(root)
            os.link(result_path, root / "linked-G12.json")

            hardlinked = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )
            self.assertEqual(hardlinked.returncode, 1)
            self.assertIn("multiple hard links", hardlinked.stderr)

    def test_g12_result_replacement_is_detected_before_completion_commit(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            result_path = self.install_g12_pass(root)
            original_decode = statectl.decode_strict_json_object

            with statectl.locked_state_directory(root, create=False) as descriptor:
                state = statectl.require_state_at(descriptor, statectl.control_budget())

                def replace_during_decode(raw: bytes, *, label: str):
                    value = original_decode(raw, label=label)
                    if label == "G12 gate result":
                        replacement = result_path.with_name("replacement-G12.json")
                        replacement.write_bytes(raw)
                        replacement.chmod(0o600)
                        os.replace(replacement, result_path)
                    return value

                with fixture_p10_module(root), mock.patch.object(
                    statectl,
                    "decode_strict_json_object",
                    side_effect=replace_during_decode,
                ):
                    with self.assertRaisesRegex(
                        EvidenceSupportError,
                        "G12 gate result changed",
                    ):
                        statectl.require_g12_completion_contract(
                            root,
                            descriptor,
                            state,
                            self.G12_OPERATION_ID,
                        )

            current = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(current["status"], "active")

    def test_nonpassed_gate_update_demotes_complete_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            result_path = self.install_g12_pass(root)
            completed = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
                "--operation-id",
                "completion-transition",
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

            demoted = self.run_statectl(
                root,
                "gate",
                "G12",
                "failed",
                "--evaluator",
                str(result_path),
                "--operation-id",
                "g12-invalidation",
            )

            self.assertEqual(demoted.returncode, 0, demoted.stdout + demoted.stderr)
            state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(state["status"], "active")
            self.assertEqual(state["gates"]["G12"]["status"], "failed")

    def test_new_passed_gate_operation_also_demotes_complete_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            result_path = self.install_g12_pass(root)
            completed = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
                "--operation-id",
                "completion-transition",
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

            rerun = self.run_statectl(
                root,
                "gate",
                "G12",
                "passed",
                "--evaluator",
                str(result_path),
                "--operation-id",
                "new-g12-pass",
            )

            self.assertEqual(rerun.returncode, 0, rerun.stdout + rerun.stderr)
            state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(state["status"], "active")
            self.assertEqual(state["gates"]["G12"]["status"], "passed")
            self.assertEqual(state["gates"]["G12"]["operation_id"], "new-g12-pass")

    def test_any_new_state_mutation_demotes_an_exactly_completed_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)
            completed = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
                "--operation-id",
                "completion-transition",
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

            changed = self.run_statectl(
                root,
                "reference",
                "decisions",
                "post-completion-change",
                "--operation-id",
                "post-completion-state-change",
            )

            self.assertEqual(changed.returncode, 0, changed.stdout + changed.stderr)
            state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(state["status"], "active")

    def test_completed_status_retry_revalidates_source_and_read_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)
            command = (
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
                "--operation-id",
                "completion-source-revalidation",
            )
            completed = self.run_statectl(root, *command)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

            phases = root / ".forge-codex/plans/phases.json"
            phases.write_text('{"phases": [], "drift": true}\n', encoding="utf-8")
            retried = self.run_statectl(root, *command)
            shown = self.run_statectl(root, "show")
            validated = self.run_statectl(root, "validate")

            self.assertEqual(retried.returncode, 1)
            self.assertIn("current-source envelope", retried.stderr)
            self.assertEqual(shown.returncode, 1)
            self.assertEqual(validated.returncode, 1)
            self.assertIn("completion authority is stale or invalid", validated.stdout)
            state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(state["status"], "complete")

    def test_feature_baseline_drift_after_g12_or_completion_fails_closed(self) -> None:
        invalid_baseline = {
            "runtime_completion_required": True,
            "parity_summary": {"unknown": 1, "untested": 1, "removed": 1},
            "features": [],
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)
            self.write_json(
                root / ".forge-codex/state/feature-baseline.json",
                invalid_baseline,
            )
            rejected = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
                "--operation-id",
                "feature-baseline-drift-before-completion",
            )
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("current-source envelope", rejected.stderr)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)
            command = (
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
                "--operation-id",
                "feature-baseline-drift-after-completion",
            )
            completed = self.run_statectl(root, *command)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.write_json(
                root / ".forge-codex/state/feature-baseline.json",
                invalid_baseline,
            )
            self.assertEqual(self.run_statectl(root, *command).returncode, 1)
            self.assertEqual(self.run_statectl(root, "show").returncode, 1)
            self.assertEqual(self.run_statectl(root, "validate").returncode, 1)

    def test_completed_status_retry_after_demotion_does_not_repromote(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)
            command = (
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
                "--operation-id",
                "completion-demotion-retry",
            )
            completed = self.run_statectl(root, *command)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            changed = self.run_statectl(
                root,
                "reference",
                "decisions",
                "later-transaction",
                "--operation-id",
                "later-transaction-operation",
            )
            self.assertEqual(changed.returncode, 0, changed.stdout + changed.stderr)
            events_before_retry = self.read_events(root)

            retried = self.run_statectl(root, *command)

            self.assertEqual(retried.returncode, 1)
            state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(state["status"], "active")
            self.assertNotIn("completion_authority", state)
            self.assertEqual(self.read_events(root), events_before_retry)

    def test_status_complete_rejects_minimal_g12_and_state_only_prerequisite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            result_path = self.install_g12_pass(root)
            state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.write_json(
                result_path,
                {
                    "schema_version": 1,
                    "gate_id": "G12",
                    "status": "passed",
                    "finalized": True,
                    "operation_id": self.G12_OPERATION_ID,
                    "source_head": current_git_head(root),
                    "source_manifest": source_manifest(root),
                    "state_sequence_before": state["last_event_sequence"] - 1,
                },
            )
            minimal = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )
            self.assertEqual(minimal.returncode, 1)
            self.assertIn("finalized current-source envelope", minimal.stderr)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)
            (root / ".forge-codex/state/gate-results/G00.json").unlink()
            state_only = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )
            self.assertEqual(state_only.returncode, 1)
            self.assertIn("G00 gate result is unavailable", state_only.stderr)

    def test_status_complete_rejects_noncanonical_inventory_and_report_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)
            self.write_json(
                root / ".forge-codex/plans/gates.json",
                {
                    "completion_requires": ["G12"],
                    "gates": [{"id": "G12", "criteria": ["criterion G12"]}],
                },
            )
            inventory = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )
            self.assertEqual(inventory.returncode, 1)
            self.assertIn("canonical G00-G12 inventory", inventory.stderr)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_g12_repository(root)
            self.install_g12_pass(root)
            report_path = root / ".forge-codex/state/completion-report.json"
            report = json.loads(report_path.read_text(encoding="utf-8"))
            report["passed"] = False
            self.write_json(report_path, report)
            rewritten = self.run_statectl(
                root,
                "status",
                "complete",
                "--expected-g12-operation-id",
                self.G12_OPERATION_ID,
            )
            self.assertEqual(rewritten.returncode, 1)
            self.assertIn("exact successful completion reports", rewritten.stderr)

    def test_noncomplete_status_transitions_remain_compatible(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_repository(root)

            result = self.run_statectl(root, "status", "blocked_environment")

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(state["status"], "blocked_environment")


if __name__ == "__main__":
    unittest.main()
