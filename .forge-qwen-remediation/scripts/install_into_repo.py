#!/usr/bin/env python3
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
MARKER_BEGIN = "<!-- FORGE-QWEN-REMEDIATION:BEGIN -->"
MARKER_END = "<!-- FORGE-QWEN-REMEDIATION:END -->"
AGENT_MARKER = (
    MARKER_BEGIN
    + "\n# Shippable remediation contract\n\n"
    + "Read `.forge-qwen-remediation/AGENTS.md` and use its doctor, "
    + "selector, deterministic gates, and do-not-ship boundary. Shell "
    + "access and every current feature must remain available.\n"
    + MARKER_END
    + "\n"
)
QWEN_MARKER = (
    MARKER_BEGIN
    + "\n# Forge Conductor remediation\n\n"
    + "Read @.forge-qwen-remediation/QWEN-START-HERE.md and "
    + "@.forge-qwen-state/current-task.md. Use fresh bounded sessions, "
    + "deterministic validators, and durable handoffs. Do not ship or "
    + "add model/tool attribution.\n"
    + MARKER_END
    + "\n"
)

def backup(path: Path) -> None:
    if not path.exists():
        return
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    repository = path.parent
    backup_root = repository / ".forge-qwen-state" / "install-backups" / stamp
    backup_root.mkdir(parents=True, exist_ok=False)
    destination = backup_root / path.name
    if path.is_dir():
        shutil.copytree(path, destination)
    else:
        shutil.copy2(path, destination)

def patch(path: Path, marker: str) -> None:
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    if MARKER_BEGIN in text and MARKER_END in text:
        text = (
            text.split(MARKER_BEGIN, 1)[0]
            + marker
            + text.split(MARKER_END, 1)[1].lstrip("\n")
        )
    else:
        text = marker + "\n" + text
    path.write_text(text, encoding="utf-8")


def product_source_digest(target: Path) -> str:
    result = subprocess.run(
        [
            sys.executable,
            str(PACKAGE / "scripts/source_manifest.py"),
            "--repo",
            str(target),
            "--digest-only",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "could not compute product source manifest: "
            + (result.stdout + result.stderr)[-2000:]
        )
    return result.stdout.strip()


def write_specialist_qwen(target: Path, kind: str) -> None:
    if kind == "continuity":
        content = """# Forge Conductor continuity specialist design

This directory is a required design input. Read the root repository `QWEN.md`, the selected `.forge-qwen-state/current-task.md`, and only the continuity documents referenced by the selected work-package card.

Do not run a package-specific autonomous driver from this directory. The root `.forge-qwen-remediation` ledger, validators, shell non-regression rule, no-attribution rule, and do-not-ship boundary remain authoritative.
"""
    else:
        content = """# Forge Conductor E2 specialist design

This directory is a required design input. Read the root repository `QWEN.md`, the selected `.forge-qwen-state/current-task.md`, and only the E2 documents referenced by the selected work-package card.

Implement the atomic-capture design through the root remediation ledger. Do not use a package-specific autonomous driver from this directory. Do not disable shell, bypass deterministic gates, publish changes, or add model/tool attribution.
"""
    (target / "QWEN.md").write_text(content, encoding="utf-8")

def copy_design(target: Path) -> None:
    destination = target / ".forge-qwen-remediation"
    backup(destination)
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    names = [
        "VERSION",
        "README.md",
        "PACKAGE-CONTENTS.md",
        "VALIDATION-SUMMARY.md",
        "QWEN-START-HERE.md",
        "QWEN.md",
        "AGENTS.md",
        "DO-NOT-SHIP.md",
        "INPUT-CHECKSUMS.json",
        "audit",
        "docs",
        "architecture",
        "plans",
        "schemas",
        "interfaces",
        "tests",
        "scripts",
        "templates",
        "evidence",
        "state",
        "model",
        "qwen",
    ]
    for name in names:
        source = PACKAGE / name
        output = destination / name
        if source.is_dir():
            shutil.copytree(source, output)
        elif source.is_file():
            shutil.copy2(source, output)
    for script in (destination / "scripts").iterdir():
        if script.is_file() and script.suffix in {".py", ".sh"}:
            script.chmod(script.stat().st_mode | 0o111)

    entries = []
    for item in sorted(destination.rglob("*")):
        if not item.is_file() or item.name == "INSTALLED-MANIFEST.json":
            continue
        data = item.read_bytes()
        entries.append({
            "path": item.relative_to(destination).as_posix(),
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        })
    (destination / "INSTALLED-MANIFEST.json").write_text(
        json.dumps({"schema_version": 1, "files": entries}, indent=2)
        + "\n"
    )

def extract_design(zip_path: Path, target: Path) -> None:
    backup(target)
    if target.exists():
        shutil.rmtree(target)
    with tempfile.TemporaryDirectory() as temporary:
        with zipfile.ZipFile(zip_path) as archive:
            for name in archive.namelist():
                candidate = Path(name)
                if candidate.is_absolute() or ".." in candidate.parts:
                    raise RuntimeError(f"unsafe ZIP member {name}")
            archive.extractall(temporary)
        roots = [path for path in Path(temporary).iterdir() if path.is_dir()]
        if len(roots) != 1:
            raise RuntimeError(
                f"expected one top-level directory in {zip_path.name}"
            )
        shutil.copytree(roots[0], target)
    scripts = target / "scripts"
    if scripts.exists():
        for script in scripts.iterdir():
            if script.is_file() and script.suffix in {".py", ".sh"}:
                script.chmod(script.stat().st_mode | 0o111)

def initialize_state(target: Path) -> None:
    state = target / ".forge-qwen-state"
    state.mkdir(exist_ok=True)
    for name in [
        "run-state.json",
        "issues.json",
        "events.jsonl",
        "current-handoff.json",
    ]:
        output = state / name
        if not output.exists():
            shutil.copy2(PACKAGE / "state" / name, output)
    for name in [
        "evidence",
        "command-logs",
        "gate-results",
        "finding-closures",
        "release-candidate",
        "qwen-invocations",
        "qwen-plans",
        "qwen-reviews",
    ]:
        (state / name).mkdir(exist_ok=True)

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    args = parser.parse_args()
    target = Path(args.repo).resolve()
    missing = [
        name
        for name in ("Package.swift", "Sources", "Tests")
        if not (target / name).exists()
    ]
    if missing:
        raise SystemExit(
            f"not a Forge Conductor repository: missing {missing}"
        )

    before_source = product_source_digest(target)
    copy_design(target)
    extract_design(
        PACKAGE
        / "inputs/Forge-Conductor-Autonomous-Continuity-Implementation-Design.zip",
        target / ".forge-continuity-design",
    )
    extract_design(
        PACKAGE
        / "inputs/Forge-Conductor-E2-Secure-Filesystem-Codex-Package.zip",
        target / ".forge-e2",
    )
    write_specialist_qwen(target / ".forge-continuity-design", "continuity")
    write_specialist_qwen(target / ".forge-e2", "e2")
    patch(target / "AGENTS.md", AGENT_MARKER)
    patch(target / "QWEN.md", QWEN_MARKER)
    initialize_state(target)
    after_source = product_source_digest(target)
    if before_source != after_source:
        raise RuntimeError(
            "installation changed Forge Conductor product source: "
            f"before={before_source} after={after_source}"
        )

    # Install safe project-local Qwen controls even when no provider is running.
    subprocess.run(
        [
            sys.executable,
            str(
                target
                / ".forge-qwen-remediation/scripts/configure_qwen_local.py"
            ),
            "--repo",
            str(target),
            "--no-provider-probe",
        ],
        check=False,
    )
    print(json.dumps({
        "installed": True,
        "repo": str(target),
        "design": str(target / ".forge-qwen-remediation"),
        "state": str(target / ".forge-qwen-state"),
        "source_manifest_preserved": before_source == after_source,
        "source_manifest_sha256": after_source,
        "do_not_ship": True,
    }, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
