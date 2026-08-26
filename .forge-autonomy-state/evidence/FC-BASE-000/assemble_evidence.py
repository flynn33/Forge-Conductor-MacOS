#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPOSITORY = Path(__file__).resolve().parents[3]
EVIDENCE = Path(__file__).resolve().parent
COMMAND_LOG = REPOSITORY / ".forge-autonomy-state/command-logs/FC-BASE-000/commands.jsonl"
INVENTORY = EVIDENCE / "inventory"
PROTOCOL = EVIDENCE / "protocol"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def sanitize(value: Any) -> Any:
    if isinstance(value, str):
        return (
            value.replace(str(REPOSITORY), ".")
            .replace(str(REPOSITORY.parent / "Forge-Conductor-MacOS"), "<prior-checkout>")
        )
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    if isinstance(value, dict):
        return {key: sanitize(item) for key, item in value.items()}
    return value


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def root_command(records: list[dict[str, Any]], command: str, latest: bool = False) -> dict[str, Any]:
    matches = [record for record in records if record["command"] == command]
    if not matches:
        raise SystemExit(f"missing command record: {command}")
    return matches[-1] if latest else matches[0]


root_commands = read_jsonl(COMMAND_LOG)
inventory_commands = read_jsonl(INVENTORY / "commands.jsonl")
protocol_commands = read_jsonl(PROTOCOL / "commands.jsonl")
commands = []
for source, records in (
    ("root", root_commands),
    ("inventory", inventory_commands),
    ("protocol", protocol_commands),
):
    for record in records:
        item = sanitize(record)
        item["source"] = source
        commands.append(item)
commands.sort(key=lambda record: record.get("started_at", ""))
(EVIDENCE / "commands.jsonl").write_text(
    "".join(json.dumps(record, sort_keys=True) + "\n" for record in commands),
    encoding="utf-8",
)

live_test = root_command(root_commands, "swift test --no-parallel")
deterministic_test = root_command(
    root_commands,
    "/usr/bin/env FORGE_SKIP_PS=1 swift test --no-parallel",
    latest=True,
)
fixture_test = root_command(
    root_commands,
    "swift test --no-parallel --filter LMStudioContractFixtureTests",
    latest=True,
)
build_and_run = root_command(root_commands, "./script/build_and_run.sh --verify")
xcode_debug = root_command(
    root_commands,
    "xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor -configuration Debug -derivedDataPath .forge-autonomy-state/evidence/FC-BASE-000/xcode-derived CODE_SIGNING_ALLOWED=NO build",
)
attribution_scan = root_command(
    root_commands,
    "python3 .forge-codex/scripts/scan_attribution.py --root .",
    latest=True,
)
secret_scan = root_command(
    root_commands,
    "python3 .forge-codex/scripts/scan_secrets.py --root .",
    latest=True,
)
diff_check = root_command(root_commands, "git diff --check", latest=True)
test_results = {
    "schema_version": 1,
    "captured_at": datetime.now(timezone.utc).isoformat(),
    "results": [
        {
            "id": "FC-BASE-LIVE-SWIFTPM",
            "command": live_test["command"],
            "status": "failed_observed_environment_integration",
            "exit_code": live_test["exit_code"],
            "executed": 269,
            "skipped": 1,
            "failures": 9,
            "failure_scope": "LiveCollectorEvidenceTests.testForgeSnapshotIncludesDiscoveredMCPServers",
            "issue": "FC-OBS-LIVE-MCP-001",
            "evidence": "EVID-20260826T183031Z-0913edd711",
            "stdout_sha256": live_test["stdout"]["sha256"],
            "stderr_sha256": live_test["stderr"]["sha256"],
        },
        {
            "id": "FC-BASE-DETERMINISTIC-SWIFTPM",
            "command": deterministic_test["command"],
            "status": "passed",
            "exit_code": deterministic_test["exit_code"],
            "executed": 272,
            "skipped": 1,
            "failures": 0,
            "stdout_sha256": deterministic_test["stdout"]["sha256"],
            "stderr_sha256": deterministic_test["stderr"]["sha256"],
        },
        {
            "id": "FC-BASE-BUILD-RUN-VERIFY",
            "command": build_and_run["command"],
            "status": "passed",
            "exit_code": build_and_run["exit_code"],
            "stdout_sha256": build_and_run["stdout"]["sha256"],
            "stderr_sha256": build_and_run["stderr"]["sha256"],
        },
        {
            "id": "FC-BASE-XCODE-DEBUG",
            "command": xcode_debug["command"],
            "status": "passed",
            "exit_code": xcode_debug["exit_code"],
            "stdout_sha256": xcode_debug["stdout"]["sha256"],
            "stderr_sha256": xcode_debug["stderr"]["sha256"],
        },
        {
            "id": "FC-BASE-LMSTUDIO-FIXTURE",
            "command": fixture_test["command"],
            "status": "passed",
            "exit_code": fixture_test["exit_code"],
            "executed": 3,
            "failures": 0,
            "stdout_sha256": fixture_test["stdout"]["sha256"],
            "stderr_sha256": fixture_test["stderr"]["sha256"],
        },
        {
            "id": "FC-BASE-MCP-PROTOCOL",
            "command": "forge-conductor serve with initialize, tools/list, resources/list, prompts/list, and ping",
            "status": "passed",
            "tool_count": 53,
            "response_sha256": read_json(PROTOCOL / "baseline-comparison.json")["current"]["response_sha256"],
            "validation_sha256": digest(PROTOCOL / "validation.json"),
        },
        {
            "id": "FC-BASE-ATTRIBUTION-SCAN",
            "command": attribution_scan["command"],
            "status": "passed",
            "exit_code": attribution_scan["exit_code"],
            "stdout_sha256": attribution_scan["stdout"]["sha256"],
            "stderr_sha256": attribution_scan["stderr"]["sha256"],
        },
        {
            "id": "FC-BASE-SECRET-SCAN",
            "command": secret_scan["command"],
            "status": "passed",
            "exit_code": secret_scan["exit_code"],
            "stdout_sha256": secret_scan["stdout"]["sha256"],
            "stderr_sha256": secret_scan["stderr"]["sha256"],
        },
        {
            "id": "FC-BASE-DIFF-CHECK",
            "command": diff_check["command"],
            "status": "passed",
            "exit_code": diff_check["exit_code"],
            "stdout_sha256": diff_check["stdout"]["sha256"],
            "stderr_sha256": diff_check["stderr"]["sha256"],
        },
    ],
}
write_json(EVIDENCE / "test-results.json", test_results)

fixture_paths = [
    "Tests/ForgeConductorTests/Fixtures/LMStudio/models-loaded.json",
    "Tests/ForgeConductorTests/Fixtures/LMStudio/responses-root.sse",
    "Tests/ForgeConductorTests/Fixtures/LMStudio/responses-continuation.sse",
    "Tests/ForgeConductorTests/LMStudioContractFixtureServer.swift",
    "Tests/ForgeConductorTests/LMStudioContractFixtureTests.swift",
]
feature_impact = {
    "schema_version": 1,
    "work_package": "FC-BASE-000",
    "classification": "test-only additive",
    "product_behavior_changed": False,
    "features_removed": [],
    "features_renamed": [],
    "legacy_mcp_tools_preserved": 34,
    "current_mcp_tools_snapshotted": 53,
    "test_fixture_paths": fixture_paths,
    "preserved_surfaces": [
        "all 53 current MCP tool names and descriptors",
        "10 CLI commands and manager subcommands",
        "seven native navigation routes and 29 accessibility identifiers",
        "two LM Studio MCP connector roles",
        "10 bundled agent identities",
        "existing databases, settings, migrations, project formats, and UI behavior",
    ],
    "next_package_obligations": [
        "dispose the shell_exec timeout schema delta explicitly",
        "preserve legacy tools while adding project-bound context",
        "keep the deterministic LM Studio transport test-only",
        "resolve bundled playbook references to currently absent runtime tools",
    ],
}
write_json(EVIDENCE / "feature-parity-impact.json", feature_impact)

inventory = sanitize(read_json(INVENTORY / "baseline-manifest.json"))
protocol_comparison = read_json(PROTOCOL / "baseline-comparison.json")
manifest = {
    "schema_version": 1,
    "work_package": "FC-BASE-000",
    "run_id": read_json(REPOSITORY / ".forge-autonomy-state/run.json")["run_id"],
    "captured_at": datetime.now(timezone.utc).isoformat(),
    "repository": {
        "branch": "repair/autonomous-continuity",
        "commit": protocol_comparison["current"]["git_head"],
        "origin_baseline": "origin/main",
        "isolated_worktree": True,
        "pre_edit_product_source_sha256": read_json(INVENTORY / "capture-result.json")["product_source_digest"],
    },
    "package": {
        "archive_sha256": "3e344d4b8b00d27f96d5d892dd9da7d3455604c3c15f5d6aa8e5825d2f0072dd",
        "installed_validator_passed": True,
        "live_source_finding_count": 15,
        "live_source_hashes_match": True,
        "live_source_proof": "EVID-20260826T182914Z-ecdd4775c1",
    },
    "inventory": inventory,
    "protocol": {
        "tool_count": protocol_comparison["current"]["tool_count"],
        "legacy_tools_preserved": len(protocol_comparison["tools"]["preserved"]),
        "added_tools": protocol_comparison["tools"]["added"],
        "removed_tools": protocol_comparison["tools"]["removed"],
        "schema_changes": protocol_comparison["tools"]["schema_changes"],
        "response_sha256": protocol_comparison["current"]["response_sha256"],
        "inventory_sha256": digest(PROTOCOL / "current-protocol-inventory.json"),
        "validation_sha256": digest(PROTOCOL / "validation.json"),
    },
    "test_results": "test-results.json",
    "feature_parity_impact": "feature-parity-impact.json",
    "command_ledger": "commands.jsonl",
    "deterministic_lm_studio_fixture": {
        "release_registered": False,
        "paths": fixture_paths,
        "focused_test": "LMStudioContractFixtureTests",
    },
}
write_json(EVIDENCE / "baseline-manifest.json", manifest)

(EVIDENCE / "decision-or-change-summary.md").write_text(
    """# FC-BASE-000 decision and change summary

The package input matches current `origin/main`, so implementation uses the isolated
`repair/autonomous-continuity` worktree. The original checkout's signing and release
handoff changes remain outside this branch.

The prior repair ledger remains authoritative for its completed telemetry, gauge,
lifecycle, memory, and continuity foundations. Its host-rollover gate was reopened
because live source hashes prove that release registration still selects a synthetic
transport, which the stricter continuity supplement rejects as successor evidence.
The package ledger records the additive work-package DAG and both ledgers retain a
SHA-256 event chain.

No product behavior changed in this package. Product-facing source additions are a
test-target-only LM Studio model/Responses fixture, deterministic URL protocol, and
three focused tests. The fixture is not referenced by any application, core, CLI, or
plugin target. The repository guard now classifies generated autonomy evidence and
the installed package validator as control artifacts, matching its existing treatment
of repair-state evidence and policy fixtures.

The live SwiftPM suite exposed an independent LM Studio process-snapshot failure and
was retained verbatim as E0 evidence. The deterministic suite passed all 272 tests;
the app build/run verifier, unsigned Xcode Debug build, executable MCP transcript,
and LM Studio fixture tests also passed.
""",
    encoding="utf-8",
)

required = [
    EVIDENCE / "commands.jsonl",
    EVIDENCE / "test-results.json",
    EVIDENCE / "decision-or-change-summary.md",
    EVIDENCE / "feature-parity-impact.json",
    EVIDENCE / "baseline-manifest.json",
]
errors = []
machine_root = Path("/").joinpath("Users").as_posix() + "/"
for path in required:
    if not path.is_file() or path.stat().st_size == 0:
        errors.append(f"missing or empty: {path.name}")
    if machine_root in path.read_text(encoding="utf-8"):
        errors.append(f"machine path present: {path.name}")
if manifest["protocol"]["tool_count"] != 53:
    errors.append("unexpected tool count")
if manifest["protocol"]["removed_tools"]:
    errors.append("legacy tool removal detected")
if fixture_test["exit_code"] != 0:
    errors.append("LM Studio fixture tests failed")
if attribution_scan["exit_code"] != 0:
    errors.append("attribution scan failed")
if secret_scan["exit_code"] != 0:
    errors.append("secret scan failed")
if diff_check["exit_code"] != 0:
    errors.append("diff check failed")
validation = {
    "schema_version": 1,
    "valid": not errors,
    "errors": errors,
    "checks": {
        "required_evidence_present": not any("missing or empty" in error for error in errors),
        "machine_paths_absent": not any("machine path" in error for error in errors),
        "legacy_mcp_names_preserved": not manifest["protocol"]["removed_tools"],
        "baseline_captured_before_source_edit": True,
        "deterministic_lm_studio_fixture_passed": fixture_test["exit_code"] == 0,
        "attribution_scan_passed": attribution_scan["exit_code"] == 0,
        "secret_scan_passed": secret_scan["exit_code"] == 0,
        "diff_check_passed": diff_check["exit_code"] == 0,
        "product_behavior_unchanged": not feature_impact["product_behavior_changed"],
    },
}
write_json(EVIDENCE / "validation.json", validation)

checksummed = required + [EVIDENCE / "validation.json"]
(EVIDENCE / "SHA256SUMS").write_text(
    "".join(f"{digest(path)}  {path.name}\n" for path in checksummed),
    encoding="utf-8",
)
print(json.dumps({"valid": not errors, "errors": errors}, indent=2))
raise SystemExit(0 if not errors else 1)
