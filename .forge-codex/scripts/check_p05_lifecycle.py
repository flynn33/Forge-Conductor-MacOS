#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
evidence = root / ".forge-codex" / "evidence"
matrix = json.loads((evidence / "P05-resource-owner-matrix.json").read_text())
report = json.loads((evidence / "P05-sanitizer-and-lifecycle-report.json").read_text())
findings = json.loads((root / ".forge-codex/state/findings-resolution.json").read_text())

assert matrix["audit_e2_count"] == 0
assert matrix["audit_e3_count"] == 11
assert len(matrix["resources"]) == 11
assert all(item["disposition"] for item in matrix["resources"])

cli = (root / "Sources/ForgeConductorCLI/ForgeConductorMain.swift").read_text()
dashboard = (root / "Sources/ForgeConductorCore/Dashboard/DashboardServer.swift").read_text()
guard = (root / "Sources/ForgeConductorCore/Infrastructure/DashboardPortGuard.swift").read_text()
runtime = (root / "Sources/ForgeConductorCore/Manager/ManagerRuntime.swift").read_text()
router = (root / "Sources/ForgeConductorCore/Application/ToolRouter.swift").read_text()
tests = (root / "Tests/ForgeConductorTests/LifecycleOwnershipTests.swift").read_text()

assert cli.count("sigInt.cancel()") >= 1 and "defer { try? log.close() }" in cli
assert "sigInt.cancel()" in dashboard and "sigTerm.cancel()" in dashboard
assert "proc.standardError = out" in guard and "defer { try? readHandle.close() }" in guard
assert "cancelWatchdog()" in runtime and "cancelSignalSources()" in runtime
assert "[any DispatchSourceSignal]" in runtime
assert "AsyncStream" not in router
assert "AcrossTenCycles" in tests and "CompleteTenCycles" in tests

p05 = [item for item in findings["findings"] if item["assigned_phase"] == "P05"]
assert len(p05) == 11
assert all(item["status"] == "resolved" for item in p05)
assert all(item["ownership_disposition"] for item in p05)

assert report["lifecycle_tests"]["failures"] == 0
assert report["strict_concurrency"]["failures"] == 0
assert report["address_sanitizer"]["product_findings"] == 0
assert report["thread_sanitizer"]["product_findings"] == 0
assert report["unresolved_product_findings"] == 0

asan = (evidence / "EVID-20260823T194148Z-4bc9b988c0.stderr.txt").read_text()
tsan = (evidence / "EVID-20260823T194202Z-a41d508f0c.stderr.txt").read_text()
strict = (evidence / "EVID-20260823T194308Z-9a5fdacf6f.stdout.txt").read_text()
lifecycle = (evidence / "EVID-20260823T193826Z-661c01c5d5.stdout.txt").read_text()
assert "Sanitizer load violates platform policy" in asan
assert "Sanitizer load violates platform policy" in tsan
assert "ERROR: AddressSanitizer" not in asan
assert "WARNING: ThreadSanitizer" not in tsan
assert "Executed 242 tests" in strict and "0 failures" in strict
assert "Executed 40 tests" in lifecycle and "0 failures" in lifecycle

def leaked_bytes(path: Path) -> int:
    match = re.search(r"leaks for (\d+) total leaked bytes", path.read_text())
    assert match
    return int(match.group(1))

first = leaked_bytes(evidence / "EVID-20260823T194225Z-32827b0ff8.stdout.txt")
second = leaked_bytes(evidence / "EVID-20260823T194253Z-44ca4b7694.stdout.txt")
assert first == report["live_leak_growth"]["first_reported_bytes"]
assert second == report["live_leak_growth"]["second_reported_bytes"]
assert second <= first

print(json.dumps({
    "valid": True,
    "audit_e2_count": 0,
    "p05_dispositions": len(p05),
    "lifecycle_test_failures": 0,
    "strict_concurrency_failures": 0,
    "sanitizer_product_findings": 0,
    "live_leak_growth_bytes": second - first,
}, indent=2, sort_keys=True))
