#!/usr/bin/env python3
"""Fail-closed canonical inventory validation for the P10 feature baseline."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from datetime import datetime
import hashlib
import json
import re
from typing import Any


EXPECTED_BASELINE_SCHEMA_VERSION = 2
EXPECTED_REGISTRY_SCHEMA_VERSION = 1
EXPECTED_REGISTRY_ID = "forge-conductor-p10-feature-registry"
EXPECTED_REGISTRY_SHA256 = "d20b40d015e188e8be6f98a973cba1a382be6549cccf6de8a80f843b534756cb"
EXPECTED_QUALIFIER = {"name": "forge-p10-production-matrix", "version": 2}
EXPECTED_PARITY_COUNTS = {
    "preserved": 66,
    "additive": 38,
    "migrated": 0,
    "unknown": 0,
    "removed": 0,
    "untested": 0,
}
EXPECTED_FEATURE_COUNT = 104
EXACT_CURRENT_PRODUCTION_EVIDENCE_KIND = "p10-feature-production-qualification"
EXACT_CURRENT_PRODUCTION_TIER = "exact_current_production_qualified"
FEATURE_BASELINE_PATH = ".forge-codex/state/feature-baseline.json"
FEATURE_REGISTRY_PATH = ".forge-codex/specifications/p10-feature-registry.v1.json"
PRODUCTION_PROBE_REGISTRY_PATH = ".forge-codex/specifications/p10-production-probes.v1.json"
EXPECTED_PRODUCTION_PROBE_REGISTRY_SHA256 = "f11bc867208c637bcd8d27a8d88ed69dc0c76ef8d4e534cf6bf0d02a5145dfef"
FEATURE_QUALIFICATION_SCHEMA_PATH = ".forge-codex/schemas/p10-feature-production-qualification.schema.json"
FEATURE_QUALIFICATION_REPORT_SOURCE_PATH = ".forge-codex/evidence/P10-feature-production-qualification-report.json"
FEATURE_QUALIFIER_PATH = ".forge-codex/scripts/qualify_p10_features.py"
EXPECTED_FEATURE_QUALIFIER_SHA256 = "da1daec2d49618ff0a1ede9a5b94dc64ce90be97b2362727ab2e39fd54ad783b"
HISTORICAL_STATIC_INVENTORY_PATH = ".forge-codex/state/gate-results/G01.static-inventory.json"
EXPECTED_HISTORICAL_STATIC_INVENTORY_SHA256 = "2e2e786e595770749754026e1dbc8728e1ab80e377ffdf37454ae12cc87733e6"
EXPECTED_HISTORICAL_STATIC_FEATURE_COUNT = 98
SUPPORTED_PARITY_STATUSES = frozenset(("preserved", "additive", "migrated"))
BLOCKING_PARITY_STATUSES = frozenset(("unknown", "untested", "removed"))
SUPPORTED_BASELINE_STATUSES = frozenset(("present", "present_broken", "absent"))
BLOCKING_BASELINE_STATUSES = frozenset(("present_broken", "absent"))
SUPPORTED_OPERABILITY_TIERS = frozenset(
    (
        EXACT_CURRENT_PRODUCTION_TIER,
        "signed_supporting",
        "production_component",
        "fixture_or_source_only",
        "broken_or_absent",
    )
)
EXPECTED_CATEGORIES = (
    "build", "cli", "command", "http", "integration", "lifecycle", "mcp",
    "mcp_tool", "mcp_tool_pack", "persistence", "settings", "telemetry", "ui",
)
NON_SIGNED_FEATURE_IDS = frozenset(
    (
        "BUILD-CORE-LIBRARY",
        "BUILD-XCODE-WORKSPACE",
        "BUILD-RUN-ENTRYPOINT",
        "BUILD-FILESYSTEM-PROTOCOL",
        "BUILD-FILESYSTEM-QUALIFICATION",
    )
)
EXPECTED_PROVIDER_FEATURE_IDS = frozenset(
    (
        "MCP-TOOL-SESSION-CHECKPOINT", "MCP-TOOL-SESSION-HANDOFF",
        "DATA-LMSTUDIO-CONFIG", "RUNTIME-LMSTUDIO-PRIMARY-FALLBACK",
        "UI-TAB-AUTONOMY", "UI-TAB-CONTINUITY", "UI-TAB-PROVIDER",
        "MCP-TOOL-CONTINUITY-LIFECYCLE", "HTTP-PROVIDER-PROBE",
        "HTTP-AUTONOMY-CONTROL", "DATA-PROVIDER-RECEIPTS",
        "RUNTIME-MANAGED-AUTONOMY", "RUNTIME-CONTEXT-BUDGET",
        "RUNTIME-LMSTUDIO-MANAGED-PROVIDER",
    )
)
EXPECTED_TOOL_PACK_MEMBERS = {
    "MCP-TOOL-FILESYSTEM": (
        "fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir",
        "fs_delete", "fs_move",
    ),
    "MCP-TOOL-GIT": ("git_status", "git_diff", "git_log", "git_add", "git_commit"),
    "MCP-TOOL-MEMORY": (
        "memory_set", "memory_get", "memory_list", "memory_search", "memory_delete",
    ),
    "MCP-TOOL-PDF": ("pdf_write", "pdf_from_file"),
    "MCP-TOOL-PROJECT-MEMORY": (
        "project_memory.initialize", "project_memory.remember",
        "project_memory.remember_batch", "project_memory.search", "project_memory.get",
        "project_memory.update", "project_memory.forget", "project_memory.list_recent",
        "project_memory.link", "project_memory.export", "project_memory.import",
        "project_memory.status",
    ),
    "MCP-TOOL-CONTINUITY-LIFECYCLE": (
        "continuity.checkpoint", "continuity.prepare_handoff",
        "continuity.get_pending_handoff", "continuity.acknowledge_handoff",
        "continuity.resume", "continuity.status", "continuity.request_rollover",
    ),
    "MCP-TOOL-RUNTIME-JOBS": (
        "runtime.capabilities", "process.run", "shell.run", "bash.run", "python.run",
        "powershell.run", "job.status", "job.read_output", "job.cancel", "job.list",
    ),
}
EXPECTED_SIGNING_ARTIFACTS = {
    "forge-conductor-app": {"kind": "app_bundle", "product_name": "Forge Conductor", "relative_path": "Contents/MacOS/Forge Conductor", "installation_kind": "app-executable"},
    "forge-conductor-cli": {"kind": "executable", "product_name": "forge-conductor", "relative_path": "Contents/Helpers/forge-conductor", "installation_kind": "helper"},
    "forge-filesystem-daemon": {"kind": "executable", "product_name": "forge-filesystem-daemon", "relative_path": "Contents/MacOS/forge-filesystem-daemon", "installation_kind": "helper"},
    "forge-runtime-launcher": {"kind": "executable", "product_name": "forge-runtime-launcher", "relative_path": "Contents/Helpers/forge-runtime-launcher", "installation_kind": "helper"},
}
# Each canonical feature is qualified at one declared shipping boundary. Cross-
# binary behavior is split into independently registered feature surfaces (for
# example the CLI MCP contract, runtime launcher, and filesystem daemon), so a
# feature cannot borrow a signature from an unrelated shipped product.
APP_SIGNED_FEATURE_IDS = frozenset(
    (
        "BUILD-GUI-EXECUTABLE", "BUILD-NATIVE-HOST-PLUGIN",
        "UI-MAIN-WINDOW", "UI-SETTINGS-WINDOW", "UI-NAVIGATION-SIDEBAR",
        "UI-TAB-RIG", "UI-TAB-MCP", "UI-TAB-AGENTS", "UI-TAB-TOOLS",
        "UI-TAB-LIVE-FEED", "UI-TAB-DIAGNOSTICS", "UI-TAB-MANAGER",
        "CMD-TOGGLE-NAVIGATION", "CMD-REFRESH-NOW", "CMD-AUTO-REFRESH",
        "TEL-REALTIME-ENGINE", "TEL-COMPOSED-SNAPSHOT", "TEL-UI-BINDING",
        "TEL-METAL-GAUGES", "TEL-NATIVE-COLLECTORS", "TEL-SSE-DASHBOARD",
        "UI-TAB-PROJECTS", "UI-TAB-AUTONOMY", "UI-TAB-CONTINUITY",
        "UI-TAB-RUNTIMES", "UI-TAB-PROVIDER", "UI-TAB-EVIDENCE",
        "CMD-OPERATOR-NAVIGATION", "UI-SETTINGS-AUTHORIZED-ROOTS",
        "UI-SETTINGS-SHELL-POLICY", "UI-SETTINGS-PROTECTED-FILESYSTEM",
    )
)
FILESYSTEM_DAEMON_SIGNED_FEATURE_IDS = frozenset(
    ("BUILD-FILESYSTEM-DAEMON", "MCP-TOOL-FS-DELETE-RECOVERY", "DATA-FILESYSTEM-RECOVERY")
)
RUNTIME_LAUNCHER_SIGNED_FEATURE_IDS = frozenset(
    ("BUILD-RUNTIME-LAUNCHER", "RUNTIME-PROCESS-RUNNER", "MCP-TOOL-RUNTIME-JOBS", "DATA-RUNTIME-JOBS")
)
EXPECTED_BASELINE_KEYS = frozenset(
    (
        "schema_version", "generated_at", "repository_root",
        "authoritative_registry", "source_snapshot", "historical_static_inventory",
        "runtime_evidence", "operability_evidence_tiers", "operability_summary",
        "features", "required_runtime_surfaces", "runtime_completion_required",
        "parity_summary", "known_environment_limits",
    )
)
EXPECTED_FEATURE_KEYS = frozenset(
    (
        "id", "category", "name", "baseline_status", "parity_status",
        "operability_tier", "operability_gap", "evidence", "tests",
    )
)
EXPECTED_REGISTRY_KEYS = frozenset(
    ("schema_version", "registry_id", "qualifier", "feature_count",
     "parity_summary", "category_set", "features", "tool_pack_members",
     "signing_artifacts", "runtime_surface_inventory", "historical_feature_mapping")
)
EXPECTED_REGISTRY_FEATURE_KEYS = frozenset(
    (
        "id", "name", "category", "parity_status", "signing_required",
        "signing_artifact", "provider_required", "required_assertions",
    )
)
FEATURE_ID_PATTERN = re.compile(r"[A-Z0-9][A-Z0-9._-]{0,250}")
EVIDENCE_ID_PATTERN = re.compile(r"EVID-[A-Za-z0-9][A-Za-z0-9._-]{0,250}")


@dataclass
class FeatureBaselineEvaluation:
    feature_count: int
    inventory_failures: list[str]
    completion_blockers: list[str]
    qualification_evidence_references: dict[str, tuple[str, ...]]
    feature_record_bindings: list[dict[str, Any]]
    registry_features: dict[str, dict[str, Any]]


def canonical_json_sha256(value: Any) -> str:
    raw = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
    ).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def _exact_integer(value: Any, minimum: int = 0) -> bool:
    return type(value) is int and value >= minimum


def _text(value: Any, maximum_bytes: int = 16_384) -> bool:
    if not isinstance(value, str) or not value.strip():
        return False
    try:
        return len(value.encode("utf-8")) <= maximum_bytes
    except UnicodeEncodeError:
        return False


def _text_list(value: Any, maximum_items: int = 1024) -> bool:
    return (
        isinstance(value, list)
        and 0 < len(value) <= maximum_items
        and all(_text(item) for item in value)
        and len(value) == len(set(value))
    )


def _timestamp(value: Any) -> bool:
    if not _text(value, 128):
        return False
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return False
    return parsed.tzinfo is not None and parsed.utcoffset() is not None


def _evidence_references(value: Any) -> tuple[str, ...]:
    if not isinstance(value, list):
        return ()
    return tuple(
        item for item in value
        if isinstance(item, str) and EVIDENCE_ID_PATTERN.fullmatch(item) is not None
    )


def expected_signing_artifact(feature_id: str) -> str | None:
    if feature_id in NON_SIGNED_FEATURE_IDS:
        return None
    if feature_id in APP_SIGNED_FEATURE_IDS:
        return "forge-conductor-app"
    if feature_id in FILESYSTEM_DAEMON_SIGNED_FEATURE_IDS:
        return "forge-filesystem-daemon"
    if feature_id in RUNTIME_LAUNCHER_SIGNED_FEATURE_IDS:
        return "forge-runtime-launcher"
    return "forge-conductor-cli"


def signing_artifact_from_assertion(assertion_id: Any) -> str | None:
    if not isinstance(assertion_id, str):
        return None
    marker = ".signed-product."
    if assertion_id.count(marker) != 1:
        return None
    artifact_id = assertion_id.split(marker, 1)[1]
    return artifact_id if artifact_id in EXPECTED_SIGNING_ARTIFACTS else None


def validate_feature_registry(
    registry: Any,
    *,
    registry_artifact: Any,
) -> tuple[list[str], dict[str, dict[str, Any]]]:
    failures: list[str] = []
    by_id: dict[str, dict[str, Any]] = {}
    if not isinstance(registry, dict):
        return ["authoritative feature registry is not an object"], by_id
    if set(registry) != EXPECTED_REGISTRY_KEYS:
        failures.append("authoritative feature registry key set is not exact")
    if type(registry.get("schema_version")) is not int or registry.get("schema_version") != 1:
        failures.append("authoritative feature registry schema is unsupported")
    if registry.get("registry_id") != EXPECTED_REGISTRY_ID:
        failures.append("authoritative feature registry identifier is unsupported")
    if registry.get("qualifier") != EXPECTED_QUALIFIER:
        failures.append("authoritative feature qualifier identity is unsupported")
    if type(registry.get("feature_count")) is not int or registry.get("feature_count") != 104:
        failures.append("authoritative feature registry count is not exactly 104")
    if registry.get("parity_summary") != {"preserved": 66, "additive": 38, "migrated": 0}:
        failures.append("authoritative feature registry parity mapping is unsupported")
    if registry.get("category_set") != list(EXPECTED_CATEGORIES):
        failures.append("authoritative feature registry category set is unsupported")
    expected_members = {key: list(value) for key, value in EXPECTED_TOOL_PACK_MEMBERS.items()}
    if registry.get("tool_pack_members") != expected_members:
        failures.append("authoritative MCP tool-pack membership is unsupported")
    if registry.get("signing_artifacts") != EXPECTED_SIGNING_ARTIFACTS:
        failures.append("authoritative shipped signing artifact inventory is unsupported")
    if not isinstance(registry_artifact, dict):
        failures.append("authoritative feature registry artifact binding is unavailable")
    else:
        if registry_artifact.get("path") != FEATURE_REGISTRY_PATH:
            failures.append("authoritative feature registry path is not canonical")
        if registry_artifact.get("sha256") != EXPECTED_REGISTRY_SHA256:
            failures.append("authoritative feature registry digest is unsupported")
        if not _exact_integer(registry_artifact.get("bytes"), 1):
            failures.append("authoritative feature registry byte count is invalid")

    features = registry.get("features")
    if not isinstance(features, list) or len(features) != 104:
        failures.append("authoritative feature registry does not contain 104 records")
        features = []
    parity: Counter[str] = Counter()
    categories: set[str] = set()
    ids: list[str] = []
    for index, feature in enumerate(features):
        label = f"authoritative feature registry entry {index}"
        if not isinstance(feature, dict):
            failures.append(f"{label} is not an object")
            continue
        if set(feature) != EXPECTED_REGISTRY_FEATURE_KEYS:
            failures.append(f"{label} key set is not exact")
        feature_id = feature.get("id")
        if not isinstance(feature_id, str) or FEATURE_ID_PATTERN.fullmatch(feature_id) is None:
            failures.append(f"{label} has an invalid feature ID")
            continue
        ids.append(feature_id)
        by_id[feature_id] = feature
        if not _text(feature.get("name"), 1024):
            failures.append(f"{label} has an invalid name")
        category = feature.get("category")
        if category not in EXPECTED_CATEGORIES:
            failures.append(f"{label} has an unsupported category")
        else:
            categories.add(category)
        status = feature.get("parity_status")
        if status not in SUPPORTED_PARITY_STATUSES:
            failures.append(f"{label} has an unsupported parity mapping")
        else:
            parity[status] += 1
        expected_artifact = expected_signing_artifact(feature_id)
        expected_signing = expected_artifact is not None
        if type(feature.get("signing_required")) is not bool:
            failures.append(f"{label} signing applicability is not boolean")
        elif feature.get("signing_required") != expected_signing:
            failures.append(f"{label} signing applicability is not authoritative")
        if feature.get("signing_artifact") != expected_artifact:
            failures.append(f"{label} signing artifact mapping is not authoritative")
        expected_provider = feature_id in EXPECTED_PROVIDER_FEATURE_IDS
        if type(feature.get("provider_required")) is not bool:
            failures.append(f"{label} provider applicability is not boolean")
        elif feature.get("provider_required") != expected_provider:
            failures.append(f"{label} provider applicability is not authoritative")
        members = EXPECTED_TOOL_PACK_MEMBERS.get(feature_id)
        if members is not None:
            if category != "mcp_tool_pack" or feature.get("name") != ", ".join(members):
                failures.append(f"{label} MCP tool-pack identity is malformed")
            expected_assertions = [
                f"{feature_id}.member.{member}.production-path" for member in members
            ]
        else:
            if category == "mcp_tool_pack":
                failures.append(f"{label} MCP tool-pack has no authoritative member list")
            expected_assertions = [f"{feature_id}.production-path"]
        if expected_signing:
            expected_assertions.append(f"{feature_id}.signed-product.{expected_artifact}")
        if expected_provider:
            expected_assertions.append(f"{feature_id}.real-provider")
        if feature.get("required_assertions") != expected_assertions:
            failures.append(f"{label} semantic assertion matrix is unsupported")
    if len(ids) != len(set(ids)) or len(by_id) != len(ids):
        failures.append("authoritative feature registry contains duplicate IDs")
    expected_mcp_tools = sorted(
        [
            feature["name"]
            for feature in features
            if isinstance(feature, dict) and feature.get("category") == "mcp_tool"
        ]
        + [member for members in EXPECTED_TOOL_PACK_MEMBERS.values() for member in members]
    )
    expected_runtime_surfaces = {
        "mcp_tools": expected_mcp_tools,
        "cli_feature_ids": sorted(
            feature["id"] for feature in features
            if isinstance(feature, dict) and feature.get("category") == "cli"
        ),
        "http_feature_ids": sorted(
            feature["id"] for feature in features
            if isinstance(feature, dict) and feature.get("category") == "http"
        ),
        "native_ui_feature_ids": sorted(
            feature["id"] for feature in features
            if isinstance(feature, dict) and feature.get("category") in {"ui", "settings", "command"}
        ),
    }
    if registry.get("runtime_surface_inventory") != expected_runtime_surfaces:
        failures.append("authoritative runtime surface inventory is not exact")
    historical_mapping = registry.get("historical_feature_mapping")
    if (
        not isinstance(historical_mapping, dict)
        or len(historical_mapping) != EXPECTED_HISTORICAL_STATIC_FEATURE_COUNT
        or any(value is not None and value not in by_id for value in historical_mapping.values())
    ):
        failures.append("authoritative historical feature mapping is malformed")
    if categories != set(EXPECTED_CATEGORIES):
        failures.append("authoritative feature registry categories are incomplete")
    if {name: parity.get(name, 0) for name in ("preserved", "additive", "migrated")} != registry.get("parity_summary"):
        failures.append("authoritative feature registry counters do not match records")
    return failures, by_id


def _metadata_failures(
    baseline: dict[str, Any],
    *,
    registry_artifact: Any,
    current_source_snapshot: Any,
    historical_inventory_artifact: Any,
) -> list[str]:
    failures: list[str] = []
    if set(baseline) != EXPECTED_BASELINE_KEYS:
        failures.append("baseline metadata key set is not exact")
    if type(baseline.get("schema_version")) is not int or baseline.get("schema_version") != 2:
        failures.append("baseline feature inventory schema is unsupported")
    if not _timestamp(baseline.get("generated_at")):
        failures.append("baseline generated_at is not a timezone-aware timestamp")
    if baseline.get("repository_root") != ".":
        failures.append("baseline repository root is not portable and canonical")
    if baseline.get("authoritative_registry") != registry_artifact:
        failures.append("baseline authoritative registry binding is stale or malformed")
    expected_snapshot = {
        "schema_version": 1,
        "scope": "current_controlled_source_excluding_feature_baseline",
        "excluded_paths": [FEATURE_BASELINE_PATH],
        "manifest": current_source_snapshot,
    }
    if baseline.get("source_snapshot") != expected_snapshot:
        failures.append("baseline current source snapshot is stale or malformed")
    if baseline.get("historical_static_inventory") != historical_inventory_artifact:
        failures.append("baseline historical static inventory binding is stale or malformed")
    if not _text_list(baseline.get("runtime_evidence")):
        failures.append("baseline runtime evidence list is malformed")
    runtime_surfaces = baseline.get("required_runtime_surfaces")
    if not isinstance(runtime_surfaces, list) or not runtime_surfaces:
        failures.append("baseline required runtime surfaces are malformed")
    else:
        surface_names: list[str] = []
        for index, item in enumerate(runtime_surfaces):
            if (
                not isinstance(item, dict)
                or set(item) != {"surface", "requirement"}
                or not _text(item.get("surface"))
                or not _text(item.get("requirement"))
            ):
                failures.append(f"baseline required runtime surface {index} is malformed")
                continue
            surface_names.append(item["surface"])
        if len(surface_names) != len(set(surface_names)):
            failures.append("baseline required runtime surfaces are duplicated")
    limits = baseline.get("known_environment_limits")
    if not isinstance(limits, list) or not limits:
        failures.append("baseline known environment limits are malformed")
    else:
        surfaces: list[str] = []
        for index, item in enumerate(limits):
            if not isinstance(item, dict) or set(item) != {"surface", "status", "evidence", "detail"}:
                failures.append(f"baseline environment limit {index} is malformed")
                continue
            if not all(_text(value) for value in item.values()):
                failures.append(f"baseline environment limit {index} has empty fields")
            if item.get("status") not in {"open_release_blocking", "deferred_release_blocking"}:
                failures.append(f"baseline environment limit {index} status is unsupported")
            surfaces.append(item.get("surface"))
        if len(surfaces) != len(set(surfaces)):
            failures.append("baseline environment limit surfaces are duplicated")
    return failures


def validate_feature_baseline(
    baseline: Any,
    *,
    registry: Any,
    registry_artifact: Any,
    current_source_snapshot: Any,
    historical_inventory_artifact: Any,
) -> FeatureBaselineEvaluation:
    inventory_failures, registry_features = validate_feature_registry(
        registry, registry_artifact=registry_artifact
    )
    blockers: list[str] = []
    if not isinstance(baseline, dict):
        return FeatureBaselineEvaluation(
            0, inventory_failures + ["baseline feature inventory is not an object"],
            blockers, {}, [], registry_features,
        )
    inventory_failures.extend(
        _metadata_failures(
            baseline,
            registry_artifact=registry_artifact,
            current_source_snapshot=current_source_snapshot,
            historical_inventory_artifact=historical_inventory_artifact,
        )
    )
    features_value = baseline.get("features")
    features = features_value if isinstance(features_value, list) else []
    if not isinstance(features_value, list):
        inventory_failures.append("baseline feature inventory is not a list")
    if len(features) != 104:
        inventory_failures.append("baseline feature inventory is not exactly 104 entries")

    ids: list[str] = []
    parity: Counter[str] = Counter()
    tiers: Counter[str] = Counter()
    exact_ids: set[str] = set()
    evidence_by_feature: dict[str, tuple[str, ...]] = {}
    record_bindings: list[dict[str, Any]] = []
    broken: set[str] = set()
    for index, feature in enumerate(features):
        label = f"baseline feature entry {index}"
        if not isinstance(feature, dict):
            inventory_failures.append(f"{label} is not an object")
            continue
        if set(feature) != EXPECTED_FEATURE_KEYS:
            inventory_failures.append(f"{label} key set is not exact")
        feature_id = feature.get("id")
        if isinstance(feature_id, str) and FEATURE_ID_PATTERN.fullmatch(feature_id):
            ids.append(feature_id)
            label = f"baseline feature {feature_id}"
        else:
            inventory_failures.append(f"{label} has an invalid feature ID")
            feature_id = None
        authority = registry_features.get(feature_id) if feature_id else None
        if authority is None:
            inventory_failures.append(f"{label} is not in the authoritative registry")
        else:
            for key in ("name", "category", "parity_status"):
                if feature.get(key) != authority.get(key):
                    inventory_failures.append(f"{label} {key} does not match the authoritative registry")
        if not _text(feature.get("name"), 1024):
            inventory_failures.append(f"{label} has an invalid name")
        if feature.get("category") not in EXPECTED_CATEGORIES:
            inventory_failures.append(f"{label} has an unsupported category")
        status = feature.get("parity_status")
        if status in SUPPORTED_PARITY_STATUSES:
            parity[status] += 1
        elif status in BLOCKING_PARITY_STATUSES:
            parity[status] += 1
            inventory_failures.append(f"{label} has an unknown, untested, or removed parity status")
        else:
            inventory_failures.append(f"{label} has an unsupported parity status")
        baseline_status = feature.get("baseline_status")
        if baseline_status not in SUPPORTED_BASELINE_STATUSES:
            inventory_failures.append(f"{label} has an unsupported baseline status")
        elif baseline_status in BLOCKING_BASELINE_STATUSES and feature_id:
            broken.add(feature_id)
        evidence = feature.get("evidence")
        references = _evidence_references(evidence)
        if not _text_list(evidence):
            inventory_failures.append(f"{label} is without unique nonempty evidence")
        if not _text_list(feature.get("tests")):
            inventory_failures.append(f"{label} is without unique nonempty tests")
        tier = feature.get("operability_tier")
        if not _text(tier):
            inventory_failures.append(f"{label} is without an operability tier")
        elif tier not in SUPPORTED_OPERABILITY_TIERS:
            inventory_failures.append(f"{label} has an unsupported operability tier")
        else:
            tiers[tier] += 1
            if tier == "broken_or_absent" and feature_id:
                broken.add(feature_id)
            if tier == EXACT_CURRENT_PRODUCTION_TIER:
                if baseline_status != "present":
                    inventory_failures.append(f"{label} claims exact qualification without present status")
                elif not references:
                    inventory_failures.append(f"{label} claims exact qualification without an EVID reference")
                elif len(references) != len(set(references)):
                    inventory_failures.append(f"{label} repeats a production evidence reference")
                elif feature_id:
                    exact_ids.add(feature_id)
                    evidence_by_feature[feature_id] = references
        if not _text(feature.get("operability_gap")):
            inventory_failures.append(f"{label} is without a nonempty operability gap")
        if feature_id:
            record_bindings.append({"feature_id": feature_id, "record_sha256": canonical_json_sha256(feature)})
    if len(ids) != len(set(ids)):
        inventory_failures.append("baseline feature inventory contains duplicate feature IDs")
    if ids != list(registry_features):
        inventory_failures.append("baseline feature IDs or ordering do not match the authoritative registry")

    summary = baseline.get("parity_summary")
    if not isinstance(summary, dict) or set(summary) != set(EXPECTED_PARITY_COUNTS) or any(
        not _exact_integer(summary.get(name)) for name in EXPECTED_PARITY_COUNTS
    ):
        inventory_failures.append("baseline parity counter set is not exact")
    else:
        if summary != EXPECTED_PARITY_COUNTS:
            inventory_failures.append("baseline parity summary does not match the authoritative registry")
        if summary != {name: parity.get(name, 0) for name in EXPECTED_PARITY_COUNTS}:
            inventory_failures.append("baseline parity counters do not match feature records")
    definitions = baseline.get("operability_evidence_tiers")
    if not isinstance(definitions, dict) or set(definitions) != SUPPORTED_OPERABILITY_TIERS:
        inventory_failures.append("baseline operability tier definition set is not exact")
    elif not all(_text(value) for value in definitions.values()):
        inventory_failures.append("baseline operability tier definition is empty")

    operability = baseline.get("operability_summary")
    expected_keys = {
        "interpretation", "feature_count", "tier_counts",
        "exact_current_production_qualified", "release_ready",
        "open_release_blockers", "qualification_rule",
    }
    if not isinstance(operability, dict):
        inventory_failures.append("baseline operability summary is not an object")
        operability = {}
    elif set(operability) != expected_keys:
        inventory_failures.append("baseline operability summary key set is not exact")
    if not _text(operability.get("interpretation")) or not _text(operability.get("qualification_rule")):
        inventory_failures.append("baseline operability prose is malformed")
    if not _text_list(operability.get("open_release_blockers")):
        inventory_failures.append("baseline open release blocker list is malformed")
    if type(operability.get("feature_count")) is not int or operability.get("feature_count") != 104:
        inventory_failures.append("baseline operability feature count is not exactly 104")
    declared_tiers = operability.get("tier_counts")
    if not isinstance(declared_tiers, dict) or set(declared_tiers) != SUPPORTED_OPERABILITY_TIERS or any(
        not _exact_integer(declared_tiers.get(tier)) for tier in SUPPORTED_OPERABILITY_TIERS
    ):
        inventory_failures.append("baseline operability tier counter set is not exact")
    else:
        actual_tiers = {tier: tiers.get(tier, 0) for tier in SUPPORTED_OPERABILITY_TIERS}
        if declared_tiers != actual_tiers:
            inventory_failures.append("baseline operability tier counters do not match feature records")
        if sum(declared_tiers.values()) != len(features):
            inventory_failures.append("baseline operability tier counters do not total the feature inventory")
    runtime_open = baseline.get("runtime_completion_required")
    if type(runtime_open) is not bool:
        inventory_failures.append("baseline runtime_completion_required is not a boolean")
    elif runtime_open:
        blockers.append("baseline requires outstanding runtime completion evidence")
    declared_exact = operability.get("exact_current_production_qualified")
    if type(declared_exact) is not int or declared_exact != len(exact_ids):
        inventory_failures.append("baseline exact-qualified count does not match feature records")
    lower = {
        tier: tiers.get(tier, 0) for tier in sorted(SUPPORTED_OPERABILITY_TIERS)
        if tier != EXACT_CURRENT_PRODUCTION_TIER and tiers.get(tier, 0) > 0
    }
    if lower or len(exact_ids) != 104:
        detail = ", ".join(f"{tier}={count}" for tier, count in lower.items())
        blockers.append(f"baseline has {104 - len(exact_ids)} features without exact-current production qualification" + (f": {detail}" if detail else ""))
    if broken:
        blockers.append("baseline broken or absent features block P10: " + ", ".join(sorted(broken)))
    derived_ready = runtime_open is False and len(exact_ids) == 104 and not lower and not broken
    if type(operability.get("release_ready")) is not bool:
        inventory_failures.append("baseline release_ready is not a boolean")
    elif operability.get("release_ready") != derived_ready:
        inventory_failures.append("baseline release_ready does not match feature qualification records")
    return FeatureBaselineEvaluation(
        len(features), inventory_failures, blockers, evidence_by_feature,
        record_bindings, registry_features,
    )
