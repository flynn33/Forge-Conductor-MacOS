#!/usr/bin/env python3
from __future__ import annotations

import copy
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock

import verify_completion
from evidence_support import source_manifest
from p10_fixture_support import (
    FIXTURE_BASELINE,
    FIXTURE_BASELINE_PATH,
    FIXTURE_EVIDENCE_ID,
    FIXTURE_SENTINEL,
    fixture_p10_binding,
    fixture_p10_module,
    fixture_python_command,
    install_fixture_p10_evaluator,
)


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
VERIFIER = SCRIPT_ROOT / "verify_completion.py"
G12_CRITERIA = [
    "all prior hard gates pass",
    "critical/high unresolved findings = 0",
    "full build/test matrix passes",
    "secret and prohibited-authorship scans pass",
    "evidence hashes validate",
    "completion validator exits zero",
]


class CompletionVerifierHardeningTests(unittest.TestCase):
    def write_json(self, path: pathlib.Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def run_git(self, root: pathlib.Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["/usr/bin/git", "-C", str(root), *arguments],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(
            completed.returncode,
            0,
            completed.stdout + completed.stderr,
        )
        return completed.stdout.strip()

    def commit_repository(self, root: pathlib.Path, message: str) -> str:
        self.run_git(root, "add", "-A")
        self.run_git(
            root,
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-q",
            "-m",
            message,
        )
        return self.run_git(root, "rev-parse", "HEAD")

    def bind_current_source(
        self,
        root: pathlib.Path,
        fixture: dict[str, object],
    ) -> None:
        head = self.run_git(root, "rev-parse", "HEAD")
        manifest = verify_completion.source_manifest(root)
        bound_results: dict[str, dict[str, object]] = {}
        result_paths = fixture.get("result_paths")
        if not isinstance(result_paths, dict):
            result_paths = {
                fixture["gate_identifier"]: fixture["result_path"],
            }
        for identifier, raw_path in result_paths.items():
            result_path = pathlib.Path(raw_path)
            result = json.loads(result_path.read_text(encoding="utf-8"))
            result["source_head"] = head
            result["source_manifest"] = manifest
            self.write_json(result_path, result)
            bound_results[str(identifier)] = result
        fixture["results"] = bound_results
        fixture["result"] = bound_results[str(fixture["gate_identifier"])]
        state = json.loads(
            (pathlib.Path(fixture["package"]) / "state/run-state.json").read_text(
                encoding="utf-8"
            )
        )
        state["repository"]["commit"] = head
        self.write_json(
            pathlib.Path(fixture["package"]) / "state/run-state.json",
            state,
        )
        fixture["state"] = state

    def install_repository(
        self,
        root: pathlib.Path,
        *,
        gate_identifier: str = "G00",
    ) -> dict[str, object]:
        package = root / ".forge-codex"
        scripts = package / "scripts"
        scripts.mkdir(parents=True)
        install_fixture_p10_evaluator(root)
        for name in (
            "statectl.py",
            "validate_package.py",
            "scan_attribution.py",
            "scan_secrets.py",
        ):
            path = scripts / name
            path.write_text(
                "#!/usr/bin/env python3\nraise SystemExit(0)\n",
                encoding="utf-8",
            )
            path.chmod(0o755)
        gate_identifiers = [f"G{index:02d}" for index in range(13)]
        criteria_by_gate = {
            identifier: (
                G12_CRITERIA
                if identifier == "G12"
                else [
                    "baseline criterion"
                    if identifier == gate_identifier
                    else f"baseline criterion {identifier}"
                ]
            )
            for identifier in gate_identifiers
        }
        for identifier in gate_identifiers:
            active_handler = package / f"state/gate-handlers/{identifier}.sh"
            active_handler.parent.mkdir(parents=True, exist_ok=True)
            active_handler.write_text(
                "#!/usr/bin/env bash\nexit 0\n",
                encoding="utf-8",
            )
            active_handler.chmod(0o755)

        self.write_json(
            package / "plans/gates.json",
            {
                "completion_requires": gate_identifiers,
                "gates": [
                    {"id": identifier, "criteria": criteria_by_gate[identifier]}
                    for identifier in gate_identifiers
                ],
            },
        )
        operation_ids = {
            identifier: str(uuid.uuid4())
            for identifier in gate_identifiers[:-1]
        }
        result_paths = {
            identifier: package / f"state/gate-results/{identifier}.json"
            for identifier in gate_identifiers[:-1]
        }
        state = {
            "run_id": "fixture-run",
            "repository": {"commit": "0" * 40},
            "status": "active",
            "gates": {
                identifier: {
                    "status": "passed",
                    "operation_id": operation_ids[identifier],
                    "evaluator": str(result_paths[identifier]),
                }
                for identifier in gate_identifiers[:-1]
            }
            | {
                "G12": {
                    "status": "not_started",
                    "operation_id": None,
                    "evaluator": None,
                }
            },
            "issues": [],
            "evidence": [FIXTURE_EVIDENCE_ID],
            "last_event_sequence": 0,
        }
        self.write_json(package / "state/run-state.json", state)
        results: dict[str, dict[str, object]] = {}
        for identifier in gate_identifiers[:-1]:
            artifact = root / f"artifact-{identifier}.txt"
            artifact.write_bytes(f"bounded evidence {identifier}\n".encode())
            result = {
                "schema_version": 1,
                "gate_id": identifier,
                "operation_id": operation_ids[identifier],
                "status": "passed",
                "finalized": True,
                "started_at": "2026-08-31T00:00:00+00:00",
                "ended_at": "2026-08-31T00:00:01+00:00",
                "commands": [
                    {
                        "command": "fixture",
                        "exit_code": 0,
                        "timed_out": False,
                        "stdout_sha256": hashlib.sha256(b"").hexdigest(),
                        "stderr_sha256": hashlib.sha256(b"").hexdigest(),
                    }
                ],
                "environment": {
                    "repository": str(root),
                    "platform": "fixture",
                    "machine": "fixture",
                },
                "artifacts": [
                    {
                        "path": str(artifact.relative_to(root)),
                        "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
                        "kind": "fixture",
                    }
                ],
                "evaluator": {
                    "name": "fixture",
                    "version": "1",
                    "criteria_results": [
                        {
                            "criterion": criterion,
                            "passed": True,
                            "evidence": "fixture",
                        }
                        for criterion in criteria_by_gate[identifier]
                    ],
                },
            }
            results[identifier] = result
            self.write_json(result_paths[identifier], result)
        for identifier in verify_completion.ACCEPTANCE_REQUIRED_GATES:
            self.write_json(
                package / f"state/acceptance/{identifier}.json",
                {
                    "schema_version": 1,
                    "gate_id": identifier,
                    "current_release_authority": True,
                },
            )
        self.write_json(
            package / "state/feature-baseline.json",
            FIXTURE_BASELINE,
        )
        self.write_json(package / "state/findings-resolution.json", {"findings": []})
        self.write_json(
            package / "state/host-capability-report.json",
            {
                "autonomous_rollover_proven": True,
                "selected_adapter": "fixture",
                "uses_private_ui_automation": False,
            },
        )
        fixture: dict[str, object] = {
            "package": package,
            "state": state,
            "result": results[gate_identifier],
            "result_path": result_paths[gate_identifier],
            "results": results,
            "result_paths": result_paths,
            "gate_identifier": gate_identifier,
        }
        self.run_git(root, "init", "-q")
        self.commit_repository(root, "initial fixture")
        self.bind_current_source(root, fixture)
        current_head = self.run_git(root, "rev-parse", "HEAD")
        current_manifest = verify_completion.source_manifest(root)
        binding = fixture_p10_binding(
            root,
            current_manifest=current_manifest,
            current_git_head=current_head,
            ledger_evidence_ids={FIXTURE_EVIDENCE_ID},
        )
        g10_criteria_path = package / "state/gate-results/G10.criteria.json"
        self.write_json(
            g10_criteria_path,
            {
                "criteria_results": [
                    {
                        "criterion": criterion,
                        "passed": True,
                        "evidence": "strict fixture P10 sentinel",
                    }
                    for criterion in criteria_by_gate["G10"]
                ],
                "valid": True,
                "errors": [],
                "p10_feature_binding": binding,
            },
        )
        g10_result = fixture["results"]["G10"]
        g10_result["artifacts"].append(
            {
                "path": str(g10_criteria_path.relative_to(root)),
                "sha256": hashlib.sha256(g10_criteria_path.read_bytes()).hexdigest(),
                "kind": "criteria",
            }
        )
        self.write_json(result_paths["G10"], g10_result)
        return fixture

    def run_verifier(
        self,
        root: pathlib.Path,
        *arguments: str,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            fixture_python_command(
                root,
                SCRIPT_ROOT,
                VERIFIER,
                "--repo",
                str(root),
                "--no-finalize",
                *arguments,
            ),
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )

    def test_valid_pair_passes_without_finalizing_and_writes_exact_criteria(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            fixture = self.install_repository(root)
            criteria = fixture["package"] / "state/gate-results/G12.criteria.json"

            completed = self.run_verifier(
                root,
                "--criteria-output",
                str(criteria),
            )

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            payload = json.loads(completed.stdout)
            self.assertTrue(payload["passed"])
            self.assertFalse(payload["finalized"])
            run_state = json.loads(
                (fixture["package"] / "state/run-state.json").read_text(encoding="utf-8")
            )
            self.assertEqual(run_state["gates"]["G12"]["status"], "not_started")
            criteria_payload = json.loads(criteria.read_text(encoding="utf-8"))
            self.assertEqual(
                [item["criterion"] for item in criteria_payload["criteria_results"]],
                G12_CRITERIA,
            )
            self.assertTrue(
                all(item["passed"] is True for item in criteria_payload["criteria_results"])
            )
            g10_criteria = json.loads(
                (
                    fixture["package"]
                    / "state/gate-results/G10.criteria.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(
                set(g10_criteria),
                {"criteria_results", "valid", "errors", "p10_feature_binding"},
            )
            self.assertEqual(
                g10_criteria["p10_feature_binding"]["sentinel"]["value"],
                FIXTURE_SENTINEL,
            )

    def test_unfinalized_and_mismatched_operations_fail_closed(self) -> None:
        mutations = ("unfinalized", "mismatched")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                fixture = self.install_repository(root)
                result = dict(fixture["result"])
                if mutation == "unfinalized":
                    result["finalized"] = False
                else:
                    state = dict(fixture["state"])
                    state["gates"] = dict(state["gates"])
                    state["gates"]["G00"] = dict(state["gates"]["G00"])
                    state["gates"]["G00"]["operation_id"] = str(uuid.uuid4())
                    self.write_json(fixture["package"] / "state/run-state.json", state)
                self.write_json(fixture["result_path"], result)

                completed = self.run_verifier(root)

                self.assertEqual(completed.returncode, 1)
                self.assertIn(
                    "gate-finalized-result:G00"
                    if mutation == "unfinalized"
                    else "gate-operation-pair:G00",
                    completed.stdout,
                )

    def test_fixture_p10_binding_rejects_stale_mutated_symlinked_and_traversal_values(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            fixture = self.install_repository(root)
            criteria_path = (
                fixture["package"] / "state/gate-results/G10.criteria.json"
            )
            criteria = json.loads(criteria_path.read_text(encoding="utf-8"))
            binding = criteria["p10_feature_binding"]
            head = self.run_git(root, "rev-parse", "HEAD")
            manifest = source_manifest(root)

            with fixture_p10_module(root) as module:
                self.assertEqual(
                    module.validate_p10_feature_binding(
                        root,
                        binding,
                        current_manifest=manifest,
                        current_git_head=head,
                        ledger_evidence_ids={FIXTURE_EVIDENCE_ID},
                    ),
                    [],
                )

                for mutation in ("stale", "traversal"):
                    with self.subTest(mutation=mutation):
                        changed = copy.deepcopy(binding)
                        if mutation == "stale":
                            changed["source_identity"]["git_head"] = "f" * 40
                        else:
                            changed["sentinel"]["path"] = "../outside.json"
                        failures = module.validate_p10_feature_binding(
                            root,
                            changed,
                            current_manifest=manifest,
                            current_git_head=head,
                            ledger_evidence_ids={FIXTURE_EVIDENCE_ID},
                        )
                        self.assertIn(
                            "fixture P10 sentinel binding changed after gate evaluation",
                            failures,
                        )

                missing_ledger = module.validate_p10_feature_binding(
                    root,
                    binding,
                    current_manifest=manifest,
                    current_git_head=head,
                    ledger_evidence_ids=set(),
                )
                self.assertIn(
                    "fixture P10 evidence sentinel is absent from the ledger",
                    missing_ledger,
                )

                baseline_path = root / FIXTURE_BASELINE_PATH
                self.write_json(
                    baseline_path,
                    {**FIXTURE_BASELINE, "sentinel": "mutated"},
                )
                mutated = module.validate_p10_feature_binding(
                    root,
                    binding,
                    current_manifest=manifest,
                    current_git_head=head,
                    ledger_evidence_ids={FIXTURE_EVIDENCE_ID},
                )
                self.assertIn(
                    "fixture P10 baseline sentinel is not exact",
                    mutated,
                )

                outside = root / "outside-feature-baseline.json"
                self.write_json(outside, FIXTURE_BASELINE)
                baseline_path.unlink()
                baseline_path.symlink_to(outside)
                symlinked = module.validate_p10_feature_binding(
                    root,
                    binding,
                    current_manifest=manifest,
                    current_git_head=head,
                    ledger_evidence_ids={FIXTURE_EVIDENCE_ID},
                )
                self.assertTrue(
                    any(
                        "symlink" in failure or "unavailable" in failure
                        for failure in symlinked
                    ),
                    symlinked,
                )

    def test_gate_result_exact_bound_passes_and_plus_one_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            fixture = self.install_repository(root)
            result = dict(fixture["result"])
            result["padding"] = ""
            base_size = len(
                (json.dumps(result, indent=2, sort_keys=True) + "\n").encode("utf-8")
            )
            result["padding"] = "x" * (
                verify_completion.MAXIMUM_CONTROL_FILE_BYTES - base_size
            )
            encoded = (json.dumps(result, indent=2, sort_keys=True) + "\n").encode(
                "utf-8"
            )
            self.assertEqual(
                len(encoded),
                verify_completion.MAXIMUM_CONTROL_FILE_BYTES,
            )
            fixture["result_path"].write_bytes(encoded)

            exact = self.run_verifier(root)

            self.assertEqual(exact.returncode, 0, exact.stdout + exact.stderr)
            result["padding"] += "x"
            fixture["result_path"].write_text(
                json.dumps(result, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            overflow = self.run_verifier(root)

            self.assertEqual(overflow.returncode, 1)
            self.assertIn("exceeds its 1048576-byte file read bound", overflow.stdout)

    def test_symlink_and_hardlink_gate_results_fail_closed(self) -> None:
        for link_kind in ("symlink", "hardlink"):
            with self.subTest(link_kind=link_kind), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                fixture = self.install_repository(root)
                result_path = fixture["result_path"]
                outside = root / "outside-result.json"
                outside.write_bytes(result_path.read_bytes())
                result_path.unlink()
                if link_kind == "symlink":
                    result_path.symlink_to(outside)
                else:
                    os.link(outside, result_path)

                completed = self.run_verifier(root)

                self.assertEqual(completed.returncode, 1)
                if link_kind == "hardlink":
                    self.assertIn("owner-controlled single-link", completed.stdout)

    def test_unresolved_high_run_state_issue_blocks_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            fixture = self.install_repository(root)
            state = dict(fixture["state"])
            state["issues"] = [
                {
                    "id": "BLOCKER",
                    "severity": "High",
                    "status": "deferred",
                }
            ]
            self.write_json(fixture["package"] / "state/run-state.json", state)

            completed = self.run_verifier(root)

            self.assertEqual(completed.returncode, 1)
            self.assertIn("critical-high-run-state-issues-resolved", completed.stdout)

    def test_expected_acceptance_is_required_and_authority_must_be_literal_true(self) -> None:
        mutations: tuple[tuple[str, object], ...] = (
            ("missing", None),
            ("wrong-gate", {"gate_id": "G03", "current_release_authority": True}),
            ("missing-authority", {"gate_id": "G02"}),
            ("false", {"gate_id": "G02", "current_release_authority": False}),
            ("integer", {"gate_id": "G02", "current_release_authority": 1}),
            ("string", {"gate_id": "G02", "current_release_authority": "true"}),
        )
        for mutation, replacement in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                fixture = self.install_repository(root, gate_identifier="G02")
                acceptance = fixture["package"] / "state/acceptance/G02.json"
                if replacement is None:
                    acceptance.unlink()
                else:
                    self.write_json(acceptance, replacement)

                completed = self.run_verifier(root)

                self.assertEqual(completed.returncode, 1)
                self.assertIn("gate-current-release-authority:G02", completed.stdout)

    def test_malformed_or_missing_findings_fail_closed(self) -> None:
        mutations: tuple[tuple[str, object], ...] = (
            ("missing", None),
            ("missing-array", {}),
            ("wrong-array-type", {"findings": {}}),
            ("non-object", {"findings": ["bad"]}),
            (
                "missing-severity",
                {"findings": [{"id": "FINDING", "status": "resolved"}]},
            ),
            (
                "duplicate-id",
                {
                    "findings": [
                        {"id": "FINDING", "severity": "Low", "status": "resolved"},
                        {"id": "FINDING", "severity": "Low", "status": "resolved"},
                    ]
                },
            ),
        )
        for mutation, replacement in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                fixture = self.install_repository(root)
                findings = fixture["package"] / "state/findings-resolution.json"
                if replacement is None:
                    findings.unlink()
                else:
                    self.write_json(findings, replacement)

                completed = self.run_verifier(root)

                self.assertEqual(completed.returncode, 1)
                self.assertIn("findings-resolution", completed.stdout)

    def test_malformed_run_state_issues_fail_closed(self) -> None:
        malformed_values: tuple[object, ...] = (
            None,
            {},
            ["bad"],
            [{"id": "ISSUE", "severity": "High"}],
            [
                {"id": "ISSUE", "severity": "Low", "status": "resolved"},
                {"id": "ISSUE", "severity": "Low", "status": "resolved"},
            ],
        )
        for value in malformed_values:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                fixture = self.install_repository(root)
                state = json.loads(
                    (fixture["package"] / "state/run-state.json").read_text(
                        encoding="utf-8"
                    )
                )
                state["issues"] = value
                self.write_json(fixture["package"] / "state/run-state.json", state)

                completed = self.run_verifier(root)

                self.assertEqual(completed.returncode, 1)
                self.assertIn("run-state-issues-structure", completed.stdout)

    def test_each_prerequisite_result_requires_current_head_and_manifest(self) -> None:
        mutations = ("missing-head", "wrong-head", "missing-manifest", "wrong-manifest")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                fixture = self.install_repository(root)
                result = json.loads(
                    fixture["result_path"].read_text(encoding="utf-8")
                )
                if mutation == "missing-head":
                    result.pop("source_head")
                elif mutation == "wrong-head":
                    result["source_head"] = "0" * 40
                elif mutation == "missing-manifest":
                    result.pop("source_manifest")
                else:
                    result["source_manifest"] = {
                        "schema_version": 1,
                        "sha256": "0" * 64,
                        "file_count": 1,
                        "bytes": 1,
                    }
                self.write_json(fixture["result_path"], result)

                completed = self.run_verifier(root)

                self.assertEqual(completed.returncode, 1)
                self.assertIn("gate-current-source-binding:G00", completed.stdout)

    def test_git_identity_unavailable_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.install_repository(root)
            (root / ".git").rename(root / "git-metadata-unavailable")

            completed = self.run_verifier(root)

            self.assertEqual(completed.returncode, 1)
            self.assertIn("current-git-head-valid", completed.stdout)
            self.assertIn("relevant-source-clean", completed.stdout)

    def test_state_and_evidence_changes_are_allowed_but_relevant_source_is_not(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            fixture = self.install_repository(root)
            (fixture["package"] / "state/runtime-only.txt").write_text(
                "state\n", encoding="utf-8"
            )
            evidence = fixture["package"] / "evidence/runtime-only.txt"
            evidence.parent.mkdir(parents=True, exist_ok=True)
            evidence.write_text("evidence\n", encoding="utf-8")

            allowed = self.run_verifier(root)

            self.assertEqual(allowed.returncode, 0, allowed.stdout + allowed.stderr)
            source = root / "Sources/Dirty.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("let dirty = true\n", encoding="utf-8")

            blocked = self.run_verifier(root)

            self.assertEqual(blocked.returncode, 1)
            self.assertIn("relevant-source-clean", blocked.stdout)

    def test_active_gate_handler_change_is_relevant_dirty_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            fixture = self.install_repository(root)
            handler = fixture["package"] / "state/gate-handlers/G00.sh"
            handler.write_text(
                "#!/usr/bin/env bash\nexit 1\n",
                encoding="utf-8",
            )

            completed = self.run_verifier(root)

            self.assertEqual(completed.returncode, 1)
            self.assertIn("relevant-source-clean", completed.stdout)

    def test_final_g12_pair_requires_current_source_binding_and_clean_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            from test_statectl_transactions import StateTransactionTests

            builder = StateTransactionTests()
            builder.make_g12_repository(root)
            result_path = builder.install_g12_pass(root)
            package = root / ".forge-codex"
            result = json.loads(result_path.read_text(encoding="utf-8"))
            operation_id = result["operation_id"]

            with fixture_p10_module(root):
                loaded_state, loaded_result = verify_completion.load_final_g12_pair(root)

            self.assertEqual(loaded_state["gates"]["G12"]["operation_id"], operation_id)
            self.assertEqual(loaded_result["source_head"], result["source_head"])
            result["source_head"] = "0" * 40
            self.write_json(result_path, result)
            with fixture_p10_module(root), self.assertRaisesRegex(
                verify_completion.EvidenceSupportError,
                "finalized matching operation",
            ):
                verify_completion.load_final_g12_pair(root)

            result["source_head"] = self.run_git(root, "rev-parse", "HEAD")
            self.write_json(result_path, result)
            source = root / "Sources/Dirty.swift"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("let dirty = true\n", encoding="utf-8")
            with fixture_p10_module(root), self.assertRaisesRegex(
                verify_completion.EvidenceSupportError,
                "dirty, or unstable",
            ):
                verify_completion.load_final_g12_pair(root)

    def test_finalization_requires_confirmed_g12_pair_and_complete_transition(self) -> None:
        root = pathlib.Path("/fixture").resolve()
        successful_command = (0, b"{}", b"")
        g12_operation_id = str(uuid.uuid4())
        with mock.patch.object(
            verify_completion,
            "run_bounded_readonly_command",
            side_effect=[successful_command, (1, b"", b"first"), (1, b"", b"second")],
        ), mock.patch.object(
            verify_completion,
            "load_final_g12_pair",
            return_value=({}, {"operation_id": g12_operation_id}),
        ):
            with self.assertRaisesRegex(
                verify_completion.EvidenceSupportError,
                "could not be committed idempotently",
            ):
                verify_completion.finalize(root)

        status_operation_id = "56565656-5656-4565-8565-565656565656"
        readback = json.dumps(
            {
                "status": "complete",
                "completion_authority": {
                    "schema_version": 1,
                    "g12_operation_id": g12_operation_id,
                    "status_operation_id": status_operation_id,
                },
            }
        ).encode("utf-8")
        with mock.patch.object(
            verify_completion,
            "run_bounded_readonly_command",
            side_effect=[successful_command, successful_command, (0, readback, b"")],
        ) as bounded, mock.patch.object(
            verify_completion,
            "load_final_g12_pair",
            return_value=({}, {"operation_id": g12_operation_id}),
        ) as pair, mock.patch.object(
            verify_completion.uuid,
            "uuid4",
            return_value=uuid.UUID(status_operation_id),
        ):
            verify_completion.finalize(root)
            pair.assert_called_once_with(root)
            status_command = bounded.call_args_list[1].args[2]
            expected_index = status_command.index("--expected-g12-operation-id")
            self.assertEqual(status_command[expected_index + 1], g12_operation_id)

    def test_default_command_finalizes_through_real_gate_and_state_transactions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            fixture = self.install_repository(root)
            package = fixture["package"]
            scripts = package / "scripts"
            for name in (
                "evidence_support.py",
                "run_gate.py",
                "statectl.py",
                "validate_acceptance.py",
                "verify_completion.py",
            ):
                destination = scripts / name
                destination.write_bytes((SCRIPT_ROOT / name).read_bytes())
                destination.chmod(0o755)
            self.write_json(package / "plans/phases.json", {"phases": []})
            handlers = package / "state/gate-handlers"
            handlers.mkdir(parents=True, exist_ok=True)
            gate_plan = json.loads(
                (package / "plans/gates.json").read_text(encoding="utf-8")
            )
            criteria_by_gate = {
                item["id"]: item["criteria"]
                for item in gate_plan["gates"]
            }
            for index in range(12):
                identifier = f"G{index:02d}"
                handler = handlers / f"{identifier}.sh"
                source = (
                    "#!/usr/bin/env python3\n"
                    "import json, os, pathlib, sys\n"
                    "root = pathlib.Path(os.environ['FORGE_GATE_REPOSITORY_ROOT'])\n"
                    "sys.path.insert(0, str(root / '.forge-codex/scripts'))\n"
                    f"criteria = {criteria_by_gate[identifier]!r}\n"
                    f"path = root / '.forge-codex/state/gate-results/{identifier}.criteria.json'\n"
                    "payload = {'criteria_results': ["
                    "{'criterion': item, 'passed': True, 'evidence': 'fixture'} "
                    "for item in criteria]}\n"
                )
                if identifier == "G10":
                    source += (
                        "from evidence_support import current_git_head, source_manifest\n"
                        "from p10_feature_evidence import evaluate_p10_feature_evidence\n"
                        "state = json.loads((root / '.forge-codex/state/run-state.json').read_text())\n"
                        "evaluation = evaluate_p10_feature_evidence(\n"
                        "    root,\n"
                        "    current_manifest=source_manifest(root),\n"
                        "    current_git_head=current_git_head(root) or '',\n"
                        "    ledger_evidence_ids={item for item in state.get('evidence', []) if isinstance(item, str)},\n"
                        ")\n"
                        "if evaluation.failures:\n"
                        "    raise SystemExit('; '.join(evaluation.failures))\n"
                        "payload.update({'valid': True, 'errors': [], 'p10_feature_binding': evaluation.binding})\n"
                    )
                source += (
                    "path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\\n')\n"
                )
                handler.write_text(source, encoding="utf-8")
                handler.chmod(0o755)
            g12_handler = handlers / "G12.sh"
            g12_handler.write_bytes(
                (SCRIPT_ROOT.parent / "state/gate-handlers/G12.sh").read_bytes()
            )
            g12_handler.chmod(0o755)
            self.commit_repository(root, "install completion pipeline")

            (package / "state/run-state.json").unlink()
            events_path = package / "state/events.jsonl"
            if events_path.exists():
                events_path.unlink()
            initialized = subprocess.run(
                [
                    sys.executable,
                    str(scripts / "statectl.py"),
                    "--repo",
                    str(root),
                    "init",
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(
                initialized.returncode,
                0,
                initialized.stdout + initialized.stderr,
            )
            referenced = subprocess.run(
                [
                    sys.executable,
                    str(scripts / "statectl.py"),
                    "--repo",
                    str(root),
                    "reference",
                    "evidence",
                    FIXTURE_EVIDENCE_ID,
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(
                referenced.returncode,
                0,
                referenced.stdout + referenced.stderr,
            )
            for index in range(12):
                identifier = f"G{index:02d}"
                admitted = subprocess.run(
                    [
                        sys.executable,
                        str(scripts / "run_gate.py"),
                        "--repo",
                        str(root),
                        "--",
                        identifier,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=20,
                    check=False,
                )
                gate_stderr = package / f"state/gate-results/{identifier}.stderr.txt"
                gate_diagnostic = (
                    gate_stderr.read_text(encoding="utf-8", errors="replace")
                    if gate_stderr.is_file()
                    else ""
                )
                self.assertEqual(
                    admitted.returncode,
                    0,
                    admitted.stdout + admitted.stderr + gate_diagnostic,
                )

            completed = subprocess.run(
                [
                    sys.executable,
                    str(scripts / "verify_completion.py"),
                    "--repo",
                    str(root),
                ],
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            payload = json.loads(completed.stdout)
            self.assertTrue(payload["passed"])
            self.assertTrue(payload["finalized"])
            state = json.loads(
                (package / "state/run-state.json").read_text(encoding="utf-8")
            )
            result = json.loads(
                (package / "state/gate-results/G12.json").read_text(encoding="utf-8")
            )
            self.assertEqual(state["status"], "complete")
            self.assertEqual(state["gates"]["G12"]["status"], "passed")
            self.assertEqual(
                state["gates"]["G12"]["operation_id"],
                result["operation_id"],
            )
            self.assertIs(result["finalized"], True)


if __name__ == "__main__":
    unittest.main()
