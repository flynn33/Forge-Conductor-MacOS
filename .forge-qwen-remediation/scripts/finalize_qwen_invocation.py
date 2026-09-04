#!/usr/bin/env python3
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import subprocess
import sys
from pathlib import Path

def sha256(path: Path) -> str | None:
    return (
        hashlib.sha256(path.read_bytes()).hexdigest()
        if path.is_file()
        else None
    )

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--stdout", required=True)
    parser.add_argument("--stderr", required=True)
    parser.add_argument("--exit-code", required=True, type=int)
    parser.add_argument("--invocation", required=True, type=int)
    parser.add_argument(
        "--kind",
        choices=["plan", "implement", "review"],
        required=True,
    )
    parser.add_argument("--before-source", required=True)
    parser.add_argument("--before-state")
    parser.add_argument("--before-handoff")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    design = repo / ".forge-qwen-remediation"
    state = repo / ".forge-qwen-state"
    invocation_dir = state / "qwen-invocations"
    invocation_dir.mkdir(parents=True, exist_ok=True)
    stdout = Path(args.stdout).resolve()
    stderr = Path(args.stderr).resolve()
    normalized = (
        invocation_dir
        / f"{args.invocation:04d}-{args.kind}-normalized.json"
    )

    parsed = None
    parse_error = None
    if stdout.is_file() and stdout.stat().st_size:
        result = subprocess.run(
            [
                sys.executable,
                str(design / "scripts/extract_qwen_structured.py"),
                str(stdout),
                "--output",
                str(normalized),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode == 0:
            parsed = json.loads(normalized.read_text())
        else:
            parse_error = (result.stdout + result.stderr)[-4000:]

    after_source = subprocess.check_output(
        [
            sys.executable,
            str(design / "scripts/source_manifest.py"),
            "--repo",
            str(repo),
            "--digest-only",
        ],
        text=True,
    ).strip()
    state_path = state / "run-state.json"
    handoff_path = state / "current-handoff.json"
    selected = (
        json.loads((state / "selected-work.json").read_text())
        if (state / "selected-work.json").is_file()
        else {}
    )
    selected_work = (
        selected.get("work_package")
        or selected.get("selected")
        or {}
    ).get("id")
    structured = (parsed or {}).get("structured")
    warnings: list[str] = []
    if isinstance(structured, dict):
        if structured.get("claims_gate_passed") is True:
            warnings.append(
                "model attempted to claim a gate pass; claim ignored"
            )
        if (
            structured.get("work_package_id")
            and selected_work
            and structured["work_package_id"] != selected_work
        ):
            warnings.append(
                "structured result work package does not match selected work"
            )

    after_handoff = sha256(handoff_path)
    if (
        args.kind == "implement"
        and args.before_handoff == after_handoff
    ):
        summary = "Qwen invocation ended without updating the durable handoff."
        next_action = (
            "Inspect the raw invocation logs, verify repository state, "
            "and continue with a different bounded strategy."
        )
        if isinstance(structured, dict):
            summary = str(structured.get("summary") or summary)[:3000]
            next_action = str(
                structured.get("next_action") or next_action
            )[:2000]
        subprocess.run(
            [
                sys.executable,
                str(design / "scripts/statectl.py"),
                "--repo",
                str(repo),
                "handoff",
                "--summary",
                summary,
                "--next",
                next_action,
            ],
            check=False,
        )
        after_handoff = sha256(handoff_path)

    def relative_or_absolute(path: Path) -> str:
        try:
            return path.relative_to(repo).as_posix()
        except ValueError:
            return str(path)

    record = {
        "schema_version": 1,
        "invocation": args.invocation,
        "kind": args.kind,
        "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "exit_code": args.exit_code,
        "selected_work_package": selected_work,
        "before_source_manifest": args.before_source,
        "after_source_manifest": after_source,
        "before_state_sha256": args.before_state,
        "after_state_sha256": sha256(state_path),
        "before_handoff_sha256": args.before_handoff,
        "after_handoff_sha256": after_handoff,
        "stdout": {
            "path": relative_or_absolute(stdout),
            "bytes": stdout.stat().st_size if stdout.exists() else 0,
            "sha256": sha256(stdout),
        },
        "stderr": {
            "path": relative_or_absolute(stderr),
            "bytes": stderr.stat().st_size if stderr.exists() else 0,
            "sha256": sha256(stderr),
        },
        "parsed": parsed,
        "parse_error": parse_error,
        "warnings": warnings,
        "gate_authority": "none; model output cannot pass a gate",
        "shipped": False,
    }
    output = (
        invocation_dir
        / f"{args.invocation:04d}-{args.kind}-record.json"
    )
    output.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
