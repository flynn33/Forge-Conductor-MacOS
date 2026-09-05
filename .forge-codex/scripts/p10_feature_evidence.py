#!/usr/bin/env python3
"""Bounded P10 feature evidence loading, semantics, and deterministic sealing."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
import base64
import binascii
import hashlib
import json
import pathlib
import re
import shlex
import p10_native_cli_scenario as native_cli
from p10_source_candidate import validate_source_candidate
from typing import Any

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:  # pragma: no cover - a qualification host must provide it
    Draft202012Validator = None
    FormatChecker = None

from evidence_support import (
    BoundedReadBudget,
    EvidenceSupportError,
    decode_strict_json_object,
    read_bounded_repository_bytes,
    source_manifest,
)
from p10_feature_baseline import (
    EXACT_CURRENT_PRODUCTION_EVIDENCE_KIND,
    EXPECTED_QUALIFIER,
    EXPECTED_REGISTRY_SHA256,
    EXPECTED_SIGNING_ARTIFACTS,
    EXPECTED_TOOL_PACK_MEMBERS,
    EXPECTED_FEATURE_QUALIFIER_SHA256,
    EXPECTED_PRODUCTION_PROBE_REGISTRY_SHA256,
    FEATURE_BASELINE_PATH,
    FEATURE_QUALIFICATION_REPORT_SOURCE_PATH,
    FEATURE_QUALIFICATION_SCHEMA_PATH,
    FEATURE_QUALIFIER_PATH,
    FEATURE_REGISTRY_PATH,
    FEATURE_ID_PATTERN,
    PRODUCTION_PROBE_REGISTRY_PATH,
    HISTORICAL_STATIC_INVENTORY_PATH,
    EXPECTED_HISTORICAL_STATIC_FEATURE_COUNT,
    EXPECTED_HISTORICAL_STATIC_INVENTORY_SHA256,
    FeatureBaselineEvaluation,
    canonical_json_sha256,
    signing_artifact_from_assertion,
    validate_feature_baseline,
)
from qualify_p10_features import (
    MAXIMUM_OBSERVATION_BYTES_PER_SCENARIO,
    OBSERVATION_PATH,
    derive_installation_facts,
    derive_signing_fact,
    evaluate_probe_artifact,
    installation_contract_valid,
    installed_cli_contract_valid,
    probe_environment,
    runner_argv,
    runner_identity,
    validate_provider_fact,
)


MAXIMUM_CONTROL_BYTES = 1024 * 1024
MAXIMUM_CONTROL_TOTAL_BYTES = 64 * 1024 * 1024
MAXIMUM_EVIDENCE_FILE_BYTES = 64 * 1024 * 1024
MAXIMUM_EVIDENCE_TOTAL_BYTES = 512 * 1024 * 1024
MAXIMUM_ARTIFACTS_PER_RECORD = 256
MAXIMUM_EVIDENCE_RECORDS = 104
EXPECTED_RECORDER_STREAM_BYTES = 64 * 1024 * 1024
MAXIMUM_RECORDER_SECONDS = 1560
SHA256 = re.compile(r"[0-9a-f]{64}")
SELECTOR_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,250}")
EXPECTED_PROBE_REGISTRY_KEYS = {
    "schema_version", "registry_id", "feature_registry_sha256", "qualifier",
    "allowlisted_runner_kinds", "limits", "implemented_scenarios",
}
EXPECTED_SCENARIO_KEYS = {"scenario_id", "assertions", "runner", "installation"}
EXPECTED_SCENARIO_ASSERTION_KEYS = {
    "feature_id", "assertion_id", "selector", "evidence_kind", "expected",
}
EXPECTED_RUNNER_KINDS = ["repository_qualification", native_cli.RUNNER_KIND]
EXPECTED_PROBE_LIMITS = {
    "maximum_matrix_seconds": 1500,
    "maximum_probe_stream_bytes": 65536,
    "maximum_observation_bytes_per_scenario": 262144,
    "maximum_total_raw_output_bytes": 8388608,
    "maximum_unique_runners": 64,
}
EXPECTED_RECEIPT_KEYS = {
    "schema_version", "kind", "scenario_id", "assertions", "runner",
    "runner_argv", "runner_environment", "started_at", "ended_at", "exit_code", "timed_out",
    "stream_limit_exceeded", "executed_tests", "observed_assertions",
    "stdout_base64", "stderr_base64", "challenge_nonce",
    "observation_sha256", "observation_bytes",
}


@dataclass
class P10FeatureEvidenceEvaluation:
    baseline: dict[str, Any]
    baseline_evaluation: FeatureBaselineEvaluation
    failures: list[str]
    binding: dict[str, Any]


def _timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 128:
        return None
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed


def _load_json(
    repository: pathlib.Path,
    relative: str,
    *,
    label: str,
    budget: BoundedReadBudget,
    maximum_bytes: int = MAXIMUM_CONTROL_BYTES,
) -> tuple[dict[str, Any], bytes]:
    raw = read_bounded_repository_bytes(
        repository,
        relative,
        label=label,
        maximum_bytes=maximum_bytes,
        budget=budget,
    )
    return decode_strict_json_object(raw, label=label), raw


def _file_binding(path: str, raw: bytes) -> dict[str, Any]:
    return {
        "path": path,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "bytes": len(raw),
    }


def _historical_binding(document: dict[str, Any], raw: bytes) -> dict[str, Any]:
    features = document.get("features")
    features = features if isinstance(features, list) else []
    return {
        **_file_binding(HISTORICAL_STATIC_INVENTORY_PATH, raw),
        "schema_version": document.get("schema_version"),
        "feature_count": len(features),
        "parity_summary": document.get("parity_summary"),
        "authority": "historical_discovery_only",
    }


def _schema_failures(
    report: dict[str, Any],
    schema: dict[str, Any],
    *,
    label: str,
) -> list[str]:
    if Draft202012Validator is None or FormatChecker is None:
        return [f"{label} schema runtime is unavailable"]
    try:
        Draft202012Validator.check_schema(schema)
        errors = sorted(
            Draft202012Validator(
                schema,
                format_checker=FormatChecker(),
            ).iter_errors(report),
            key=lambda item: tuple(str(part) for part in item.absolute_path),
        )
    except Exception as error:
        return [f"{label} schema validation failed closed: {error}"]
    failures: list[str] = []
    if errors:
        failures.append(f"{label} does not conform to its exact typed schema")
        for error in errors[:12]:
            location = ".".join(str(part) for part in error.absolute_path) or "<root>"
            failures.append(f"{label} schema error at {location}: {error.message}")
        if len(errors) > 12:
            failures.append(f"{label} schema has {len(errors) - 12} additional errors")
    return failures


def _cached_signing_revalidation(
    cache: dict[str, tuple[dict[str, Any] | None, dict[str, Any] | None]],
    *,
    selector: str,
    binding: dict[str, Any],
    installation: dict[str, Any],
    observed_signing: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    """Revalidate one canonical installed-artifact signing receipt once."""

    if selector not in cache:
        signing_from_receipt = observed_signing.get(selector)
        try:
            current_signing = derive_signing_fact(binding, installation)
        except (OSError, EvidenceSupportError):
            current_signing = None
        cache[selector] = (signing_from_receipt, current_signing)
    return cache[selector]


def _validate_probe_registry(
    repository: pathlib.Path,
    probe_registry: dict[str, Any],
    *,
    probe_registry_artifact: dict[str, Any],
    qualifier_artifact: dict[str, Any],
    registry_features: dict[str, dict[str, Any]],
    canonical_feature_registry: bool,
) -> tuple[list[str], dict[str, dict[str, Any]], list[str]]:
    failures: list[str] = []
    probes: dict[str, dict[str, Any]] = {}
    required = {
        assertion_id: feature_id
        for feature_id, feature in registry_features.items()
        for assertion_id in feature.get("required_assertions", [])
    }
    if set(probe_registry) != EXPECTED_PROBE_REGISTRY_KEYS:
        failures.append("P10 production probe registry key set is not exact")
    if type(probe_registry.get("schema_version")) is not int or probe_registry.get("schema_version") != 1:
        failures.append("P10 production probe registry schema is unsupported")
    if probe_registry.get("registry_id") != "forge-conductor-p10-production-probes":
        failures.append("P10 production probe registry identifier is unsupported")
    if probe_registry.get("feature_registry_sha256") != EXPECTED_REGISTRY_SHA256:
        failures.append("P10 production probe registry is not bound to the canonical feature registry")
    if probe_registry.get("allowlisted_runner_kinds") != EXPECTED_RUNNER_KINDS:
        failures.append("P10 production probe runner allowlist is unsupported")
    if probe_registry.get("limits") != EXPECTED_PROBE_LIMITS:
        failures.append("P10 production probe aggregate bounds are unsupported")
    expected_qualifier = {
        **EXPECTED_QUALIFIER,
        "source_path": FEATURE_QUALIFIER_PATH,
        "source_sha256": EXPECTED_FEATURE_QUALIFIER_SHA256,
    }
    if probe_registry.get("qualifier") != expected_qualifier:
        failures.append("P10 production probe qualifier binding is stale or malformed")
    if probe_registry_artifact != {
        "path": PRODUCTION_PROBE_REGISTRY_PATH,
        "sha256": EXPECTED_PRODUCTION_PROBE_REGISTRY_SHA256,
        "bytes": probe_registry_artifact.get("bytes"),
    } or type(probe_registry_artifact.get("bytes")) is not int or probe_registry_artifact["bytes"] < 1:
        failures.append("P10 production probe registry artifact is not canonical")
    if qualifier_artifact != {
        "path": FEATURE_QUALIFIER_PATH,
        "sha256": EXPECTED_FEATURE_QUALIFIER_SHA256,
        "bytes": qualifier_artifact.get("bytes"),
    } or type(qualifier_artifact.get("bytes")) is not int or qualifier_artifact["bytes"] < 1:
        failures.append("P10 production qualifier artifact is not canonical")
    implemented = probe_registry.get("implemented_scenarios")
    if not isinstance(implemented, list) or len(implemented) > EXPECTED_PROBE_LIMITS["maximum_unique_runners"]:
        failures.append("P10 production probe inventory is malformed")
        implemented = []
    scenario_ids: list[str] = []
    runner_hashes: list[str] = []
    ordinary_selectors: list[str] = []
    signing_artifact_selectors: set[str] = set()
    signing_contracts: dict[str, dict[str, Any]] = {}
    signing_owner_scenarios: dict[str, str] = {}
    for index, scenario in enumerate(implemented):
        label = f"P10 production scenario {index}"
        if not isinstance(scenario, dict) or set(scenario) != EXPECTED_SCENARIO_KEYS:
            failures.append(f"{label} key set is not exact")
            continue
        scenario_id = scenario.get("scenario_id")
        if not isinstance(scenario_id, str) or FEATURE_ID_PATTERN.fullmatch(scenario_id) is None:
            failures.append(f"{label} has an invalid scenario identifier")
            continue
        scenario_ids.append(scenario_id)
        runner_hashes.append(runner_identity(scenario))
        try:
            runner_argv(repository, scenario)
        except (OSError, EvidenceSupportError, ValueError) as error:
            failures.append(f"{label} concrete runner is invalid: {error}")
            continue
        native_scenario = native_cli.scenario_valid(scenario)
        installation_contract = native_cli.bound_probe(pathlib.Path("/validated/Forge Conductor.app"))["installation"] if native_scenario else scenario.get("installation")
        if not installation_contract_valid(installation_contract):
            failures.append(f"{label} has no exact installed-product contract")
            continue
        if pathlib.PurePosixPath(installation_contract["root"]).name != "Forge Conductor.app":
            failures.append(f"{label} installation root is not a canonical Forge Conductor app bundle")
            continue
        declared_artifacts = {
            item.get("artifact_id")
            for item in scenario["installation"].get("artifacts", [])
            if isinstance(item, dict)
        }
        if declared_artifacts != set(EXPECTED_SIGNING_ARTIFACTS):
            failures.append(f"{label} installation contract does not bind the coherent shipped artifact set")
            continue
        expected_installation_artifacts = [
            {
                "artifact_id": artifact_id,
                "relative_path": definition["relative_path"],
                "kind": definition["installation_kind"],
            }
            for artifact_id, definition in EXPECTED_SIGNING_ARTIFACTS.items()
        ]
        if scenario["installation"].get("artifacts") != expected_installation_artifacts:
            failures.append(f"{label} installation paths do not match the canonical app bundle layout")
            continue
        assertions = scenario.get("assertions")
        if not isinstance(assertions, list) or not assertions or len(assertions) > len(required):
            failures.append(f"{label} assertion mapping is malformed")
            continue
        kind = scenario["runner"].get("kind")
        for assertion_index, binding in enumerate(assertions):
            assertion_label = f"{label} assertion {assertion_index}"
            if not isinstance(binding, dict) or set(binding) != EXPECTED_SCENARIO_ASSERTION_KEYS:
                failures.append(f"{assertion_label} key set is not exact")
                continue
            feature_id = binding.get("feature_id")
            assertion_id = binding.get("assertion_id")
            selector = binding.get("selector")
            evidence_kind = binding.get("evidence_kind")
            expected = binding.get("expected")
            if required.get(assertion_id) != feature_id:
                failures.append(f"{assertion_label} is not authoritative")
                continue
            if assertion_id in probes:
                failures.append(f"{assertion_label} duplicates an authoritative assertion")
                continue
            if not isinstance(selector, str) or SELECTOR_PATTERN.fullmatch(selector) is None:
                failures.append(f"{assertion_label} selector is invalid")
                continue
            if evidence_kind not in {
                "installed-cli-transcript", "codesign-identity", "lmstudio-nonce-transcript", "native-cli-version-help",
            } or not isinstance(expected, dict) or not expected:
                failures.append(f"{assertion_label} has no exact typed evidence contract")
                continue
            if assertion_id.endswith(".production-path"):
                feature_category = registry_features.get(feature_id, {}).get("category")
                if feature_category != "cli":
                    failures.append(
                        f"{assertion_label} has no trusted ordinary adapter for its non-CLI surface"
                    )
                    continue
                if native_scenario and binding == native_cli.SCENARIO["assertions"][0]:
                    ordinary_selectors.append(selector)
                    probes[assertion_id] = {"scenario": scenario, "binding": binding}
                    continue
                if canonical_feature_registry:
                    failures.append(
                        f"{assertion_label} has no reviewed snapshot-safe semantic contract"
                    )
                    continue
                if evidence_kind != "installed-cli-transcript" or not installed_cli_contract_valid(expected):
                    failures.append(
                        f"{assertion_label} is not bound to the trusted installed CLI adapter"
                    )
                    continue
                if expected.get("artifact_id") not in declared_artifacts:
                    failures.append(f"{assertion_label} does not name an installed artifact")
                    continue
            signing_artifact = signing_artifact_from_assertion(assertion_id)
            if signing_artifact is not None:
                authoritative_artifact = registry_features.get(feature_id, {}).get("signing_artifact")
                expected_selector = f"signing.{signing_artifact}"
                if signing_artifact != authoritative_artifact or selector != expected_selector:
                    failures.append(
                        f"{assertion_label} does not identify the feature's authoritative shipped signing artifact"
                    )
                    continue
                signing_artifact_selectors.add(selector)
                prior_contract = signing_contracts.setdefault(selector, expected)
                if prior_contract != expected:
                    failures.append(
                        f"{assertion_label} disagrees with the shared signing receipt contract"
                    )
                    continue
                prior_owner = signing_owner_scenarios.setdefault(selector, scenario_id)
                if prior_owner != scenario_id:
                    failures.append(
                        f"{assertion_label} assigns one canonical signing receipt to multiple owner scenarios"
                    )
                    continue
            else:
                ordinary_selectors.append(selector)
            if signing_artifact is not None and evidence_kind != "codesign-identity":
                failures.append(f"{assertion_label} is not bound to independently derived signing evidence")
                continue
            if signing_artifact is not None and (
                set(expected) != {"artifact_id", "team_id", "identifier", "hardened_runtime"}
                or expected.get("artifact_id") != signing_artifact
                or not isinstance(expected.get("team_id"), str)
                or re.fullmatch(r"[A-Z0-9]{10}", expected["team_id"]) is None
                or not isinstance(expected.get("identifier"), str)
                or not expected["identifier"]
                or type(expected.get("hardened_runtime")) is not bool
            ):
                failures.append(f"{assertion_label} has no exact expected signing identity")
                continue
            if isinstance(assertion_id, str) and assertion_id.endswith(".real-provider") and evidence_kind != "lmstudio-nonce-transcript":
                failures.append(f"{assertion_label} is not bound to a live provider nonce transcript")
                continue
            if isinstance(assertion_id, str) and assertion_id.endswith(".real-provider"):
                endpoint = expected.get("endpoint")
                if (
                    set(expected) != {"endpoint", "model", "timeout_seconds"}
                    or not isinstance(endpoint, str)
                    or not endpoint.startswith(("http://127.0.0.1:", "http://localhost:", "http://[::1]:"))
                    or not endpoint.endswith("/v1/chat/completions")
                    or not isinstance(expected.get("model"), str)
                    or not expected["model"]
                    or type(expected.get("timeout_seconds")) is not int
                    or not (1 <= expected["timeout_seconds"] <= 60)
                ):
                    failures.append(f"{assertion_label} has no exact bounded provider contract")
                    continue
            probes[assertion_id] = {"scenario": scenario, "binding": binding}
    if len(scenario_ids) != len(set(scenario_ids)):
        failures.append("P10 production scenarios contain duplicate identifiers")
    if len(runner_hashes) != len(set(runner_hashes)):
        failures.append("P10 production scenarios repeat a runner instead of grouping its assertions")
    if (
        len(ordinary_selectors) != len(set(ordinary_selectors))
        or set(ordinary_selectors).intersection(signing_artifact_selectors)
    ):
        failures.append(
            "P10 ordinary assertions do not have globally distinct semantic selectors"
        )
    expected_signing_selectors = {
        f"signing.{artifact_id}" for artifact_id in EXPECTED_SIGNING_ARTIFACTS
    }
    if signing_artifact_selectors != expected_signing_selectors:
        missing_signing = sorted(expected_signing_selectors - signing_artifact_selectors)
        failures.append(
            "P10 production scenarios do not execute signing qualification for every shipped artifact: "
            + ", ".join(missing_signing)
        )
    missing = sorted(set(required) - set(probes))
    if missing:
        failures.append(
            f"P10 production probe registry has no concrete runner for {len(missing)} authoritative assertions"
        )
    return failures, probes, missing


def _decode_probe_receipts(
    raw: bytes,
    *,
    evidence_id: str,
) -> tuple[list[str], dict[str, dict[str, Any]]]:
    failures: list[str] = []
    receipts: dict[str, dict[str, Any]] = {}
    total_raw_output_bytes = 0
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return [f"production evidence {evidence_id} qualifier stdout is not UTF-8"], receipts
    for index, line in enumerate(text.splitlines()):
        if not line:
            continue
        label = f"production evidence {evidence_id} qualifier receipt {index}"
        try:
            receipt = decode_strict_json_object(line.encode("utf-8"), label=label)
        except EvidenceSupportError:
            failures.append(f"{label} is not strict JSON")
            continue
        if not isinstance(receipt, dict) or set(receipt) != EXPECTED_RECEIPT_KEYS:
            failures.append(f"{label} key set is not exact")
            continue
        scenario_id = receipt.get("scenario_id")
        if not isinstance(scenario_id, str) or scenario_id in receipts:
            failures.append(f"{label} has an invalid or duplicate scenario identifier")
            continue
        if receipt.get("schema_version") != 1 or receipt.get("kind") != "p10-production-probe-receipt":
            failures.append(f"{label} identity is unsupported")
        started = _timestamp(receipt.get("started_at"))
        ended = _timestamp(receipt.get("ended_at"))
        if started is None or ended is None or started > ended:
            failures.append(f"{label} timing is malformed")
        if type(receipt.get("exit_code")) is not int:
            failures.append(f"{label} exit code is not an exact integer")
        if type(receipt.get("executed_tests")) is not int or receipt.get("executed_tests", 0) < 1:
            failures.append(f"{label} did not execute an intended test or production probe")
        if type(receipt.get("observed_assertions")) is not int or receipt.get("observed_assertions", 0) < 1:
            failures.append(f"{label} did not observe a concrete assertion")
        if not isinstance(receipt.get("challenge_nonce"), str) or re.fullmatch(r"[0-9a-f]{64}", receipt["challenge_nonce"]) is None:
            failures.append(f"{label} challenge nonce is malformed")
        if not isinstance(receipt.get("observation_sha256"), str) or SHA256.fullmatch(receipt["observation_sha256"]) is None:
            failures.append(f"{label} observation digest is malformed")
        if type(receipt.get("observation_bytes")) is not int or not (
            1 <= receipt["observation_bytes"] <= MAXIMUM_OBSERVATION_BYTES_PER_SCENARIO
        ):
            failures.append(f"{label} observation byte count is invalid")
        if type(receipt.get("timed_out")) is not bool or type(receipt.get("stream_limit_exceeded")) is not bool:
            failures.append(f"{label} result booleans are malformed")
        for field in ("stdout_base64", "stderr_base64"):
            value = receipt.get(field)
            try:
                decoded = base64.b64decode(value, validate=True) if isinstance(value, str) else b""
            except (binascii.Error, ValueError):
                failures.append(f"{label} {field} is not canonical base64")
                continue
            if len(decoded) > 64 * 1024:
                failures.append(f"{label} {field} exceeds the per-probe bound")
            total_raw_output_bytes += len(decoded)
        receipts[scenario_id] = receipt
    if len(receipts) > EXPECTED_PROBE_LIMITS["maximum_unique_runners"]:
        failures.append(f"production evidence {evidence_id} exceeds the unique-runner bound")
    if total_raw_output_bytes > EXPECTED_PROBE_LIMITS["maximum_total_raw_output_bytes"]:
        failures.append(f"production evidence {evidence_id} exceeds the aggregate output bound")
    return failures, receipts


def _decode_observation_aggregate(
    raw: bytes,
    *,
    evidence_id: str,
) -> tuple[list[str], dict[str, tuple[bytes, dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]]]:
    label = f"production evidence {evidence_id} observation aggregate"
    try:
        aggregate = decode_strict_json_object(raw, label=label)
    except EvidenceSupportError as error:
        return [str(error)], {}
    if set(aggregate) != {"schema_version", "kind", "evidence_id", "scenarios"} or (
        aggregate.get("schema_version") != 1
        or aggregate.get("kind") != "p10-production-observation-aggregate"
        or aggregate.get("evidence_id") != evidence_id
    ):
        return [f"{label} identity is malformed"], {}
    scenarios = aggregate.get("scenarios")
    if not isinstance(scenarios, list) or len(scenarios) > EXPECTED_PROBE_LIMITS["maximum_unique_runners"]:
        return [f"{label} scenario inventory is malformed"], {}
    failures: list[str] = []
    documents: dict[str, tuple[bytes, dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]] = {}
    total = 0
    for index, item in enumerate(scenarios):
        item_label = f"{label} scenario {index}"
        if not isinstance(item, dict) or set(item) != {
            "scenario_id", "challenge_nonce", "sha256", "bytes", "document_base64",
            "installation", "signing", "providers",
        }:
            failures.append(f"{item_label} key set is not exact")
            continue
        scenario_id = item.get("scenario_id")
        try:
            document_raw = base64.b64decode(item.get("document_base64", ""), validate=True)
        except (binascii.Error, ValueError):
            failures.append(f"{item_label} document is not canonical base64")
            continue
        total += len(document_raw)
        if (
            not isinstance(scenario_id, str)
            or scenario_id in documents
            or item.get("bytes") != len(document_raw)
            or item.get("sha256") != hashlib.sha256(document_raw).hexdigest()
            or len(document_raw) > MAXIMUM_OBSERVATION_BYTES_PER_SCENARIO
        ):
            failures.append(f"{item_label} binding is malformed")
            continue
        try:
            document = decode_strict_json_object(document_raw, label=item_label)
        except EvidenceSupportError as error:
            failures.append(str(error))
            continue
        if document.get("challenge_nonce") != item.get("challenge_nonce"):
            failures.append(f"{item_label} challenge nonce is mismatched")
        if not isinstance(item.get("installation"), dict):
            failures.append(f"{item_label} has no derived installation receipt")
        if not isinstance(item.get("signing"), dict) or not isinstance(item.get("providers"), dict):
            failures.append(f"{item_label} sensitive fact maps are malformed")
        documents[scenario_id] = (
            document_raw,
            document,
            item.get("installation"),
            item.get("signing"),
            item.get("providers"),
        )
    if total > EXPECTED_PROBE_LIMITS["maximum_total_raw_output_bytes"]:
        failures.append(f"{label} exceeds the aggregate artifact bound")
    return failures, documents


def _validate_artifacts(
    repository: pathlib.Path,
    record: dict[str, Any],
    *,
    evidence_id: str,
    budget: BoundedReadBudget,
) -> tuple[list[str], list[dict[str, Any]], dict[str, bytes], str | None, str | None]:
    failures: list[str] = []
    bindings: list[dict[str, Any]] = []
    raw_by_path: dict[str, bytes] = {}
    report_paths: list[str] = []
    observation_paths: list[str] = []
    artifacts = record.get("artifacts")
    if not isinstance(artifacts, list) or not (3 <= len(artifacts) <= MAXIMUM_ARTIFACTS_PER_RECORD):
        return [f"production evidence {evidence_id} artifact inventory is malformed"], bindings, raw_by_path, None, None
    paths: list[str] = []
    for index, artifact in enumerate(artifacts):
        label = f"production evidence {evidence_id} artifact {index}"
        if not isinstance(artifact, dict):
            failures.append(f"{label} is not an object")
            continue
        storage = artifact.get("storage")
        expected_keys = (
            {"path", "source_path", "sha256", "bytes", "storage"}
            if storage == "evidence-id-specific-copy"
            else {"path", "sha256", "bytes", "storage"}
        )
        if storage not in {"evidence-id-specific-copy", "evidence-id-specific-stream"}:
            failures.append(f"{label} is not a repository-preserved artifact")
            continue
        if set(artifact) != expected_keys:
            failures.append(f"{label} key set is not exact")
        path = artifact.get("path")
        expected_hash = artifact.get("sha256")
        expected_bytes = artifact.get("bytes")
        if (
            not isinstance(path, str)
            or not path.startswith(f".forge-codex/evidence/{evidence_id}.")
            or pathlib.PurePosixPath(path).as_posix() != path
            or ".." in pathlib.PurePosixPath(path).parts
        ):
            failures.append(f"{label} path is not canonical and evidence-specific")
            continue
        paths.append(path)
        if not isinstance(expected_hash, str) or SHA256.fullmatch(expected_hash) is None:
            failures.append(f"{label} digest is invalid")
            continue
        if type(expected_bytes) is not int or not (0 <= expected_bytes <= MAXIMUM_EVIDENCE_FILE_BYTES):
            failures.append(f"{label} byte count is invalid")
            continue
        try:
            raw = read_bounded_repository_bytes(
                repository,
                path,
                label=label,
                maximum_bytes=MAXIMUM_EVIDENCE_FILE_BYTES,
                budget=budget,
            )
        except EvidenceSupportError as error:
            failures.append(f"{label} cannot be read: {error}")
            continue
        actual_hash = hashlib.sha256(raw).hexdigest()
        if len(raw) != expected_bytes or actual_hash != expected_hash:
            failures.append(f"{label} content does not match its recorder binding")
        raw_by_path[path] = raw
        bindings.append({"path": path, "sha256": actual_hash, "bytes": len(raw)})
        if artifact.get("source_path") == FEATURE_QUALIFICATION_REPORT_SOURCE_PATH:
            report_paths.append(path)
        if artifact.get("source_path") == OBSERVATION_PATH:
            observation_paths.append(path)
    if len(paths) != len(set(paths)):
        failures.append(f"production evidence {evidence_id} repeats an artifact path")
    if len(report_paths) != 1:
        failures.append(f"production evidence {evidence_id} has no unique typed qualification report")
    if len(observation_paths) != 1:
        failures.append(f"production evidence {evidence_id} has no unique typed observation artifact")
    return (
        failures,
        bindings,
        raw_by_path,
        report_paths[0] if len(report_paths) == 1 else None,
        observation_paths[0] if len(observation_paths) == 1 else None,
    )


def _validate_record_and_report(
    record: dict[str, Any],
    report: dict[str, Any],
    *,
    evidence_id: str,
    expected_features: set[str],
    registry_features: dict[str, dict[str, Any]],
    current_manifest: dict[str, Any],
    current_git_head: str,
    registry_sha256: str,
    probe_registry_sha256: str,
    qualifier_sha256: str,
    baseline_sha256: str,
    repository: pathlib.Path,
    artifact_bindings: list[dict[str, Any]],
    qualification_report_path: str,
    stdout_artifact_path: str,
    observation_artifact_path: str,
    production_probes: dict[str, dict[str, Any]],
    probe_receipts: dict[str, dict[str, Any]],
    probe_observations: dict[str, tuple[bytes, dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]],
) -> tuple[list[str], list[dict[str, Any]]]:
    label = f"production evidence {evidence_id}"
    failures: list[str] = []
    expected_record_keys = {
        "schema_version", "id", "kind", "command", "exit_code", "timed_out",
        "stream_limit_exceeded", "maximum_stream_bytes", "started_at", "ended_at",
        "environment", "execution_provenance", "child_evidence_context",
        "source_manifest", "source_manifest_after", "source_manifest_changed",
        "artifacts", "artifact_capture_errors", "ledger_reference",
        "related_findings", "related_gates",
    }
    if set(record) != expected_record_keys:
        failures.append(f"{label} recorder key set is not exact")
    if type(record.get("schema_version")) is not int or record.get("schema_version") != 2:
        failures.append(f"{label} is not recorded schema v2")
    if record.get("id") != evidence_id:
        failures.append(f"{label} evidence ID is mismatched")
    if record.get("kind") != EXACT_CURRENT_PRODUCTION_EVIDENCE_KIND:
        failures.append(f"{label} kind is unsupported")
    if record.get("related_gates") != ["G10"]:
        failures.append(f"{label} is not exclusively bound to G10")
    related_findings = record.get("related_findings")
    if not isinstance(related_findings, list) or len(related_findings) != len(set(related_findings)) or any(
        not isinstance(item, str) or not item for item in related_findings
    ):
        failures.append(f"{label} related findings are malformed")
    if type(record.get("exit_code")) is not int or record.get("exit_code") != 0:
        failures.append(f"{label} did not exit zero")
    if record.get("timed_out") is not False:
        failures.append(f"{label} timed out")
    if record.get("stream_limit_exceeded") is not False:
        failures.append(f"{label} exceeded its stream limit")
    if record.get("maximum_stream_bytes") != EXPECTED_RECORDER_STREAM_BYTES:
        failures.append(f"{label} stream bound is invalid")
    if record.get("artifact_capture_errors") != []:
        failures.append(f"{label} has artifact capture errors")
    if record.get("ledger_reference") != {"status": "recorded", "exit_code": 0}:
        failures.append(f"{label} ledger receipt is malformed")
    if record.get("source_manifest_changed") is not False:
        failures.append(f"{label} changed source during capture")
    if record.get("source_manifest") != current_manifest or record.get("source_manifest_after") != current_manifest:
        failures.append(f"{label} source manifest is stale")
    started = _timestamp(record.get("started_at"))
    ended = _timestamp(record.get("ended_at"))
    if started is None or ended is None or started > ended:
        failures.append(f"{label} recorder timing is malformed")
    elif (ended - started).total_seconds() > MAXIMUM_RECORDER_SECONDS:
        failures.append(f"{label} recorder exceeded its exact total deadline")

    command = report.get("command") if isinstance(report.get("command"), dict) else {}
    argv = command.get("argv")
    expected_argv = [
        str(repository / FEATURE_QUALIFIER_PATH),
        "--report",
        FEATURE_QUALIFICATION_REPORT_SOURCE_PATH,
    ]
    selection = report.get("selection")
    if selection is not None:
        required_ids = {assertion for feature in registry_features.values() for assertion in feature.get("required_assertions", [])}
        expected_selection = {
            "feature_ids": [native_cli.FEATURE_ID], "scope": native_cli.SCOPE,
            "distribution_qualified": False, "global_required_assertion_count": len(required_ids),
            "global_missing_assertion_ids": sorted(required_ids - set(registry_features.get(native_cli.FEATURE_ID, {}).get("required_assertions", []))),
            "build_evidence_id": selection.get("build_evidence_id") if isinstance(selection, dict) else None,
            "installation_evidence_id": selection.get("installation_evidence_id") if isinstance(selection, dict) else None,
        }
        if selection != expected_selection or expected_features != {native_cli.FEATURE_ID}:
            failures.append(f"{label} selected feature scope is not exact")
        elif any(not isinstance(selection[key], str) or re.fullmatch(r"EVID-[A-Za-z0-9_-]{1,128}", selection[key]) is None for key in ("build_evidence_id", "installation_evidence_id")):
            failures.append(f"{label} selected feature provenance IDs are malformed")
        else:
            expected_argv.extend(["--feature", native_cli.FEATURE_ID, "--build-evidence", selection["build_evidence_id"], "--installation-evidence", selection["installation_evidence_id"]])
    if argv != expected_argv or record.get("command") != shlex.join(expected_argv):
        failures.append(f"{label} did not execute the exact known qualifier command")
    if command.get("exit_code") != 0 or command.get("timed_out") is not False or command.get("stream_limit_exceeded") is not False:
        failures.append(f"{label} qualifier command result is nonpassing")
    if report.get("qualifier") != EXPECTED_QUALIFIER:
        failures.append(f"{label} qualifier identity or version is unsupported")
    report_timing = report.get("timing") if isinstance(report.get("timing"), dict) else {}
    report_started = _timestamp(report_timing.get("started_at"))
    report_ended = _timestamp(report_timing.get("ended_at"))
    if (
        started is None
        or ended is None
        or report_started is None
        or report_ended is None
        or not (started <= report_started <= report_ended <= ended)
    ):
        failures.append(f"{label} report timing is not contained by recorder timing")
    elif (report_ended - report_started).total_seconds() > EXPECTED_PROBE_LIMITS["maximum_matrix_seconds"]:
        failures.append(f"{label} report exceeded its exact matrix deadline")

    provenance = record.get("execution_provenance")
    repository_provenance = provenance.get("repository") if isinstance(provenance, dict) else None
    test_environment = provenance.get("test_environment") if isinstance(provenance, dict) else None
    if not isinstance(repository_provenance, dict) or not isinstance(test_environment, dict):
        failures.append(f"{label} execution provenance is malformed")
    else:
        try:
            validate_source_candidate(repository, repository_provenance.get("head_sha"), current_git_head, record.get("source_manifest"), current_manifest)
        except EvidenceSupportError as error:
            failures.append(f"{label} source candidate is invalid: {error}")
        if repository_provenance.get("repository_path") != str(repository):
            failures.append(f"{label} repository path is stale")
        if not all(
            isinstance(repository_provenance.get(key), str) and repository_provenance.get(key)
            for key in ("branch", "head_sha", "base_branch", "base_sha", "repository_path")
        ):
            failures.append(f"{label} repository provenance fields are malformed")
        if not all(
            isinstance(test_environment.get(key), str) and test_environment.get(key)
            for key in ("macos_build", "machine_identifier", "platform", "architecture")
        ):
            failures.append(f"{label} test environment provenance fields are malformed")
    report_environment = report.get("environment")
    configuration = report_environment.get("configuration") if isinstance(report_environment, dict) else None
    installations = [item[2] for item in probe_observations.values()]
    installation_receipt = installations[0] if installations and all(
        item == installations[0] for item in installations
    ) else None
    expected_report_environment = {
        "repository": str(repository),
        "platform": test_environment.get("platform") if isinstance(test_environment, dict) else None,
        "architecture": test_environment.get("architecture") if isinstance(test_environment, dict) else None,
        "macos_build": test_environment.get("macos_build") if isinstance(test_environment, dict) else None,
        "machine_identifier": test_environment.get("machine_identifier") if isinstance(test_environment, dict) else None,
        "configuration": configuration,
        "installed_product": True,
        "installation_receipt": installation_receipt,
    }
    if report_environment != expected_report_environment:
        failures.append(f"{label} report environment does not match recorder provenance")
    if installation_receipt is None:
        failures.append(f"{label} has no independently derived coherent installation receipt")
    expected_record_environment = {
        "platform": expected_report_environment["platform"],
        "architecture": expected_report_environment["architecture"],
        "macos_build": expected_report_environment["macos_build"],
        "machine_identifier": expected_report_environment["machine_identifier"],
        "cwd": str(repository),
    }
    if record.get("environment") != expected_record_environment:
        failures.append(f"{label} recorder environment is malformed")
    if report.get("source_identity") != {
        "git_head": repository_provenance.get("head_sha") if isinstance(repository_provenance, dict) else None,
        "source_manifest": current_manifest,
        "registry_sha256": registry_sha256,
        "probe_registry_sha256": probe_registry_sha256,
        "qualifier_sha256": qualifier_sha256,
        "baseline_sha256": baseline_sha256,
    }:
        failures.append(f"{label} report source identity is stale or malformed")
    child = record.get("child_evidence_context")
    expected_child = {
        "schema_version": 1,
        "binding_schema_version": 1,
        "evidence_id": evidence_id,
        "source_manifest": current_manifest,
        "repository": repository_provenance,
        "test_environment": test_environment,
    }
    if child != expected_child:
        failures.append(f"{label} child evidence context is stale or malformed")

    results = report.get("results")
    rows = results if isinstance(results, list) else []
    row_ids = [row.get("feature_id") for row in rows if isinstance(row, dict)]
    if len(rows) != len(expected_features) or set(row_ids) != expected_features or len(row_ids) != len(set(row_ids)):
        failures.append(f"{label} does not have one distinct semantic row per feature")
    execution = report.get("execution") if isinstance(report.get("execution"), dict) else {}
    row_bindings: list[dict[str, Any]] = []
    total_assertions = 0
    signing_revalidation_cache: dict[
        str, tuple[dict[str, Any] | None, dict[str, Any] | None]
    ] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        feature_id = row.get("feature_id")
        authority = registry_features.get(feature_id)
        assertions = row.get("assertions") if isinstance(row.get("assertions"), list) else []
        total_assertions += len(assertions)
        expected_assertions = authority.get("required_assertions") if isinstance(authority, dict) else None
        assertion_ids = [item.get("id") for item in assertions if isinstance(item, dict)]
        if assertion_ids != expected_assertions:
            failures.append(f"{label} feature {feature_id} assertion matrix is not authoritative")
        if type(row.get("assertion_count")) is not int or row.get("assertion_count") != len(assertions):
            failures.append(f"{label} feature {feature_id} assertion count is mismatched")
        if type(row.get("execution_count")) is not int or row.get("execution_count") != sum(
            item.get("executed_tests", 0) for item in assertions if isinstance(item, dict)
        ):
            failures.append(f"{label} feature {feature_id} execution count is mismatched")
        signing_from_receipt: dict[str, Any] | None = None
        provider_from_receipt: dict[str, Any] | None = None
        for assertion in assertions:
            if not isinstance(assertion, dict):
                continue
            assertion_id = assertion.get("id")
            probe_entry = production_probes.get(assertion_id)
            references = assertion.get("artifact_references")
            if probe_entry is None:
                failures.append(f"{label} feature {feature_id} has no recorder-owned allowlisted probe receipt")
                continue
            probe = probe_entry["scenario"]
            assertion_binding = probe_entry["binding"]
            receipt = probe_receipts.get(probe.get("scenario_id"))
            observation_entry = probe_observations.get(probe.get("scenario_id"))
            if receipt is None or observation_entry is None:
                failures.append(f"{label} feature {feature_id} has no recorder-owned allowlisted probe receipt")
                continue
            (
                observation_raw,
                observation_document,
                observed_installation,
                observed_signing,
                observed_providers,
            ) = observation_entry
            try:
                if probe.get("runner", {}).get("kind") == native_cli.RUNNER_KIND:
                    probe = native_cli.probe_from_observation(probe, observation_document)
                    native_results = [item for item in observation_document["results"] if item.get("selector") == "cli.version-help"]
                    transcript = native_results[0]["transcript"]
                    native_started, native_ended = _timestamp(transcript.get("started_at")), _timestamp(transcript.get("ended_at"))
                    outer_started, outer_ended = _timestamp(receipt.get("started_at")), _timestamp(receipt.get("ended_at"))
                    if None in (native_started, native_ended, outer_started, outer_ended) or not (outer_started <= native_started <= native_ended <= outer_ended):
                        failures.append(f"{label} native CLI transcript timing is outside its captured scenario")
                    if not isinstance(selection, dict) or any(native_results[0]["provenance"].get(key) != selection.get(key) for key in ("build_evidence_id", "installation_evidence_id")):
                        failures.append(f"{label} selected feature provenance is not bound to its transcript")
                expected_runner_argv, _ = runner_argv(repository, probe)
            except (OSError, EvidenceSupportError, ValueError, KeyError, TypeError, IndexError, AttributeError) as error:
                failures.append(f"{label} feature {feature_id} probe runner is invalid: {error}")
                continue
            try:
                current_installation = derive_installation_facts(
                    probe,
                    observation_document,
                    require_live_process=False,
                )
            except (OSError, EvidenceSupportError):
                current_installation = None
            observed_pass, observed_executions, result_by_selector, result_document = evaluate_probe_artifact(
                probe,
                observation_raw,
                evidence_id=evidence_id,
                challenge_nonce=receipt.get("challenge_nonce"),
                installation=current_installation,
                repository=repository,
            )
            selected_result = result_by_selector.get(assertion_binding.get("selector"))
            expected_assertion_observations = 1 if isinstance(selected_result, dict) else 0
            receipt_started = _timestamp(receipt.get("started_at"))
            receipt_ended = _timestamp(receipt.get("ended_at"))
            probe_timeout = probe.get("runner", {}).get("timeout_seconds")
            if (
                assertion.get("scenario_id") != probe.get("scenario_id")
                or assertion.get("selector") != assertion_binding.get("selector")
                or assertion.get("runner_kind") != probe["runner"].get("kind")
                or assertion.get("runner_argv") != expected_runner_argv
                or assertion.get("executed_tests") != receipt.get("executed_tests")
                or assertion.get("observed_assertions") != expected_assertion_observations
                or type(receipt.get("executed_tests")) is not int
                or receipt.get("executed_tests", 0) < 1
                or type(receipt.get("observed_assertions")) is not int
                or receipt.get("observed_assertions", 0) < 1
                or references != [{
                    "source_path": OBSERVATION_PATH,
                    "scenario_id": probe.get("scenario_id"),
                    "selector": assertion_binding.get("selector"),
                    "sha256": receipt.get("observation_sha256"),
                }]
                or receipt.get("scenario_id") != probe.get("scenario_id")
                or receipt.get("assertions") != probe.get("assertions")
                or receipt.get("runner") != probe.get("runner")
                or receipt.get("runner_argv") != expected_runner_argv
                or receipt.get("runner_environment") != probe_environment()
                or receipt.get("observation_sha256") != hashlib.sha256(observation_raw).hexdigest()
                or receipt.get("observation_bytes") != len(observation_raw)
                or current_installation != observed_installation
                or receipt_started is None
                or receipt_ended is None
                or receipt_started > receipt_ended
                or type(probe_timeout) is not int
                or (receipt_ended - receipt_started).total_seconds() > probe_timeout + 1
                or report_started is None
                or report_ended is None
                or not (report_started <= receipt_started <= receipt_ended <= report_ended)
                or receipt.get("exit_code") != 0
                or receipt.get("timed_out") is not False
                or receipt.get("stream_limit_exceeded") is not False
                or observed_pass is not True
                or receipt.get("executed_tests") != observed_executions
                or receipt.get("observed_assertions") != len(result_by_selector)
                or assertion.get("execution_receipt_sha256") != canonical_json_sha256(receipt)
                or assertion.get("passed") is not True
                or assertion.get("result") != "passed"
            ):
                failures.append(f"{label} feature {feature_id} assertion is not bound to a passing allowlisted probe receipt")
            signing_artifact = signing_artifact_from_assertion(assertion_id)
            if signing_artifact is not None or (
                isinstance(assertion_id, str) and assertion_id.endswith(".real-provider")
            ):
                if not isinstance(selected_result, dict):
                    failures.append(f"{label} feature {feature_id} sensitive probe result contract is invalid")
                elif signing_artifact is not None:
                    signing_selector = assertion_binding.get("selector")
                    if not isinstance(signing_selector, str):
                        signing_from_receipt = None
                        current_signing = None
                    else:
                        signing_from_receipt, current_signing = _cached_signing_revalidation(
                            signing_revalidation_cache,
                            selector=signing_selector,
                            binding=assertion_binding,
                            installation=current_installation or {},
                            observed_signing=observed_signing,
                        )
                    if signing_from_receipt != current_signing:
                        failures.append(f"{label} feature {feature_id} signing fact is not independently derived")
                else:
                    provider_from_receipt = observed_providers.get(assertion_binding.get("selector"))
                    if not validate_provider_fact(
                        assertion_binding,
                        observation_document,
                        provider_from_receipt,
                    ):
                        failures.append(f"{label} feature {feature_id} provider fact is not an independently parsed nonce transcript")
        signing = row.get("signing")
        if isinstance(authority, dict) and authority.get("signing_required") is True:
            if not isinstance(signing, dict) or not (
                signing.get("applicable") is True
                and signing.get("artifact_id") == authority.get("signing_artifact")
                and isinstance(signing.get("path"), str)
                and isinstance(signing.get("artifact_sha256"), str)
                and type(signing.get("artifact_bytes")) is int
                and isinstance(signing.get("team_id"), str)
                and isinstance(signing.get("identifier"), str)
                and isinstance(signing.get("cdhash"), str)
                and isinstance(signing.get("designated_requirement_sha256"), str)
                and type(signing.get("hardened_runtime")) is bool
            ):
                failures.append(f"{label} feature {feature_id} signing facts are incomplete")
            if signing != signing_from_receipt:
                failures.append(f"{label} feature {feature_id} signing facts are not probe-derived")
        elif isinstance(authority, dict) and signing != {
            "applicable": False,
            "artifact_id": None,
            "path": None,
            "artifact_sha256": None,
            "artifact_bytes": None,
            "team_id": None,
            "identifier": None,
            "cdhash": None,
            "designated_requirement_sha256": None,
            "hardened_runtime": None,
        }:
            failures.append(f"{label} feature {feature_id} signing nonapplicability is malformed")
        provider = row.get("provider")
        if isinstance(authority, dict) and authority.get("provider_required") is True:
            if not isinstance(provider, dict) or not (
                provider.get("applicable") is True
                and provider.get("kind") == "lm_studio"
                and provider.get("transport") == "http"
                and isinstance(provider.get("endpoint"), str)
                and isinstance(provider.get("model"), str)
                and provider.get("real_provider") is True
                and type(provider.get("provider_pid")) is int
                and isinstance(provider.get("provider_executable_path"), str)
                and isinstance(provider.get("provider_executable_sha256"), str)
                and type(provider.get("provider_executable_bytes")) is int
                and isinstance(provider.get("challenge_nonce"), str)
                and isinstance(provider.get("request_sha256"), str)
                and isinstance(provider.get("response_sha256"), str)
                and isinstance(provider.get("response_id"), str)
                and isinstance(provider.get("request_base64"), str)
                and isinstance(provider.get("response_base64"), str)
            ):
                failures.append(f"{label} feature {feature_id} provider facts are incomplete")
            if provider != provider_from_receipt:
                failures.append(f"{label} feature {feature_id} provider facts are not probe-derived")
        elif isinstance(authority, dict) and provider != {
            "applicable": False,
            "kind": "not_applicable",
            "transport": None,
            "endpoint": None,
            "model": None,
            "real_provider": False,
            "provider_pid": None,
            "provider_executable_path": None,
            "provider_executable_sha256": None,
            "provider_executable_bytes": None,
            "challenge_nonce": None,
            "request_sha256": None,
            "response_sha256": None,
            "response_id": None,
            "request_base64": None,
            "response_base64": None,
        }:
            failures.append(f"{label} feature {feature_id} provider nonapplicability is malformed")
        if isinstance(feature_id, str):
            row_bindings.append({"feature_id": feature_id, "semantic_row_sha256": canonical_json_sha256(row)})
    expected_scenarios = {
        production_probes[assertion_id]["scenario"]["scenario_id"]
        for feature_id in expected_features
        for assertion_id in registry_features[feature_id].get("required_assertions", [])
        if assertion_id in production_probes
    }
    if type(execution.get("count")) is not int or execution.get("count") != len(expected_scenarios):
        failures.append(f"{label} execution count is invalid")
    if (
        type(execution.get("assertion_count")) is not int
        or execution.get("assertion_count") != total_assertions
        or execution.get("passed_assertion_count") != total_assertions
        or execution.get("failed_assertion_count") != 0
    ):
        failures.append(f"{label} aggregate assertion results are nonpassing")
    if set(probe_receipts) != expected_scenarios:
        failures.append(f"{label} recorder stdout does not contain the exact required receipt set")
    if set(probe_observations) != expected_scenarios:
        failures.append(f"{label} typed observation artifact does not contain the exact required scenario set")
    return failures, sorted(row_bindings, key=lambda item: item["feature_id"])


def evaluate_p10_feature_evidence(
    repository: pathlib.Path,
    *,
    current_manifest: dict[str, Any],
    current_git_head: str,
    ledger_evidence_ids: set[str],
    expected_binding: Any | None = None,
) -> P10FeatureEvidenceEvaluation:
    repository = repository.resolve(strict=True)
    failures: list[str] = []
    control_budget = BoundedReadBudget(MAXIMUM_CONTROL_TOTAL_BYTES, "P10 feature controls")
    evidence_budget = BoundedReadBudget(MAXIMUM_EVIDENCE_TOTAL_BYTES, "P10 feature evidence")
    empty_evaluation = FeatureBaselineEvaluation(0, [], [], {}, [], {})
    try:
        baseline, baseline_raw = _load_json(repository, FEATURE_BASELINE_PATH, label="P10 feature baseline", budget=control_budget)
        registry, registry_raw = _load_json(repository, FEATURE_REGISTRY_PATH, label="P10 feature registry", budget=control_budget)
        historical, historical_raw = _load_json(repository, HISTORICAL_STATIC_INVENTORY_PATH, label="P10 historical static inventory", budget=control_budget)
        probe_registry, probe_registry_raw = _load_json(
            repository,
            PRODUCTION_PROBE_REGISTRY_PATH,
            label="P10 production probe registry",
            budget=control_budget,
        )
        schema, _ = _load_json(repository, FEATURE_QUALIFICATION_SCHEMA_PATH, label="P10 feature qualification schema", budget=control_budget)
        qualifier_raw = read_bounded_repository_bytes(
            repository,
            FEATURE_QUALIFIER_PATH,
            label="P10 production qualifier",
            maximum_bytes=MAXIMUM_CONTROL_BYTES,
            budget=control_budget,
        )
        current_feature_source = source_manifest(repository, excluded_paths=(FEATURE_BASELINE_PATH,))
    except EvidenceSupportError as error:
        return P10FeatureEvidenceEvaluation({}, empty_evaluation, [str(error)], {})
    registry_binding = _file_binding(FEATURE_REGISTRY_PATH, registry_raw)
    historical_binding = _historical_binding(historical, historical_raw)
    if historical_binding != {
        "path": HISTORICAL_STATIC_INVENTORY_PATH,
        "sha256": EXPECTED_HISTORICAL_STATIC_INVENTORY_SHA256,
        "bytes": len(historical_raw),
        "schema_version": 1,
        "feature_count": EXPECTED_HISTORICAL_STATIC_FEATURE_COUNT,
        "parity_summary": {
            "preserved": 0,
            "additive": 0,
            "migrated": 0,
            "unknown": EXPECTED_HISTORICAL_STATIC_FEATURE_COUNT,
            "removed": 0,
            "untested": EXPECTED_HISTORICAL_STATIC_FEATURE_COUNT,
        },
        "authority": "historical_discovery_only",
    }:
        failures.append(
            "historical G01 static inventory is not the pinned 98-entry discovery artifact"
        )
    baseline_evaluation = validate_feature_baseline(
        baseline,
        registry=registry,
        registry_artifact=registry_binding,
        current_source_snapshot=current_feature_source,
        historical_inventory_artifact=historical_binding,
    )
    failures.extend(baseline_evaluation.inventory_failures)
    failures.extend(baseline_evaluation.completion_blockers)
    historical_features = historical.get("features")
    historical_ids = {
        item.get("id") for item in historical_features
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    } if isinstance(historical_features, list) else set()
    historical_mapping = registry.get("historical_feature_mapping")
    if not isinstance(historical_mapping, dict) or set(historical_mapping) != historical_ids:
        failures.append("historical G01 features do not have an exact explicit current-registry mapping")
    elif {
        key for key, value in historical_mapping.items() if value is None
    } != {
        "MCP-A5A3AD85C6", "MCP-D13412AEA8", "MCP-10220416F0",
        "MCP-D3D3CDE3DB", "MEM-091BDBEC8D",
    }:
        failures.append("historical false-positive disposition set is not exact")
    probe_registry_binding = _file_binding(PRODUCTION_PROBE_REGISTRY_PATH, probe_registry_raw)
    qualifier_binding = _file_binding(FEATURE_QUALIFIER_PATH, qualifier_raw)
    probe_failures, production_probes, missing_probe_assertions = _validate_probe_registry(
        repository,
        probe_registry,
        probe_registry_artifact=probe_registry_binding,
        qualifier_artifact=qualifier_binding,
        registry_features=baseline_evaluation.registry_features,
        canonical_feature_registry=True,
    )
    failures.extend(probe_failures)
    baseline_binding = _file_binding(FEATURE_BASELINE_PATH, baseline_raw)
    evidence_to_features: dict[str, set[str]] = defaultdict(set)
    for feature_id, evidence_ids in baseline_evaluation.qualification_evidence_references.items():
        for evidence_id in evidence_ids:
            evidence_to_features[evidence_id].add(feature_id)
    if len(evidence_to_features) > MAXIMUM_EVIDENCE_RECORDS:
        failures.append("P10 feature evidence record count exceeds 104")

    evidence_bindings: list[dict[str, Any]] = []
    for evidence_id in sorted(evidence_to_features):
        label = f"production evidence {evidence_id}"
        if evidence_id not in ledger_evidence_ids:
            failures.append(f"{label} is absent from current run-state")
        relative = f".forge-codex/evidence/{evidence_id}.json"
        try:
            record, record_raw = _load_json(
                repository,
                relative,
                label=label,
                budget=control_budget,
            )
        except EvidenceSupportError as error:
            failures.append(str(error))
            continue
        artifact_failures, artifact_bindings, raw_by_path, report_path, observation_path = _validate_artifacts(
            repository,
            record,
            evidence_id=evidence_id,
            budget=evidence_budget,
        )
        failures.extend(artifact_failures)
        report: dict[str, Any] = {}
        row_bindings: list[dict[str, Any]] = []
        stdout_path = f".forge-codex/evidence/{evidence_id}.stdout.txt"
        receipt_failures, probe_receipts = _decode_probe_receipts(
            raw_by_path.get(stdout_path, b""),
            evidence_id=evidence_id,
        )
        failures.extend(receipt_failures)
        probe_observations: dict[str, tuple[bytes, dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]] = {}
        if observation_path is not None and observation_path in raw_by_path:
            observation_failures, probe_observations = _decode_observation_aggregate(
                raw_by_path[observation_path],
                evidence_id=evidence_id,
            )
            failures.extend(observation_failures)
        if stdout_path not in raw_by_path:
            failures.append(f"{label} has no recorder-owned qualifier stdout")
        if report_path is not None and report_path in raw_by_path:
            try:
                report = decode_strict_json_object(raw_by_path[report_path], label=f"{label} typed qualification report")
            except EvidenceSupportError as error:
                failures.append(str(error))
            else:
                failures.extend(_schema_failures(report, schema, label=f"{label} typed qualification report"))
                semantic_failures, row_bindings = _validate_record_and_report(
                    record,
                    report,
                    evidence_id=evidence_id,
                    expected_features=evidence_to_features[evidence_id],
                    registry_features=baseline_evaluation.registry_features,
                    current_manifest=current_manifest,
                    current_git_head=current_git_head,
                    registry_sha256=registry_binding["sha256"],
                    probe_registry_sha256=probe_registry_binding["sha256"],
                    qualifier_sha256=qualifier_binding["sha256"],
                    baseline_sha256=baseline_binding["sha256"],
                    repository=repository,
                    artifact_bindings=artifact_bindings,
                    qualification_report_path=report_path,
                    stdout_artifact_path=stdout_path,
                    observation_artifact_path=observation_path or "",
                    production_probes=production_probes,
                    probe_receipts=probe_receipts,
                    probe_observations=probe_observations,
                )
                failures.extend(semantic_failures)
        evidence_bindings.append(
            {
                "evidence_id": evidence_id,
                "record": _file_binding(relative, record_raw),
                "features": row_bindings,
                "artifacts": artifact_bindings,
            }
        )

    binding_payload = {
        "schema_version": 1,
        "kind": "p10-feature-evidence-binding",
        "source_identity": {
            "git_head": current_git_head,
            "source_manifest": current_manifest,
            "feature_source_snapshot": current_feature_source,
        },
        "registry": registry_binding,
        "production_probe_registry": {
            **probe_registry_binding,
            "implemented_assertion_count": len(production_probes),
            "unique_runner_count": len({
                item["scenario"]["scenario_id"] for item in production_probes.values()
            }),
            "missing_assertion_ids": missing_probe_assertions,
            "missing_assertion_ids_sha256": canonical_json_sha256(missing_probe_assertions),
        },
        "qualifier": qualifier_binding,
        "baseline": baseline_binding,
        "historical_static_inventory": historical_binding,
        "feature_records": baseline_evaluation.feature_record_bindings,
        "evidence_records": evidence_bindings,
        "ledger": {
            "qualified_evidence_ids": sorted(evidence_to_features),
            "qualified_evidence_ids_sha256": canonical_json_sha256(sorted(evidence_to_features)),
        },
    }
    binding = {**binding_payload, "binding_sha256": canonical_json_sha256(binding_payload)}
    if expected_binding is not None and expected_binding != binding:
        failures.append("P10 feature/evidence binding changed after gate evaluation")
    return P10FeatureEvidenceEvaluation(baseline, baseline_evaluation, failures, binding)


def validate_p10_feature_binding(
    repository: pathlib.Path,
    binding: Any,
    *,
    current_manifest: dict[str, Any],
    current_git_head: str,
    ledger_evidence_ids: set[str],
) -> list[str]:
    evaluation = evaluate_p10_feature_evidence(
        repository,
        current_manifest=current_manifest,
        current_git_head=current_git_head,
        ledger_evidence_ids=ledger_evidence_ids,
        expected_binding=binding,
    )
    return evaluation.failures
