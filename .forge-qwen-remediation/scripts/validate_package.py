#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
import zipfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from source_manifest import manifest as source_manifest  # noqa: E402

REQUIRED = [
    "VERSION",
    "README.md",
    "PACKAGE-CONTENTS.md",
    "VALIDATION-SUMMARY.md",
    "QWEN-START-HERE.md",
    "QWEN.md",
    "model/qwen3.8-27b-4bit-profile.json",
    "qwen/settings.template.json",
    "qwen/work-package-cards/P00.md",
    "qwen/work-package-cards/P14.md",
    "schemas/qwen-slice-plan.schema.json",
    "schemas/qwen-invocation-result.schema.json",
    "schemas/qwen-review.schema.json",
    "scripts/configure_qwen_local.py",
    "scripts/prepare_qwen_code.sh",
    "scripts/qwen_preflight.py",
    "scripts/qwen_pretool_guard.py",
    "scripts/run_qwen_autonomously.sh",
    "scripts/run_qwen_review.sh",
    "docs/16-QWEN-CODE-3.8-27B-4BIT-EXECUTION.md",
    "docs/17-QWEN-LOCAL-PROVIDER-AND-RESOURCE-POLICY.md",
    "docs/18-QWEN-AUTONOMOUS-DRIVER-AND-RECOVERY.md",
    "docs/19-QWEN-RESEARCH-BASIS.md",
    "tests/QwenCodeDriverQualification.md",
    "AGENTS.md",
    "DO-NOT-SHIP.md",
    "INPUT-CHECKSUMS.json",
    "audit/Findings.tsv",
    "audit/Feature-Coverage-Matrix.tsv",
    "audit/Forge-Conductor-Current-State-Audit.md",
    "audit/Source-Evidence.md",
    "plans/work-packages.json",
    "plans/gates.json",
    "plans/finding-to-work-package.json",
    "plans/feature-preservation.json",
    "plans/release-blocker-matrix.json",
    "plans/gate-validator-registry.json",
    "plans/final-qualification-order.json",
    "schemas/control-plane-v3.sql",
    "schemas/finding-closure.schema.json",
    "scripts/bootstrap.sh",
    "scripts/install_into_repo.sh",
    "scripts/statectl.py",
    "scripts/accept_gate_result.py",
    "scripts/close_finding.py",
    "scripts/verify_completion.py",
    "inputs/Forge-Conductor-MacOS-main.zip",
    "inputs/Forge-Conductor-Current-State-Full-Audit.zip",
    "inputs/Forge-Conductor-Autonomous-Continuity-Implementation-Design.zip",
    "inputs/Forge-Conductor-E2-Secure-Filesystem-Codex-Package.zip",
    "inputs/Plan Forge Conductor Autonomy.txt",
]

ZIP_INPUTS = [
    "Forge-Conductor-MacOS-main.zip",
    "Forge-Conductor-Current-State-Full-Audit.zip",
    "Forge-Conductor-Autonomous-Continuity-Implementation-Design.zip",
    "Forge-Conductor-E2-Secure-Filesystem-Codex-Package.zip",
]


def add_check(checks: list[dict[str, Any]], errors: list[str], name: str, passed: bool, detail: str = "") -> None:
    checks.append({"name": name, "passed": bool(passed), "detail": detail})
    if not passed:
        errors.append(f"{name}: {detail or 'failed'}")


def load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def validate_dag(graph: dict[str, list[str]]) -> None:
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(node: str) -> None:
        if node in visiting:
            raise ValueError(f"dependency cycle at {node}")
        if node in visited:
            return
        visiting.add(node)
        for dependency in graph[node]:
            if dependency not in graph:
                raise ValueError(f"{node} depends on unknown {dependency}")
            visit(dependency)
        visiting.remove(node)
        visited.add(node)

    for node in graph:
        visit(node)


def expected_manifest_paths() -> set[str]:
    paths: set[str] = set()
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT).as_posix()
        if relative in {"MANIFEST.json", "PACKAGE_VALIDATION.json"}:
            continue
        if relative.startswith("work/") or "/__pycache__/" in f"/{relative}" or relative.endswith(".pyc"):
            continue
        paths.add(relative)
    return paths


def validate_manifest(errors: list[str], checks: list[dict[str, Any]]) -> None:
    path = ROOT / "MANIFEST.json"
    if not path.is_file():
        add_check(checks, errors, "manifest-present", False, "MANIFEST.json missing")
        return
    try:
        document = load(path)
        entries = document["files"]
        indexed = {entry["path"]: entry for entry in entries}
        expected = expected_manifest_paths()
        actual = set(indexed)
        if expected != actual:
            missing = sorted(expected - actual)
            extra = sorted(actual - expected)
            raise ValueError(f"manifest path set mismatch; missing={missing[:20]}, extra={extra[:20]}")
        for relative, entry in indexed.items():
            target = ROOT / relative
            data = target.read_bytes()
            if entry.get("bytes") != len(data):
                raise ValueError(f"manifest byte mismatch: {relative}")
            if entry.get("sha256") != hashlib.sha256(data).hexdigest():
                raise ValueError(f"manifest hash mismatch: {relative}")
        add_check(checks, errors, "manifest-integrity", True, f"{len(entries)} files")
    except Exception as exc:
        add_check(checks, errors, "manifest-integrity", False, str(exc))


def validate_json_schemas(errors: list[str], checks: list[dict[str, Any]]) -> None:
    schema_paths = sorted((ROOT / "schemas").glob("*.schema.json"))
    try:
        import jsonschema  # type: ignore
    except Exception:
        add_check(checks, errors, "json-schema-meta-validation", True, "jsonschema unavailable; JSON syntax and manual contracts still checked")
        return
    try:
        for path in schema_paths:
            jsonschema.Draft202012Validator.check_schema(load(path))
        example_pairs = [
            ("gate-definition.schema.json", "gate-definition.example.json"),
            ("queue-assignment.schema.json", "queue-assignment.example.json"),
            ("release-readiness.schema.json", "release-readiness.example.json"),
            ("finding-closure.schema.json", "finding-closure.example.json"),
            ("gate-result.schema.json", "gate-result.example.json"),
        ]
        for schema_name, example_name in example_pairs:
            jsonschema.Draft202012Validator(load(ROOT / "schemas" / schema_name)).validate(load(ROOT / "templates" / example_name))
        add_check(checks, errors, "json-schema-meta-validation", True, f"{len(schema_paths)} schemas")
    except Exception as exc:
        add_check(checks, errors, "json-schema-meta-validation", False, str(exc))


def validate_inputs(errors: list[str], checks: list[dict[str, Any]]) -> None:
    declared = {item["file"]: item for item in load(ROOT / "INPUT-CHECKSUMS.json")["inputs"]}
    expected_names = set(ZIP_INPUTS + ["Plan Forge Conductor Autonomy.txt"])
    add_check(checks, errors, "input-checksum-index", set(declared) == expected_names, f"declared={sorted(declared)}")
    for name, entry in declared.items():
        path = ROOT / "inputs" / name
        if not path.is_file():
            add_check(checks, errors, f"input:{name}", False, "missing")
            continue
        data = path.read_bytes()
        passed = len(data) == entry["bytes"] and hashlib.sha256(data).hexdigest() == entry["sha256"]
        add_check(checks, errors, f"input:{name}", passed, f"{len(data)} bytes")
    for name in ZIP_INPUTS:
        try:
            with zipfile.ZipFile(ROOT / "inputs" / name) as archive:
                bad = archive.testzip()
                if bad:
                    raise ValueError(f"CRC failure: {bad}")
                for member in archive.namelist():
                    candidate = Path(member)
                    if candidate.is_absolute() or ".." in candidate.parts:
                        raise ValueError(f"unsafe member: {member}")
            add_check(checks, errors, f"zip-safe:{name}", True)
        except Exception as exc:
            add_check(checks, errors, f"zip-safe:{name}", False, str(exc))


def validate_plans(errors: list[str], checks: list[dict[str, Any]]) -> None:
    try:
        with (ROOT / "audit/Findings.tsv").open(newline="", encoding="utf-8") as handle:
            findings = list(csv.DictReader(handle, delimiter="\t"))
        finding_ids = [row["id"] for row in findings]
        if len(finding_ids) != 30 or len(set(finding_ids)) != 30:
            raise ValueError(f"expected 30 unique findings, found {len(finding_ids)}")
        work = load(ROOT / "plans/work-packages.json")["work_packages"]
        gates = load(ROOT / "plans/gates.json")["gates"]
        mapping = load(ROOT / "plans/finding-to-work-package.json")["mapping"]
        blocker_matrix = load(ROOT / "plans/release-blocker-matrix.json")["blockers"]
        validator_registry = load(ROOT / "plans/gate-validator-registry.json")["validators"]
        qualification_order = load(ROOT / "plans/final-qualification-order.json")["stages"]
        work_ids = [item["id"] for item in work]
        gate_ids = [item["id"] for item in gates]
        if len(work_ids) != len(set(work_ids)):
            raise ValueError("duplicate work package IDs")
        if len(gate_ids) != len(set(gate_ids)):
            raise ValueError("duplicate gate IDs")
        work_map = {item["id"]: item for item in work}
        gate_map = {item["id"]: item for item in gates}
        validate_dag({item["id"]: item.get("depends_on", []) for item in work})
        if set(mapping) != set(finding_ids):
            raise ValueError("finding mapping does not cover exactly all audit findings")
        for finding_id, packages in mapping.items():
            if not packages:
                raise ValueError(f"finding {finding_id} has no work package")
            for package in packages:
                if package not in work_map:
                    raise ValueError(f"finding {finding_id} references unknown work package {package}")
        for package in work:
            for gate_id in package.get("gates", []):
                if gate_id not in gate_map:
                    raise ValueError(f"{package['id']} references unknown gate {gate_id}")
                if gate_map[gate_id]["work_package"] not in {package["id"], "P12", "P13", "P14"} and package["id"] not in {"P07", "P08"}:
                    raise ValueError(f"gate {gate_id} ownership is inconsistent with {package['id']}")
            for finding_id in package.get("findings", []):
                if finding_id not in mapping:
                    raise ValueError(f"{package['id']} references unknown finding {finding_id}")
        for gate in gates:
            for field in ("validator_id", "validator_version", "required_platform", "timeout_seconds", "acceptance_contract", "pass_criteria", "forbidden_substitutes"):
                if field not in gate:
                    raise ValueError(f"gate {gate['id']} missing {field}")
            if gate["work_package"] not in work_map:
                raise ValueError(f"gate {gate['id']} references unknown work package")
        if {item["finding_id"] for item in blocker_matrix} != set(finding_ids):
            raise ValueError("release blocker matrix does not cover all findings")
        if {item["gate_id"] for item in validator_registry} != set(gate_ids):
            raise ValueError("gate validator registry does not cover exactly all gates")
        for item in validator_registry:
            definition = gate_map[item["gate_id"]]
            if item["validator_id"] != definition["validator_id"] or item["validator_version"] != definition["validator_version"]:
                raise ValueError(f"validator registry drift for {item['gate_id']}")
        ordered_gates = [gate_id for stage in qualification_order for gate_id in stage["gates"]]
        if set(ordered_gates) != set(gate_ids) or len(ordered_gates) != len(set(ordered_gates)):
            raise ValueError("final qualification order must enumerate every gate exactly once")
        state = load(ROOT / "state/run-state.json")
        if set(state["open_findings"]) != set(finding_ids):
            raise ValueError("initial run state does not contain all thirty open findings")
        if set(state["finding_status"]) != set(finding_ids) or any(value != "open" for value in state["finding_status"].values()):
            raise ValueError("initial finding status map is incomplete")
        if set(state["gate_status"]) != set(gate_ids) or any(value != "pending" for value in state["gate_status"].values()):
            raise ValueError("initial gate status map is incomplete")
        if set(state["gate_receipts"]) != set(gate_ids) or any(value is not None for value in state["gate_receipts"].values()):
            raise ValueError("initial gate receipt map is invalid")
        add_check(checks, errors, "plan-coverage-and-dag", True, f"{len(work)} work packages, {len(gates)} gates, {len(findings)} findings")
    except Exception as exc:
        add_check(checks, errors, "plan-coverage-and-dag", False, str(exc))


def validate_sql(errors: list[str], checks: list[dict[str, Any]]) -> None:
    try:
        connection = sqlite3.connect(":memory:")
        connection.executescript((ROOT / "schemas/control-plane-v3.sql").read_text(encoding="utf-8"))
        connection.executescript("""
        CREATE TABLE IF NOT EXISTS autonomy_events(event_id TEXT PRIMARY KEY, project_id TEXT, created_at TEXT);
        CREATE TABLE IF NOT EXISTS protected_event_references(event_id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS prune_batch_ids(id TEXT PRIMARY KEY);
        """)
        retention_sql = (ROOT / "schemas/retention-pruning.sql").read_text(encoding="utf-8")
        retention_sql = (retention_sql
            .replace(":project_id", "'project-example'")
            .replace(":cutoff", "'9999-12-31T00:00:00Z'")
            .replace(":batch_size", "100"))
        connection.executescript(retention_sql)
        result = connection.execute("PRAGMA integrity_check").fetchone()[0]
        connection.close()
        if result != "ok":
            raise ValueError(result)
        add_check(checks, errors, "sql-schema", True)
    except Exception as exc:
        add_check(checks, errors, "sql-schema", False, str(exc))


def validate_scripts(errors: list[str], checks: list[dict[str, Any]]) -> None:
    for path in sorted((ROOT / "scripts").glob("*.py")):
        try:
            compile(path.read_text(encoding="utf-8"), str(path), "exec")
            add_check(checks, errors, f"python-syntax:{path.name}", True)
        except Exception as exc:
            add_check(checks, errors, f"python-syntax:{path.name}", False, str(exc))
    for path in sorted((ROOT / "scripts").glob("*.sh")):
        result = subprocess.run(["bash", "-n", str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        add_check(checks, errors, f"shell-syntax:{path.name}", result.returncode == 0, result.stdout.strip())
        add_check(checks, errors, f"executable:{path.name}", os.access(path, os.X_OK), "script must be executable")


def validate_hygiene(errors: list[str], checks: list[dict[str, Any]]) -> None:
    bad_cache = [path.relative_to(ROOT).as_posix() for path in ROOT.rglob("*") if path.name == "__pycache__" or path.suffix == ".pyc"]
    add_check(checks, errors, "no-python-cache", not bad_cache, str(bad_cache[:20]))
    symlinks = [path.relative_to(ROOT).as_posix() for path in ROOT.rglob("*") if path.is_symlink()]
    add_check(checks, errors, "no-package-symlinks", not symlinks, str(symlinks[:20]))
    attribution = subprocess.run([sys.executable, str(ROOT / "scripts/scan_publication_hygiene.py"), "--repo", str(ROOT)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    add_check(checks, errors, "publication-hygiene", attribution.returncode == 0, attribution.stdout.strip()[:2000])
    secrets = subprocess.run([sys.executable, str(ROOT / "scripts/scan_secrets.py"), "--repo", str(ROOT)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    add_check(checks, errors, "secret-scan", secrets.returncode == 0, secrets.stdout.strip()[:2000])
    text = (ROOT / "DO-NOT-SHIP.md").read_text(encoding="utf-8")
    add_check(checks, errors, "do-not-ship-contract", "ready_to_ship" in text and "shipped" in text and "false" in text, "terminal state must be ready_to_ship=true, shipped=false")




def run_guard(payload: dict[str, Any]) -> dict[str, Any]:
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts/qwen_pretool_guard.py")],
        input=json.dumps(payload),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"guard exited {result.returncode}: {result.stderr}")
    return json.loads(result.stdout)


def validate_qwen_customization(errors: list[str], checks: list[dict[str, Any]]) -> None:
    try:
        profile = load(ROOT / "model/qwen3.8-27b-4bit-profile.json")
        passed = (
            profile.get("model_family") == "Qwen3.8"
            and profile.get("parameter_class") == "27B dense"
            and profile.get("required_quantization") == "4-bit"
            and profile.get("execution_host") == "Qwen Code CLI"
            and profile.get("do_not_ship") is True
            and profile.get("no_attribution") is True
            and profile.get("absolute_context_ceiling") == 262144
        )
        add_check(checks, errors, "qwen-model-profile", passed, str(profile.get("profile_id")))
    except Exception as exc:
        add_check(checks, errors, "qwen-model-profile", False, str(exc))

    cards = sorted((ROOT / "qwen/work-package-cards").glob("P*.md"))
    expected_cards = [f"P{index:02d}.md" for index in range(15)]
    add_check(
        checks,
        errors,
        "qwen-work-package-cards",
        [path.name for path in cards] == expected_cards,
        f"cards={[path.name for path in cards]}",
    )

    try:
        settings = load(ROOT / "qwen/settings.template.json")
        memory = settings["memory"]
        hooks = settings["hooks"]["PreToolUse"]
        required_hooks = [
            hook
            for group in hooks
            if isinstance(group, dict)
            for hook in group.get("hooks", [])
            if isinstance(hook, dict) and hook.get("name") == "forge-do-not-ship-guard"
        ]
        passed = (
            settings["tools"]["approvalMode"] == "yolo"
            and all(memory.get(key) is False for key in (
                "enableManagedAutoMemory",
                "enableManagedAutoDream",
                "enableAutoSkill",
                "enableTeamMemory",
                "enableTeamMemorySync",
            ))
            and len(required_hooks) == 1
            and settings["model"]["name"] == "__MODEL_ID__"
        )
        add_check(checks, errors, "qwen-settings-template", passed, f"guard_count={len(required_hooks)}")
    except Exception as exc:
        add_check(checks, errors, "qwen-settings-template", False, str(exc))

    driver = (ROOT / "scripts/run_qwen_autonomously.sh").read_text(encoding="utf-8")
    required_fragments = [
        "--model",
        "--approval-mode plan",
        "--approval-mode yolo",
        "--output-format json",
        "--json-schema",
        "--max-session-turns",
        "--max-wall-time",
        "--max-tool-calls",
        "--exclude-tools agent",
        "--append-system-prompt",
        "qwen-slice-plan.schema.json",
        "qwen-invocation-result.schema.json",
        "verify_completion.py",
    ]
    missing = [value for value in required_fragments if value not in driver]
    forbidden = [value for value in ("--continue", "--resume", "--session-id") if value in driver]
    add_check(
        checks,
        errors,
        "qwen-bounded-fresh-session-driver",
        not missing and not forbidden,
        f"missing={missing}, forbidden={forbidden}",
    )

    try:
        allow = run_guard({"tool_name": "run_shell_command", "tool_input": {"command": "swift test --filter MemoryToolTests"}})
        deny_push = run_guard({"tool_name": "run_shell_command", "tool_input": {"command": "git push origin main"}})
        deny_pr = run_guard({"tool_name": "run_shell_command", "tool_input": {"command": "gh pr create --title release"}})
        def decision(value: dict[str, Any]) -> str | None:
            return value.get("hookSpecificOutput", {}).get("permissionDecision")
        passed = decision(allow) == "allow" and decision(deny_push) == "deny" and decision(deny_pr) == "deny"
        add_check(checks, errors, "qwen-pretool-guard", passed, f"allow={decision(allow)} push={decision(deny_push)} pr={decision(deny_pr)}")
    except Exception as exc:
        add_check(checks, errors, "qwen-pretool-guard", False, str(exc))

    try:
        with tempfile.TemporaryDirectory(prefix="qwen-settings-test-") as temporary:
            repo = Path(temporary)
            (repo / ".qwen").mkdir()
            existing = {
                "unrelated": {"keep": True},
                "hooks": {
                    "PreToolUse": [{
                        "matcher": "other_tool",
                        "hooks": [{"type": "command", "name": "other-hook", "command": "true"}],
                    }],
                    "AfterTool": [{"matcher": "*", "hooks": []}],
                },
            }
            (repo / ".qwen/settings.json").write_text(json.dumps(existing), encoding="utf-8")
            command = [
                sys.executable,
                str(ROOT / "scripts/configure_qwen_local.py"),
                "--repo",
                str(repo),
                "--base-url",
                "http://127.0.0.1:9/v1",
                "--no-provider-probe",
            ]
            first = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False, timeout=60)
            second = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False, timeout=60)
            configured = load(repo / ".qwen/settings.json")
            pre = configured.get("hooks", {}).get("PreToolUse", [])
            names = [
                hook.get("name")
                for group in pre if isinstance(group, dict)
                for hook in group.get("hooks", []) if isinstance(hook, dict)
            ]
            passed = (
                first.returncode == 0
                and second.returncode == 0
                and configured.get("unrelated", {}).get("keep") is True
                and "AfterTool" in configured.get("hooks", {})
                and "other-hook" in names
                and names.count("forge-do-not-ship-guard") == 1
            )
            add_check(checks, errors, "qwen-settings-merge-idempotent", passed, (first.stdout + second.stdout)[-2000:])
    except Exception as exc:
        add_check(checks, errors, "qwen-settings-merge-idempotent", False, str(exc))

    try:
        with tempfile.TemporaryDirectory(prefix="qwen-output-test-") as temporary:
            sample = Path(temporary) / "output.json"
            sample.write_text(json.dumps([{
                "type": "result",
                "model": "Qwen3.8-27B-Q4_K_M",
                "result": json.dumps({"ok": True, "model": "Qwen3.8-27B-Q4_K_M"}),
                "is_error": False,
            }]), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/extract_qwen_structured.py"), str(sample)],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            value = json.loads(result.stdout) if result.returncode == 0 else {}
            passed = value.get("structured", {}).get("ok") is True and value.get("model") == "Qwen3.8-27B-Q4_K_M"
            add_check(checks, errors, "qwen-structured-output-extractor", passed, result.stdout[-1000:])
    except Exception as exc:
        add_check(checks, errors, "qwen-structured-output-extractor", False, str(exc))

def validate_deep(errors: list[str], checks: list[dict[str, Any]]) -> None:
    with tempfile.TemporaryDirectory(prefix="forge-package-deep-") as temporary:
        temp_root = Path(temporary)
        with zipfile.ZipFile(ROOT / "inputs/Forge-Conductor-MacOS-main.zip") as archive:
            archive.extractall(temp_root)
        repositories = [path.parent for path in temp_root.rglob("Package.swift") if (path.parent / "Sources").is_dir() and (path.parent / "Tests").is_dir()]
        if len(repositories) != 1:
            add_check(checks, errors, "deep-source-root", False, f"expected one repository, found {repositories}")
            return
        repository = repositories[0]
        generated = source_manifest(repository)
        expected = load(ROOT / "evidence/current-source-manifest.json")
        add_check(
            checks,
            errors,
            "deep-source-manifest",
            generated["manifest_sha256"] == expected["manifest_sha256"] and generated["file_count"] == expected["file_count"],
            f"generated={generated['manifest_sha256']} expected={expected['manifest_sha256']}",
        )
        before = generated["manifest_sha256"]
        result = subprocess.run([sys.executable, str(ROOT / "scripts/install_into_repo.py"), str(repository)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        add_check(checks, errors, "deep-installer", result.returncode == 0, result.stdout.strip()[:4000])
        installed = all((repository / name).is_dir() for name in (".forge-qwen-remediation", ".forge-continuity-design", ".forge-e2", ".forge-qwen-state"))
        add_check(checks, errors, "deep-installed-directories", installed)
        qwen_installed = (repository / "QWEN.md").is_file() and (repository / ".qwen/settings.json").is_file()
        add_check(checks, errors, "deep-qwen-files-installed", qwen_installed)
        root_qwen = (repository / "QWEN.md").read_text(encoding="utf-8") if (repository / "QWEN.md").is_file() else ""
        root_agents = (repository / "AGENTS.md").read_text(encoding="utf-8") if (repository / "AGENTS.md").is_file() else ""
        marker = "<!-- FORGE-QWEN-REMEDIATION:BEGIN -->"
        add_check(checks, errors, "deep-root-markers", root_qwen.count(marker) == 1 and root_agents.count(marker) == 1)
        installed_cards = sorted((repository / ".forge-qwen-remediation/qwen/work-package-cards").glob("P*.md"))
        add_check(checks, errors, "deep-qwen-cards-installed", len(installed_cards) == 15, f"cards={len(installed_cards)}")
        specialist_qwen = all((repository / name / "QWEN.md").is_file() for name in (".forge-continuity-design", ".forge-e2"))
        add_check(checks, errors, "deep-specialist-qwen-contracts", specialist_qwen)
        settings = load(repository / ".qwen/settings.json") if (repository / ".qwen/settings.json").is_file() else {}
        guard_count = sum(
            1
            for group in settings.get("hooks", {}).get("PreToolUse", [])
            if isinstance(group, dict)
            for hook in group.get("hooks", [])
            if isinstance(hook, dict) and hook.get("name") == "forge-do-not-ship-guard"
        )
        add_check(checks, errors, "deep-qwen-guard-installed-once", guard_count == 1, f"guard_count={guard_count}")
        after = source_manifest(repository)["manifest_sha256"]
        add_check(checks, errors, "deep-installer-source-preservation", before == after, f"before={before} after={after}")
        selector = subprocess.run([sys.executable, str(repository / ".forge-qwen-remediation/scripts/select_next_work.py"), "--repo", str(repository)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        add_check(checks, errors, "deep-work-selector", selector.returncode == 0 and '"id": "P00"' in selector.stdout, selector.stdout.strip()[:2000])
        manual_pass = subprocess.run([sys.executable, str(repository / ".forge-qwen-remediation/scripts/statectl.py"), "--repo", str(repository), "gate", "G00", "passed"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        add_check(checks, errors, "deep-manual-gate-pass-rejected", manual_pass.returncode != 0, manual_pass.stdout.strip()[:1000])
        early_complete = subprocess.run([sys.executable, str(repository / ".forge-qwen-remediation/scripts/statectl.py"), "--repo", str(repository), "complete", "P00"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        add_check(checks, errors, "deep-early-work-completion-rejected", early_complete.returncode != 0, early_complete.stdout.strip()[:1000])
        completion = subprocess.run([sys.executable, str(repository / ".forge-qwen-remediation/scripts/verify_completion.py"), "--repo", str(repository)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        add_check(checks, errors, "deep-initial-completion-must-fail", completion.returncode != 0 and '"ready_to_ship": false' in completion.stdout, completion.stdout.strip()[:2000])
        task = subprocess.run([sys.executable, str(repository / ".forge-qwen-remediation/scripts/prepare_qwen_task.py"), "--repo", str(repository)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        current_task = (repository / ".forge-qwen-state/current-task.md").read_text(encoding="utf-8") if (repository / ".forge-qwen-state/current-task.md").is_file() else ""
        add_check(checks, errors, "deep-qwen-task-preparation", task.returncode == 0 and "P00" in current_task, task.stdout.strip()[:2000])
        second = subprocess.run([sys.executable, str(ROOT / "scripts/install_into_repo.py"), str(repository)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        second_after = source_manifest(repository)["manifest_sha256"]
        root_qwen_second = (repository / "QWEN.md").read_text(encoding="utf-8")
        root_agents_second = (repository / "AGENTS.md").read_text(encoding="utf-8")
        settings_second = load(repository / ".qwen/settings.json")
        guard_count_second = sum(
            1
            for group in settings_second.get("hooks", {}).get("PreToolUse", [])
            if isinstance(group, dict)
            for hook in group.get("hooks", [])
            if isinstance(hook, dict) and hook.get("name") == "forge-do-not-ship-guard"
        )
        idempotent = (
            second.returncode == 0
            and second_after == before
            and root_qwen_second.count(marker) == 1
            and root_agents_second.count(marker) == 1
            and guard_count_second == 1
        )
        add_check(checks, errors, "deep-installer-idempotent", idempotent, second.stdout.strip()[-2000:])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--deep", action="store_true", help="also extract and install into a temporary current repository")
    args = parser.parse_args()
    errors: list[str] = []
    checks: list[dict[str, Any]] = []

    for relative in REQUIRED:
        add_check(checks, errors, f"required:{relative}", (ROOT / relative).is_file(), "missing" if not (ROOT / relative).is_file() else "")
    for path in ROOT.rglob("*.json"):
        try:
            load(path)
        except Exception as exc:
            errors.append(f"invalid JSON {path.relative_to(ROOT)}: {exc}")
    validate_json_schemas(errors, checks)
    validate_inputs(errors, checks)
    validate_plans(errors, checks)
    validate_sql(errors, checks)
    validate_scripts(errors, checks)
    validate_hygiene(errors, checks)
    validate_qwen_customization(errors, checks)
    validate_manifest(errors, checks)
    if args.deep:
        validate_deep(errors, checks)

    report = {
        "schema_version": 1,
        "valid": not errors,
        "deep": args.deep,
        "checks_passed": sum(1 for check in checks if check["passed"]),
        "checks_total": len(checks),
        "checks": checks,
        "errors": errors,
    }
    (ROOT / "PACKAGE_VALIDATION.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
