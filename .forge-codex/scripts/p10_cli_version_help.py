#!/usr/bin/env python3
"""Bounded supporting observations of the embedded native CLI's read-only help.

This adapter intentionally makes no installed-product, signing, source-to-build,
or accepted P10 assertion claim. Canonical acceptance additionally requires the reviewed build/install adapter.
"""

from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
import json
import os
import pathlib
import plistlib
import re
import stat
import tempfile
import time
from typing import Any

from evidence_support import EvidenceSupportError, atomic_write_json
from p10_feature_baseline import EXPECTED_SIGNING_ARTIFACTS
from record_command import execute_command


OBSERVATION_PATH = ".forge-codex/evidence/P10-cli-version-help-observations.json"
SOURCE_VERSION_PATH = "Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift"
MAXIMUM_STREAM_BYTES = 16384
MAXIMUM_CASE_SECONDS = 10
MAXIMUM_TOTAL_SECONDS = 90
MAXIMUM_BUNDLE_FILES = 2048
MAXIMUM_BUNDLE_BYTES = 1024 * 1024 * 1024
MAXIMUM_FILE_BYTES = 512 * 1024 * 1024
MAXIMUM_OBSERVATION_BYTES = 2 * 1024 * 1024
UNKNOWN_COMMAND = "__forge_unknown_command__"
CASES = (
    ("no_arguments_help", ()),
    ("help", ("help",)),
    ("short_help", ("-h",)),
    ("long_help", ("--help",)),
    ("version", ("version",)),
    ("long_version", ("--version",)),
    ("unknown_command", (UNKNOWN_COMMAND,)),
)
COMMANDS = (
    "install", "install-lmstudio-plugin", "doctor", "status", "serve",
    "dashboard", "manager", "agents", "version", "help",
)
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def identity(value: os.stat_result) -> tuple[int, ...]:
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def file_binding(path: pathlib.Path) -> dict[str, Any]:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > MAXIMUM_FILE_BYTES:
        raise EvidenceSupportError("CLI bundle contains an unsupported or oversized file")
    digest = hashlib.sha256()
    total = 0
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        if identity(os.fstat(stream.fileno())) != identity(before):
            raise EvidenceSupportError("CLI bundle file changed before hashing")
        while block := stream.read(1024 * 1024):
            total += len(block)
            if total > MAXIMUM_FILE_BYTES:
                raise EvidenceSupportError("CLI bundle file exceeded its byte bound")
            digest.update(block)
        after_descriptor = os.fstat(stream.fileno())
    if identity(before) != identity(after_descriptor) or identity(before) != identity(path.lstat()) or total != before.st_size:
        raise EvidenceSupportError("CLI bundle file changed during hashing")
    return {"sha256": digest.hexdigest(), "bytes": total, "mode": stat.S_IMODE(before.st_mode)}


def bundle_manifest(root: pathlib.Path) -> list[dict[str, Any]]:
    """Bind in-bundle libraries/resources too, preserving internal framework links."""
    entries: list[dict[str, Any]] = []
    total = 0
    pending = [root]
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as children:
            for child in children:
                if len(entries) >= MAXIMUM_BUNDLE_FILES:
                    raise EvidenceSupportError("CLI bundle exceeds its entry bound")
                path = pathlib.Path(child.path)
                relative = path.relative_to(root).as_posix()
                if child.is_symlink():
                    resolved = path.resolve(strict=True)
                    if resolved != root and root not in resolved.parents:
                        raise EvidenceSupportError("CLI bundle symlink escapes the app")
                    entries.append({"path": relative, "kind": "symlink", "target": os.readlink(path)})
                elif child.is_dir(follow_symlinks=False):
                    entries.append({"path": relative, "kind": "directory"})
                    pending.append(path)
                else:
                    binding = file_binding(path)
                    total += binding["bytes"]
                    if total > MAXIMUM_BUNDLE_BYTES:
                        raise EvidenceSupportError("CLI bundle exceeds its total byte bound")
                    entries.append({"path": relative, "kind": "file", **binding})
    return sorted(entries, key=lambda item: item["path"])


def source_version(repository: pathlib.Path) -> tuple[str, dict[str, Any]]:
    path = repository / SOURCE_VERSION_PATH
    binding = file_binding(path)
    if binding["bytes"] > 256 * 1024:
        raise EvidenceSupportError("CLI version source exceeds its byte bound")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != binding["sha256"]:
        raise EvidenceSupportError("CLI version source changed during capture")
    matches = re.findall(rb'public static let productVersion = "((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"', raw)
    if len(matches) != 1:
        raise EvidenceSupportError("CLI source has no unique canonical product version")
    return matches[0].decode("ascii"), {"path": SOURCE_VERSION_PATH, **binding}


def stream_binding(raw: bytes) -> dict[str, Any]:
    return {"base64": base64.b64encode(raw).decode("ascii"),
            "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}


def validate_cases(cases: list[dict[str, Any]], *, executable: str, version: str) -> list[str]:
    """Recompute semantics from raw bytes, never from reported pass Booleans."""
    failures: list[str] = []
    if len(cases) != len(CASES):
        return ["seven distinct version/help invocations are required"]
    canonical_help: bytes | None = None
    first_case = cases[0] if isinstance(cases[0], dict) else {}
    for result, (case_id, arguments) in zip(cases, CASES):
        label = f"CLI case {case_id}"
        if not isinstance(result, dict) or set(result) != {"id", "argv", "pid", "cwd", "environment", "started_at", "ended_at", "timeout_seconds", "maximum_stream_bytes", "exit_code", "timed_out", "stream_limit_exceeded", "stdout", "stderr"}:
            failures.append(f"{label} has a malformed transcript")
            continue
        if result["id"] != case_id or result["argv"] != [executable, *arguments]:
            failures.append(f"{label} command identity changed")
        if type(result["pid"]) is not int or result["pid"] <= 1:
            failures.append(f"{label} has no captured child process")
        if type(result["timeout_seconds"]) is not int or result["timeout_seconds"] != MAXIMUM_CASE_SECONDS or type(result["maximum_stream_bytes"]) is not int or result["maximum_stream_bytes"] != MAXIMUM_STREAM_BYTES:
            failures.append(f"{label} capture bounds changed")
        cwd = result["cwd"]
        if not isinstance(cwd, str) or not cwd.startswith("/") or result["environment"] != {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
            "HOME": cwd, "TMPDIR": str(pathlib.Path(cwd).parent),
            "FORGE_CONDUCTOR_HOME": str(pathlib.Path(cwd) / ".forge-conductor"),
        }:
            failures.append(f"{label} did not use the isolated read-only environment")
        if result["cwd"] != first_case.get("cwd") or result["environment"] != first_case.get("environment"):
            failures.append(f"{label} environment changed between aliases")
        try:
            started = datetime.fromisoformat(result["started_at"])
            ended = datetime.fromisoformat(result["ended_at"])
            if started.tzinfo is None or ended.tzinfo is None or not 0 <= (ended - started).total_seconds() <= MAXIMUM_CASE_SECONDS + 5:
                raise ValueError("invalid time interval")
        except (TypeError, ValueError):
            failures.append(f"{label} has invalid timing")
        expected_exit = 2 if case_id == "unknown_command" else 0
        if type(result["exit_code"]) is not int or result["exit_code"] != expected_exit or result["timed_out"] is not False or result["stream_limit_exceeded"] is not False:
            failures.append(f"{label} did not complete within bounds with the expected exit status")
        decoded: dict[str, bytes] = {}
        for name in ("stdout", "stderr"):
            stream = result[name]
            try:
                raw = base64.b64decode(stream["base64"], validate=True)
                if len(raw) > MAXIMUM_STREAM_BYTES or stream != stream_binding(raw):
                    raise ValueError("stream binding mismatch")
                raw.decode("utf-8", errors="strict")
                decoded[name] = raw
            except (KeyError, TypeError, ValueError, UnicodeDecodeError):
                failures.append(f"{label} has an invalid {name} binding")
        if len(decoded) != 2:
            continue
        expected_stderr = f"Unknown command: {UNKNOWN_COMMAND}\n\n".encode() if case_id == "unknown_command" else b""
        if decoded["stderr"] != expected_stderr:
            failures.append(f"{label} stderr contract changed")
        if case_id in {"version", "long_version"}:
            if decoded["stdout"] != (version + "\n").encode():
                failures.append(f"{label} does not match the current source version")
        else:
            text = decoded["stdout"].decode("utf-8")
            if not text.startswith(f"Forge-Conductor {version} — native Swift MCP orchestrator\n\nUsage:\n  forge-conductor <command> [options]\n"):
                failures.append(f"{label} header/usage contract changed")
            for command in COMMANDS:
                if re.search(rf"(?m)^  {re.escape(command)}(?:\s|$)", text) is None:
                    failures.append(f"{label} omits {command}")
            if canonical_help is None:
                canonical_help = decoded["stdout"]
            elif decoded["stdout"] != canonical_help:
                failures.append(f"{label} differs from the no-argument help output")
    return failures


def capture(repository: pathlib.Path, app: pathlib.Path, *, evidence_id: str, challenge_nonce: str) -> dict[str, Any]:
    """Run only the seven reviewed read-only cases, preserving failures as evidence."""
    document: dict[str, Any] = {
        "schema_version": 1, "kind": "p10-cli-version-help-supporting-observations",
        "evidence_id": evidence_id, "challenge_nonce": challenge_nonce,
        "candidate_assertion_id": "CLI-VERSION-HELP.production-path",
        "accepted_p10_assertions": [], "artifact_origin": "embedded-app",
        "installation_assessed": False, "signing_assessed": False,
        "build_provenance_assessed": False, "configuration_assessed": False,
        "app_path": str(app), "started_at": now(), "cases": [], "failures": [],
        "cleanup": {"temporary_home_removed": False},
    }
    temporary_path: pathlib.Path | None = None
    try:
        if not app.is_absolute() or app.resolve(strict=True) != app or not app.is_dir() or app.name != "Forge Conductor.app":
            raise EvidenceSupportError("CLI app must be an absolute canonical Forge Conductor.app directory")
        executable = app / "Contents/Helpers/forge-conductor"
        for definition in EXPECTED_SIGNING_ARTIFACTS.values():
            path = app / definition["relative_path"]
            if path.resolve(strict=True) != path or not os.access(path, os.X_OK):
                raise EvidenceSupportError("CLI app is missing an exact executable from the coherent artifact set")
            with path.open("rb") as stream:
                if stream.read(4) not in MACHO_MAGICS:
                    raise EvidenceSupportError("CLI app artifact is not a native Mach-O executable")
        version, version_binding = source_version(repository)
        document["expected_version"] = version
        document["version_source"] = version_binding
        before = bundle_manifest(app)
        document["bundle_before"] = before
        info_path = app / "Contents/Info.plist"
        if info_path.stat().st_size > 1024 * 1024:
            raise EvidenceSupportError("CLI app metadata exceeds its byte bound")
        info = plistlib.loads(info_path.read_bytes())
        if info.get("CFBundleShortVersionString") != version:
            raise EvidenceSupportError("CLI app version differs from the current source")
        document["bundle_version"] = info["CFBundleShortVersionString"]
        document["bundle_build"] = info.get("CFBundleVersion")
        deadline = time.monotonic() + MAXIMUM_TOTAL_SECONDS
        with tempfile.TemporaryDirectory(prefix="forge-p10-cli-help-") as temporary:
            temporary_path = pathlib.Path(temporary).resolve(strict=True)
            home = temporary_path / "home"
            home.mkdir()
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C", "HOME": str(home), "TMPDIR": str(temporary_path), "FORGE_CONDUCTOR_HOME": str(home / ".forge-conductor")}
            for case_id, arguments in CASES:
                if time.monotonic() + MAXIMUM_CASE_SECONDS > deadline:
                    raise EvidenceSupportError("CLI cases exceeded their total deadline")
                stdout_path, stderr_path = temporary_path / "stdout", temporary_path / "stderr"
                # Recorder output files become read-only; each case owns new files.
                stdout_path = stdout_path.with_name(case_id + ".stdout")
                stderr_path = stderr_path.with_name(case_id + ".stderr")
                metadata: dict[str, Any] = {}
                started_at = now()
                argv = [str(executable), *arguments]
                exit_code, timed_out, truncated = execute_command(argv, home, stdout_path, stderr_path, MAXIMUM_CASE_SECONDS, MAXIMUM_STREAM_BYTES, environment, process_metadata=metadata)
                document["cases"].append({"id": case_id, "argv": argv, "pid": metadata["pid"], "cwd": str(home), "environment": environment, "started_at": started_at, "ended_at": now(), "timeout_seconds": MAXIMUM_CASE_SECONDS, "maximum_stream_bytes": MAXIMUM_STREAM_BYTES, "exit_code": exit_code, "timed_out": timed_out, "stream_limit_exceeded": truncated, "stdout": stream_binding(stdout_path.read_bytes()), "stderr": stream_binding(stderr_path.read_bytes())})
                if timed_out or truncated:
                    break
            document["isolated_home_unchanged"] = not any(home.iterdir())
            if not document["isolated_home_unchanged"]:
                document["failures"].append("read-only CLI cases unexpectedly wrote to the isolated home")
        after = bundle_manifest(app)
        document["bundle_after"] = after
        if before != after:
            document["failures"].append("CLI bundle changed during execution")
        if source_version(repository)[1] != version_binding:
            document["failures"].append("CLI version source changed during execution")
        document["failures"].extend(validate_cases(document["cases"], executable=str(executable), version=version))
    except (OSError, ValueError, EvidenceSupportError) as error:
        document["failures"].append(str(error))
    document["cleanup"]["temporary_home_removed"] = temporary_path is not None and not temporary_path.exists()
    document["ended_at"] = now()
    document["executed_case_count"] = len(document["cases"])
    document["passed"] = len(document["cases"]) == len(CASES) and not document["failures"] and document["cleanup"]["temporary_home_removed"]
    raw = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if len(raw) > MAXIMUM_OBSERVATION_BYTES:
        raise EvidenceSupportError("CLI supporting observations exceed their byte bound")
    atomic_write_json(repository / OBSERVATION_PATH, document)
    # Hash the exact serialized bytes produced by the shared atomic writer.
    preserved = (repository / OBSERVATION_PATH).read_bytes()
    return {"source_path": OBSERVATION_PATH, "sha256": hashlib.sha256(preserved).hexdigest(), "bytes": len(preserved), "executed_case_count": document["executed_case_count"], "passed": document["passed"], "accepted_p10_assertions": [], "failures": document["failures"]}
