#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from typing import Any

BLOCKS: list[tuple[re.Pattern[str], str]] = [
    (
        re.compile(r"(^|[;&|]\s*)git\s+(?:push\b|tag\b)", re.I),
        "publishing Git refs or creating release tags is forbidden",
    ),
    (
        re.compile(r"\bgit\s+remote\s+(?:add|set-url|rename|remove)\b", re.I),
        "changing remote publication targets is forbidden during remediation",
    ),
    (
        re.compile(
            r"\bgh\s+(?:release\s+create|pr\s+(?:create|merge)|repo\s+(?:create|sync)|gist\s+create)\b",
            re.I,
        ),
        "GitHub publication, pull-request creation, or merge is forbidden",
    ),
    (
        re.compile(
            r"\b(?:npm|pnpm|yarn)\s+publish\b|\bpython\d*\s+-m\s+twine\s+upload\b|\btwine\s+upload\b",
            re.I,
        ),
        "package publication is forbidden",
    ),
    (
        re.compile(
            r"\b(?:swift\s+package-registry\s+publish|pod\s+trunk\s+push|docker\s+push)\b",
            re.I,
        ),
        "registry publication is forbidden",
    ),
    (
        re.compile(
            r"\b(?:xcrun\s+)?notarytool\s+submit\b|\baltool\b[^\n]*(?:upload|validate-app)",
            re.I,
        ),
        "distribution submission is forbidden",
    ),
    (
        re.compile(
            r"\b(?:fastlane\s+(?:deliver|pilot|upload_to_app_store)|"
            r"xcodebuild\s+-exportArchive\b[^\n]*(?:app-store|upload))",
            re.I,
        ),
        "store delivery is forbidden",
    ),
    (
        re.compile(
            r"\b(?:scp|sftp)\b|\brsync\b[^\n]*(?:[A-Za-z0-9_.-]+@|::)",
            re.I,
        ),
        "remote artifact transfer is forbidden",
    ),
    (
        re.compile(
            r"\b(?:aws\s+s3\s+(?:cp|sync)|gsutil\s+(?:cp|rsync)|"
            r"az\s+storage\s+blob\s+upload)\b",
            re.I,
        ),
        "cloud artifact upload is forbidden",
    ),
    (
        re.compile(
            r"\bcurl\b[^\n]*(?:--upload-file|-T(?:\s|=)|--data-binary\s*@)",
            re.I,
        ),
        "network upload is forbidden",
    ),
    (
        re.compile(
            r"\brm\s+-[A-Za-z]*r[A-Za-z]*f[A-Za-z]*\s+(?:/|~|\$HOME)(?:\s|$)",
            re.I,
        ),
        "catastrophic deletion is forbidden",
    ),
    (
        re.compile(r"\bgit\s+(?:clean\s+-[^\n]*[xX]|reset\s+--hard)\b", re.I),
        "destructive repository reset is forbidden",
    ),
]

COMMAND_KEYS = {
    "command",
    "cmd",
    "script",
    "shell_command",
    "input",
    "tool_input",
}


def strings(value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            if str(key).lower() in COMMAND_KEYS:
                yield from strings(item)
            elif isinstance(item, (dict, list)):
                yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def response(decision: str, reason: str) -> dict[str, Any]:
    return {
        "continue": True,
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        },
    }


def main() -> int:
    raw = sys.stdin.read()
    try:
        document = json.loads(raw) if raw.strip() else {}
    except Exception:
        print(json.dumps(response(
            "deny",
            "shell guard could not parse the PreToolUse request",
        )))
        return 0

    command = "\n".join(strings(document))
    for pattern, reason in BLOCKS:
        if pattern.search(command):
            print(json.dumps(response("deny", reason)))
            return 0

    print(json.dumps(response(
        "allow",
        "local non-publication command allowed",
    )))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
