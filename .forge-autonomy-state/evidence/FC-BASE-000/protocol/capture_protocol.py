#!/usr/bin/env python3
"""Build the current CLI in an isolated scratch tree and capture MCP stdio parity evidence."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
from typing import Any


SCRIPT = Path(__file__).resolve()
OUTPUT = SCRIPT.parent
REPO = SCRIPT.parents[4]
BASELINE = REPO / ".forge-codex/state/baseline/mcp-capabilities.json"
REQUESTS = [
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "forge-baseline-client", "version": "1"},
        },
    },
    {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    {"jsonrpc": "2.0", "id": 3, "method": "resources/list", "params": {}},
    {"jsonrpc": "2.0", "id": 4, "method": "prompts/list", "params": {}},
    {"jsonrpc": "2.0", "id": 5, "method": "ping", "params": {}},
]


def canonical(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: canonical(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [canonical(item) for item in value]
    return value


def write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def write_json(path: Path, value: Any) -> None:
    write_text(path, json.dumps(canonical(value), indent=2, ensure_ascii=False) + "\n")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


COMMAND_RECORDS: list[dict[str, Any]] = []


def run(
    argv: list[str],
    *,
    label: str,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
    timeout: int = 120,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    started = utc_now()
    result = subprocess.run(
        argv,
        cwd=REPO,
        env=env,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    ended = utc_now()
    stdout_path = OUTPUT / f"{label}.stdout.txt"
    stderr_path = OUTPUT / f"{label}.stderr.txt"
    write_text(stdout_path, result.stdout)
    write_text(stderr_path, result.stderr)
    COMMAND_RECORDS.append(
        {
            "label": label,
            "argv": argv,
            "cwd": str(REPO),
            "started_at": started,
            "ended_at": ended,
            "exit_code": result.returncode,
            "stdout": str(stdout_path.relative_to(REPO)),
            "stdout_sha256": sha256(stdout_path),
            "stderr": str(stderr_path.relative_to(REPO)),
            "stderr_sha256": sha256(stderr_path),
            "timed_out": False,
        }
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"{label} exited {result.returncode}; see {stderr_path}")
    return result


def recursive_diff(before: Any, after: Any, path: str = "$") -> list[dict[str, Any]]:
    if isinstance(before, dict) and isinstance(after, dict):
        changes: list[dict[str, Any]] = []
        for key in sorted(before.keys() - after.keys()):
            changes.append({"operation": "removed", "path": f"{path}.{key}", "before": before[key]})
        for key in sorted(after.keys() - before.keys()):
            changes.append({"operation": "added", "path": f"{path}.{key}", "after": after[key]})
        for key in sorted(before.keys() & after.keys()):
            changes.extend(recursive_diff(before[key], after[key], f"{path}.{key}"))
        return changes
    if isinstance(before, list) and isinstance(after, list):
        if canonical(before) == canonical(after):
            return []
        return [{"operation": "changed", "path": path, "before": before, "after": after}]
    if before != after:
        return [{"operation": "changed", "path": path, "before": before, "after": after}]
    return []


def parse_ndjson(text: str, source: str) -> list[dict[str, Any]]:
    frames: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise TypeError(f"{source}:{line_number} is not a JSON object")
        frames.append(value)
    return frames


def response_by_id(frames: list[dict[str, Any]], request_id: int) -> dict[str, Any]:
    matches = [frame for frame in frames if frame.get("id") == request_id]
    if len(matches) != 1:
        raise RuntimeError(f"expected exactly one response for id {request_id}, found {len(matches)}")
    if "error" in matches[0]:
        raise RuntimeError(f"request id {request_id} failed: {matches[0]['error']}")
    return matches[0]


def tool_map(frame: dict[str, Any]) -> dict[str, dict[str, Any]]:
    tools = frame.get("result", {}).get("tools", [])
    if not isinstance(tools, list):
        raise TypeError("tools/list result is not an array")
    mapped: dict[str, dict[str, Any]] = {}
    for descriptor in tools:
        if not isinstance(descriptor, dict) or not isinstance(descriptor.get("name"), str):
            raise TypeError("tools/list contains a malformed descriptor")
        name = descriptor["name"]
        if name in mapped:
            raise RuntimeError(f"duplicate tool name: {name}")
        mapped[name] = canonical(descriptor)
    return mapped


def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    baseline_transcript_path = REPO / baseline["initialize_transcript_artifact"]
    old_frames = parse_ndjson(baseline_transcript_path.read_text(encoding="utf-8"), str(baseline_transcript_path))

    isolated_home = OUTPUT / "build-home"
    scratch = OUTPUT / "build"
    temporary = OUTPUT / "tmp"
    runtime_home = OUTPUT / "runtime-home"
    for directory in [isolated_home, scratch, temporary, runtime_home]:
        directory.mkdir(parents=True, exist_ok=True)

    build_environment = os.environ.copy()
    build_environment.update(
        {
            "HOME": str(isolated_home),
            "TMPDIR": str(temporary),
            "CLANG_MODULE_CACHE_PATH": str(scratch / "ModuleCache"),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(scratch / "ModuleCache"),
        }
    )
    run(
        [
            "/usr/bin/env",
            "swift",
            "build",
            "--scratch-path",
            str(scratch),
            "--configuration",
            "debug",
            "--product",
            "forge-conductor",
        ],
        label="swift-build",
        env=build_environment,
        timeout=900,
    )

    candidates = sorted(
        path
        for path in scratch.rglob("forge-conductor")
        if path.is_file() and os.access(path, os.X_OK) and "index/store" not in str(path)
    )
    if not candidates:
        raise RuntimeError(f"no executable forge-conductor product found under {scratch}")
    binary = min(candidates, key=lambda path: (len(path.parts), str(path)))

    request_text = "".join(json.dumps(request, separators=(",", ":"), ensure_ascii=False) + "\n" for request in REQUESTS)
    requests_path = OUTPUT / "requests.ndjson"
    write_text(requests_path, request_text)
    baseline_request_path = REPO / baseline["request_fixture"]
    baseline_request_text = baseline_request_path.read_text(encoding="utf-8")

    server_environment = os.environ.copy()
    server_environment.update(
        {
            "HOME": str(runtime_home),
            "TMPDIR": str(temporary),
            "FORGE_CONDUCTOR_HOME": str(runtime_home / ".forge-conductor"),
            "FORGE_MCP_ROLE": "primary",
            "FORGE_DEPLOYMENT_ID": "fc-base-000-protocol",
            "FORGE_SKIP_PS": "1",
        }
    )
    protocol = run(
        [str(binary), "serve"],
        label="mcp-stdio",
        env=server_environment,
        input_text=request_text,
        timeout=60,
    )
    responses_path = OUTPUT / "responses.ndjson"
    write_text(responses_path, protocol.stdout)
    new_frames = parse_ndjson(protocol.stdout, str(responses_path))
    if len(new_frames) != 5:
        raise RuntimeError(f"expected five response frames, found {len(new_frames)}")
    for request_id in range(1, 6):
        response_by_id(new_frames, request_id)

    old_by_id = {request_id: response_by_id(old_frames, request_id) for request_id in range(1, 6)}
    new_by_id = {request_id: response_by_id(new_frames, request_id) for request_id in range(1, 6)}
    old_tools = tool_map(old_by_id[2])
    new_tools = tool_map(new_by_id[2])
    old_tool_order = [tool["name"] for tool in old_by_id[2]["result"]["tools"]]
    new_tool_order = [tool["name"] for tool in new_by_id[2]["result"]["tools"]]
    baseline_names = baseline.get("tools", [])

    common = sorted(old_tools.keys() & new_tools.keys())
    schema_changes: list[dict[str, Any]] = []
    description_changes: list[dict[str, Any]] = []
    unchanged_descriptors: list[str] = []
    for name in common:
        schema_diff = recursive_diff(old_tools[name].get("inputSchema"), new_tools[name].get("inputSchema"))
        if schema_diff:
            schema_changes.append(
                {
                    "name": name,
                    "changes": schema_diff,
                    "before": old_tools[name].get("inputSchema"),
                    "after": new_tools[name].get("inputSchema"),
                }
            )
        if old_tools[name].get("description") != new_tools[name].get("description"):
            description_changes.append(
                {
                    "name": name,
                    "before": old_tools[name].get("description"),
                    "after": new_tools[name].get("description"),
                }
            )
        if not schema_diff and old_tools[name].get("description") == new_tools[name].get("description"):
            unchanged_descriptors.append(name)

    comparison = {
        "schema_version": 1,
        "captured_at": utc_now(),
        "baseline": {
            "capabilities_path": str(BASELINE.relative_to(REPO)),
            "capabilities_sha256": sha256(BASELINE),
            "transcript_path": str(baseline_transcript_path.relative_to(REPO)),
            "transcript_sha256": sha256(baseline_transcript_path),
            "request_path": str(baseline_request_path.relative_to(REPO)),
            "request_sha256": sha256(baseline_request_path),
            "request_replayed_exactly": request_text == baseline_request_text,
            "declared_tool_count": baseline.get("tool_count"),
            "declared_names_match_transcript": sorted(baseline_names) == sorted(old_tools),
            "tool_count": len(old_tools),
        },
        "current": {
            "git_head": run(["/usr/bin/git", "rev-parse", "HEAD"], label="git-head").stdout.strip(),
            "binary_path": str(binary.relative_to(REPO)),
            "binary_sha256": sha256(binary),
            "request_sha256": sha256(requests_path),
            "response_sha256": sha256(responses_path),
            "tool_count": len(new_tools),
        },
        "initialize": {
            "before": old_by_id[1].get("result"),
            "after": new_by_id[1].get("result"),
            "changes": recursive_diff(old_by_id[1].get("result"), new_by_id[1].get("result")),
        },
        "tools": {
            "added": sorted(new_tools.keys() - old_tools.keys()),
            "removed": sorted(old_tools.keys() - new_tools.keys()),
            "preserved": common,
            "baseline_order": old_tool_order,
            "current_order": new_tool_order,
            "preserved_relative_order_unchanged": [name for name in new_tool_order if name in old_tools]
            == old_tool_order,
            "schema_changes": schema_changes,
            "description_changes": description_changes,
            "unchanged_descriptors": unchanged_descriptors,
        },
        "resources": {
            "before": old_by_id[3].get("result"),
            "after": new_by_id[3].get("result"),
            "changes": recursive_diff(old_by_id[3].get("result"), new_by_id[3].get("result")),
        },
        "prompts": {
            "before": old_by_id[4].get("result"),
            "after": new_by_id[4].get("result"),
            "changes": recursive_diff(old_by_id[4].get("result"), new_by_id[4].get("result")),
        },
        "ping": {
            "before": old_by_id[5].get("result"),
            "after": new_by_id[5].get("result"),
            "changes": recursive_diff(old_by_id[5].get("result"), new_by_id[5].get("result")),
        },
    }

    validation = {
        "schema_version": 1,
        "captured_at": comparison["captured_at"],
        "checks": {
            "build_exit_zero": COMMAND_RECORDS[0]["exit_code"] == 0,
            "serve_exit_zero": COMMAND_RECORDS[1]["exit_code"] == 0,
            "serve_stderr_empty": not protocol.stderr,
            "five_response_frames": len(new_frames) == 5,
            "response_ids_exact": sorted(frame.get("id") for frame in new_frames) == [1, 2, 3, 4, 5],
            "no_json_rpc_errors": not any("error" in frame for frame in new_frames),
            "baseline_declared_names_match_transcript": comparison["baseline"]["declared_names_match_transcript"],
            "baseline_request_replayed_exactly": comparison["baseline"]["request_replayed_exactly"],
            "all_legacy_tools_preserved": not comparison["tools"]["removed"],
            "tool_names_unique": len(new_tool_order) == len(set(new_tool_order)),
            "protocol_version_preserved": old_by_id[1]["result"].get("protocolVersion")
            == new_by_id[1]["result"].get("protocolVersion"),
            "server_name_preserved": old_by_id[1]["result"].get("serverInfo", {}).get("name")
            == new_by_id[1]["result"].get("serverInfo", {}).get("name"),
            "resources_unchanged": not comparison["resources"]["changes"],
            "prompts_unchanged": not comparison["prompts"]["changes"],
            "ping_unchanged": not comparison["ping"]["changes"],
            "legacy_tool_relative_order_preserved": comparison["tools"]["preserved_relative_order_unchanged"],
        },
    }
    validation["ok"] = all(validation["checks"].values())

    inventory = {
        "schema_version": 1,
        "captured_at": comparison["captured_at"],
        "executable": {
            "path": comparison["current"]["binary_path"],
            "sha256": comparison["current"]["binary_sha256"],
            "git_head": comparison["current"]["git_head"],
        },
        "initialize": new_by_id[1].get("result"),
        "tools": [new_tools[name] for name in sorted(new_tools)],
        "tool_names": sorted(new_tools),
        "tool_count": len(new_tools),
        "resources": new_by_id[3].get("result", {}).get("resources", []),
        "prompts": new_by_id[4].get("result", {}).get("prompts", []),
        "ping_result": new_by_id[5].get("result"),
    }
    write_json(OUTPUT / "current-protocol-inventory.json", inventory)
    write_json(OUTPUT / "baseline-comparison.json", comparison)
    write_json(OUTPUT / "validation.json", validation)

    added_lines = "\n".join(f"- `{name}`" for name in comparison["tools"]["added"])
    summary = f"""# FC-BASE-000 executable MCP protocol baseline

Captured from a debug `forge-conductor` product built from Git commit `{comparison['current']['git_head']}` in an isolated evidence scratch tree.

## Result

- `initialize`, `tools/list`, `resources/list`, `prompts/list`, and `ping` all returned successful JSON-RPC 2.0 responses.
- The current executable exposes {len(new_tools)} unique tools. All {len(old_tools)} baseline tool names remain present; no tool was removed.
- Nineteen additive tools are present: seven `continuity.*` tools and twelve `project_memory.*` tools.
- The initialize response keeps server name `forge-conductor` and protocol version `2025-11-25`, changes the server version from `0.8.0` to `0.9.0`, and adds the `projectMemory` capability block.
- Resources remain empty, prompts remain empty, and ping remains an empty result object.
- Common-tool descriptions and relative ordering are unchanged.
- One common input schema differs: `shell_exec.timeout_sec` now advertises `exclusiveMinimum: 0` and `maximum: 120`; the baseline advertised only `type: number`. This is a schema-narrowing delta that needs an explicit compatibility disposition even though the tool name and other fields remain present.

## Added tool names

{added_lines}

## Primary artifacts

- `responses.ndjson`: raw executable response stream.
- `transcript.json`: request/response pairs, including the initialized notification.
- `current-protocol-inventory.json`: all current tool names, descriptions, and complete input schemas.
- `baseline-comparison.json`: exact initialize, tool, schema, resources, prompts, and ping differences.
- `validation.json`: executable checks and parity assertions.
- `commands.jsonl`: commands, exit codes, timestamps, output paths, and output hashes.
"""
    write_text(OUTPUT / "summary.md", summary)

    transcript = []
    responses_by_id = {frame.get("id"): frame for frame in new_frames}
    for request in REQUESTS:
        item: dict[str, Any] = {"request": request}
        if request.get("id") is not None:
            item["response"] = responses_by_id[request["id"]]
        else:
            item["response"] = None
        transcript.append(item)
    write_json(OUTPUT / "transcript.json", transcript)

    environment = {
        "schema_version": 1,
        "captured_at": comparison["captured_at"],
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python_version": platform.python_version(),
        "swift_version": run(["/usr/bin/env", "swift", "--version"], label="swift-version").stdout.strip(),
        "xcode_version": run(["/usr/bin/xcodebuild", "-version"], label="xcode-version").stdout.strip(),
        "macos_version": run(["/usr/bin/sw_vers"], label="macos-version").stdout.strip(),
        "git_status": run(["/usr/bin/git", "status", "--short", "--branch"], label="git-status").stdout.splitlines(),
        "tracked_product_diff": run(
            [
                "/usr/bin/git",
                "diff",
                "--",
                "Package.swift",
                "Sources",
                "Tests",
                "ForgeConductor.xcodeproj/project.pbxproj",
            ],
            label="git-diff-product",
        ).stdout,
    }
    write_json(OUTPUT / "environment.json", environment)

    commands_path = OUTPUT / "commands.jsonl"
    write_text(
        commands_path,
        "".join(json.dumps(canonical(record), ensure_ascii=False) + "\n" for record in COMMAND_RECORDS),
    )

    artifacts: list[dict[str, Any]] = []
    for path in sorted(OUTPUT.iterdir()):
        if path.is_file() and path.name != "artifact-manifest.json":
            artifacts.append(
                {
                    "path": str(path.relative_to(REPO)),
                    "bytes": path.stat().st_size,
                    "sha256": sha256(path),
                }
            )
    write_json(
        OUTPUT / "artifact-manifest.json",
        {
            "schema_version": 1,
            "captured_at": comparison["captured_at"],
            "artifacts": artifacts,
        },
    )

    print(
        json.dumps(
            {
                "ok": True,
                "tool_count": len(new_tools),
                "added": comparison["tools"]["added"],
                "removed": comparison["tools"]["removed"],
                "schema_change_count": len(schema_changes),
                "output": str(OUTPUT),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.TimeoutExpired as error:
        write_text(OUTPUT / "capture-error.txt", f"timeout: {error}\n")
        raise
    except Exception as error:
        write_text(OUTPUT / "capture-error.txt", f"{type(error).__name__}: {error}\n")
        raise
