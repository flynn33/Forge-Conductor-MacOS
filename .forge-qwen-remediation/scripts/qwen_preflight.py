#!/usr/bin/env python3
from __future__ import annotations
import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REQUIRED_FLAGS = [
    "--prompt",
    "--model",
    "--output-format",
    "--json-schema",
    "--approval-mode",
    "--max-session-turns",
    "--max-wall-time",
    "--max-tool-calls",
    "--exclude-tools",
    "--append-system-prompt",
]

def run(command: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        **kwargs,
    )

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--skip-smoke", action="store_true")
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    design = repo / ".forge-qwen-remediation"
    state = repo / ".forge-qwen-state"
    state.mkdir(exist_ok=True)
    report = {
        "schema_version": 1,
        "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "passed": False,
        "checks": [],
    }

    if shutil.which("qwen") is None:
        preparation = run(
            [str(design / "scripts/prepare_qwen_code.sh")],
            cwd=repo,
        )
        report["checks"].append({
            "name": "qwen-install",
            "passed": preparation.returncode == 0,
            "detail": (preparation.stdout + preparation.stderr)[-4000:],
        })
        if preparation.returncode:
            (state / "qwen-preflight.json").write_text(
                json.dumps(report, indent=2) + "\n"
            )
            print(json.dumps(report, indent=2))
            return 69

    version = run(["qwen", "--version"], cwd=repo, timeout=20)
    help_result = run(["qwen", "--help"], cwd=repo, timeout=20)
    help_text = help_result.stdout + help_result.stderr
    missing = [flag for flag in REQUIRED_FLAGS if flag not in help_text]
    report["qwen_version"] = (version.stdout + version.stderr).strip()
    report["checks"].append({
        "name": "required-cli-flags",
        "passed": not missing,
        "detail": missing,
    })

    configuration = run(
        [
            sys.executable,
            str(design / "scripts/configure_qwen_local.py"),
            "--repo",
            str(repo),
            "--strict",
        ],
        cwd=repo,
        timeout=180,
    )
    report["checks"].append({
        "name": "local-provider",
        "passed": configuration.returncode == 0,
        "detail": (configuration.stdout + configuration.stderr)[-8000:],
    })
    if missing or configuration.returncode:
        (state / "qwen-preflight.json").write_text(
            json.dumps(report, indent=2) + "\n"
        )
        print(json.dumps(report, indent=2))
        return 69

    profile = json.loads((state / "qwen-provider.json").read_text())
    if not args.skip_smoke:
        schema = {
            "type": "object",
            "additionalProperties": False,
            "required": ["ok", "model"],
            "properties": {
                "ok": {"const": True},
                "model": {"type": "string"},
            },
        }
        environment = os.environ.copy()
        environment.setdefault("FORGE_QWEN_LOCAL_API_KEY", "local-only")
        environment.setdefault("QWEN_CODE_SUPPRESS_YOLO_WARNING", "1")
        command = [
            "qwen",
            "-p",
            "Return a structured object with ok=true and the active model ID. Do not use tools.",
            "--model",
            profile["model_id"],
            "--output-format",
            "json",
            "--json-schema",
            json.dumps(schema, separators=(",", ":")),
            "--approval-mode",
            "plan",
            "--max-session-turns",
            "4",
            "--max-wall-time",
            "3m",
            "--max-tool-calls",
            "2",
            "--exclude-tools",
            "agent",
        ]
        smoke = run(command, cwd=repo, env=environment, timeout=240)
        output_path = state / "qwen-preflight-smoke.json"
        output_path.write_text(smoke.stdout, encoding="utf-8")
        parsed = None
        if smoke.stdout.strip():
            extraction = run(
                [
                    sys.executable,
                    str(design / "scripts/extract_qwen_structured.py"),
                    str(output_path),
                ],
                cwd=repo,
                timeout=20,
            )
            if extraction.returncode == 0:
                parsed = json.loads(extraction.stdout)
        structured = (parsed or {}).get("structured")
        passed = (
            smoke.returncode == 0
            and isinstance(structured, dict)
            and structured.get("ok") is True
            and parsed.get("model") == profile["model_id"]
        )
        report["checks"].append({
            "name": "structured-model-smoke",
            "passed": passed,
            "exit_code": smoke.returncode,
            "stderr": smoke.stderr[-4000:],
            "parsed": parsed,
        })

    report["passed"] = all(check.get("passed") for check in report["checks"])
    (state / "qwen-preflight.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 69

if __name__ == "__main__":
    raise SystemExit(main())
