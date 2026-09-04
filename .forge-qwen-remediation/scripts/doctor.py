#!/usr/bin/env python3
from __future__ import annotations
import argparse
import datetime as dt
import json
import platform
import subprocess
from pathlib import Path

def command(arguments: list[str]) -> dict:
    try:
        result = subprocess.run(
            arguments,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        return {
            "available": True,
            "exit_code": result.returncode,
            "output": result.stdout.strip()[:8192],
        }
    except FileNotFoundError:
        return {"available": False, "exit_code": None, "output": "not found"}
    except Exception as error:
        return {"available": True, "exit_code": None, "output": str(error)}

def read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    state = repo / ".forge-qwen-state"
    state.mkdir(exist_ok=True)
    report = {
        "schema_version": 2,
        "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "repo": str(repo),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "tools": {
            "git": command(["git", "--version"]),
            "swift": command(["swift", "--version"]),
            "xcodebuild": command(["xcodebuild", "-version"]),
            "codesign": command(["codesign", "--version"]),
            "security_identities": command([
                "security", "find-identity", "-v", "-p", "codesigning"
            ]),
            "lms": command(["lms", "--version"]),
            "qwen": command(["qwen", "--version"]),
            "pwsh": command([
                "pwsh", "-NoLogo", "-NoProfile", "-Command",
                "$PSVersionTable.PSVersion.ToString()",
            ]),
            "xctrace": command(["xcrun", "xctrace", "version"]),
        },
        "qwen_provider": read_json(state / "qwen-provider.json"),
        "qwen_preflight": read_json(state / "qwen-preflight.json"),
        "paths": {
            "package_swift": (repo / "Package.swift").is_file(),
            "xcode_project": (repo / "ForgeConductor.xcodeproj").is_dir(),
            "build_script": (repo / "script/build_and_run.sh").is_file(),
            "qwen_settings": (repo / ".qwen/settings.json").is_file(),
            "qwen_contract": (repo / "QWEN.md").is_file(),
        },
        "do_not_ship": True,
    }
    (state / "environment.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
