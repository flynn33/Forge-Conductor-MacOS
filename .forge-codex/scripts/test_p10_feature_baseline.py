#!/usr/bin/env python3
"""Adversarial tests for P10 inventory identity and evidence sealing."""

from __future__ import annotations

import copy
import base64
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock

from evidence_support import EvidenceSupportError, source_manifest
from p10_feature_baseline import (
    EXACT_CURRENT_PRODUCTION_TIER,
    EXPECTED_FEATURE_QUALIFIER_SHA256,
    EXPECTED_PARITY_COUNTS,
    EXPECTED_PRODUCTION_PROBE_REGISTRY_SHA256,
    EXPECTED_SIGNING_ARTIFACTS,
    EXPECTED_TOOL_PACK_MEMBERS,
    FEATURE_BASELINE_PATH,
    FEATURE_QUALIFICATION_REPORT_SOURCE_PATH,
    FEATURE_QUALIFIER_PATH,
    FEATURE_REGISTRY_PATH,
    HISTORICAL_STATIC_INVENTORY_PATH,
    PRODUCTION_PROBE_REGISTRY_PATH,
    SUPPORTED_OPERABILITY_TIERS,
    canonical_json_sha256,
    validate_feature_baseline,
)
from p10_feature_evidence import (
    _cached_signing_revalidation,
    _decode_observation_aggregate,
    _validate_probe_registry,
    evaluate_p10_feature_evidence,
)
from qualify_p10_features import (
    bounded_remaining_seconds,
    capture_installed_cli_transcript,
    canonical_bytes,
    derive_provider_fact,
    derive_signing_fact,
    evaluate_probe_artifact,
    evaluate_probe_output,
    evaluate_runner_artifact,
    installed_cli_contract_valid,
    runner_argv,
    runner_identity,
    validate_installed_cli_transcript,
    validate_provider_fact,
)


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
PACKAGE_ROOT = SCRIPT_ROOT.parent
REPOSITORY_ROOT = PACKAGE_ROOT.parent
EVIDENCE_ID = "EVID-feature-production-fixture"
HEAD = "a" * 40


def encoded(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def binding(path: str, raw: bytes) -> dict[str, object]:
    return {"path": path, "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}


def compile_native_cli_fixture(destination: pathlib.Path) -> None:
    source = destination.with_suffix(".c")
    source.write_text(
        "#include <string.h>\n"
        "#include <unistd.h>\n"
        "int main(int argc, char **argv) {\n"
        "  if (argc < 2) return 0;\n"
        "  if (strcmp(argv[1], \"trusted-output\") == 0) {\n"
        "    const char output[] = \"trusted-output\\n\";\n"
        "    return write(STDOUT_FILENO, output, sizeof(output) - 1) < 0;\n"
        "  }\n"
        "  if (strcmp(argv[1], \"timeout\") == 0) { sleep(2); return 0; }\n"
        "  if (strcmp(argv[1], \"stay-alive\") == 0) { sleep(5); return 0; }\n"
        "  if (strcmp(argv[1], \"flood\") == 0) {\n"
        "    char output[4096]; memset(output, 'x', sizeof(output));\n"
        "    while (write(STDOUT_FILENO, output, sizeof(output)) > 0) {}\n"
        "    return 1;\n"
        "  }\n"
        "  return 64;\n"
        "}\n",
        encoding="utf-8",
    )
    subprocess.run(
        ["/usr/bin/clang", "-O0", str(source), "-o", str(destination)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    destination.chmod(0o755)


class P10FeatureBaselineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.registry_raw = (REPOSITORY_ROOT / FEATURE_REGISTRY_PATH).read_bytes()
        cls.registry = json.loads(cls.registry_raw)
        cls.registry_binding = binding(FEATURE_REGISTRY_PATH, cls.registry_raw)
        cls.historical_raw = (REPOSITORY_ROOT / HISTORICAL_STATIC_INVENTORY_PATH).read_bytes()
        cls.historical = json.loads(cls.historical_raw)
        cls.historical_binding = {
            **binding(HISTORICAL_STATIC_INVENTORY_PATH, cls.historical_raw),
            "schema_version": 1,
            "feature_count": 98,
            "parity_summary": {
                "preserved": 0,
                "additive": 0,
                "migrated": 0,
                "unknown": 98,
                "removed": 0,
                "untested": 98,
            },
            "authority": "historical_discovery_only",
        }

    def source_snapshot(self) -> dict[str, object]:
        return {"schema_version": 1, "sha256": "b" * 64, "file_count": 1, "bytes": 1}

    def baseline(
        self,
        *,
        source_snapshot: dict[str, object] | None = None,
        registry_binding: dict[str, object] | None = None,
        historical_binding: dict[str, object] | None = None,
    ) -> dict[str, object]:
        features = [
            {
                "id": item["id"],
                "name": item["name"],
                "category": item["category"],
                "baseline_status": "present",
                "parity_status": item["parity_status"],
                "operability_tier": "production_component",
                "operability_gap": "Exact-current production qualification remains open.",
                "evidence": [f"Sources/{item['id']}.swift"],
                "tests": [f"{item['id']}.productionTest"],
            }
            for item in self.registry["features"]
        ]
        snapshot = source_snapshot or self.source_snapshot()
        return {
            "schema_version": 2,
            "generated_at": "2026-09-01T00:00:00+00:00",
            "repository_root": ".",
            "authoritative_registry": copy.deepcopy(registry_binding or self.registry_binding),
            "source_snapshot": {
                "schema_version": 1,
                "scope": "current_controlled_source_excluding_feature_baseline",
                "excluded_paths": [FEATURE_BASELINE_PATH],
                "manifest": snapshot,
            },
            "historical_static_inventory": copy.deepcopy(historical_binding or self.historical_binding),
            "runtime_evidence": [".forge-codex/evidence/EVID-supporting.json"],
            "operability_evidence_tiers": {
                tier: f"Definition for {tier}." for tier in sorted(SUPPORTED_OPERABILITY_TIERS)
            },
            "operability_summary": {
                "interpretation": "Inventory is not production qualification.",
                "feature_count": 104,
                "tier_counts": {
                    EXACT_CURRENT_PRODUCTION_TIER: 0,
                    "signed_supporting": 0,
                    "production_component": 104,
                    "fixture_or_source_only": 0,
                    "broken_or_absent": 0,
                },
                "exact_current_production_qualified": 0,
                "release_ready": False,
                "open_release_blockers": ["Production evidence remains open."],
                "qualification_rule": "Every feature requires exact typed production evidence.",
            },
            "features": features,
            "required_runtime_surfaces": [
                {
                    "surface": "all registered features",
                    "requirement": "Every canonical feature needs exact production evidence.",
                }
            ],
            "runtime_completion_required": False,
            "parity_summary": dict(EXPECTED_PARITY_COUNTS),
            "known_environment_limits": [
                {
                    "surface": "native qualification",
                    "status": "deferred_release_blocking",
                    "evidence": "Tests/Qualification.swift",
                    "detail": "The final native qualification remains open.",
                }
            ],
        }

    def fully_qualified_baseline(self, **kwargs: object) -> dict[str, object]:
        baseline = self.baseline(**kwargs)
        features = copy.deepcopy(baseline["features"])
        for feature in features:
            feature["operability_tier"] = EXACT_CURRENT_PRODUCTION_TIER
            feature["operability_gap"] = "Exact typed production evidence is recorded."
            feature["evidence"] = [EVIDENCE_ID]
        baseline["features"] = features
        baseline["operability_summary"]["tier_counts"] = {
            EXACT_CURRENT_PRODUCTION_TIER: 104,
            "signed_supporting": 0,
            "production_component": 0,
            "fixture_or_source_only": 0,
            "broken_or_absent": 0,
        }
        baseline["operability_summary"]["exact_current_production_qualified"] = 104
        baseline["operability_summary"]["release_ready"] = True
        return baseline

    def evaluate_baseline(
        self,
        baseline: dict[str, object],
        *,
        registry: dict[str, object] | None = None,
        registry_binding: dict[str, object] | None = None,
    ):
        return validate_feature_baseline(
            baseline,
            registry=registry or self.registry,
            registry_artifact=registry_binding or self.registry_binding,
            current_source_snapshot=self.source_snapshot(),
            historical_inventory_artifact=self.historical_binding,
        )

    def assert_inventory_failure(self, baseline: dict[str, object], fragment: str) -> None:
        evaluation = self.evaluate_baseline(baseline)
        self.assertTrue(any(fragment in item for item in evaluation.inventory_failures), evaluation.inventory_failures)

    def test_authoritative_inventory_is_valid_but_all_104_remain_completion_blocked(self) -> None:
        evaluation = self.evaluate_baseline(self.baseline())
        self.assertEqual(evaluation.inventory_failures, [])
        self.assertEqual(evaluation.feature_count, 104)
        self.assertEqual(
            evaluation.completion_blockers,
            ["baseline has 104 features without exact-current production qualification: production_component=104"],
        )

    def test_structurally_qualified_inventory_requires_all_104_exact_records(self) -> None:
        evaluation = self.evaluate_baseline(self.fully_qualified_baseline())
        self.assertEqual(evaluation.inventory_failures, [])
        self.assertEqual(evaluation.completion_blockers, [])

    def test_registry_rejects_rename_drop_add_parity_and_category_swaps(self) -> None:
        mutations = {}
        renamed = copy.deepcopy(self.registry)
        renamed["features"][0]["id"] = "BUILD-SYNTHETIC-RENAME"
        mutations["rename"] = renamed
        dropped = copy.deepcopy(self.registry)
        dropped["features"].pop()
        dropped["feature_count"] = 103
        dropped["parity_summary"]["additive"] = 37
        mutations["drop"] = dropped
        added = copy.deepcopy(self.registry)
        synthetic = copy.deepcopy(added["features"][-1])
        synthetic["id"] = "RUNTIME-SYNTHETIC-ADDITION"
        synthetic["required_assertions"] = [
            "RUNTIME-SYNTHETIC-ADDITION.production-path",
            "RUNTIME-SYNTHETIC-ADDITION.signed-product.forge-conductor-cli",
        ]
        added["features"].append(synthetic)
        added["feature_count"] = 105
        added["parity_summary"]["additive"] = 39
        mutations["add"] = added
        parity = copy.deepcopy(self.registry)
        parity["features"][0]["parity_status"] = "additive"
        mutations["parity"] = parity
        category = copy.deepcopy(self.registry)
        category["features"][0]["category"] = "ui"
        mutations["category"] = category
        for name, registry in mutations.items():
            with self.subTest(name=name):
                raw = encoded(registry)
                evaluation = validate_feature_baseline(
                    self.baseline(registry_binding=binding(FEATURE_REGISTRY_PATH, raw)),
                    registry=registry,
                    registry_artifact=binding(FEATURE_REGISTRY_PATH, raw),
                    current_source_snapshot=self.source_snapshot(),
                    historical_inventory_artifact=self.historical_binding,
                )
                self.assertTrue(evaluation.inventory_failures, name)

    def test_registry_rejects_signing_provider_and_tool_member_applicability_downgrades(self) -> None:
        mutations: dict[str, dict[str, object]] = {}
        lowered_signing = copy.deepcopy(self.registry)
        signed_feature = next(item for item in lowered_signing["features"] if item["id"] == "BUILD-CLI-EXECUTABLE")
        signed_feature["signing_required"] = False
        signed_feature["signing_artifact"] = None
        signed_feature["required_assertions"].remove(
            "BUILD-CLI-EXECUTABLE.signed-product.forge-conductor-cli"
        )
        mutations["lower-signed-runtime"] = lowered_signing
        invented_signing = copy.deepcopy(self.registry)
        conceptual = next(item for item in invented_signing["features"] if item["id"] == "BUILD-XCODE-WORKSPACE")
        conceptual["signing_required"] = True
        conceptual["signing_artifact"] = "forge-conductor-app"
        conceptual["required_assertions"].append(
            "BUILD-XCODE-WORKSPACE.signed-product.forge-conductor-app"
        )
        mutations["invent-conceptual-signing"] = invented_signing
        lowered_provider = copy.deepcopy(self.registry)
        provider = next(item for item in lowered_provider["features"] if item["id"] == "HTTP-PROVIDER-PROBE")
        provider["provider_required"] = False
        provider["required_assertions"].remove("HTTP-PROVIDER-PROBE.real-provider")
        mutations["lower-real-provider"] = lowered_provider
        missing_member = copy.deepcopy(self.registry)
        missing_member["tool_pack_members"]["MCP-TOOL-FILESYSTEM"].remove("fs_move")
        filesystem = next(item for item in missing_member["features"] if item["id"] == "MCP-TOOL-FILESYSTEM")
        filesystem["required_assertions"].remove("MCP-TOOL-FILESYSTEM.member.fs_move.production-path")
        mutations["drop-fs-move"] = missing_member
        pack_spoof = copy.deepcopy(self.registry)
        filesystem = next(item for item in pack_spoof["features"] if item["id"] == "MCP-TOOL-FILESYSTEM")
        filesystem["required_assertions"] = [
            "MCP-TOOL-FILESYSTEM.production-path",
            "MCP-TOOL-FILESYSTEM.signed-product.forge-conductor-cli",
        ]
        mutations["pack-level-spoof"] = pack_spoof
        wrong_feature_artifact = copy.deepcopy(self.registry)
        cli_feature = next(
            item for item in wrong_feature_artifact["features"]
            if item["id"] == "BUILD-CLI-EXECUTABLE"
        )
        cli_feature["signing_artifact"] = "forge-conductor-app"
        cli_feature["required_assertions"][-1] = (
            "BUILD-CLI-EXECUTABLE.signed-product.forge-conductor-app"
        )
        mutations["wrong-feature-signing-artifact"] = wrong_feature_artifact
        missing_signing_artifact = copy.deepcopy(self.registry)
        missing_signing_artifact["signing_artifacts"].pop("forge-filesystem-daemon")
        mutations["drop-shipped-signing-artifact"] = missing_signing_artifact
        extra_runtime_tool = copy.deepcopy(self.registry)
        extra_runtime_tool["runtime_surface_inventory"]["mcp_tools"].append("undeclared_tool")
        mutations["extra-runtime-tool"] = extra_runtime_tool
        missing_historical_mapping = copy.deepcopy(self.registry)
        missing_historical_mapping["historical_feature_mapping"].pop(next(iter(missing_historical_mapping["historical_feature_mapping"])))
        mutations["missing-historical-mapping"] = missing_historical_mapping
        invalid_historical_target = copy.deepcopy(self.registry)
        first_historical = next(iter(invalid_historical_target["historical_feature_mapping"]))
        invalid_historical_target["historical_feature_mapping"][first_historical] = "FEATURE-NOT-REGISTERED"
        mutations["invalid-historical-target"] = invalid_historical_target
        for label, registry in mutations.items():
            with self.subTest(label=label):
                raw = encoded(registry)
                evaluation = validate_feature_baseline(
                    self.baseline(registry_binding=binding(FEATURE_REGISTRY_PATH, raw)),
                    registry=registry,
                    registry_artifact=binding(FEATURE_REGISTRY_PATH, raw),
                    current_source_snapshot=self.source_snapshot(),
                    historical_inventory_artifact=self.historical_binding,
                )
                self.assertTrue(evaluation.inventory_failures, label)

    def test_baseline_rejects_rename_drop_add_parity_category_and_name_swaps(self) -> None:
        cases: dict[str, dict[str, object]] = {}
        renamed = self.baseline()
        renamed["features"] = copy.deepcopy(renamed["features"])
        renamed["features"][0]["id"] = "BUILD-SYNTHETIC-RENAME"
        cases["rename"] = renamed
        dropped = self.baseline()
        dropped["features"] = copy.deepcopy(dropped["features"][:-1])
        cases["drop"] = dropped
        added = self.baseline()
        added["features"] = copy.deepcopy(added["features"])
        added["features"].append(copy.deepcopy(added["features"][-1]))
        cases["add"] = added
        parity = self.baseline()
        parity["features"] = copy.deepcopy(parity["features"])
        parity["features"][0]["parity_status"] = "additive"
        cases["parity"] = parity
        category = self.baseline()
        category["features"] = copy.deepcopy(category["features"])
        category["features"][0]["category"] = "ui"
        cases["category"] = category
        name = self.baseline()
        name["features"] = copy.deepcopy(name["features"])
        name["features"][0]["name"] = "Substitute feature"
        cases["name"] = name
        for label, baseline in cases.items():
            with self.subTest(label=label):
                self.assertTrue(self.evaluate_baseline(baseline).inventory_failures)

    def test_count_counter_duplicate_missing_field_broken_and_stale_tier_fail_closed(self) -> None:
        cases: list[tuple[str, dict[str, object], str]] = []
        count = self.baseline()
        count["operability_summary"]["feature_count"] = 105
        cases.append(("count", count, "feature count"))
        counter = self.baseline()
        counter["parity_summary"]["preserved"] = 65
        counter["parity_summary"]["additive"] = 39
        cases.append(("counter", counter, "parity"))
        duplicate = self.baseline()
        duplicate["features"] = copy.deepcopy(duplicate["features"])
        duplicate["features"][1]["id"] = duplicate["features"][0]["id"]
        cases.append(("duplicate", duplicate, "duplicate"))
        for field in ("evidence", "tests", "operability_tier", "operability_gap"):
            missing = self.baseline()
            missing["features"] = copy.deepcopy(missing["features"])
            missing["features"][0].pop(field)
            cases.append((f"missing-{field}", missing, field.replace("operability_", "")))
        broken = self.baseline()
        broken["features"] = copy.deepcopy(broken["features"])
        broken["features"][0]["baseline_status"] = "present_broken"
        broken["features"][0]["operability_tier"] = "broken_or_absent"
        broken["operability_summary"]["tier_counts"]["production_component"] = 103
        broken["operability_summary"]["tier_counts"]["broken_or_absent"] = 1
        self.assertTrue(any("broken or absent" in item for item in self.evaluate_baseline(broken).completion_blockers))
        stale = self.baseline()
        stale["features"] = copy.deepcopy(stale["features"])
        stale["features"][0]["operability_tier"] = "legacy_unit_only"
        cases.append(("stale-tier", stale, "unsupported operability tier"))
        for label, baseline, fragment in cases:
            with self.subTest(label=label):
                self.assertTrue(any(fragment in item for item in self.evaluate_baseline(baseline).inventory_failures))

    def test_unknown_untested_removed_and_summary_spoofs_fail_closed(self) -> None:
        for status in ("unknown", "untested", "removed"):
            with self.subTest(status=status):
                baseline = self.baseline()
                baseline["features"] = copy.deepcopy(baseline["features"])
                baseline["features"][0]["parity_status"] = status
                self.assertTrue(self.evaluate_baseline(baseline).inventory_failures)
        baseline = self.baseline()
        baseline["operability_summary"]["exact_current_production_qualified"] = 104
        baseline["operability_summary"]["release_ready"] = True
        self.assertTrue(self.evaluate_baseline(baseline).inventory_failures)

    def test_runtime_flag_flip_cannot_bypass_lower_tiers(self) -> None:
        baseline = self.baseline()
        baseline["runtime_completion_required"] = True
        baseline["runtime_completion_required"] = False
        evaluation = self.evaluate_baseline(baseline)
        self.assertTrue(any("104 features" in item for item in evaluation.completion_blockers))

    def test_metadata_source_snapshot_artifact_hash_and_types_fail_closed(self) -> None:
        mutations: list[tuple[str, object]] = [
            ("generated_at", 1),
            ("repository_root", str(REPOSITORY_ROOT)),
            ("schema_version", True),
            ("runtime_completion_required", 0),
        ]
        for field, value in mutations:
            with self.subTest(field=field):
                baseline = self.baseline()
                baseline[field] = value
                self.assertTrue(self.evaluate_baseline(baseline).inventory_failures)
        baseline = self.baseline()
        baseline["source_snapshot"]["manifest"]["sha256"] = "c" * 64
        self.assert_inventory_failure(baseline, "source snapshot")
        baseline = self.baseline()
        baseline["authoritative_registry"]["sha256"] = "d" * 64
        self.assert_inventory_failure(baseline, "registry")
        baseline = self.baseline()
        baseline["historical_static_inventory"]["sha256"] = "e" * 64
        self.assert_inventory_failure(baseline, "historical static inventory")


class P10FeatureEvidenceTests(P10FeatureBaselineTests):
    def create_qualified_repository(self, directory: pathlib.Path) -> tuple[pathlib.Path, dict[str, object]]:
        root = directory.resolve()
        for relative in (
            FEATURE_REGISTRY_PATH,
            PRODUCTION_PROBE_REGISTRY_PATH,
            ".forge-codex/schemas/p10-feature-production-qualification.schema.json",
            HISTORICAL_STATIC_INVENTORY_PATH,
            ".forge-codex/scripts/qualify_p10_features.py",
        ):
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY_ROOT / relative, destination)
        qualifier = root / ".forge-codex/scripts/qualify_p10_features.py"
        qualifier.chmod(0o755)
        feature_source = source_manifest(root, excluded_paths=(FEATURE_BASELINE_PATH,))
        registry_binding = binding(FEATURE_REGISTRY_PATH, (root / FEATURE_REGISTRY_PATH).read_bytes())
        historical_binding = {
            **binding(HISTORICAL_STATIC_INVENTORY_PATH, (root / HISTORICAL_STATIC_INVENTORY_PATH).read_bytes()),
            "schema_version": 1,
            "feature_count": 98,
            "parity_summary": self.historical_binding["parity_summary"],
            "authority": "historical_discovery_only",
        }
        baseline = self.fully_qualified_baseline(
            source_snapshot=feature_source,
            registry_binding=registry_binding,
            historical_binding=historical_binding,
        )
        baseline_path = root / FEATURE_BASELINE_PATH
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        baseline_path.write_bytes(encoded(baseline))
        current_manifest = source_manifest(root)
        evidence_directory = root / ".forge-codex/evidence"
        evidence_directory.mkdir(parents=True, exist_ok=True)
        proof_path = f".forge-codex/evidence/{EVIDENCE_ID}.artifact-000-proof.json"
        proof_raw = encoded({"executed": True, "result": "production-path"})
        (root / proof_path).write_bytes(proof_raw)
        proof_hash = hashlib.sha256(proof_raw).hexdigest()
        rows = []
        for authority in self.registry["features"]:
            assertions = [
                {
                    "id": assertion_id,
                    "passed": True,
                    "result": "passed",
                    "expected": proof_hash,
                    "actual": proof_hash,
                    "artifact_references": [proof_path],
                }
                for assertion_id in authority["required_assertions"]
            ]
            provider = (
                {
                    "applicable": True,
                    "kind": "lm_studio",
                    "transport": "http",
                    "endpoint": "http://127.0.0.1:1234",
                    "model": "qwen/test",
                    "real_provider": True,
                }
                if authority["provider_required"]
                else {
                    "applicable": False,
                    "kind": "not_applicable",
                    "transport": None,
                    "endpoint": None,
                    "model": None,
                    "real_provider": False,
                }
            )
            rows.append(
                {
                    "feature_id": authority["id"],
                    "status": "passed",
                    "execution_count": 1,
                    "assertion_count": len(assertions),
                    "assertions": assertions,
                    "signing": {
                        "applicable": True,
                        "artifact_id": authority["signing_artifact"],
                        "team_id": "9AQ2C2838M",
                        "identifier": "com.cyberworlds.forge-conductor",
                        "cdhash": "1" * 40,
                        "designated_requirement_sha256": "2" * 64,
                        "hardened_runtime": False,
                    },
                    "provider": provider,
                }
            )
        assertion_count = sum(item["assertion_count"] for item in rows)
        started = "2026-09-01T00:00:00+00:00"
        ended = "2026-09-01T00:01:00+00:00"
        command_argv = [
            str(root / ".forge-codex/scripts/qualify_p10_features.py"),
            "--report",
            FEATURE_QUALIFICATION_REPORT_SOURCE_PATH,
        ]
        report = {
            "schema_version": 1,
            "qualifier": {"name": "forge-p10-production-matrix", "version": 1},
            "command": {
                "argv": command_argv,
                "exit_code": 0,
                "timed_out": False,
                "stream_limit_exceeded": False,
            },
            "execution": {
                "count": 1,
                "assertion_count": assertion_count,
                "passed_assertion_count": assertion_count,
                "failed_assertion_count": 0,
            },
            "environment": {
                "repository": str(root),
                "platform": "macOS-fixture",
                "architecture": "arm64",
                "macos_build": "25A1",
                "machine_identifier": "MacFixture1,1",
                "configuration": "Debug",
                "installed_product": True,
            },
            "timing": {"started_at": started, "ended_at": ended},
            "source_identity": {
                "git_head": HEAD,
                "source_manifest": current_manifest,
                "registry_sha256": registry_binding["sha256"],
                "baseline_sha256": hashlib.sha256((root / FEATURE_BASELINE_PATH).read_bytes()).hexdigest(),
            },
            "results": rows,
        }
        report_raw = encoded(report)
        report_path = f".forge-codex/evidence/{EVIDENCE_ID}.artifact-001-P10-feature-production-qualification-report.json"
        (root / report_path).write_bytes(report_raw)
        stdout_path = f".forge-codex/evidence/{EVIDENCE_ID}.stdout.txt"
        stderr_path = f".forge-codex/evidence/{EVIDENCE_ID}.stderr.txt"
        (root / stdout_path).write_bytes(b"qualified\n")
        (root / stderr_path).write_bytes(b"")
        provenance = {
            "repository": {
                "branch": "fixture",
                "head_sha": HEAD,
                "base_branch": "main",
                "base_sha": HEAD,
                "repository_path": str(root),
            },
            "test_environment": {
                "macos_build": "25A1",
                "machine_identifier": "MacFixture1,1",
                "platform": "macOS-fixture",
                "architecture": "arm64",
            },
        }
        artifacts = [
            {
                **binding(proof_path, proof_raw),
                "source_path": "Tests/P10FeatureProof.json",
                "storage": "evidence-id-specific-copy",
            },
            {
                **binding(report_path, report_raw),
                "source_path": FEATURE_QUALIFICATION_REPORT_SOURCE_PATH,
                "storage": "evidence-id-specific-copy",
            },
            {**binding(stdout_path, b"qualified\n"), "storage": "evidence-id-specific-stream"},
            {**binding(stderr_path, b""), "storage": "evidence-id-specific-stream"},
        ]
        record = {
            "schema_version": 2,
            "id": EVIDENCE_ID,
            "kind": "p10-feature-production-qualification",
            "command": " ".join(command_argv),
            "exit_code": 0,
            "timed_out": False,
            "stream_limit_exceeded": False,
            "maximum_stream_bytes": 67108864,
            "started_at": started,
            "ended_at": ended,
            "environment": {
                "platform": "macOS-fixture",
                "architecture": "arm64",
                "macos_build": "25A1",
                "machine_identifier": "MacFixture1,1",
                "cwd": str(root),
            },
            "execution_provenance": provenance,
            "child_evidence_context": {
                "schema_version": 1,
                "binding_schema_version": 1,
                "evidence_id": EVIDENCE_ID,
                "source_manifest": current_manifest,
                "repository": provenance["repository"],
                "test_environment": provenance["test_environment"],
            },
            "source_manifest": current_manifest,
            "source_manifest_after": current_manifest,
            "source_manifest_changed": False,
            "artifacts": artifacts,
            "artifact_capture_errors": [],
            "ledger_reference": {"status": "recorded", "exit_code": 0},
            "related_findings": [],
            "related_gates": ["G10"],
        }
        (root / f".forge-codex/evidence/{EVIDENCE_ID}.json").write_bytes(encoded(record))
        return root, current_manifest

    def evaluate_repository(
        self,
        root: pathlib.Path,
        current_manifest: dict[str, object],
        *,
        ledger: set[str] | None = None,
        expected_binding: object | None = None,
    ):
        return evaluate_p10_feature_evidence(
            root,
            current_manifest=current_manifest,
            current_git_head=HEAD,
            ledger_evidence_ids={EVIDENCE_ID} if ledger is None else ledger,
            expected_binding=expected_binding,
        )

    def rewrite_report(self, root: pathlib.Path, mutation) -> None:
        record_path = root / f".forge-codex/evidence/{EVIDENCE_ID}.json"
        record = json.loads(record_path.read_text())
        report_artifact = next(item for item in record["artifacts"] if item.get("source_path") == FEATURE_QUALIFICATION_REPORT_SOURCE_PATH)
        report_path = root / report_artifact["path"]
        report = json.loads(report_path.read_text())
        mutation(report)
        raw = encoded(report)
        report_path.write_bytes(raw)
        report_artifact["sha256"] = hashlib.sha256(raw).hexdigest()
        report_artifact["bytes"] = len(raw)
        record_path.write_bytes(encoded(record))

    def test_unimplemented_canonical_probe_matrix_blocks_fabricated_rows_but_binding_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, manifest = self.create_qualified_repository(pathlib.Path(temporary))
            first = self.evaluate_repository(root, manifest)
            second = self.evaluate_repository(root, manifest)
            self.assertTrue(any("no concrete runner for 257" in item for item in first.failures), first.failures)
            self.assertEqual(first.binding, second.binding)
            self.assertEqual(len(first.binding["feature_records"]), 104)
            self.assertEqual(len(first.binding["evidence_records"]), 1)
            self.assertEqual(first.binding["ledger"]["qualified_evidence_ids"], [EVIDENCE_ID])
            payload = dict(first.binding)
            digest = payload.pop("binding_sha256")
            self.assertEqual(digest, canonical_json_sha256(payload))

    def test_arbitrary_command_boolean_spoof_missing_row_and_stale_source_fail_closed(self) -> None:
        mutations = {
            "boolean-count": lambda report: report["execution"].__setitem__("count", True),
            "missing-row": lambda report: report["results"].pop(),
            "stale-source": lambda report: report["source_identity"].__setitem__("git_head", "b" * 40),
            "missing-signing": lambda report: report["results"][0].__setitem__("signing", {"applicable": False}),
            "provider-spoof": lambda report: next(
                row for row in report["results"]
                if next(item for item in self.registry["features"] if item["id"] == row["feature_id"])["provider_required"]
            ).__setitem__("provider", {"applicable": False}),
        }
        for label, mutation in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root, manifest = self.create_qualified_repository(pathlib.Path(temporary))
                self.rewrite_report(root, mutation)
                self.assertTrue(self.evaluate_repository(root, manifest).failures)
        with tempfile.TemporaryDirectory() as temporary:
            root, manifest = self.create_qualified_repository(pathlib.Path(temporary))
            record_path = root / f".forge-codex/evidence/{EVIDENCE_ID}.json"
            record = json.loads(record_path.read_text())
            record["command"] = "true"
            record_path.write_bytes(encoded(record))
            self.assertTrue(any("exact known qualifier" in item for item in self.evaluate_repository(root, manifest).failures))

    def test_post_check_record_artifact_deletion_mutation_and_ledger_removal_fail_closed(self) -> None:
        cases = ("record-mutation", "record-deletion", "artifact-mutation", "artifact-deletion", "ledger-removal")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root, manifest = self.create_qualified_repository(pathlib.Path(temporary))
                initial = self.evaluate_repository(root, manifest)
                self.assertTrue(initial.failures)
                record_path = root / f".forge-codex/evidence/{EVIDENCE_ID}.json"
                record = json.loads(record_path.read_text())
                proof_path = root / record["artifacts"][0]["path"]
                ledger = {EVIDENCE_ID}
                if case == "record-mutation":
                    record["maximum_stream_bytes"] += 1
                    record_path.write_bytes(encoded(record))
                elif case == "record-deletion":
                    record_path.unlink()
                elif case == "artifact-mutation":
                    proof_path.write_bytes(b"changed")
                elif case == "artifact-deletion":
                    proof_path.unlink()
                else:
                    ledger = set()
                evaluation = self.evaluate_repository(
                    root,
                    manifest,
                    ledger=ledger,
                    expected_binding=initial.binding,
                )
                self.assertTrue(evaluation.failures, case)
                if case != "ledger-removal":
                    self.assertTrue(
                        any("binding changed after gate evaluation" in item for item in evaluation.failures),
                        evaluation.failures,
                    )

    def test_zero_test_filter_and_exit_zero_without_observations_fail_closed(self) -> None:
        xctest_probe = {"runner": {"kind": "swift_test"}}
        passed, executed, assertions, _ = evaluate_probe_output(
            xctest_probe,
            b"Executed 0 tests, with 0 failures in 0.001 seconds\n",
            b"",
            exit_code=0,
            timed_out=False,
            stream_limit_exceeded=False,
        )
        self.assertFalse(passed)
        self.assertEqual((executed, assertions), (0, 0))
        repository_probe = {
            "scenario_id": "SCENARIO-ZERO",
            "assertions": [{
                "feature_id": "BUILD-001",
                "assertion_id": "BUILD-001.production-path",
                "selector": "build-zero",
            }],
            "runner": {"kind": "repository_qualification"},
        }
        passed, executed, assertions, _ = evaluate_probe_output(
            repository_probe,
            b'{"schema_version":1,"scenario_id":"SCENARIO-ZERO","passed":true,"executions":0,"results":[{"selector":"build-zero","passed":true,"observed_assertions":0}]}',
            b"",
            exit_code=0,
            timed_out=False,
            stream_limit_exceeded=False,
        )
        self.assertFalse(passed)
        self.assertEqual((executed, assertions), (0, 0))
        with self.assertRaisesRegex(EvidenceSupportError, "total deadline"):
            bounded_remaining_seconds(100.0, 90, now_value=100.0)
        self.assertEqual(bounded_remaining_seconds(110.0, 90, now_value=100.0), 10)

    def test_stdout_self_attestation_and_xctest_summary_injection_never_qualify(self) -> None:
        probe = {
            "scenario_id": "SCENARIO-STDOUT",
            "assertions": [{
                "feature_id": "FEATURE-A",
                "assertion_id": "FEATURE-A.production-path",
                "selector": "feature-a",
                "evidence_kind": "installed-process-transcript",
                "expected": {"ok": True},
            }],
            "runner": {"kind": "repository_qualification"},
        }
        fabricated = encoded({
            "schema_version": 1,
            "scenario_id": "SCENARIO-STDOUT",
            "passed": True,
            "executions": 1,
            "results": [{"selector": "feature-a", "passed": True, "observed_assertions": 1}],
        })
        for stdout in (
            fabricated,
            b"Executed 1 test, with 0 failures in 0.001 seconds\n",
            b"Executed 0 tests, with 0 failures\nExecuted 1 test, with 0 failures\n",
        ):
            passed, executed, observed, document = evaluate_probe_output(
                probe,
                stdout,
                b"",
                exit_code=0,
                timed_out=False,
                stream_limit_exceeded=False,
            )
            self.assertFalse(passed)
            self.assertEqual((executed, observed, document), (0, 0, None))

    def test_only_qualifier_captured_installed_cli_transcripts_can_qualify(self) -> None:
        evidence_id = "EVID-cli-fixture"
        nonce = "1" * 64
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            executable = root / "forge-conductor"
            compile_native_cli_fixture(executable)
            executable_raw = executable.read_bytes()
            installation = {
                "artifacts": [{
                    "artifact_id": "forge-conductor-cli",
                    "kind": "helper",
                    "path": str(executable),
                    "sha256": hashlib.sha256(executable_raw).hexdigest(),
                    "bytes": len(executable_raw),
                }],
            }
            contract = {
                "artifact_id": "forge-conductor-cli",
                "argv": ["trusted-output"],
                "cwd": str(root),
                "timeout_seconds": 5,
                "expected_exit_code": 0,
                "stdout": {"encoding": "utf-8", "exact": "trusted-output\n", "maximum_bytes": 64},
                "stderr": {"encoding": "utf-8", "exact": "", "maximum_bytes": 64},
            }
            self.assertTrue(installed_cli_contract_valid(contract))
            binding = {
                "feature_id": "CLI-FIXTURE",
                "assertion_id": "CLI-FIXTURE.production-path",
                "selector": "cli-fixture",
                "evidence_kind": "installed-cli-transcript",
                "expected": contract,
            }
            probe = {
                "scenario_id": "SCENARIO-CLI",
                "assertions": [binding],
                "runner": {"kind": "repository_qualification"},
            }
            result = capture_installed_cli_transcript(
                binding,
                installation,
                challenge_nonce=nonce,
                matrix_deadline=time.monotonic() + 10,
            )
            self.assertTrue(validate_installed_cli_transcript(
                binding,
                result,
                installation,
                challenge_nonce=nonce,
            ))
            document = {
                "schema_version": 3,
                "kind": "p10-qualifier-observations",
                "evidence_id": evidence_id,
                "scenario_id": "SCENARIO-CLI",
                "challenge_nonce": nonce,
                "process": {
                    "pid": os.getpid(),
                    "artifact_id": "forge-conductor-app",
                    "executable_path": "/usr/bin/false",
                },
                "provider_process": None,
                "results": [result],
            }
            passed, executions, results, _ = evaluate_probe_artifact(
                probe,
                canonical_bytes(document),
                evidence_id=evidence_id,
                challenge_nonce=nonce,
                installation=installation,
            )
            self.assertTrue(passed)
            self.assertEqual(executions, 1)
            self.assertEqual(set(results), {"cli-fixture"})

            invented_runner_document = {
                **document,
                "schema_version": 2,
                "kind": "p10-runner-context",
            }
            runner_passed, _, _ = evaluate_runner_artifact(
                probe,
                canonical_bytes(invented_runner_document),
                evidence_id=evidence_id,
                challenge_nonce=nonce,
            )
            self.assertFalse(runner_passed)

            copied_executable = root / "copied-forge-conductor"
            shutil.copyfile(executable, copied_executable)
            copied_executable.chmod(0o755)
            copied_installation = copy.deepcopy(installation)
            copied_installation["artifacts"][0]["path"] = str(copied_executable)
            self.assertFalse(validate_installed_cli_transcript(
                binding,
                result,
                copied_installation,
                challenge_nonce=nonce,
            ))

            for label, mutate in (
                ("nonce", lambda value: value.__setitem__("challenge_nonce", "2" * 64)),
                ("selector", lambda value: value["results"][0].__setitem__("selector", "other")),
                ("exit", lambda value: value["results"][0]["response"].__setitem__("exit_code", 7)),
                ("snapshot", lambda value: value["results"][0]["response"]["execution_snapshot"].__setitem__("sha256", "0" * 64)),
                ("stdout", lambda value: value["results"][0]["response"]["stdout"].__setitem__("base64", "Zm9yZ2Vk")),
            ):
                with self.subTest(label=label):
                    changed = copy.deepcopy(document)
                    mutate(changed)
                    self.assertFalse(evaluate_probe_artifact(
                        probe,
                        canonical_bytes(changed),
                        evidence_id=evidence_id,
                        challenge_nonce=nonce,
                        installation=installation,
                    )[0])
            duplicate_key = canonical_bytes(document).replace(
                b'"schema_version":3',
                b'"schema_version":3,"schema_version":3',
                1,
            )
            self.assertFalse(evaluate_probe_artifact(
                probe,
                duplicate_key,
                evidence_id=evidence_id,
                challenge_nonce=nonce,
                installation=installation,
            )[0])
            nonfinite = canonical_bytes(document).replace(b'"exit_code":0', b'"exit_code":NaN', 1)
            self.assertFalse(evaluate_probe_artifact(
                probe,
                nonfinite,
                evidence_id=evidence_id,
                challenge_nonce=nonce,
                installation=installation,
            )[0])

            for label, argv, timeout_seconds, maximum_bytes in (
                ("timeout", ["timeout"], 1, 0),
                ("output-bound", ["flood"], 3, 8),
            ):
                with self.subTest(label=label):
                    bounded_executable = root / f"forge-conductor-{label}"
                    shutil.copyfile(executable, bounded_executable)
                    bounded_executable.chmod(0o755)
                    bounded_raw = bounded_executable.read_bytes()
                    bounded_installation = {
                        "artifacts": [{
                            "artifact_id": "forge-conductor-cli",
                            "kind": "helper",
                            "path": str(bounded_executable),
                            "sha256": hashlib.sha256(bounded_raw).hexdigest(),
                            "bytes": len(bounded_raw),
                        }],
                    }
                    bounded_binding = copy.deepcopy(binding)
                    bounded_binding["expected"] = {
                        "artifact_id": "forge-conductor-cli",
                        "argv": argv,
                        "cwd": str(root),
                        "timeout_seconds": timeout_seconds,
                        "expected_exit_code": 0,
                        "stdout": {"encoding": "utf-8", "exact": "", "maximum_bytes": maximum_bytes},
                        "stderr": {"encoding": "utf-8", "exact": "", "maximum_bytes": maximum_bytes},
                    }
                    bounded_result = capture_installed_cli_transcript(
                        bounded_binding,
                        bounded_installation,
                        challenge_nonce=nonce,
                        matrix_deadline=time.monotonic() + 10,
                    )
                    self.assertFalse(validate_installed_cli_transcript(
                        bounded_binding,
                        bounded_result,
                        bounded_installation,
                        challenge_nonce=nonce,
                    ))
                    if label == "timeout":
                        self.assertIs(bounded_result["response"]["timed_out"], True)
                    else:
                        self.assertIs(bounded_result["response"]["stream_limit_exceeded"], True)

            executable.write_bytes(executable_raw + b"changed")
            self.assertFalse(validate_installed_cli_transcript(
                binding,
                result,
                installation,
                challenge_nonce=nonce,
            ))

    def test_one_derived_signing_receipt_can_serve_multiple_feature_assertions(self) -> None:
        evidence_id = "EVID-shared-signing-fixture"
        nonce = "3" * 64
        expected_signing = {
            "artifact_id": "forge-conductor-app",
            "team_id": "9AQ2C2838M",
            "identifier": "com.cyberworlds.forge-conductor",
            "hardened_runtime": True,
        }
        assertions = [
            {
                "feature_id": feature_id,
                "assertion_id": f"{feature_id}.signed-product.forge-conductor-app",
                "selector": "signing.forge-conductor-app",
                "evidence_kind": "codesign-identity",
                "expected": dict(expected_signing),
            }
            for feature_id in ("FEATURE-A", "FEATURE-B")
        ]
        probe = {
            "scenario_id": "SCENARIO-SHARED-SIGNING",
            "assertions": assertions,
            "runner": {"kind": "repository_qualification"},
        }
        result = {
            "selector": "signing.forge-conductor-app",
            "evidence_kind": "codesign-identity",
            "request": {
                "challenge_nonce": nonce,
                "selector": "signing.forge-conductor-app",
            },
            "response": {
                "challenge_nonce": nonce,
                "selector": "signing.forge-conductor-app",
                "observed": expected_signing,
            },
        }
        document = {
            "schema_version": 3,
            "kind": "p10-qualifier-observations",
            "evidence_id": evidence_id,
            "scenario_id": probe["scenario_id"],
            "challenge_nonce": nonce,
            "process": {
                "pid": os.getpid(),
                "artifact_id": "forge-conductor-app",
                "executable_path": "/usr/bin/false",
            },
            "provider_process": None,
            "results": [result],
        }
        passed, executions, results, _ = evaluate_probe_artifact(
            probe,
            encoded(document),
            evidence_id=evidence_id,
            challenge_nonce=nonce,
        )
        self.assertTrue(passed)
        self.assertEqual(executions, 1)
        self.assertEqual(set(results), {"signing.forge-conductor-app"})

        conflicting = copy.deepcopy(probe)
        conflicting["assertions"][1]["expected"]["identifier"] = "different.identifier"
        self.assertFalse(evaluate_probe_artifact(
            conflicting,
            encoded(document),
            evidence_id=evidence_id,
            challenge_nonce=nonce,
        )[0])

    def test_runner_identity_cannot_be_evaded_by_timeout_and_xctest_is_not_allowlisted(self) -> None:
        first = {
            "scenario_id": "SCENARIO-A",
            "runner": {
                "kind": "repository_qualification",
                "executable": ".forge-codex/scripts/qualification-probes/a.py",
                "arguments": [],
                "timeout_seconds": 10,
            },
        }
        second = copy.deepcopy(first)
        second["runner"]["timeout_seconds"] = 11
        self.assertEqual(runner_identity(first), runner_identity(second))
        xctest = {
            "scenario_id": "SCENARIO-XCTEST",
            "runner": {
                "kind": "swift_test",
                "test_identifier": "Tests/testSynthetic",
                "configuration": "release",
                "timeout_seconds": 10,
            },
        }
        with self.assertRaisesRegex(EvidenceSupportError, "not allowlisted"):
            runner_argv(REPOSITORY_ROOT, xctest)

    def test_observation_aggregate_digest_and_strict_json_are_fail_closed(self) -> None:
        document = encoded({
            "schema_version": 3,
            "kind": "p10-qualifier-observations",
            "evidence_id": EVIDENCE_ID,
            "scenario_id": "SCENARIO-A",
            "challenge_nonce": "1" * 64,
            "process": {"pid": 2, "artifact_id": "forge-conductor-app", "executable_path": "/tmp/a"},
            "provider_process": None,
            "results": [],
        })
        aggregate = {
            "schema_version": 1,
            "kind": "p10-production-observation-aggregate",
            "evidence_id": EVIDENCE_ID,
            "scenarios": [{
                "scenario_id": "SCENARIO-A",
                "challenge_nonce": "1" * 64,
                "sha256": hashlib.sha256(document).hexdigest(),
                "bytes": len(document),
                "document_base64": base64.b64encode(document).decode("ascii"),
                "installation": {"derived": True},
                "signing": {},
                "providers": {},
            }],
        }
        failures, documents = _decode_observation_aggregate(encoded(aggregate), evidence_id=EVIDENCE_ID)
        self.assertEqual(failures, [])
        self.assertEqual(set(documents), {"SCENARIO-A"})
        aggregate["scenarios"][0]["sha256"] = "0" * 64
        failures, _ = _decode_observation_aggregate(encoded(aggregate), evidence_id=EVIDENCE_ID)
        self.assertTrue(any("binding" in item for item in failures), failures)

    def test_scenario_grouping_deduplicates_one_runner_and_rejects_repeated_runner_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            executable = root / ".forge-codex/scripts/qualification-probes/grouped.py"
            executable.parent.mkdir(parents=True)
            executable.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
            executable.chmod(0o755)
            cli_contract = lambda argument: {
                "artifact_id": "forge-conductor-cli",
                "argv": [argument],
                "cwd": str(root),
                "timeout_seconds": 5,
                "expected_exit_code": 0,
                "stdout": {"encoding": "utf-8", "exact": "", "maximum_bytes": 0},
                "stderr": {"encoding": "utf-8", "exact": "", "maximum_bytes": 0},
            }
            assertions = [
                {"feature_id": "FEATURE-ONE", "assertion_id": "FEATURE-ONE.production-path", "selector": "feature-one", "evidence_kind": "installed-cli-transcript", "expected": cli_contract("feature-one")},
                {"feature_id": "FEATURE-TWO", "assertion_id": "FEATURE-TWO.production-path", "selector": "feature-two", "evidence_kind": "installed-cli-transcript", "expected": cli_contract("feature-two")},
            ]
            runner = {
                "kind": "repository_qualification",
                "executable": ".forge-codex/scripts/qualification-probes/grouped.py",
                "arguments": [],
                "timeout_seconds": 10,
            }
            installation = {
                "root": "/tmp/Forge Conductor.app",
                "configuration": "Release",
                "process_artifact_id": "forge-conductor-app",
                "artifacts": [
                    {"artifact_id": "forge-conductor-app", "relative_path": "Contents/MacOS/Forge Conductor", "kind": "app-executable"},
                    {"artifact_id": "forge-conductor-cli", "relative_path": "Contents/Helpers/forge-conductor", "kind": "helper"},
                    {"artifact_id": "forge-filesystem-daemon", "relative_path": "Contents/MacOS/forge-filesystem-daemon", "kind": "helper"},
                    {"artifact_id": "forge-runtime-launcher", "relative_path": "Contents/Helpers/forge-runtime-launcher", "kind": "helper"},
                ],
            }
            base = copy.deepcopy(json.loads((REPOSITORY_ROOT / PRODUCTION_PROBE_REGISTRY_PATH).read_text()))
            base["implemented_scenarios"] = [{
                "scenario_id": "SCENARIO-GROUPED",
                "assertions": assertions,
                "runner": runner,
                "installation": installation,
            }]
            registry_features = {
                "FEATURE-ONE": {"category": "cli", "required_assertions": ["FEATURE-ONE.production-path"]},
                "FEATURE-TWO": {"category": "cli", "required_assertions": ["FEATURE-TWO.production-path"]},
            }
            probe_artifact = {
                "path": PRODUCTION_PROBE_REGISTRY_PATH,
                "sha256": EXPECTED_PRODUCTION_PROBE_REGISTRY_SHA256,
                "bytes": 1,
            }
            qualifier_artifact = {
                "path": FEATURE_QUALIFIER_PATH,
                "sha256": EXPECTED_FEATURE_QUALIFIER_SHA256,
                "bytes": 1,
            }
            failures, mappings, missing = _validate_probe_registry(
                root,
                base,
                probe_registry_artifact=probe_artifact,
                qualifier_artifact=qualifier_artifact,
                registry_features=registry_features,
                canonical_feature_registry=False,
            )
            self.assertEqual(missing, [])
            self.assertEqual(set(mappings), {"FEATURE-ONE.production-path", "FEATURE-TWO.production-path"})
            self.assertFalse(any("repeat a runner" in item for item in failures), failures)
            duplicated = copy.deepcopy(base)
            duplicated["implemented_scenarios"] = [
                {"scenario_id": "SCENARIO-ONE", "assertions": [assertions[0]], "runner": runner, "installation": installation},
                {"scenario_id": "SCENARIO-TWO", "assertions": [assertions[1]], "runner": runner, "installation": installation},
            ]
            failures, _, _ = _validate_probe_registry(
                root,
                duplicated,
                probe_registry_artifact=probe_artifact,
                qualifier_artifact=qualifier_artifact,
                registry_features=registry_features,
                canonical_feature_registry=False,
            )
            self.assertTrue(any("repeat a runner" in item for item in failures), failures)

            cli_authority = copy.deepcopy(next(
                item for item in self.registry["features"]
                if item["id"] == "BUILD-CLI-EXECUTABLE"
            ))
            cli_authority["category"] = "cli"
            wrong_artifact = copy.deepcopy(base)
            wrong_artifact["implemented_scenarios"] = [{
                "scenario_id": "SCENARIO-WRONG-SIGNING-ARTIFACT",
                "assertions": [{
                    "feature_id": "BUILD-CLI-EXECUTABLE",
                    "assertion_id": "BUILD-CLI-EXECUTABLE.signed-product.forge-conductor-cli",
                    "selector": "signing.forge-conductor-app",
                    "evidence_kind": "codesign-identity",
                    "expected": {"artifact_id": "forge-conductor-app"},
                }],
                "runner": runner,
                "installation": installation,
            }]
            failures, _, _ = _validate_probe_registry(
                root,
                wrong_artifact,
                probe_registry_artifact=probe_artifact,
                qualifier_artifact=qualifier_artifact,
                registry_features={"BUILD-CLI-EXECUTABLE": cli_authority},
                canonical_feature_registry=False,
            )
            self.assertTrue(
                any("authoritative shipped signing artifact" in item for item in failures),
                failures,
            )
            selector_collision = copy.deepcopy(base)
            selector_collision["implemented_scenarios"] = [{
                "scenario_id": "SCENARIO-SELECTOR-COLLISION",
                "assertions": [
                    {
                        "feature_id": "BUILD-CLI-EXECUTABLE",
                        "assertion_id": "BUILD-CLI-EXECUTABLE.production-path",
                        "selector": "signing.forge-conductor-cli",
                        "evidence_kind": "installed-cli-transcript",
                        "expected": cli_contract("selector-collision"),
                    },
                    {
                        "feature_id": "BUILD-CLI-EXECUTABLE",
                        "assertion_id": "BUILD-CLI-EXECUTABLE.signed-product.forge-conductor-cli",
                        "selector": "signing.forge-conductor-cli",
                        "evidence_kind": "codesign-identity",
                        "expected": {
                            "artifact_id": "forge-conductor-cli",
                            "team_id": "9AQ2C2838M",
                            "identifier": "com.cyberworlds.forge-conductor.cli",
                            "hardened_runtime": True,
                        },
                    },
                ],
                "runner": runner,
                "installation": installation,
            }]
            failures, _, _ = _validate_probe_registry(
                root,
                selector_collision,
                probe_registry_artifact=probe_artifact,
                qualifier_artifact=qualifier_artifact,
                registry_features={"BUILD-CLI-EXECUTABLE": cli_authority},
                canonical_feature_registry=False,
            )
            self.assertTrue(any("globally distinct" in item for item in failures), failures)

    def test_canonical_cli_features_reject_generic_snapshot_observation(self) -> None:
        canonical_feature_ids = {
            "CLI-INSTALL",
            "CLI-INSTALL-LMSTUDIO",
            "CLI-SERVE",
            "CLI-MANAGER",
            "CLI-DASHBOARD",
            "CLI-QUALIFICATION-FILESYSTEM-HEALTH",
            "CLI-EXTENDED-INSTALL-DASHBOARD-OPTIONS",
            "CLI-VERSION-HELP",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            runner_path = root / ".forge-codex/scripts/qualification-probes/snapshot.py"
            runner_path.parent.mkdir(parents=True)
            runner_path.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
            runner_path.chmod(0o755)
            installation = {
                "root": str(root / "Forge Conductor.app"),
                "configuration": "Release",
                "process_artifact_id": "forge-conductor-app",
                "artifacts": [
                    {
                        "artifact_id": artifact_id,
                        "relative_path": definition["relative_path"],
                        "kind": definition["installation_kind"],
                    }
                    for artifact_id, definition in EXPECTED_SIGNING_ARTIFACTS.items()
                ],
            }
            contract = {
                "artifact_id": "forge-conductor-cli",
                "argv": ["--version"],
                "cwd": str(root),
                "timeout_seconds": 5,
                "expected_exit_code": 0,
                "stdout": {"encoding": "utf-8", "exact": "fixture\n", "maximum_bytes": 64},
                "stderr": {"encoding": "utf-8", "exact": "", "maximum_bytes": 64},
            }
            assertions = [
                {
                    "feature_id": feature_id,
                    "assertion_id": f"{feature_id}.production-path",
                    "selector": f"{feature_id}.snapshot",
                    "evidence_kind": "installed-cli-transcript",
                    "expected": copy.deepcopy(contract),
                }
                for feature_id in sorted(canonical_feature_ids)
            ]
            probe_registry = copy.deepcopy(
                json.loads((REPOSITORY_ROOT / PRODUCTION_PROBE_REGISTRY_PATH).read_text())
            )
            probe_registry["implemented_scenarios"] = [{
                "scenario_id": "SCENARIO-CANONICAL-CLI-SNAPSHOT",
                "assertions": assertions,
                "runner": {
                    "kind": "repository_qualification",
                    "executable": ".forge-codex/scripts/qualification-probes/snapshot.py",
                    "arguments": [],
                    "timeout_seconds": 10,
                },
                "installation": installation,
            }]
            registry_features = {
                feature["id"]: feature
                for feature in self.registry["features"]
                if feature["id"] in canonical_feature_ids
            }
            failures, mappings, missing = _validate_probe_registry(
                root,
                probe_registry,
                probe_registry_artifact={
                    "path": PRODUCTION_PROBE_REGISTRY_PATH,
                    "sha256": EXPECTED_PRODUCTION_PROBE_REGISTRY_SHA256,
                    "bytes": 1,
                },
                qualifier_artifact={
                    "path": FEATURE_QUALIFIER_PATH,
                    "sha256": EXPECTED_FEATURE_QUALIFIER_SHA256,
                    "bytes": 1,
                },
                registry_features=registry_features,
                canonical_feature_registry=True,
            )
            production_assertions = {item["assertion_id"] for item in assertions}
            self.assertEqual(set(mappings), set())
            self.assertTrue(production_assertions.issubset(set(missing)))
            self.assertEqual(
                sum("no reviewed snapshot-safe semantic contract" in item for item in failures),
                len(canonical_feature_ids),
            )

    def test_complete_104_feature_259_assertion_matrix_reuses_four_signing_receipts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            executable = root / ".forge-codex/scripts/qualification-probes/signing.py"
            executable.parent.mkdir(parents=True)
            executable.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
            executable.chmod(0o755)
            installed_root = root / "Forge Conductor.app"
            artifacts = [
                {
                    "artifact_id": artifact_id,
                    "relative_path": definition["relative_path"],
                    "kind": definition["installation_kind"],
                }
                for artifact_id, definition in EXPECTED_SIGNING_ARTIFACTS.items()
            ]
            installation = {
                "root": str(installed_root),
                "configuration": "Release",
                "process_artifact_id": "forge-conductor-app",
                "artifacts": artifacts,
            }
            registry_features = {
                feature["id"]: feature for feature in self.registry["features"]
            }
            signing_contracts = {
                "forge-conductor-app": {
                    "artifact_id": "forge-conductor-app",
                    "team_id": "9AQ2C2838M",
                    "identifier": "com.cyberworlds.forge-conductor",
                    "hardened_runtime": True,
                },
                "forge-conductor-cli": {
                    "artifact_id": "forge-conductor-cli",
                    "team_id": "9AQ2C2838M",
                    "identifier": "com.cyberworlds.forge-conductor.cli",
                    "hardened_runtime": True,
                },
                "forge-filesystem-daemon": {
                    "artifact_id": "forge-filesystem-daemon",
                    "team_id": "9AQ2C2838M",
                    "identifier": "com.cyberworlds.forge-conductor.filesystem-daemon",
                    "hardened_runtime": True,
                },
                "forge-runtime-launcher": {
                    "artifact_id": "forge-runtime-launcher",
                    "team_id": "9AQ2C2838M",
                    "identifier": "com.cyberworlds.forge-conductor.runtime-launcher",
                    "hardened_runtime": True,
                },
            }
            cli_contract = lambda argument: {
                "artifact_id": "forge-conductor-cli",
                "argv": [argument],
                "cwd": str(root),
                "timeout_seconds": 5,
                "expected_exit_code": 0,
                "stdout": {"encoding": "utf-8", "exact": "", "maximum_bytes": 0},
                "stderr": {"encoding": "utf-8", "exact": "", "maximum_bytes": 0},
            }
            assertions: list[dict[str, object]] = []
            for feature in self.registry["features"]:
                for assertion_id in feature["required_assertions"]:
                    if ".signed-product." in assertion_id:
                        artifact_id = feature["signing_artifact"]
                        selector = f"signing.{artifact_id}"
                        evidence_kind = "codesign-identity"
                        expected = copy.deepcopy(signing_contracts[artifact_id])
                    elif assertion_id.endswith(".real-provider"):
                        selector = assertion_id
                        evidence_kind = "lmstudio-nonce-transcript"
                        expected = {
                            "endpoint": "http://127.0.0.1:1234/v1/chat/completions",
                            "model": "fixture-model",
                            "timeout_seconds": 5,
                        }
                    else:
                        selector = assertion_id
                        evidence_kind = "installed-cli-transcript"
                        expected = cli_contract(assertion_id)
                    assertions.append({
                        "feature_id": feature["id"],
                        "assertion_id": assertion_id,
                        "selector": selector,
                        "evidence_kind": evidence_kind,
                        "expected": expected,
                    })
            signing_assertions = [
                item for item in assertions if item["evidence_kind"] == "codesign-identity"
            ]
            provider_assertions = [
                item for item in assertions if item["evidence_kind"] == "lmstudio-nonce-transcript"
            ]
            production_assertions = [
                item for item in assertions if str(item["assertion_id"]).endswith(".production-path")
            ]
            snapshot_cli_assertions = [
                item for item in production_assertions
                if registry_features[str(item["feature_id"])]["category"] == "cli"
            ]
            unsupported_ordinary_assertions = [
                item for item in production_assertions if item not in snapshot_cli_assertions
            ]
            ordinary_selectors = {
                item["selector"] for item in assertions
                if item["evidence_kind"] != "codesign-identity"
            }
            signing_selectors = {item["selector"] for item in signing_assertions}
            self.assertEqual(len(registry_features), 104)
            self.assertEqual(len(assertions), 259)
            self.assertEqual(len(production_assertions), 146)
            self.assertEqual(len(snapshot_cli_assertions), 11)
            self.assertEqual(len(unsupported_ordinary_assertions), 135)
            self.assertEqual(len(signing_assertions), 99)
            self.assertEqual(len(provider_assertions), 14)
            self.assertEqual(len(ordinary_selectors), 160)
            self.assertEqual(
                signing_selectors,
                {f"signing.{artifact_id}" for artifact_id in EXPECTED_SIGNING_ARTIFACTS},
            )
            probe_registry = copy.deepcopy(
                json.loads((REPOSITORY_ROOT / PRODUCTION_PROBE_REGISTRY_PATH).read_text())
            )
            probe_registry["implemented_scenarios"] = [{
                "scenario_id": "SCENARIO-SHARED-SIGNING-RECEIPTS",
                "assertions": assertions,
                "runner": {
                    "kind": "repository_qualification",
                    "executable": ".forge-codex/scripts/qualification-probes/signing.py",
                    "arguments": [],
                    "timeout_seconds": 10,
                },
                "installation": installation,
            }]
            failures, mappings, missing = _validate_probe_registry(
                root,
                probe_registry,
                probe_registry_artifact={
                    "path": PRODUCTION_PROBE_REGISTRY_PATH,
                    "sha256": EXPECTED_PRODUCTION_PROBE_REGISTRY_SHA256,
                    "bytes": 1,
                },
                qualifier_artifact={
                    "path": FEATURE_QUALIFIER_PATH,
                    "sha256": EXPECTED_FEATURE_QUALIFIER_SHA256,
                    "bytes": 1,
                },
                registry_features=registry_features,
                canonical_feature_registry=True,
            )
            self.assertEqual(
                sum("no trusted ordinary adapter" in item for item in failures),
                135,
            )
            self.assertEqual(
                sum("no reviewed snapshot-safe semantic contract" in item for item in failures),
                11,
            )
            self.assertEqual(
                set(missing),
                {item["assertion_id"] for item in production_assertions},
            )
            supported_assertions = signing_assertions + provider_assertions
            self.assertEqual(
                set(mappings),
                {item["assertion_id"] for item in supported_assertions},
            )

            evidence_id = "EVID-complete-matrix-fixture"
            nonce = "4" * 64
            selector_bindings: dict[str, dict[str, object]] = {}
            for item in signing_assertions:
                selector = str(item["selector"])
                previous = selector_bindings.setdefault(selector, item)
                self.assertEqual(previous["evidence_kind"], item["evidence_kind"])
                self.assertEqual(previous["expected"], item["expected"])
            signing_probe = {
                "scenario_id": "SCENARIO-SHARED-SIGNING-RECEIPTS",
                "assertions": signing_assertions,
                "runner": probe_registry["implemented_scenarios"][0]["runner"],
            }
            observation = {
                "schema_version": 3,
                "kind": "p10-qualifier-observations",
                "evidence_id": evidence_id,
                "scenario_id": "SCENARIO-SHARED-SIGNING-RECEIPTS",
                "challenge_nonce": nonce,
                "process": {
                    "pid": os.getpid(),
                    "artifact_id": "forge-conductor-app",
                    "executable_path": "/usr/bin/false",
                },
                "provider_process": None,
                "results": [
                    {
                        "selector": selector,
                        "evidence_kind": item["evidence_kind"],
                        "request": {"challenge_nonce": nonce, "selector": selector},
                        "response": {
                            "challenge_nonce": nonce,
                            "selector": selector,
                            "observed": item["expected"],
                        },
                    }
                    for selector, item in selector_bindings.items()
                ],
            }
            passed, executions, observed, _ = evaluate_probe_artifact(
                signing_probe,
                encoded(observation),
                evidence_id=evidence_id,
                challenge_nonce=nonce,
            )
            self.assertTrue(passed)
            self.assertEqual(executions, 4)
            self.assertEqual(len(observed), 4)

            observed_signing = {
                selector: {"artifact_id": selector.removeprefix("signing.")}
                for selector in signing_selectors
            }
            cache: dict[str, tuple[dict[str, object] | None, dict[str, object] | None]] = {}
            with mock.patch(
                "p10_feature_evidence.derive_signing_fact",
                side_effect=lambda binding, _: observed_signing[binding["selector"]],
            ) as derive:
                for item in signing_assertions:
                    signing_from_receipt, current_signing = _cached_signing_revalidation(
                        cache,
                        selector=str(item["selector"]),
                        binding=item,
                        installation={},
                        observed_signing=observed_signing,
                    )
                    self.assertEqual(signing_from_receipt, current_signing)
            self.assertEqual(derive.call_count, 4)
            self.assertEqual(set(cache), signing_selectors)

            split_owner = copy.deepcopy(probe_registry)
            canonical = split_owner["implemented_scenarios"][0]
            moved = next(
                item for item in canonical["assertions"]
                if item["selector"] == "signing.forge-conductor-app"
            )
            canonical["assertions"].remove(moved)
            second_owner = copy.deepcopy(canonical)
            second_owner["scenario_id"] = "SCENARIO-SECOND-SIGNING-OWNER"
            second_owner["assertions"] = [moved]
            second_owner["runner"]["arguments"] = ["second-owner"]
            split_owner["implemented_scenarios"].append(second_owner)
            split_failures, _, _ = _validate_probe_registry(
                root,
                split_owner,
                probe_registry_artifact={
                    "path": PRODUCTION_PROBE_REGISTRY_PATH,
                    "sha256": EXPECTED_PRODUCTION_PROBE_REGISTRY_SHA256,
                    "bytes": 1,
                },
                qualifier_artifact={
                    "path": FEATURE_QUALIFIER_PATH,
                    "sha256": EXPECTED_FEATURE_QUALIFIER_SHA256,
                    "bytes": 1,
                },
                registry_features=registry_features,
                canonical_feature_registry=True,
            )
            self.assertTrue(
                any("multiple owner scenarios" in item for item in split_failures),
                split_failures,
            )

    def test_signing_result_cannot_substitute_another_shipped_artifact(self) -> None:
        probe = {
            "scenario_id": "SCENARIO-SIGNING-IDENTITY",
            "assertions": [{
                "feature_id": "BUILD-CLI-EXECUTABLE",
                "assertion_id": "BUILD-CLI-EXECUTABLE.signed-product.forge-conductor-cli",
                "selector": "signing.forge-conductor-cli",
            }],
            "runner": {"kind": "repository_qualification"},
        }
        output = encoded({
            "schema_version": 1,
            "scenario_id": "SCENARIO-SIGNING-IDENTITY",
            "passed": True,
            "executions": 1,
            "results": [{
                "selector": "signing.forge-conductor-cli",
                "passed": True,
                "observed_assertions": 1,
                "signing": {
                    "applicable": True,
                    "artifact_id": "forge-conductor-app",
                    "team_id": "9AQ2C2838M",
                    "identifier": "com.cyberworlds.forge-conductor",
                    "cdhash": "1" * 40,
                    "designated_requirement_sha256": "2" * 64,
                    "hardened_runtime": False,
                },
            }],
        })
        passed, _, _, _ = evaluate_probe_output(
            probe,
            output,
            b"",
            exit_code=0,
            timed_out=False,
            stream_limit_exceeded=False,
        )
        self.assertFalse(passed)

    def test_sensitive_facts_cannot_be_self_declared_without_codesign_or_live_provider(self) -> None:
        signing_binding = {
            "assertion_id": "BUILD-CLI-EXECUTABLE.signed-product.forge-conductor-cli",
            "expected": {
                "artifact_id": "forge-conductor-cli",
                "team_id": "ABCDEFGHIJ",
                "identifier": "com.example.substitute",
                "hardened_runtime": False,
            },
        }
        installation = {
            "artifacts": [{
                "artifact_id": "forge-conductor-cli",
                "path": "/usr/bin/false",
                "sha256": "0" * 64,
                "bytes": 1,
            }],
        }
        with self.assertRaises(EvidenceSupportError):
            derive_signing_fact(signing_binding, installation)

        provider_binding = {
            "expected": {
                "endpoint": "not-a-url",
                "model": "not-observed",
                "timeout_seconds": 1,
            }
        }
        observation = {
            "provider_process": {"pid": os.getpid(), "executable_path": "/usr/bin/false"}
        }
        with self.assertRaisesRegex(EvidenceSupportError, "loopback"):
            derive_provider_fact(
                provider_binding,
                observation,
                challenge_nonce="1" * 64,
            )
        fabricated = {
            "applicable": True,
            "kind": "lm_studio",
            "transport": "http",
            "real_provider": True,
            "endpoint": "not-a-url",
            "model": "not-observed",
        }
        self.assertFalse(validate_provider_fact(provider_binding, observation, fabricated))

    def test_qualifier_receipt_hash_matches_the_final_preserved_stdout_line(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            feature_id = "BUILD-FIXTURE"
            assertion_ids = [
                f"{feature_id}.first.production-path",
                f"{feature_id}.second.production-path",
            ]
            counter = pathlib.Path(temporary) / "runner-count"
            installed_root = root / "Forge Conductor.app"
            installed_app = installed_root / "Contents/MacOS/Forge Conductor"
            installed_cli = installed_root / "Contents/Helpers/forge-conductor"
            installed_daemon = installed_root / "Contents/MacOS/forge-filesystem-daemon"
            installed_launcher = installed_root / "Contents/Helpers/forge-runtime-launcher"
            installed_app.parent.mkdir(parents=True)
            installed_cli.parent.mkdir(parents=True)
            compile_native_cli_fixture(installed_app)
            for destination in (installed_cli, installed_daemon, installed_launcher):
                shutil.copyfile(installed_app, destination)
                destination.chmod(0o755)
            registry = {
                "features": [{
                    "id": feature_id,
                    "category": "cli",
                    "required_assertions": assertion_ids,
                    "provider_required": False,
                }]
            }
            probe_script = root / ".forge-codex/scripts/qualification-probes/fixture.py"
            probe_script.parent.mkdir(parents=True)
            probe_script.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, subprocess, sys\n"
                "counter = pathlib.Path(sys.argv[1])\n"
                "counter.write_text(str(int(counter.read_text()) + 1) if counter.exists() else '1')\n"
                "nonce = os.environ['FORGE_P10_CHALLENGE_NONCE']\n"
                "evidence_id = os.environ['FORGE_EVIDENCE_ID']\n"
                "process = subprocess.Popen([sys.argv[2], 'stay-alive'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)\n"
                "results = []\n"
                "if len(sys.argv) > 3 and sys.argv[3] == 'invent':\n"
                "    for selector in ('fixture-first', 'fixture-second'):\n"
                "        results.append({'selector': selector, 'evidence_kind': 'installed-cli-transcript', 'request': {'challenge_nonce': nonce, 'selector': selector}, 'response': {'challenge_nonce': nonce, 'selector': selector, 'observed': {'invented': True}}})\n"
                "document = {'schema_version': 2, 'kind': 'p10-runner-context', 'evidence_id': evidence_id, 'scenario_id': 'SCENARIO-FIXTURE', 'challenge_nonce': nonce, 'process': {'pid': process.pid, 'artifact_id': 'forge-conductor-app', 'executable_path': sys.argv[2]}, 'provider_process': None, 'results': results}\n"
                "pathlib.Path(os.environ['FORGE_P10_OBSERVATION_PATH']).write_text(json.dumps(document, separators=(',', ':')))\n",
                encoding="utf-8",
            )
            probe_script.chmod(0o755)
            probe_registry = {
                "limits": {
                    "maximum_matrix_seconds": 1500,
                    "maximum_probe_stream_bytes": 65536,
                    "maximum_observation_bytes_per_scenario": 262144,
                    "maximum_total_raw_output_bytes": 8388608,
                    "maximum_unique_runners": 64,
                },
                "implemented_scenarios": [{
                    "scenario_id": "SCENARIO-FIXTURE",
                    "assertions": [
                        {"feature_id": feature_id, "assertion_id": assertion_ids[0], "selector": "fixture-first", "evidence_kind": "installed-cli-transcript", "expected": {"artifact_id": "forge-conductor-cli", "argv": ["trusted-output"], "cwd": str(root), "timeout_seconds": 5, "expected_exit_code": 0, "stdout": {"encoding": "utf-8", "exact": "trusted-output\n", "maximum_bytes": 64}, "stderr": {"encoding": "utf-8", "exact": "", "maximum_bytes": 64}}},
                        {"feature_id": feature_id, "assertion_id": assertion_ids[1], "selector": "fixture-second", "evidence_kind": "installed-cli-transcript", "expected": {"artifact_id": "forge-conductor-cli", "argv": ["trusted-output"], "cwd": str(root), "timeout_seconds": 5, "expected_exit_code": 0, "stdout": {"encoding": "utf-8", "exact": "trusted-output\n", "maximum_bytes": 64}, "stderr": {"encoding": "utf-8", "exact": "", "maximum_bytes": 64}}},
                    ],
                    "runner": {
                        "kind": "repository_qualification",
                        "executable": ".forge-codex/scripts/qualification-probes/fixture.py",
                        "arguments": [str(counter), str(installed_app), "capture"],
                        "timeout_seconds": 10,
                    },
                    "installation": {
                        "root": str(installed_root),
                        "configuration": "Release",
                        "process_artifact_id": "forge-conductor-app",
                        "artifacts": [
                            {"artifact_id": "forge-conductor-app", "relative_path": "Contents/MacOS/Forge Conductor", "kind": "app-executable"},
                            {"artifact_id": "forge-conductor-cli", "relative_path": "Contents/Helpers/forge-conductor", "kind": "helper"},
                            {"artifact_id": "forge-filesystem-daemon", "relative_path": "Contents/MacOS/forge-filesystem-daemon", "kind": "helper"},
                            {"artifact_id": "forge-runtime-launcher", "relative_path": "Contents/Helpers/forge-runtime-launcher", "kind": "helper"},
                        ],
                    },
                }]
            }
            for relative, document in (
                (FEATURE_REGISTRY_PATH, registry),
                (PRODUCTION_PROBE_REGISTRY_PATH, probe_registry),
                (FEATURE_BASELINE_PATH, {"schema_version": 2}),
            ):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(encoded(document))
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"],
                cwd=root,
                check=True,
            )
            report_path = root / FEATURE_QUALIFICATION_REPORT_SOURCE_PATH
            environment = dict(os.environ)
            environment["FORGE_EVIDENCE_ID"] = EVIDENCE_ID
            result = subprocess.run(
                [
                    "python3",
                    str(REPOSITORY_ROOT / ".forge-codex/scripts/qualify_p10_features.py"),
                    "--repo",
                    str(root),
                    "--report",
                    FEATURE_QUALIFICATION_REPORT_SOURCE_PATH,
                ],
                cwd=REPOSITORY_ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            receipt_lines = result.stdout.decode().splitlines()
            self.assertEqual(len(receipt_lines), 1)
            receipt = json.loads(receipt_lines[0])
            report = json.loads(report_path.read_text())
            from jsonschema import Draft202012Validator

            report_schema = json.loads(
                (
                    REPOSITORY_ROOT
                    / ".forge-codex/schemas/p10-feature-production-qualification.schema.json"
                ).read_text()
            )
            schema_errors = sorted(
                Draft202012Validator(report_schema).iter_errors(report),
                key=lambda error: tuple(str(part) for part in error.absolute_path),
            )
            self.assertEqual(
                schema_errors,
                [],
                [
                    {
                        "path": list(error.absolute_path),
                        "message": error.message,
                    }
                    for error in schema_errors
                ],
            )
            self.assertIs(report["environment"]["installed_product"], True)
            installation_receipt = report["environment"]["installation_receipt"]
            self.assertEqual(installation_receipt["root"], str(installed_root))
            installed_binding = next(
                item for item in installation_receipt["artifacts"]
                if item["artifact_id"] == "forge-conductor-cli"
            )
            self.assertEqual(installed_binding["path"], str(installed_cli))
            self.assertEqual(installed_binding["sha256"], hashlib.sha256(installed_cli.read_bytes()).hexdigest())
            assertions = report["results"][0]["assertions"]
            self.assertEqual(len(assertions), 2)
            receipt_hash = hashlib.sha256(canonical_bytes(receipt)).hexdigest()
            self.assertEqual({item["execution_receipt_sha256"] for item in assertions}, {receipt_hash})
            self.assertEqual([item["selector"] for item in assertions], ["fixture-first", "fixture-second"])
            self.assertEqual(counter.read_text(), "1")

            # A missing third assertion must not discard either observed proof.
            registry["features"][0]["required_assertions"].append("BUILD-FIXTURE.missing.production-path")
            (root / FEATURE_REGISTRY_PATH).write_bytes(encoded(registry))
            partial = subprocess.run(
                ["python3", str(REPOSITORY_ROOT / ".forge-codex/scripts/qualify_p10_features.py"),
                 "--repo", str(root), "--report", FEATURE_QUALIFICATION_REPORT_SOURCE_PATH],
                cwd=REPOSITORY_ROOT, env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            self.assertEqual(partial.returncode, 2, partial.stderr.decode())
            partial_report = json.loads(report_path.read_bytes())
            self.assertEqual(partial_report["kind"], "p10-feature-partial-qualification")
            self.assertEqual(partial_report["coverage"]["missing_assertions"], ["BUILD-FIXTURE.missing.production-path"])
            self.assertEqual(partial_report["execution"]["passed_assertion_count"], 2)
            self.assertEqual(partial_report["results"][0]["status"], "partial")
            self.assertFalse(partial_report["environment"]["installed_product"])
            partial_receipt = json.loads(partial.stdout.splitlines()[-1])
            self.assertEqual(partial_receipt["kind"], "p10-production-probe-receipt")
            self.assertEqual(partial_receipt["observed_assertions"], 2)
            self.assertTrue(partial_report["results"][0]["assertions"][0]["artifact_references"])
            self.assertEqual(counter.read_text(), "2")
            registry["features"][0]["required_assertions"].pop()
            (root / FEATURE_REGISTRY_PATH).write_bytes(encoded(registry))

            probe_registry["implemented_scenarios"][0]["runner"]["arguments"][-1] = "invent"
            (root / PRODUCTION_PROBE_REGISTRY_PATH).write_bytes(encoded(probe_registry))
            invented = subprocess.run(
                [
                    "python3",
                    str(REPOSITORY_ROOT / ".forge-codex/scripts/qualify_p10_features.py"),
                    "--repo",
                    str(root),
                    "--report",
                    FEATURE_QUALIFICATION_REPORT_SOURCE_PATH,
                ],
                cwd=REPOSITORY_ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(invented.returncode, 0)
            self.assertEqual(counter.read_text(), "3")

            probe_registry["implemented_scenarios"][0]["runner"]["arguments"][-1] = "capture"
            (root / PRODUCTION_PROBE_REGISTRY_PATH).write_bytes(encoded(probe_registry))
            registry["registry_id"] = "forge-conductor-p10-feature-registry"
            (root / FEATURE_REGISTRY_PATH).write_bytes(encoded(registry))
            canonical_snapshot = subprocess.run(
                [
                    "python3",
                    str(REPOSITORY_ROOT / ".forge-codex/scripts/qualify_p10_features.py"),
                    "--repo",
                    str(root),
                    "--report",
                    FEATURE_QUALIFICATION_REPORT_SOURCE_PATH,
                ],
                cwd=REPOSITORY_ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(canonical_snapshot.returncode, 0)
            self.assertIn(
                "no reviewed snapshot-safe semantic contract",
                canonical_snapshot.stderr.decode(),
            )
            self.assertEqual(counter.read_text(), "3")

    def test_gate_finalization_and_completion_paths_revalidate_ledger_bound_criteria(self) -> None:
        run_gate = (SCRIPT_ROOT / "run_gate.py").read_text()
        verifier = (SCRIPT_ROOT / "verify_completion.py").read_text()
        statectl = (SCRIPT_ROOT / "statectl.py").read_text()
        handler = (PACKAGE_ROOT / "state/gate-handlers/G10.sh").read_text()
        for source in (run_gate, verifier, statectl):
            self.assertIn("validate_p10_feature_binding", source)
        self.assertIn("p10_feature_binding", run_gate)
        self.assertIn("g10-p10-feature-evidence-binding", verifier)
        self.assertIn("FORGE_P10_BINDING_OUTPUT", handler)
        self.assertIn("--p10-feature-binding", handler)


if __name__ == "__main__":
    unittest.main()
