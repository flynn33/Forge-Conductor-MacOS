#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import uuid
from datetime import datetime, timezone
from typing import Any

import statectl
from evidence_support import (
    BoundedCommandError,
    BoundedReadBudget,
    EvidenceSupportError,
    current_git_head,
    decode_strict_json_object,
    load_bounded_repository_json_object,
    run_bounded_readonly_command,
    sha256_bounded_repository_file,
    source_manifest,
)
from validate_acceptance import stable_evidence_digest, write_criteria_output


MAXIMUM_CONTROL_FILE_BYTES = 1024 * 1024
MAXIMUM_CONTROL_TOTAL_BYTES = 64 * 1024 * 1024
MAXIMUM_COMPLETION_REPORT_BYTES = 1024 * 1024
MAXIMUM_COMMAND_OUTPUT_BYTES = 16 * 1024 * 1024
MAXIMUM_COMMAND_SECONDS = 1800.0
MAXIMUM_REQUIRED_GATES = 128
MAXIMUM_GATE_ARTIFACTS = 4096
MAXIMUM_GATE_ARTIFACT_TOTAL_BYTES = 16 * 1024 * 1024 * 1024
MAXIMUM_G10_ARTIFACT_TOTAL_BYTES = 512 * 1024 * 1024
MAXIMUM_DETAIL_CHARACTERS = 1024
OPERATION_IDENTIFIER = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"
)
SHA256 = re.compile(r"[0-9a-f]{64}")
ACCEPTANCE_REQUIRED_GATES = frozenset(
    f"G{identifier:02d}" for identifier in range(2, 12)
)
ISSUE_SEVERITIES = frozenset({"Critical", "High", "Medium", "Low"})
ISSUE_STATUSES = frozenset(
    {"open", "patching", "validating", "resolved", "deferred"}
)


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def locate_repo(explicit: str | None) -> pathlib.Path:
    if explicit:
        repository = pathlib.Path(explicit).resolve()
        if not (repository / ".forge-codex").is_dir():
            raise SystemExit("repository not found")
        return repository
    current = pathlib.Path.cwd().resolve()
    for candidate in (current, *current.parents):
        if (candidate / ".forge-codex").is_dir():
            return candidate
    raise SystemExit("repository not found")


def bounded_detail(value: Any) -> str:
    try:
        rendered = value if isinstance(value, str) else json.dumps(
            value,
            sort_keys=True,
            allow_nan=False,
        )
    except (TypeError, ValueError):
        rendered = repr(value)
    if len(rendered) > MAXIMUM_DETAIL_CHARACTERS:
        return rendered[:MAXIMUM_DETAIL_CHARACTERS] + "..."
    return rendered


class CompletionEvaluation:
    def __init__(self, repository: pathlib.Path) -> None:
        self.repository = repository
        self.package = repository / ".forge-codex"
        self.control_budget = BoundedReadBudget(
            MAXIMUM_CONTROL_TOTAL_BYTES,
            "completion control JSON",
        )
        self.artifact_budget = BoundedReadBudget(
            MAXIMUM_GATE_ARTIFACT_TOTAL_BYTES,
            "completion artifact evidence",
        )
        self.g10_artifact_budget = BoundedReadBudget(
            MAXIMUM_G10_ARTIFACT_TOTAL_BYTES,
            "G10 completion artifact evidence",
        )
        self.checks: list[dict[str, object]] = []
        self.errors: list[str] = []
        self.state: dict[str, Any] = {}
        self.gate_plan: dict[str, Any] = {}
        self.current_source_head: str | None = None
        self.current_source_manifest: dict[str, Any] | None = None
        self.gate_result_bindings: list[dict[str, Any]] = []

    def check(self, name: str, passed: bool, detail: Any) -> None:
        normalized_detail = bounded_detail(detail)
        self.checks.append(
            {"name": name, "passed": bool(passed), "detail": normalized_detail}
        )
        if not passed:
            self.errors.append(f"{name}: {normalized_detail}")

    def load_control(self, relative: str, *, label: str) -> dict[str, Any]:
        return load_bounded_repository_json_object(
            self.repository,
            relative,
            label=label,
            maximum_bytes=MAXIMUM_CONTROL_FILE_BYTES,
            budget=self.control_budget,
            require_owner_controlled=True,
        )

    def run_check(
        self,
        name: str,
        command: list[str],
        detail: str,
        *,
        timeout_seconds: float = MAXIMUM_COMMAND_SECONDS,
    ) -> bool:
        try:
            exit_code, stdout, stderr = run_bounded_readonly_command(
                self.repository,
                name,
                command,
                timeout_seconds=timeout_seconds,
                maximum_output_bytes=MAXIMUM_COMMAND_OUTPUT_BYTES,
            )
            output = (stderr + stdout)[:MAXIMUM_DETAIL_CHARACTERS].decode(
                "utf-8", errors="replace"
            ).strip()
            passed = exit_code == 0
            self.check(name, passed, detail if passed else (output or f"exit {exit_code}"))
            return passed
        except (BoundedCommandError, EvidenceSupportError) as error:
            self.check(name, False, error)
            return False

    def run_git(self, label: str, arguments: list[str]) -> tuple[bool, bytes, str]:
        try:
            exit_code, stdout, stderr = run_bounded_readonly_command(
                self.repository,
                label,
                ["/usr/bin/git", "-C", str(self.repository), *arguments],
                timeout_seconds=60.0,
                maximum_output_bytes=MAXIMUM_COMMAND_OUTPUT_BYTES,
            )
        except (BoundedCommandError, EvidenceSupportError) as error:
            return False, b"", str(error)
        if exit_code != 0:
            diagnostic = (stderr + stdout)[:MAXIMUM_DETAIL_CHARACTERS].decode(
                "utf-8", errors="replace"
            ).strip()
            return False, b"", diagnostic or f"exit {exit_code}"
        return True, stdout, ""

    def observe_source_identity(
        self,
    ) -> tuple[str | None, dict[str, Any] | None, bool, list[str]]:
        diagnostics: list[str] = []
        head = current_git_head(self.repository)
        if head is None:
            diagnostics.append("Git HEAD unavailable or malformed")

        clean_ok, status_raw, status_diagnostic = self.run_git(
            "completion relevant-source status",
            [
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
                "--",
                ".",
                ":(exclude).forge-codex/state",
                ":(exclude).forge-codex/state/**",
                ":(exclude).forge-codex/evidence",
                ":(exclude).forge-codex/evidence/**",
            ],
        )
        handler_clean_ok, handler_status_raw, handler_status_diagnostic = self.run_git(
            "completion active gate-handler status",
            [
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
                "--",
                ".forge-codex/state/gate-handlers",
            ],
        )
        combined_status = status_raw + handler_status_raw
        clean = clean_ok and handler_clean_ok and not combined_status
        if not clean_ok:
            diagnostics.append(
                f"relevant-source status unavailable: {status_diagnostic}"
            )
        if not handler_clean_ok:
            diagnostics.append(
                "active gate-handler status unavailable: "
                f"{handler_status_diagnostic}"
            )
        if combined_status:
            rendered = combined_status[:MAXIMUM_DETAIL_CHARACTERS].decode(
                "utf-8", errors="replace"
            ).replace("\x00", " ").strip()
            diagnostics.append(f"relevant source is dirty: {rendered}")

        manifest: dict[str, Any] | None = None
        try:
            manifest = source_manifest(self.repository)
        except EvidenceSupportError as error:
            diagnostics.append(f"source manifest unavailable: {error}")
        return head, manifest, clean, diagnostics

    def validate_current_source_identity(self) -> None:
        first_head, first_manifest, first_clean, first_diagnostics = (
            self.observe_source_identity()
        )
        second_head, second_manifest, second_clean, second_diagnostics = (
            self.observe_source_identity()
        )
        stable = (
            first_head is not None
            and first_manifest is not None
            and first_clean
            and second_head == first_head
            and second_manifest == first_manifest
            and second_clean
        )
        diagnostics = first_diagnostics + second_diagnostics
        self.check(
            "current-git-head-valid",
            first_head is not None and second_head == first_head,
            first_head or "; ".join(diagnostics) or "unavailable",
        )
        self.check(
            "current-source-manifest-valid",
            first_manifest is not None and second_manifest == first_manifest,
            first_manifest or "; ".join(diagnostics) or "unavailable",
        )
        self.check(
            "relevant-source-clean",
            first_clean and second_clean,
            "clean" if first_clean and second_clean else "; ".join(diagnostics),
        )
        self.check(
            "current-source-identity-stable",
            stable,
            "two matching bounded observations" if stable else diagnostics,
        )
        if stable:
            self.current_source_head = first_head
            self.current_source_manifest = first_manifest

    def validate_source_identity_unchanged(self) -> None:
        head, manifest, clean, diagnostics = self.observe_source_identity()
        unchanged = (
            self.current_source_head is not None
            and self.current_source_manifest is not None
            and head == self.current_source_head
            and manifest == self.current_source_manifest
            and clean
        )
        self.check(
            "source-identity-unchanged-through-evaluation",
            unchanged,
            (
                "Git HEAD, manifest, and relevant-source status remained stable"
                if unchanged
                else diagnostics
                or {
                    "expected_head": self.current_source_head,
                    "actual_head": head,
                    "expected_manifest": self.current_source_manifest,
                    "actual_manifest": manifest,
                    "clean": clean,
                }
            ),
        )

    def load_required_controls(self) -> bool:
        self.run_check(
            "run-state-valid",
            [
                str(self.package / "scripts/statectl.py"),
                "--repo",
                str(self.repository),
                "validate",
            ],
            "state/event chain",
            timeout_seconds=60.0,
        )
        try:
            self.state = self.load_control(
                ".forge-codex/state/run-state.json",
                label="completion run state",
            )
            self.gate_plan = self.load_control(
                ".forge-codex/plans/gates.json",
                label="completion gate plan",
            )
            return True
        except EvidenceSupportError as error:
            self.check("completion-controls-load", False, error)
            return False

    def validate_gate_artifacts(
        self, gate_identifier: str, result: dict[str, Any]
    ) -> None:
        artifacts = result.get("artifacts")
        if (
            not isinstance(artifacts, list)
            or not artifacts
            or len(artifacts) > MAXIMUM_GATE_ARTIFACTS
        ):
            self.check(
                f"gate-artifacts:{gate_identifier}",
                False,
                "artifact list is missing, empty, or exceeds its count bound",
            )
            return
        errors: list[str] = []
        seen_paths: set[str] = set()
        budget = (
            self.g10_artifact_budget if gate_identifier == "G10" else self.artifact_budget
        )
        for index, artifact in enumerate(artifacts):
            if not isinstance(artifact, dict):
                errors.append(f"artifact[{index}] is not an object")
                continue
            raw_path = artifact.get("path")
            expected = artifact.get("sha256")
            if (
                not isinstance(raw_path, str)
                or not raw_path
                or raw_path in seen_paths
                or not isinstance(expected, str)
                or SHA256.fullmatch(expected) is None
            ):
                errors.append(f"artifact[{index}] has invalid path or digest")
                continue
            seen_paths.add(raw_path)
            try:
                path, actual = stable_evidence_digest(
                    self.repository,
                    raw_path,
                    label=f"{gate_identifier} completion artifact",
                    budget=budget,
                    require_repository_content=gate_identifier == "G10",
                )
            except EvidenceSupportError as error:
                errors.append(f"{raw_path}: {error}")
                continue
            if actual != expected:
                errors.append(f"{path}: hash mismatch")
        self.check(
            f"gate-artifacts:{gate_identifier}",
            not errors,
            (
                f"{len(artifacts)} bounded artifact(s) verified"
                if not errors
                else "; ".join(errors[:8])
            ),
        )

    def validate_gate(self, gate_identifier: str, criteria: list[str]) -> None:
        relative = f".forge-codex/state/gate-results/{gate_identifier}.json"
        result_path = self.repository / relative
        try:
            result = self.load_control(
                relative,
                label=f"{gate_identifier} completion gate result",
            )
        except EvidenceSupportError as error:
            self.check(f"gate-result-valid:{gate_identifier}", False, error)
            return

        try:
            result_sha256, result_bytes = sha256_bounded_repository_file(
                self.repository,
                relative,
                label=f"{gate_identifier} completion gate result binding",
                maximum_bytes=MAXIMUM_CONTROL_FILE_BYTES,
            )
            self.gate_result_bindings.append(
                {
                    "gate_id": gate_identifier,
                    "operation_id": result.get("operation_id"),
                    "sha256": result_sha256,
                    "bytes": result_bytes,
                }
            )
            self.check(
                f"gate-result-binding:{gate_identifier}",
                True,
                {"sha256": result_sha256, "bytes": result_bytes},
            )
        except EvidenceSupportError as error:
            self.check(f"gate-result-binding:{gate_identifier}", False, error)

        state_gates = self.state.get("gates")
        state_item = state_gates.get(gate_identifier) if isinstance(state_gates, dict) else None
        operation_id = result.get("operation_id")
        result_valid = (
            result.get("gate_id") == gate_identifier
            and result.get("status") == "passed"
            and result.get("finalized") is True
            and isinstance(operation_id, str)
            and OPERATION_IDENTIFIER.fullmatch(operation_id) is not None
        )
        state_valid = (
            isinstance(state_item, dict)
            and state_item.get("status") == "passed"
            and state_item.get("operation_id") == operation_id
            and state_item.get("evaluator") == str(result_path)
        )
        self.check(
            f"gate-finalized-result:{gate_identifier}",
            result_valid,
            {
                "status": result.get("status"),
                "finalized": result.get("finalized"),
                "operation_id": operation_id,
            },
        )
        self.check(
            f"gate-operation-pair:{gate_identifier}",
            result_valid and state_valid,
            {
                "result_operation_id": operation_id,
                "state_operation_id": (
                    state_item.get("operation_id") if isinstance(state_item, dict) else None
                ),
                "state_status": (
                    state_item.get("status") if isinstance(state_item, dict) else None
                ),
            },
        )
        source_binding_valid = (
            self.current_source_head is not None
            and self.current_source_manifest is not None
            and result.get("source_head") == self.current_source_head
            and result.get("source_manifest") == self.current_source_manifest
        )
        self.check(
            f"gate-current-source-binding:{gate_identifier}",
            source_binding_valid,
            {
                "expected_head": self.current_source_head,
                "result_head": result.get("source_head"),
                "expected_manifest": self.current_source_manifest,
                "result_manifest": result.get("source_manifest"),
            },
        )

        commands = result.get("commands")
        commands_valid = (
            isinstance(commands, list)
            and bool(commands)
            and all(
                isinstance(command, dict)
                and isinstance(command.get("command"), str)
                and bool(command.get("command"))
                and isinstance(command.get("exit_code"), int)
                and not isinstance(command.get("exit_code"), bool)
                and command.get("exit_code") == 0
                and command.get("timed_out") is False
                and isinstance(command.get("stdout_sha256"), str)
                and SHA256.fullmatch(command["stdout_sha256"]) is not None
                and isinstance(command.get("stderr_sha256"), str)
                and SHA256.fullmatch(command["stderr_sha256"]) is not None
                for command in commands
            )
        )
        evaluator = result.get("evaluator")
        criteria_results = evaluator.get("criteria_results") if isinstance(evaluator, dict) else None
        criteria_valid = (
            isinstance(criteria_results, list)
            and len(criteria_results) == len(criteria)
            and all(
                isinstance(item, dict)
                and item.get("criterion") == criterion
                and item.get("passed") is True
                for item, criterion in zip(criteria_results, criteria)
            )
        )
        environment = result.get("environment")
        environment_valid = (
            isinstance(environment, dict)
            and environment.get("repository") == str(self.repository)
            and isinstance(environment.get("platform"), str)
            and bool(environment.get("platform"))
            and isinstance(environment.get("machine"), str)
            and bool(environment.get("machine"))
        )
        try:
            started = datetime.fromisoformat(result.get("started_at"))
            ended = datetime.fromisoformat(result.get("ended_at"))
            timing_valid = (
                started.tzinfo is not None
                and ended.tzinfo is not None
                and started <= ended
            )
        except (TypeError, ValueError):
            timing_valid = False
        envelope_valid = (
            result.get("schema_version") == 1
            and environment_valid
            and timing_valid
            and isinstance(evaluator, dict)
            and isinstance(evaluator.get("name"), str)
            and bool(evaluator.get("name"))
            and isinstance(evaluator.get("version"), str)
            and bool(evaluator.get("version"))
        )
        self.check(
            f"gate-command-contract:{gate_identifier}",
            commands_valid,
            "all recorded commands exited zero within their deadline",
        )
        self.check(
            f"gate-criteria-contract:{gate_identifier}",
            criteria_valid,
            "exact ordered criteria with literal Boolean passes",
        )
        self.check(
            f"gate-result-envelope:{gate_identifier}",
            envelope_valid,
            "schema, timing, environment, and evaluator metadata",
        )
        self.validate_gate_artifacts(gate_identifier, result)
        if gate_identifier == "G10":
            try:
                criteria_document = self.load_control(
                    ".forge-codex/state/gate-results/G10.criteria.json",
                    label="G10 P10 feature-bound criteria",
                )
                if set(criteria_document) != {
                    "criteria_results",
                    "valid",
                    "errors",
                    "p10_feature_binding",
                }:
                    raise EvidenceSupportError(
                        "G10 criteria has no exact P10 feature binding"
                    )
                from p10_feature_evidence import validate_p10_feature_binding

                binding_failures = validate_p10_feature_binding(
                    self.repository,
                    criteria_document.get("p10_feature_binding"),
                    current_manifest=self.current_source_manifest or {},
                    current_git_head=self.current_source_head or "",
                    ledger_evidence_ids={
                        item
                        for item in self.state.get("evidence", [])
                        if isinstance(item, str)
                    },
                )
                self.check(
                    "g10-p10-feature-evidence-binding",
                    not binding_failures,
                    (
                        "exact feature, evidence-record, semantic-row, artifact, and ledger binding"
                        if not binding_failures
                        else "; ".join(binding_failures[:8])
                    ),
                )
            except (EvidenceSupportError, ImportError) as error:
                self.check("g10-p10-feature-evidence-binding", False, error)

        if gate_identifier not in ACCEPTANCE_REQUIRED_GATES:
            return
        acceptance_relative = f".forge-codex/state/acceptance/{gate_identifier}.json"
        try:
            acceptance = self.load_control(
                acceptance_relative,
                label=f"{gate_identifier} completion acceptance record",
            )
            current = (
                acceptance.get("gate_id") == gate_identifier
                and acceptance.get("current_release_authority") is True
            )
            self.check(
                f"gate-current-release-authority:{gate_identifier}",
                current,
                {
                    "record_gate_id": acceptance.get("gate_id"),
                    "current_release_authority": acceptance.get(
                        "current_release_authority"
                    ),
                    "authority_scope": acceptance.get("authority_scope"),
                },
            )
        except EvidenceSupportError as error:
            self.check(f"gate-current-release-authority:{gate_identifier}", False, error)

    def validate_gates(self) -> None:
        required = self.gate_plan.get("completion_requires")
        gates = self.gate_plan.get("gates")
        if (
            not isinstance(required, list)
            or not required
            or len(required) > MAXIMUM_REQUIRED_GATES
            or not all(isinstance(item, str) and item for item in required)
            or len(set(required)) != len(required)
            or not isinstance(gates, list)
        ):
            self.check("completion-gate-plan-valid", False, "malformed gate plan")
            return
        definitions = {
            item.get("id"): item
            for item in gates
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        declared_identifiers = [
            item.get("id")
            for item in gates
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        ]
        exact_inventory = (
            len(declared_identifiers) == len(gates)
            and len(set(declared_identifiers)) == len(declared_identifiers)
            and required == declared_identifiers
            and required[-1] == "G12"
        )
        self.check(
            "completion-gate-plan-valid",
            exact_inventory and all(identifier in definitions for identifier in required),
            f"{len(required)} completion gate identifiers",
        )
        for gate_identifier in required:
            if gate_identifier == "G12":
                continue
            definition = definitions.get(gate_identifier)
            criteria = definition.get("criteria") if isinstance(definition, dict) else None
            if (
                not isinstance(criteria, list)
                or not criteria
                or not all(isinstance(item, str) and item for item in criteria)
                or len(set(criteria)) != len(criteria)
            ):
                self.check(
                    f"gate-plan-criteria:{gate_identifier}",
                    False,
                    "missing or malformed criteria",
                )
                continue
            self.validate_gate(gate_identifier, criteria)

    def validate_feature_baseline(self) -> None:
        try:
            from p10_feature_evidence import evaluate_p10_feature_evidence

            evaluation = evaluate_p10_feature_evidence(
                self.repository,
                current_manifest=self.current_source_manifest or {},
                current_git_head=self.current_source_head or "",
                ledger_evidence_ids={
                    item
                    for item in self.state.get("evidence", [])
                    if isinstance(item, str)
                },
            )
            self.check(
                "feature-baseline-valid",
                not evaluation.failures,
                (
                    "104 exact registry-bound production-qualified feature records"
                    if not evaluation.failures
                    else "; ".join(evaluation.failures[:8])
                ),
            )
        except (EvidenceSupportError, ImportError) as error:
            self.check("feature-baseline-valid", False, error)

    def validate_findings(self) -> None:
        findings_document: dict[str, Any] | None = None
        try:
            findings_document = self.load_control(
                ".forge-codex/state/findings-resolution.json",
                label="completion findings resolution",
            )
        except EvidenceSupportError as error:
            self.check("findings-resolution-valid", False, error)
        findings_value = (
            findings_document.get("findings")
            if isinstance(findings_document, dict)
            else None
        )
        findings = findings_value if isinstance(findings_value, list) else []
        findings_structure_valid = isinstance(findings_value, list)
        finding_identifiers: set[str] = set()
        for item in findings:
            if not isinstance(item, dict):
                findings_structure_valid = False
                continue
            identifier = item.get("id")
            if (
                not isinstance(identifier, str)
                or not identifier
                or identifier in finding_identifiers
                or item.get("severity") not in ISSUE_SEVERITIES
                or item.get("status") not in ISSUE_STATUSES
            ):
                findings_structure_valid = False
                continue
            finding_identifiers.add(identifier)
        self.check(
            "findings-resolution-structure",
            findings_structure_valid,
            f"{len(findings)} unique, typed finding record(s)",
        )
        unresolved_findings = [
            item.get("id", "unknown")
            for item in findings
            if isinstance(item, dict)
            and item.get("severity") in {"Critical", "High"}
            and item.get("status") != "resolved"
        ]
        issues_value = self.state.get("issues")
        issues = issues_value if isinstance(issues_value, list) else []
        issues_structure_valid = isinstance(issues_value, list)
        issue_identifiers: set[str] = set()
        for item in issues:
            if not isinstance(item, dict):
                issues_structure_valid = False
                continue
            identifier = item.get("id")
            if (
                not isinstance(identifier, str)
                or not identifier
                or identifier in issue_identifiers
                or item.get("severity") not in ISSUE_SEVERITIES
                or item.get("status") not in ISSUE_STATUSES
            ):
                issues_structure_valid = False
                continue
            issue_identifiers.add(identifier)
        self.check(
            "run-state-issues-structure",
            issues_structure_valid,
            f"{len(issues)} unique, typed issue record(s)",
        )
        unresolved_issues = [
            item.get("id", "unknown")
            for item in issues
            if isinstance(item, dict)
            and item.get("severity") in {"Critical", "High"}
            and item.get("status") != "resolved"
        ]
        self.check(
            "critical-high-findings-resolved",
            not unresolved_findings,
            unresolved_findings[:128],
        )
        self.check(
            "critical-high-run-state-issues-resolved",
            not unresolved_issues,
            unresolved_issues[:128],
        )

    def validate_host(self) -> None:
        try:
            host = self.load_control(
                ".forge-codex/state/host-capability-report.json",
                label="completion host capability report",
            )
        except EvidenceSupportError as error:
            self.check("host-capability-report-valid", False, error)
            return
        self.check(
            "autonomous-rollover-mode-proven",
            host.get("autonomous_rollover_proven") is True,
            host.get("selected_adapter"),
        )
        self.check(
            "supported-api-only",
            host.get("uses_private_ui_automation") is False,
            host.get("uses_private_ui_automation"),
        )

    def evaluate(self) -> dict[str, Any]:
        controls_loaded = self.load_required_controls()
        self.run_check(
            "package-valid",
            [
                sys.executable,
                str(self.package / "scripts/validate_package.py"),
                "--root",
                str(self.package),
                "--report",
                str(self.package / "state/completion-package-validation.json"),
            ],
            "package validation",
        )
        self.run_check(
            "attribution-clean",
            [
                sys.executable,
                str(self.package / "scripts/scan_attribution.py"),
                "--root",
                str(self.repository),
            ],
            "repository scan",
        )
        self.run_check(
            "secret-scan-clean",
            [
                sys.executable,
                str(self.package / "scripts/scan_secrets.py"),
                "--root",
                str(self.repository),
            ],
            "repository scan",
        )
        if controls_loaded:
            self.validate_current_source_identity()
            self.validate_gates()
            self.validate_feature_baseline()
            self.validate_findings()
            self.validate_host()
            self.validate_source_identity_unchanged()
        required = self.gate_plan.get("completion_requires")
        prerequisite_gates = (
            required[:-1]
            if isinstance(required, list)
            and required
            and required[-1] == "G12"
            else []
        )
        binding_by_gate = {
            item.get("gate_id"): item
            for item in self.gate_result_bindings
            if isinstance(item, dict)
        }
        ordered_bindings = [
            binding_by_gate[gate_identifier]
            for gate_identifier in prerequisite_gates
            if gate_identifier in binding_by_gate
        ]
        state_sequence = self.state.get("last_event_sequence")
        return {
            "schema_version": 2,
            "evaluated_at": now(),
            "repository": str(self.repository),
            "passed": not self.errors,
            "checks": self.checks,
            "errors": self.errors,
            "run_id": self.state.get("run_id"),
            "commit": (
                self.state.get("repository", {}).get("commit")
                if isinstance(self.state.get("repository"), dict)
                else None
            ),
            "admission_contract": {
                "schema_version": 1,
                "run_id": self.state.get("run_id"),
                "repository": str(self.repository),
                "source_head": self.current_source_head,
                "source_manifest": self.current_source_manifest,
                "state_sequence_before_g12": state_sequence,
                "prerequisite_gates": prerequisite_gates,
                "gate_results": ordered_bindings,
            },
            "finalization_gate": {
                "gate_id": "G12",
                "status": "blocked_open" if self.errors else "eligible_for_finalization",
                "reason": (
                    "G12 and the run status remain nonpassing until the bounded "
                    "gate runner publishes a finalized matching operation and "
                    "the completion command confirms it."
                ),
            },
        }


def completion_markdown(completion: dict[str, Any]) -> bytes:
    lines = [
        "# Forge Conductor completion verification",
        "",
        f"- Evaluated: `{completion['evaluated_at']}`",
        f"- Passed: **{completion['passed']}**",
        "",
        "## Finalization gate",
        "",
        f"- G12 status: **{completion['finalization_gate']['status']}**",
        f"- {completion['finalization_gate']['reason']}",
        "",
        "## Checks",
        "",
    ]
    for item in completion["checks"]:
        mark = "x" if item["passed"] else " "
        lines.append(f"- [{mark}] `{item['name']}` — {item['detail']}")
    if completion["errors"]:
        lines.extend(["", "## Blocking errors", ""])
        lines.extend(f"- {error}" for error in completion["errors"])
    encoded = ("\n".join(lines) + "\n").encode("utf-8")
    if len(encoded) > MAXIMUM_COMPLETION_REPORT_BYTES:
        raise EvidenceSupportError(
            "completion Markdown report exceeds its 1048576-byte bound"
        )
    return encoded


def write_completion_reports(
    repository: pathlib.Path, completion: dict[str, Any]
) -> tuple[str, str]:
    markdown = completion_markdown(completion)
    with statectl.locked_state_directory(repository, create=False) as descriptor:
        statectl.atomic_json_at(
            descriptor,
            "completion-report.json",
            ".completion-report.json.tmp",
            completion,
            label="completion JSON report",
            maximum_bytes=MAXIMUM_COMPLETION_REPORT_BYTES,
        )
        statectl.atomic_bytes_at(
            descriptor,
            "completion-report.md",
            ".completion-report.md.tmp",
            markdown,
            label="completion Markdown report",
        )
    json_hash, _ = sha256_bounded_repository_file(
        repository,
        ".forge-codex/state/completion-report.json",
        label="completion JSON report",
        maximum_bytes=MAXIMUM_COMPLETION_REPORT_BYTES,
    )
    markdown_hash, _ = sha256_bounded_repository_file(
        repository,
        ".forge-codex/state/completion-report.md",
        label="completion Markdown report",
        maximum_bytes=MAXIMUM_COMPLETION_REPORT_BYTES,
    )
    return json_hash, markdown_hash


def write_g12_criteria(
    repository: pathlib.Path,
    gate_plan: dict[str, Any],
    completion: dict[str, Any],
    report_hashes: tuple[str, str],
    requested_output: str,
) -> None:
    gates = gate_plan.get("gates")
    definition = (
        next(
            (
                item
                for item in gates
                if isinstance(item, dict) and item.get("id") == "G12"
            ),
            None,
        )
        if isinstance(gates, list)
        else None
    )
    criteria = definition.get("criteria") if isinstance(definition, dict) else None
    if (
        not isinstance(criteria, list)
        or not criteria
        or not all(isinstance(item, str) and item for item in criteria)
    ):
        raise EvidenceSupportError("G12 criteria are malformed")
    json_hash, json_bytes = sha256_bounded_repository_file(
        repository,
        ".forge-codex/state/completion-report.json",
        label="G12 completion JSON report binding",
        maximum_bytes=MAXIMUM_COMPLETION_REPORT_BYTES,
    )
    markdown_hash, markdown_bytes = sha256_bounded_repository_file(
        repository,
        ".forge-codex/state/completion-report.md",
        label="G12 completion Markdown report binding",
        maximum_bytes=MAXIMUM_COMPLETION_REPORT_BYTES,
    )
    if (json_hash, markdown_hash) != report_hashes:
        raise EvidenceSupportError(
            "completion reports changed before G12 criteria publication"
        )
    report_bindings = [
        {
            "path": ".forge-codex/state/completion-report.json",
            "sha256": json_hash,
            "bytes": json_bytes,
        },
        {
            "path": ".forge-codex/state/completion-report.md",
            "sha256": markdown_hash,
            "bytes": markdown_bytes,
        },
    ]
    evidence = (
        ".forge-codex/state/completion-report.json sha256="
        f"{json_hash}; .forge-codex/state/completion-report.md sha256="
        f"{markdown_hash}"
    )
    payload = {
        "criteria_results": [
            {
                "criterion": criterion,
                "passed": completion["passed"] is True,
                "evidence": evidence,
            }
            for criterion in criteria
        ],
        "report_bindings": report_bindings,
        "valid": completion["passed"] is True,
        "errors": completion["errors"],
    }
    encoded = (
        json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + "\n"
    ).encode("utf-8")
    write_criteria_output(repository, "G12", encoded, requested_output)


def load_final_g12_pair(
    repository: pathlib.Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    source_evaluation = CompletionEvaluation(repository)
    source_evaluation.validate_current_source_identity()
    if source_evaluation.errors:
        raise EvidenceSupportError(
            "G12 final source identity is unavailable, dirty, or unstable: "
            + "; ".join(source_evaluation.errors)
        )
    budget = BoundedReadBudget(
        MAXIMUM_CONTROL_TOTAL_BYTES,
        "completion finalization control JSON",
    )
    state = load_bounded_repository_json_object(
        repository,
        ".forge-codex/state/run-state.json",
        label="final completion run state",
        maximum_bytes=MAXIMUM_CONTROL_FILE_BYTES,
        budget=budget,
        require_owner_controlled=True,
    )
    result = load_bounded_repository_json_object(
        repository,
        ".forge-codex/state/gate-results/G12.json",
        label="final G12 result",
        maximum_bytes=MAXIMUM_CONTROL_FILE_BYTES,
        budget=budget,
        require_owner_controlled=True,
    )
    gates = state.get("gates")
    item = gates.get("G12") if isinstance(gates, dict) else None
    operation_id = result.get("operation_id")
    sequence_before = result.get("state_sequence_before")
    current_sequence = state.get("last_event_sequence")
    if not (
        result.get("gate_id") == "G12"
        and result.get("status") == "passed"
        and result.get("finalized") is True
        and result.get("source_head") == source_evaluation.current_source_head
        and result.get("source_manifest")
        == source_evaluation.current_source_manifest
        and isinstance(sequence_before, int)
        and not isinstance(sequence_before, bool)
        and sequence_before >= 0
        and isinstance(current_sequence, int)
        and not isinstance(current_sequence, bool)
        and current_sequence == sequence_before + 1
        and isinstance(operation_id, str)
        and OPERATION_IDENTIFIER.fullmatch(operation_id) is not None
        and isinstance(item, dict)
        and item.get("status") == "passed"
        and item.get("operation_id") == operation_id
        and item.get("evaluator")
        == str(repository / ".forge-codex/state/gate-results/G12.json")
    ):
        raise EvidenceSupportError(
            "G12 result and run state do not form a finalized matching operation"
        )
    source_evaluation.validate_source_identity_unchanged()
    if source_evaluation.errors:
        raise EvidenceSupportError(
            "G12 final source identity changed during admission: "
            + "; ".join(source_evaluation.errors)
        )
    with statectl.locked_state_directory(repository, create=False) as state_descriptor:
        statectl.recover_transaction(state_descriptor)
        locked_state = statectl.require_state_at(
            state_descriptor,
            statectl.control_budget(),
        )
        statectl.require_g12_completion_contract(
            repository,
            state_descriptor,
            locked_state,
            operation_id,
        )
    return state, result


def finalize(repository: pathlib.Path) -> None:
    package = repository / ".forge-codex"
    try:
        code, stdout, stderr = run_bounded_readonly_command(
            repository,
            "G12 bounded finalization",
            [
                str(package / "scripts/run_gate.py"),
                "--repo",
                str(repository),
                "--",
                "G12",
            ],
            timeout_seconds=MAXIMUM_COMMAND_SECONDS,
            maximum_output_bytes=MAXIMUM_COMMAND_OUTPUT_BYTES,
        )
    except (BoundedCommandError, EvidenceSupportError) as error:
        raise EvidenceSupportError(f"G12 finalization failed closed: {error}") from error
    if code != 0:
        diagnostic = (stderr + stdout)[:MAXIMUM_DETAIL_CHARACTERS].decode(
            "utf-8", errors="replace"
        ).strip()
        raise EvidenceSupportError(
            f"G12 finalization exited {code}: {diagnostic or 'no diagnostic'}"
        )
    _, g12_result = load_final_g12_pair(repository)
    expected_g12_operation_id = g12_result["operation_id"]

    operation_id = str(uuid.uuid4())
    command = [
        str(package / "scripts/statectl.py"),
        "--repo",
        str(repository),
        "status",
        "complete",
        "--expected-g12-operation-id",
        expected_g12_operation_id,
        "--operation-id",
        operation_id,
    ]
    diagnostic = ""
    for _ in range(2):
        try:
            status_code, status_stdout, status_stderr = run_bounded_readonly_command(
                repository,
                "completion status transition",
                command,
                timeout_seconds=60.0,
                maximum_output_bytes=MAXIMUM_COMMAND_OUTPUT_BYTES,
            )
        except (BoundedCommandError, EvidenceSupportError) as error:
            diagnostic = str(error)
            continue
        if status_code == 0:
            try:
                readback_code, readback_stdout, readback_stderr = (
                    run_bounded_readonly_command(
                        repository,
                        "completion status readback",
                        [
                            str(package / "scripts/statectl.py"),
                            "--repo",
                            str(repository),
                            "show",
                        ],
                        timeout_seconds=60.0,
                        maximum_output_bytes=MAXIMUM_COMMAND_OUTPUT_BYTES,
                    )
                )
                readback = (
                    decode_strict_json_object(
                        readback_stdout,
                        label="completion status readback",
                    )
                    if readback_code == 0 and not readback_stderr
                    else None
                )
                authority = (
                    readback.get("completion_authority")
                    if isinstance(readback, dict)
                    else None
                )
                if (
                    isinstance(readback, dict)
                    and readback.get("status") == "complete"
                    and authority
                    == {
                        "schema_version": 1,
                        "g12_operation_id": expected_g12_operation_id,
                        "status_operation_id": operation_id,
                    }
                ):
                    return
                diagnostic = (
                    (readback_stderr + readback_stdout)
                    [:MAXIMUM_DETAIL_CHARACTERS]
                    .decode("utf-8", errors="replace")
                    .strip()
                    or "completion status readback did not match the exact operation"
                )
            except (BoundedCommandError, EvidenceSupportError) as error:
                diagnostic = f"completion status readback failed: {error}"
            continue
        diagnostic = (status_stderr + status_stdout)[:MAXIMUM_DETAIL_CHARACTERS].decode(
            "utf-8", errors="replace"
        ).strip() or f"exit {status_code}"
    raise EvidenceSupportError(
        f"completion status could not be committed idempotently: {diagnostic}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo")
    parser.add_argument("--no-finalize", action="store_true")
    parser.add_argument("--criteria-output")
    return parser


def main(arguments: list[str] | None = None) -> int:
    args = build_parser().parse_args(arguments)
    if args.criteria_output and not args.no_finalize:
        raise SystemExit("--criteria-output requires --no-finalize")
    repository = locate_repo(args.repo)
    evaluation = CompletionEvaluation(repository)
    try:
        completion = evaluation.evaluate()
        report_hashes = write_completion_reports(repository, completion)
        if args.criteria_output:
            write_g12_criteria(
                repository,
                evaluation.gate_plan,
                completion,
                report_hashes,
                args.criteria_output,
            )
        if completion["errors"]:
            print(
                json.dumps(
                    {
                        "passed": False,
                        "errors": completion["errors"],
                        "report": str(
                            repository / ".forge-codex/state/completion-report.json"
                        ),
                    },
                    indent=2,
                )
            )
            return 1
        if not args.no_finalize:
            finalize(repository)
        print(
            json.dumps(
                {
                    "passed": True,
                    "finalized": not args.no_finalize,
                    "errors": [],
                    "report": str(
                        repository / ".forge-codex/state/completion-report.json"
                    ),
                },
                indent=2,
            )
        )
        return 0
    except EvidenceSupportError as error:
        print(f"completion verification failed closed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
