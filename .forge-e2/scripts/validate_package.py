#!/usr/bin/env python3
from __future__ import annotations
import argparse
import ast
import json
import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--root")
parser.add_argument("--allow-missing-input-archive", action="store_true")
args = parser.parse_args()
root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[1]

required = [
    "README.md", "CODEX-START-HERE.md", "AGENTS.md", "INSTALLATION.md",
    "docs/01-E2-RESEARCH-CONCLUSION.md",
    "docs/13-RELEASE-COMPLETION-CONTRACT.md",
    "docs/17-ATOMIC-CAPTURE-PSEUDOCODE.md",
    "docs/18-IMPLEMENTATION-CHANGE-MAP.md",
    "docs/19-E2-CLOSURE-ARGUMENT.md",
    "docs/20-FILESYSTEM-CAPABILITY-AND-VOLUME-MATRIX.md",
    "docs/21-MIGRATION-ROLLOUT-AND-COMPATIBILITY.md",
    "work/work-packages.json", "work/acceptance-gates.json",
    "schemas/filesystem-transactions.sql",
    "schemas/filesystem-capability.schema.json",
    "schemas/filesystem-transaction.schema.json",
    "schemas/filesystem-receipt.schema.json",
    "blueprints/CForgeSecureFS/include/CForgeSecureFS.h",
    "blueprints/CForgeSecureFS/src/CForgeSecureFS.c",
    "blueprints/Swift/AtomicNamespaceTransaction.swift",
    "blueprints/Tests/AtomicSwapAttacker.c",
    "scripts/install_into_repo.sh", "scripts/macos_api_probe.c",
    "scripts/verify_baseline.py", "scripts/validate_manifest.py",
    "evidence/source-baseline.json", "evidence/apple-api-matrix.json",
    "MANIFEST.json",
]
missing = [path for path in required if not (root / path).is_file()]
if missing:
    raise SystemExit("missing required files: " + ", ".join(missing))

# Reject unsafe or ambiguous package paths before parsing content.
for path in root.rglob("*"):
    relative = path.relative_to(root)
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit(f"unsafe package path: {relative}")
    if path.is_symlink():
        raise SystemExit(f"package symlinks are forbidden: {relative}")

# JSON syntax and, when installed, JSON Schema self-validation.
json_objects: dict[Path, object] = {}
for path in root.rglob("*.json"):
    try:
        json_objects[path] = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"invalid JSON: {path}: {exc}") from exc
try:
    from jsonschema import Draft202012Validator  # type: ignore
except Exception:
    Draft202012Validator = None
if Draft202012Validator is not None:
    for path in (root / "schemas").glob("*.schema.json"):
        Draft202012Validator.check_schema(json_objects[path])

for path in root.rglob("*.py"):
    try:
        ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError as exc:
        raise SystemExit(f"invalid Python: {path}: {exc}") from exc

work_graph = json_objects[root / "work/work-packages.json"]
packages = work_graph["packages"]
ids = [item["id"] for item in packages]
if len(ids) != len(set(ids)):
    raise SystemExit("duplicate work package IDs")
by_id = {item["id"]: item for item in packages}
for item in packages:
    unknown = set(item["depends_on"]) - set(ids)
    if unknown:
        raise SystemExit(f"{item['id']} has unknown dependencies: {sorted(unknown)}")
visiting: set[str] = set()
visited: set[str] = set()
def visit(node: str) -> None:
    if node in visiting:
        raise SystemExit(f"work graph cycle at {node}")
    if node in visited:
        return
    visiting.add(node)
    for dependency in by_id[node]["depends_on"]:
        visit(dependency)
    visiting.remove(node)
    visited.add(node)
for node in ids:
    visit(node)

gates = json_objects[root / "work/acceptance-gates.json"]["gates"]
gate_ids = [item["id"] for item in gates]
if len(gate_ids) != len(set(gate_ids)):
    raise SystemExit("duplicate acceptance gate IDs")
state = json_objects[root / "work/state-template.json"]
if set(state["work"]) != set(ids):
    raise SystemExit("state template work IDs differ from work graph")
if set(state["gates"]) != set(gate_ids):
    raise SystemExit("state template gate IDs differ from acceptance gates")

with sqlite3.connect(":memory:") as database:
    database.execute("PRAGMA foreign_keys=ON")
    database.execute("CREATE TABLE projects(project_id TEXT PRIMARY KEY)")
    database.executescript((root / "schemas/filesystem-transactions.sql").read_text())
    if database.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        raise SystemExit("SQLite schema integrity check failed")

bash = shutil.which("bash")
if os.name != "nt" and bash:
    for path in root.rglob("*.sh"):
        result = subprocess.run([bash, "-n", str(path)], capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(f"shell syntax failed: {path}\n{result.stderr}")

# Compile the public-SDK probe only where the required SDK exists.
if sys.platform == "darwin" and shutil.which("xcrun"):
    result = subprocess.run(
        [str(root / "scripts/run_macos_api_probe.sh")],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise SystemExit(f"macOS API probe failed\n{result.stdout}\n{result.stderr}")

manifest_command = [
    sys.executable,
    str(root / "scripts/validate_manifest.py"),
    "--root", str(root),
]
if args.allow_missing_input_archive:
    manifest_command.append("--allow-missing-input-archive")
result = subprocess.run(manifest_command, capture_output=True, text=True)
if result.returncode:
    raise SystemExit(result.stdout + result.stderr)

print(f"Package validation passed: {root}")
print(f"Work packages: {len(ids)}; hard gates: {sum(bool(g['hard']) for g in gates)}")
