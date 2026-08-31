#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

from evidence_support import (
    BoundedCommandError,
    BoundedReadBudget,
    EvidenceSupportError,
    MAXIMUM_JSON_NUMBER_CHARACTERS,
    MAXIMUM_REPOSITORY_SCAN_ENTRIES,
    atomic_write,
    bounded_repository_tree,
    read_bounded_repository_bytes,
    run_bounded_readonly_command,
)


REQUIRED = (
    "VERSION",
    "CODEX_EXECUTION_PROMPT.md",
    "docs/EXECUTION_CONTRACT.md",
    "docs/EVIDENCE_RULES.md",
    "docs/DECISION_POLICY.md",
    "docs/FAIL_FORWARD_POLICY.md",
    "docs/FEATURE_PRESERVATION.md",
    "docs/PHASE_PLAYBOOK.md",
    "architecture/TARGET_ARCHITECTURE.md",
    "architecture/TELEMETRY_BACKPRESSURE.md",
    "architecture/GAUGE_RENDERING.md",
    "architecture/PROJECT_MEMORY_MCP.md",
    "architecture/CONTINUITY_AND_ROLLOVER.md",
    "architecture/HOST_ADAPTER_PLUGIN.md",
    "specifications/MCP_TOOL_CONTRACTS.md",
    "specifications/CONTINUITY_STATE_MACHINE.md",
    "specifications/COMPLETION_GATES.md",
    "plans/phases.json",
    "plans/gates.json",
    "plans/resource-budgets.json",
    "schemas/run-state.schema.json",
    "schemas/handoff.schema.json",
    "schemas/memory-record.schema.json",
    "scripts/statectl.py",
    "scripts/feature_inventory.py",
    "scripts/verify_completion.py",
    "scripts/scan_attribution.py",
)
TRAVERSAL_SKIP = frozenset({".git", ".build", "DerivedData", "build", "dist", "work"})
MAXIMUM_PACKAGE_FILE_BYTES = 64 * 1024 * 1024
MAXIMUM_PACKAGE_TOTAL_BYTES = 512 * 1024 * 1024
MAXIMUM_CHILD_OUTPUT_BYTES = 16 * 1024 * 1024
MAXIMUM_CHILD_SECONDS = 300.0
MAXIMUM_REPORT_BYTES = 16 * 1024 * 1024
MAXIMUM_CHECKS = 100_000


def decode_strict_json_value(raw: bytes, *, label: str) -> Any:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate key: {key}")
            result[key] = value
        return result

    def reject_constant(value: str) -> Any:
        raise ValueError(f"non-finite numeric constant: {value}")

    def bounded_integer(value: str) -> int:
        if len(value) > MAXIMUM_JSON_NUMBER_CHARACTERS:
            raise ValueError("integer token exceeds its lexical bound")
        return int(value)

    def bounded_float(value: str) -> float:
        if len(value) > MAXIMUM_JSON_NUMBER_CHARACTERS:
            raise ValueError("floating-point token exceeds its lexical bound")
        parsed = float(value)
        if parsed != parsed or parsed in {float("inf"), float("-inf")}:
            raise ValueError("floating-point token is not finite")
        return parsed

    try:
        return json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_constant,
            parse_int=bounded_integer,
            parse_float=bounded_float,
        )
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise EvidenceSupportError(
            f"{label} is not bounded strict UTF-8 JSON: {error}"
        ) from error


def compile_python_bytes(raw: bytes, *, label: str) -> None:
    try:
        compile(raw, label, "exec", dont_inherit=True)
    except (SyntaxError, UnicodeError, ValueError) as error:
        raise EvidenceSupportError(f"{label} does not compile: {error}") from error


def validate_shell_bytes(root: Path, raw: bytes, *, label: str) -> str:
    bash = shutil.which("bash")
    if bash is None:
        raise FileNotFoundError("bash unavailable")
    with tempfile.TemporaryFile() as source:
        source.write(raw)
        source.flush()
        os.fsync(source.fileno())
        source.seek(0)
        try:
            code, stdout, stderr = run_bounded_readonly_command(
                root,
                label,
                [bash, "-n", f"/dev/fd/{source.fileno()}"],
                timeout_seconds=MAXIMUM_CHILD_SECONDS,
                maximum_output_bytes=MAXIMUM_CHILD_OUTPUT_BYTES,
                pass_fds=(source.fileno(),),
            )
        except BoundedCommandError as error:
            raise EvidenceSupportError(f"{label} failed closed: {error}") from error
    output = (stderr + stdout).decode("utf-8", errors="replace").strip()
    if code != 0:
        raise EvidenceSupportError(
            f"{label} exited {code}: {output or 'no diagnostic'}"
        )
    return output or "syntax valid"


def run_pinned_python_script(root: Path, relative: PurePosixPath, *, label: str) -> str:
    raw = read_bounded_repository_bytes(
        root,
        relative,
        label=f"{label} source",
        maximum_bytes=MAXIMUM_PACKAGE_FILE_BYTES,
    )
    try:
        source = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise EvidenceSupportError(f"{label} source is not UTF-8") from error
    scripts = root / "scripts"
    environment = dict(os.environ)
    prior_path = environment.get("PYTHONPATH")
    environment["PYTHONPATH"] = (
        str(scripts) if not prior_path else f"{scripts}{os.pathsep}{prior_path}"
    )
    try:
        code, stdout, stderr = run_bounded_readonly_command(
            root,
            label,
            [sys.executable, "-c", source, "--root", str(root)],
            timeout_seconds=MAXIMUM_CHILD_SECONDS,
            maximum_output_bytes=MAXIMUM_CHILD_OUTPUT_BYTES,
            environment=environment,
        )
    except BoundedCommandError as error:
        raise EvidenceSupportError(f"{label} failed closed: {error}") from error
    output = (stderr + stdout).decode("utf-8", errors="replace").strip()
    if code != 0:
        raise EvidenceSupportError(
            f"{label} exited {code}: {output or 'no diagnostic'}"
        )
    return output


def validate_symlink(root: Path, relative: PurePosixPath) -> tuple[bool, str]:
    path = root / relative
    try:
        before = path.lstat()
        if not stat.S_ISLNK(before.st_mode):
            raise EvidenceSupportError("path is no longer a symbolic link")
        target_text = os.readlink(path)
        if len(target_text.encode("utf-8", errors="strict")) > 4096:
            raise EvidenceSupportError("symbolic-link target exceeds its byte bound")
        after = path.lstat()
    except (OSError, UnicodeError) as error:
        raise EvidenceSupportError(
            f"symbolic link cannot be inspected safely: {relative}: {error}"
        ) from error
    fields = (
        "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
        "st_mtime_ns", "st_ctime_ns",
    )
    if any(getattr(before, field) != getattr(after, field) for field in fields):
        raise EvidenceSupportError(f"symbolic link changed during validation: {relative}")
    target = (path.parent / target_text).resolve(strict=False)
    inside = target == root or root in target.parents
    return inside, str(target)


def validate(root: Path) -> dict[str, Any]:
    root = root.resolve(strict=True)
    errors: list[str] = []
    warnings: list[str] = []
    checks: list[dict[str, Any]] = []

    def check(name: str, passed: bool, detail: Any) -> None:
        if len(checks) >= MAXIMUM_CHECKS:
            raise EvidenceSupportError(
                f"package validation exceeds {MAXIMUM_CHECKS} checks"
            )
        rendered = str(detail)
        if len(rendered) > 4096:
            rendered = rendered[:4096] + "..."
        checks.append({"name": name, "passed": bool(passed), "detail": rendered})
        if not passed:
            errors.append(f"{name}: {rendered}")

    entries = bounded_repository_tree(
        root,
        skip_names=TRAVERSAL_SKIP,
        maximum_entries=MAXIMUM_REPOSITORY_SCAN_ENTRIES,
        reject_symlinks=False,
    )
    entry_map = {entry.relative_path.as_posix(): entry for entry in entries}
    for relative in REQUIRED:
        entry = entry_map.get(relative)
        check(
            f"required:{relative}",
            entry is not None and entry.is_file,
            relative,
        )

    budget = BoundedReadBudget(MAXIMUM_PACKAGE_TOTAL_BYTES, "package validation input")
    json_objects: dict[str, Any] = {}
    for entry in entries:
        relative = entry.relative_path
        if not entry.is_file or relative.suffix.lower() != ".json":
            continue
        try:
            raw = read_bounded_repository_bytes(
                root,
                relative,
                label=f"package JSON {relative}",
                maximum_bytes=MAXIMUM_PACKAGE_FILE_BYTES,
                budget=budget,
            )
            json_objects[relative.as_posix()] = decode_strict_json_value(
                raw,
                label=f"package JSON {relative}",
            )
            check(f"json:{relative}", True, "valid")
        except EvidenceSupportError as error:
            check(f"json:{relative}", False, error)

    phase_plan = json_objects.get("plans/phases.json", {})
    gate_plan = json_objects.get("plans/gates.json", {})
    if not isinstance(phase_plan, dict):
        check("phase-plan-object", False, "plans/phases.json is not an object")
        phase_plan = {}
    if not isinstance(gate_plan, dict):
        check("gate-plan-object", False, "plans/gates.json is not an object")
        gate_plan = {}
    phases = phase_plan.get("phases", [])
    gates = gate_plan.get("gates", [])
    if not isinstance(phases, list):
        check("phase-list", False, "phases is not a list")
        phases = []
    if not isinstance(gates, list):
        check("gate-list", False, "gates is not a list")
        gates = []
    phase_ids = [item.get("id") for item in phases if isinstance(item, dict)]
    gate_ids = [item.get("id") for item in gates if isinstance(item, dict)]
    check("phase-ids-unique", len(phase_ids) == len(set(phase_ids)), phase_ids)
    check("gate-ids-unique", len(gate_ids) == len(set(gate_ids)), gate_ids)
    for phase in phases:
        if not isinstance(phase, dict):
            check("phase-object", False, "phase entry is not an object")
            continue
        for dependency in phase.get("dependencies", []):
            check(
                f"phase-dependency:{phase.get('id')}->{dependency}",
                dependency in phase_ids,
                dependency,
            )
        for gate in phase.get("hard_gates", []):
            check(
                f"phase-gate:{phase.get('id')}->{gate}",
                gate in gate_ids,
                gate,
            )
    completion_requires = gate_plan.get("completion_requires", [])
    if not isinstance(completion_requires, list):
        check("completion-gate-list", False, "completion_requires is not a list")
        completion_requires = []
    for gate in completion_requires:
        check(f"completion-gate:{gate}", gate in gate_ids, gate)

    dependencies = {
        item["id"]: set(item.get("dependencies", []))
        for item in phases
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    remaining = set(dependencies)
    resolved: set[str] = set()
    while remaining:
        ready = {phase for phase in remaining if dependencies[phase] <= resolved}
        if not ready:
            break
        resolved |= ready
        remaining -= ready
    check("phase-dag-acyclic", not remaining, sorted(remaining))

    for entry in entries:
        relative = entry.relative_path
        if not entry.is_file or relative.suffix.lower() != ".py":
            continue
        try:
            raw = read_bounded_repository_bytes(
                root,
                relative,
                label=f"Python source {relative}",
                maximum_bytes=MAXIMUM_PACKAGE_FILE_BYTES,
                budget=budget,
            )
            compile_python_bytes(raw, label=relative.as_posix())
            check(f"python:{relative}", True, "compiled")
        except EvidenceSupportError as error:
            check(f"python:{relative}", False, error)

    bash = shutil.which("bash")
    for entry in entries:
        relative = entry.relative_path
        if not entry.is_file or relative.suffix.lower() != ".sh":
            continue
        if bash is None:
            warnings.append("bash unavailable; shell syntax not checked")
            break
        try:
            raw = read_bounded_repository_bytes(
                root,
                relative,
                label=f"shell source {relative}",
                maximum_bytes=MAXIMUM_PACKAGE_FILE_BYTES,
                budget=budget,
            )
            detail = validate_shell_bytes(
                root,
                raw,
                label=f"shell syntax {relative}",
            )
            check(f"shell:{relative}", True, detail)
        except EvidenceSupportError as error:
            check(f"shell:{relative}", False, error)

    for entry in entries:
        if not stat.S_ISLNK(entry.mode):
            continue
        relative = entry.relative_path
        try:
            inside, target = validate_symlink(root, relative)
            check(f"symlink:{relative}", inside, target)
        except EvidenceSupportError as error:
            check(f"symlink:{relative}", False, error)

    for relative, name in (
        (PurePosixPath("scripts/scan_attribution.py"), "authorship-attribution-scan"),
        (PurePosixPath("scripts/scan_secrets.py"), "secret-scan"),
    ):
        if relative.as_posix() not in entry_map:
            continue
        try:
            detail = run_pinned_python_script(root, relative, label=name)
            check(name, True, detail)
        except EvidenceSupportError as error:
            check(name, False, error)

    is_distribution = "START_HERE.md" in entry_map
    if is_distribution:
        check(
            "included-source-archive",
            entry_map.get("inputs/Forge-Conductor-MacOS-main.zip") is not None,
            "source archive",
        )
        check(
            "included-audit",
            entry_map.get("audit/Forge-Conductor-Consolidated-Audit.md") is not None,
            "audit report",
        )

    return {
        "schema_version": 1,
        "validated_at": datetime.now(timezone.utc).isoformat(),
        "root": str(root),
        "valid": not errors,
        "checks": checks,
        "errors": errors,
        "warnings": warnings,
    }


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--report")
    args = parser.parse_args(arguments)
    try:
        root = Path(args.root).resolve(strict=True)
        report = validate(root)
        report_path = (
            Path(args.report).resolve()
            if args.report
            else root / "PACKAGE_VALIDATION.json"
        )
        encoded = (
            json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n"
        ).encode("utf-8")
        if len(encoded) > MAXIMUM_REPORT_BYTES:
            raise EvidenceSupportError(
                f"package report exceeds its {MAXIMUM_REPORT_BYTES}-byte bound"
            )
        atomic_write(report_path, encoded, final_mode=0o644)
    except (EvidenceSupportError, OSError, UnicodeError, ValueError) as error:
        print(f"Package validation failed closed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({
        "valid": report["valid"],
        "checks": len(report["checks"]),
        "errors": report["errors"],
        "report": str(report_path),
    }, indent=2))
    return 0 if report["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
