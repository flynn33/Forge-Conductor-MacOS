#!/usr/bin/env python3
"""Validate P11 stress, profiling, resource, and memory-tier evidence."""

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess


root = pathlib.Path(__file__).resolve().parents[2]


def load(relative: str):
    return json.loads((root / relative).read_text())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def trace_tree(path: pathlib.Path) -> tuple[str, int, int]:
    files = sorted(item for item in path.rglob("*") if item.is_file() and not item.is_symlink())
    manifest = hashlib.sha256()
    total = 0
    for item in files:
        size = item.stat().st_size
        total += size
        manifest.update(f"{file_sha256(item)}  {item}\n".encode())
    return manifest.hexdigest(), total, len(files)


evidence_ids = {
    "EVID-20260823T212034Z-4070dbd74c",
    "EVID-20260823T212122Z-63e094fe2e",
    "EVID-20260823T212139Z-5e0f9ed571",
    "EVID-20260823T212941Z-7cfd677b6d",
    "EVID-20260823T213021Z-ff22ae46e0",
    "EVID-20260823T213125Z-71f05795f9",
    "EVID-20260823T213156Z-8cb418d293",
}
for evidence_id in evidence_ids:
    record = load(f".forge-codex/evidence/{evidence_id}.json")
    require(record.get("exit_code") == 0, f"failed evidence {evidence_id}")
    require(record.get("timed_out") is False, f"timed-out evidence {evidence_id}")
    for field in ["command", "started_at", "ended_at", "environment", "artifacts"]:
        require(record.get(field), f"missing {field} in {evidence_id}")

stress = load(".forge-codex/evidence/P11-release-stress-results.json")
resource = load(".forge-codex/evidence/P11-resource-results.json")
profile = load(".forge-codex/evidence/P11-profile-report.json")
gauge = load(".forge-codex/evidence/P04-metal-performance-report.json")

require(stress.get("status") == "passed", "release stress result is not passed")
require(resource.get("status") == "passed", "resource result is not passed")
require(profile.get("status") == "passed", "profile result is not passed")
require(all(item.get("passed") is True for item in resource["evaluations"].values()), "resource budget failed")
require(resource["representative_memory_tier"]["passed"] is True, "constrained policy was not executed")
require(resource["representative_memory_tier"]["physical_8_gib_hardware_claimed"] is False, "hardware scope is misstated")

hard = stress["hard_invariants"]
require(hard["telemetry_maximum_logical_slots"] <= 2, "telemetry queue exceeded two logical slots")
require(hard["telemetry_post_stop_slots"] == 0, "telemetry queue did not quiesce")
require(hard["project_contexts_after_close"] == 0, "project contexts remained open")
require(stress["resource"]["resident_post_release_slope_bytes_per_sample"] <= 0, "resident memory slope is positive")
require(stress["memory_tiers"]["lowest_executed_tier"] == "constrained", "constrained policy evidence is absent")
require(max(value["p99"] for value in stress["latency_ms"].values()) <= 2_000, "latency ceiling exceeded")

require(gauge["budgets"]["passed"] is True, "gauge resource budgets did not pass")
require(gauge["steady_buffer_window"]["allocation_delta"] == 0, "steady gauge allocation delta is nonzero")
require(gauge["paused_quiescence_window"]["metal_draw_delta"] == 0, "paused gauge continued drawing")
require(gauge["open_close_release"]["reclosed_active_surfaces"] == 0, "gauge surfaces were not released")

ui = (root / ".forge-codex/evidence/EVID-20260823T212139Z-5e0f9ed571.stdout.txt").read_text()
require("testHundredGaugeNavigationCyclesQuiesce]' passed" in ui, "100-cycle native UI proof missing")
require("Executed 1 test, with 0 failures" in ui, "native UI cycle test failed")

expected_source_hash = resource["fixture"]["source_sha256"]
require(file_sha256(root / "Tests/ForgeConductorTests/ReleaseStressTests.swift") == expected_source_hash, "stress fixture hash changed")

for trace in profile["traces"]:
    path = pathlib.Path(trace["path"])
    require(path.is_dir(), f"trace missing: {path}")
    digest, size, count = trace_tree(path)
    require(digest == trace["tree_sha256"], f"trace hash mismatch: {path.name}")
    require(size == trace["bytes"], f"trace byte count mismatch: {path.name}")
    require(count == trace["files"], f"trace file count mismatch: {path.name}")

measurements = profile["measurements"]
require(measurements["cpu_potential_hangs"] == 0, "CPU trace contains a potential hang")
require(measurements["cpu_hang_risks"] == 0, "CPU trace contains a hang risk")
require(measurements["metal_command_buffer_errors"] == 0, "Metal trace contains a command-buffer error")
require(measurements["metal_potential_hangs"] == 0, "Metal trace contains a potential hang")

process_check = subprocess.run(
    ["pgrep", "-f", str(root / ".build/DerivedData-P11") + ".*/(ForgeConductorUITests-Runner|Forge Conductor)"],
    capture_output=True,
    check=False,
)
require(process_check.returncode == 1, "P11 app or UI-test runner is still active")

print(json.dumps({
    "ok": True,
    "phase": "P11",
    "release_stress_tests": 1,
    "native_ui_cycles": 100,
    "trace_count": len(profile["traces"]),
    "resident_slope_bytes_per_sample": stress["resource"]["resident_post_release_slope_bytes_per_sample"],
    "metal_errors": measurements["metal_command_buffer_errors"],
    "lowest_executed_policy_tier": stress["memory_tiers"]["lowest_executed_tier"],
}, indent=2, sort_keys=True))
