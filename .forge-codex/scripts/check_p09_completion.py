#!/usr/bin/env python3
"""Validate P09 against the production host path and current command evidence."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re


root = pathlib.Path(__file__).resolve().parents[2]


def load(relative: str):
    return json.loads((root / relative).read_text())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def digest(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def validate_record(relative: str, command_fragment: str) -> dict:
    record = load(relative)
    require(record.get("exit_code") == 0, f"command failed: {relative}")
    require(record.get("timed_out") is False, f"command timed out: {relative}")
    require(command_fragment in record.get("command", ""), f"unexpected command: {relative}")
    require("G09" in record.get("related_gates", []), f"command is not bound to G09: {relative}")
    for artifact in record.get("artifacts", []):
        path = pathlib.Path(artifact["path"])
        require(path.is_file(), f"command artifact missing: {path}")
        require(digest(path) == artifact["sha256"], f"command artifact hash mismatch: {path}")
    return record


def command_from_jsonl(relative: str, command_id: str) -> dict:
    path = root / relative
    require(path.is_file(), f"command index missing: {relative}")
    matches = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        if record.get("id") == command_id:
            matches.append(record)
    require(len(matches) == 1, f"expected one command {command_id} in {relative}")
    command = matches[0]
    require(command.get("exit_code") == 0, f"command failed: {command_id}")
    require(command.get("timed_out") is False, f"command timed out: {command_id}")
    for stream_name in ("stdout", "stderr"):
        stream = command[stream_name]
        stream_path = root / stream["path"]
        require(stream_path.is_file(), f"{stream_name} missing for {command_id}")
        require(digest(stream_path) == stream["sha256"], f"{stream_name} hash mismatch for {command_id}")
    return command


def record_stdout(record: dict) -> pathlib.Path:
    return next(
        pathlib.Path(artifact["path"])
        for artifact in record["artifacts"] if artifact["path"].endswith(".stdout.txt")
    )


def passing_test_count(command: dict, *, full_suite: bool) -> int:
    if full_suite:
        require("--filter" not in command["command"], "full-suite proof is filtered")
    stdout = (root / command["stdout"]["path"]).read_text(errors="replace")
    matches = re.findall(
        r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures",
        stdout,
    )
    require(matches, f"test summary missing for {command['id']}")
    passing = [int(count) for count, _, failures in matches if int(failures) == 0]
    require(passing, f"zero-failure test summary missing for {command['id']}")
    return max(passing)


package = (root / "Package.swift").read_text()
require("ForgeNativeSessionHostPlugin" in package, "native plugin target is absent")
require('.library(name: "ForgeNativeSessionHostPlugin"' in package, "native plugin product is absent")

plugin_path = root / "Sources/ForgeNativeSessionHostPlugin/ForgeNativeSessionHostPlugin.swift"
registry_path = root / "Sources/ForgeConductorCore/Domain/HostAdapterRegistry.swift"
tests_path = root / "Tests/ForgeConductorTests/NativeSessionHostPluginTests.swift"
for path in (plugin_path, registry_path, tests_path):
    require(path.is_file(), f"missing {path.relative_to(root)}")

plugin = plugin_path.read_text()
production_registration = plugin[plugin.index("public enum ForgeNativeSessionHostPlugin"):]
for marker in (
    'version = "2.0.0"', 'hostType: "lmstudio-rest-managed"',
    "LMStudioProviderConfiguration.loadIfPresent", "LMStudioManagedSessionTransport",
    "LMStudioManagedSessionHostAdapter(", "LMStudioManagedSessionHostAdapterV2",
    "atomicCreateAndBootstrap: true", "freshRoot: true",
    "maximumLedgerBytes = 4 * 1024 * 1024", "maximumRecords = 1024",
    "maximumReconciliationRecords = 4096", "maximumLiveTerminalRecords = 128",
    "maximumProviderAttempts = 3", "OwnerOnlyAtomicFile.write",
):
    require(marker in plugin, f"missing production plugin marker: {marker}")
require(
    "completeFileProtectionUnlessOpen" not in plugin,
    "production plugin still uses a host-dependent file-protection write option",
)
require(
    "LocalLogicalSessionTransport" not in production_registration,
    "production registration still selects the logical fixture transport",
)

report = load(".forge-codex/evidence/P09-host-capability-report.json")
owners = load(".forge-codex/evidence/P09-resource-owner-matrix.json")
parity = load(".forge-codex/evidence/P09-feature-parity.json")
require(report.get("status") == "passed" and report.get("selected_mode") == "B", "supported host mode missing")
adapter = report.get("selected_adapter", {})
require(adapter.get("identifier") == "forge.native-session-host", "selected adapter mismatch")
require(adapter.get("version") == "2.0.0", "selected adapter version mismatch")
require(adapter.get("host_type") == "lmstudio-rest-managed", "selected host type is not provider backed")
required = {
    "atomic_create_and_bootstrap", "fresh_root", "usage_reporting",
    "idempotency_lookup", "project_generation_fencing", "cancellation", "deadlines",
}
capabilities = adapter.get("capabilities", {})
require(required <= {key for key, value in capabilities.items() if value is True}, "host capabilities incomplete")
require(len(owners.get("owners", [])) >= 5, "resource owner matrix incomplete")
require(not parity.get("removed") and not parity.get("unknown") and not parity.get("untested"), "feature parity failed")

qualification = report.get("qualification", {})
build = validate_record(qualification["plugin_release_build"]["record"], "ForgeNativeSessionHostPlugin")
plugin_tests = validate_record(qualification["plugin_contract_tests"]["record"], "NativeSessionHostPluginTests")
external_record = validate_record(qualification["external_mcp"]["record"], "check_p08_continuity.py")
private_record = validate_record(qualification["private_ui_scan"]["record"], "check_private_ui_automation.py")
plugin_test_output = record_stdout(plugin_tests).read_text(errors="replace")
plugin_matches = re.findall(
    r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures",
    plugin_test_output,
)
plugin_passing = [int(count) for count, _, failures in plugin_matches if int(failures) == 0]
require(plugin_passing, "plugin contract test summary missing")
plugin_test_count = max(plugin_passing)

debug = command_from_jsonl(
    qualification["debug_strict_suite"]["command_index"],
    qualification["debug_strict_suite"]["command_id"],
)
release = command_from_jsonl(
    qualification["release_strict_suite"]["command_index"],
    qualification["release_strict_suite"]["command_id"],
)
debug_count = passing_test_count(debug, full_suite=True)
release_count = passing_test_count(release, full_suite=True)
require(debug_count == release_count, "Debug and Release strict suites disagree on test count")

live_qualification = qualification["live_lmstudio"]
live_command = command_from_jsonl(live_qualification["command_index"], live_qualification["command_id"])
require("testLiveLMStudioFreshRootAcknowledgementAndAutomaticContinuation" in live_command["command"], "live rollover command mismatch")
live_stdout = (root / live_command["stdout"]["path"]).read_text(errors="replace")
require("passed" in live_stdout and "Executed 1 test, with 0 failures" in live_stdout, "live rollover test proof missing")
live = load(live_qualification["artifact"])
require(live.get("provider") == "lmstudio", "live proof is not from LM Studio")
require(live.get("fresh_root_validated") is True, "fresh provider root was not validated")
require(live.get("acknowledgement_validated") is True, "exact acknowledgement was not validated")
require(live.get("automatic_continuation_validated") is True, "automatic continuation was not validated")
require(
    live.get("automatic_continuation_previous_response_id") == live.get("bootstrap_response_id"),
    "automatic continuation is not rooted in the acknowledged successor",
)
require(
    live.get("automatic_continuation_response_id") != live.get("bootstrap_response_id"),
    "automatic continuation did not produce a fresh provider response",
)
usage = live.get("automatic_continuation_usage", {})
require(usage.get("source") == "provider_exact" and usage.get("total_tokens", 0) > 0, "provider-exact usage missing")
require(live.get("model_key") == live.get("loaded_instance_id"), "loaded LM Studio instance mismatch")

external = load(".forge-codex/evidence/P09-external-mcp-compatibility.json")
external_checks = {
    "tool_inventory", "tool_schemas", "memory_only_capability_fallback",
    "durable_handoff_restart", "exact_acknowledgement_rejection",
    "rejected_acknowledgement_no_mutation", "idempotent_acknowledgement",
    "predecessor_seal", "active_session_swap",
}
require(external.get("ok") is True, "external MCP compatibility failed")
require(external_checks <= set(external.get("checks", [])), "external MCP compatibility checks incomplete")
require(external_record.get("exit_code") == 0, "external MCP command failed")

private_scan = json.loads(record_stdout(private_record).read_text())
require(private_scan.get("ok") is True and private_scan.get("violations") == [], "private UI scan failed")
require(build.get("exit_code") == 0, "plugin release target did not build")

print(json.dumps({
    "ok": True,
    "phase": "P09",
    "selected_mode": report["selected_mode"],
    "adapter": adapter["identifier"],
    "adapter_version": adapter["version"],
    "provider": live["provider"],
    "model_key": live["model_key"],
    "live_rollover_command_id": live_qualification["command_id"],
    "plugin_tests": plugin_test_count,
    "debug_strict_tests": debug_count,
    "release_strict_tests": release_count,
    "external_checks": len(external.get("checks", [])),
    "private_ui_violations": 0,
}, indent=2, sort_keys=True))
