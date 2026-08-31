#!/usr/bin/env python3
"""Qualify signed shell access through an isolated installed manager lifecycle.

The default mode is read-only. Passing --execute authorizes the bounded per-user
LaunchAgent install described in the JSON preflight. The canonical launchd label
and plist must be absent before execution; the runner never takes over an existing
manager. Cleanup is scoped to artifacts whose ownership is proven from the
isolated qualification home.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import pwd
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

from check_p10_protocol_compatibility import (
    CompatibilityError,
    initialize_process,
    tool_map,
    validate_endpoint_response,
    validate_tool_call_envelope,
)


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_ROOT.parents[1]
LABEL = "com.forge-conductor.manager"
APP_IDENTIFIER = "com.forge-conductor.app"
CLI_IDENTIFIER = "com.forge-conductor.cli"
RUNTIME_LAUNCHER_IDENTIFIER = "com.forge-conductor.runtime-launcher"
DAEMON_IDENTIFIER = "com.forge-conductor.filesystem-daemon"
FRAMEWORK_IDENTIFIER = "com.forge-conductor.core"
APP_NAME = "Forge Conductor.app"
SHELL_COMMAND = (
    "shopt -q login_shell || exit 97; "
    "[ \"$0\" = /bin/bash ] || exit 98; "
    "printf '%s' 'native-restart-ok'"
)
SHELL_MARKER = "native-restart-ok"
SHELL_RESULT_KEYS = {
    "ok",
    "exit_code",
    "stdout",
    "stderr",
    "timed_out",
    "stdout_truncated",
    "stderr_truncated",
    "command",
    "cwd",
}
SANDBOX_EXEC = pathlib.Path("/usr/bin/sandbox-exec")
FIREWALL_TOOL = "/usr/libexec/ApplicationFirewall/socketfilterfw"
MANAGER_DENIAL_MAXIMUM_BYTES = 4096
INSTALL_SANDBOX_PROFILE = (
    '(version 1) (allow default) '
    '(allow job-creation) '
    f'(deny process-exec (literal "{FIREWALL_TOOL}"))'
)
MISSING_SERVICE_MARKERS = (
    "could not find service",
    "service not found",
    "no such process",
)
OPEN_GATES = [
    "P10/G10 product qualification",
    "filesystem E2 residual race",
    "native UI and signing qualification",
    "real-provider autonomous continuity",
    "whole-product rollback freshness",
]


class QualificationError(RuntimeError):
    """A qualification invariant was not proven."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise QualificationError(message)


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def bounded_text(value: str | bytes, maximum: int = 4_000) -> str:
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="replace")
    return value if len(value) <= maximum else value[-maximum:]


def run_command(
    arguments: list[str],
    *,
    timeout: float = 20,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise QualificationError(f"command failed to run: {arguments[0]}: {error}") from error


def parse_codesign_details(output: str) -> dict[str, Any]:
    details: dict[str, Any] = {"authorities": []}
    for line in output.splitlines():
        if line.startswith("Identifier="):
            details["identifier"] = line.split("=", 1)[1]
        elif line.startswith("TeamIdentifier="):
            details["team_identifier"] = line.split("=", 1)[1]
        elif line.startswith("CDHash="):
            details["cdhash"] = line.split("=", 1)[1].lower()
        elif line.startswith("Authority="):
            details["authorities"].append(line.split("=", 1)[1])
        elif line.startswith("Runtime Version="):
            details["runtime_version"] = line.split("=", 1)[1]
        elif "CodeDirectory " in line and " flags=" in line:
            details["code_directory"] = line.strip()
    return details


def inspect_signature(
    path: pathlib.Path,
    *,
    expected_identifier: str,
    expected_team: str | None = None,
    deep: bool = False,
) -> dict[str, Any]:
    verify_arguments = ["/usr/bin/codesign", "--verify", "--strict", "--verbose=4"]
    if deep:
        verify_arguments.insert(2, "--deep")
    verify_arguments.append(str(path))
    verified = run_command(verify_arguments)
    require(
        verified.returncode == 0,
        f"code signature validation failed for {path}: {bounded_text(verified.stderr)}",
    )
    displayed = run_command(["/usr/bin/codesign", "-d", "--verbose=4", str(path)])
    require(displayed.returncode == 0, f"cannot inspect code signature for {path}")
    details = parse_codesign_details(displayed.stdout + displayed.stderr)
    require(details.get("identifier") == expected_identifier, f"wrong signing identifier for {path}")
    team = details.get("team_identifier")
    require(isinstance(team, str) and team, f"missing signing team for {path}")
    if expected_team is not None:
        require(team == expected_team, f"wrong signing team for {path}")
    require(details.get("authorities"), f"missing CMS signing authority for {path}")
    require(isinstance(details.get("cdhash"), str), f"missing CDHash for {path}")
    require("runtime" in details.get("code_directory", ""), f"hardened runtime is absent for {path}")
    return {
        "path": str(path),
        "identifier": details["identifier"],
        "team_identifier": team,
        "cdhash": details["cdhash"],
        "authorities": details["authorities"],
        "runtime_version": details.get("runtime_version"),
        "sha256": sha256_file(path) if path.is_file() else None,
    }


def require_regular_executable(path: pathlib.Path, label: str) -> None:
    require(path.exists(), f"{label} is missing: {path}")
    require(not path.is_symlink(), f"{label} must not be a symlink: {path}")
    metadata = path.stat()
    require(stat.S_ISREG(metadata.st_mode), f"{label} must be a regular file: {path}")
    require(os.access(path, os.X_OK), f"{label} is not executable: {path}")


def read_plist(path: pathlib.Path) -> dict[str, Any]:
    require(path.exists() and not path.is_symlink(), f"plist is missing or symlinked: {path}")
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise QualificationError(f"invalid plist {path}: {error}") from error
    require(isinstance(value, dict), f"plist root is not a dictionary: {path}")
    return value


def embedded_cli_rpaths(path: pathlib.Path) -> list[str]:
    result = run_command(["/usr/bin/otool", "-l", str(path)])
    require(result.returncode == 0, f"otool failed for {path}: {bounded_text(result.stderr)}")
    lines = result.stdout.splitlines()
    paths: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_RPATH":
            continue
        for candidate in lines[index + 1:index + 5]:
            match = re.match(r"\s*path\s+(.*?)\s+\(offset\s+\d+\)\s*$", candidate)
            if match:
                paths.append(match.group(1))
                break
    return paths


def validate_application_bundle(app: pathlib.Path) -> dict[str, Any]:
    original = app
    require(original.exists(), f"application bundle is missing: {original}")
    require(not original.is_symlink(), f"application bundle must not be a symlink: {original}")
    app = original.resolve()
    require(app.is_dir(), f"application bundle is not a directory: {app}")
    require(app.name == APP_NAME, f"unexpected application bundle name: {app.name}")

    info_url = app / "Contents/Info.plist"
    info = read_plist(info_url)
    require(info.get("CFBundleIdentifier") == APP_IDENTIFIER, "application bundle identifier changed")
    require(info.get("CFBundleExecutable") == "Forge Conductor", "application main executable changed")

    main = app / "Contents/MacOS/Forge Conductor"
    cli = app / "Contents/Helpers/forge-conductor"
    launcher = app / "Contents/Helpers/forge-runtime-launcher"
    daemon = app / "Contents/MacOS/forge-filesystem-daemon"
    framework = app / "Contents/Frameworks/ForgeConductorCore.framework"
    daemon_plist = app / "Contents/Library/LaunchDaemons/com.forge-conductor.filesystem-daemon.plist"
    for path, label in (
        (main, "application main executable"),
        (cli, "embedded manager CLI"),
        (launcher, "runtime launcher"),
        (daemon, "filesystem daemon"),
    ):
        require_regular_executable(path, label)
    require(framework.is_dir() and not framework.is_symlink(), f"framework is missing: {framework}")

    app_signature = inspect_signature(app, expected_identifier=APP_IDENTIFIER, deep=True)
    team = app_signature["team_identifier"]
    signatures = {
        "application": app_signature,
        "embedded_cli": inspect_signature(cli, expected_identifier=CLI_IDENTIFIER, expected_team=team),
        "runtime_launcher": inspect_signature(
            launcher,
            expected_identifier=RUNTIME_LAUNCHER_IDENTIFIER,
            expected_team=team,
        ),
        "filesystem_daemon": inspect_signature(
            daemon,
            expected_identifier=DAEMON_IDENTIFIER,
            expected_team=team,
        ),
        "framework": inspect_signature(
            framework,
            expected_identifier=FRAMEWORK_IDENTIFIER,
            expected_team=team,
        ),
    }
    daemon_hash = signatures["filesystem_daemon"]["cdhash"]
    sealed_hashes = {
        key: str(value).lower()
        for key, value in info.items()
        if key.startswith("ForgeFilesystemDaemonCDHash") and isinstance(value, str)
    }
    require(sealed_hashes, "application Info.plist has no sealed filesystem daemon CDHash")
    require(daemon_hash in sealed_hashes.values(), "application seal does not match its filesystem daemon")

    launchd_payload = read_plist(daemon_plist)
    require(launchd_payload.get("Label") == DAEMON_IDENTIFIER, "filesystem daemon plist label changed")
    require(
        launchd_payload.get("BundleProgram") == "Contents/MacOS/forge-filesystem-daemon",
        "filesystem daemon BundleProgram changed",
    )
    rpaths = embedded_cli_rpaths(cli)
    require("@executable_path/../Frameworks" in rpaths, "embedded CLI cannot resolve the app framework")
    require("@executable_path" in rpaths, "embedded CLI lost the installed sibling-framework runpath")

    return {
        "path": str(app),
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "team_identifier": team,
        "signatures": signatures,
        "sealed_daemon_hashes": sealed_hashes,
        "embedded_cli_rpaths": rpaths,
        "paths": {
            "main": str(main),
            "embedded_cli": str(cli),
            "runtime_launcher": str(launcher),
            "filesystem_daemon": str(daemon),
            "framework": str(framework),
            "launchdaemon_plist": str(daemon_plist),
        },
    }


def parse_launchctl_job(output: str) -> dict[str, Any]:
    result: dict[str, Any] = {"output_sha256": sha256_bytes(output.encode("utf-8"))}
    for line in output.splitlines():
        match = re.match(r"\s*pid\s*=\s*(\d+)\s*$", line)
        if match:
            result["pid"] = int(match.group(1))
        match = re.match(r"\s*program\s*=\s*(.*?)\s*$", line)
        if match:
            result["program"] = match.group(1)
        match = re.match(r"\s*state\s*=\s*(.*?)\s*$", line)
        if match:
            result["state"] = match.group(1)
    return result


def parse_disabled_entry(output: str, label: str = LABEL) -> bool | None:
    match = re.search(
        rf'"{re.escape(label)}"\s*=>\s*(true|false|enabled|disabled)',
        output,
    )
    if match is None:
        return None
    return match.group(1) in {"true", "disabled"}


def launchctl_job(uid: int) -> dict[str, Any] | None:
    result = run_command(["/bin/launchctl", "print", f"gui/{uid}/{LABEL}"], timeout=10)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        parsed = parse_launchctl_job(combined)
        require(parsed.get("program"), "loaded manager job has no program path")
        return parsed
    lowered = combined.lower()
    if any(marker in lowered for marker in MISSING_SERVICE_MARKERS):
        return None
    raise QualificationError(f"cannot establish manager job absence: {bounded_text(combined)}")


def launchctl_disabled_snapshot(uid: int) -> dict[str, Any]:
    result = run_command(["/bin/launchctl", "print-disabled", f"gui/{uid}"], timeout=10)
    require(result.returncode == 0, f"cannot inspect launchd enablement: {bounded_text(result.stderr)}")
    return {
        "value": parse_disabled_entry(result.stdout),
        "output_sha256": sha256_bytes(result.stdout.encode("utf-8")),
    }


@dataclass(frozen=True)
class SymlinkSnapshot:
    path: pathlib.Path
    state: str
    target: str | None

    @classmethod
    def capture(cls, path: pathlib.Path) -> "SymlinkSnapshot":
        if not os.path.lexists(path):
            return cls(path=path, state="absent", target=None)
        metadata = os.lstat(path)
        if stat.S_ISLNK(metadata.st_mode):
            return cls(path=path, state="symlink", target=os.readlink(path))
        raise QualificationError(f"shared command-link path is not a symlink: {path}")

    def as_dictionary(self) -> dict[str, Any]:
        return {"path": str(self.path), "state": self.state, "target": self.target}

    def restore(self, installed_target: pathlib.Path) -> dict[str, Any]:
        current_exists = os.path.lexists(self.path)
        current_target = os.readlink(self.path) if current_exists and self.path.is_symlink() else None

        def destination(raw: str) -> pathlib.Path:
            candidate = pathlib.Path(raw)
            if not candidate.is_absolute():
                candidate = self.path.parent / candidate
            return candidate.resolve(strict=False)

        expected = installed_target.resolve(strict=False)
        current_is_installed = current_target is not None and destination(current_target) == expected
        if self.state == "absent":
            if not current_exists:
                return {"status": "restored", "action": "already_absent"}
            require(current_is_installed, f"command link changed concurrently: {self.path}")
            self.path.unlink()
            return {"status": "restored", "action": "removed_qualification_link"}

        require(self.target is not None, "symlink snapshot is incomplete")
        if current_target == self.target:
            return {"status": "restored", "action": "original_already_present"}
        require(current_is_installed, f"command link changed concurrently: {self.path}")
        self.path.unlink()
        os.symlink(self.target, self.path)
        return {"status": "restored", "action": "recreated_original", "target": self.target}


def account_home() -> pathlib.Path:
    return pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)


def product_gui_processes() -> list[dict[str, Any]]:
    result = run_command(["/bin/ps", "-axo", "pid=,comm="], timeout=10)
    require(result.returncode == 0, "cannot inspect existing product processes")
    found: list[dict[str, Any]] = []
    for raw in result.stdout.splitlines():
        match = re.match(r"\s*(\d+)\s+(.*)$", raw)
        if not match:
            continue
        pid = int(match.group(1))
        command = match.group(2).strip()
        if pathlib.Path(command).name != "Forge Conductor":
            continue
        args = run_command(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="], timeout=5)
        found.append({"pid": pid, "executable": command, "arguments": args.stdout.strip()})
    return found


def dashboard_port_is_free(host: str = "127.0.0.1", port: int = 7788) -> bool:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.settimeout(0.25)
    try:
        return probe.connect_ex((host, port)) != 0
    finally:
        probe.close()


def preflight_shared_state(uid: int, home: pathlib.Path) -> dict[str, Any]:
    plist = home / "Library/LaunchAgents" / f"{LABEL}.plist"
    command_link = home / ".local/bin/forge-conductor-swift"
    job = launchctl_job(uid)
    require(job is None, f"canonical manager job is already loaded: gui/{uid}/{LABEL}")
    require(not os.path.lexists(plist), f"canonical manager plist already exists: {plist}")
    link = SymlinkSnapshot.capture(command_link)
    processes = product_gui_processes()
    require(not processes, "a Forge Conductor GUI or app-manager process is already running")
    require(dashboard_port_is_free(), "manager dashboard port 127.0.0.1:7788 is already in use")
    return {
        "canonical_job": {"target": f"gui/{uid}/{LABEL}", "state": "absent"},
        "canonical_plist": {"path": str(plist), "state": "absent"},
        "command_link": link.as_dictionary(),
        "launchd_disabled": launchctl_disabled_snapshot(uid),
        "product_processes": processes,
        "dashboard_port_7788": "free",
    }


def sandboxed_install_command(cli: pathlib.Path, qualification_home: pathlib.Path) -> list[str]:
    return [
        str(SANDBOX_EXEC),
        "-p",
        INSTALL_SANDBOX_PROFILE,
        str(cli),
        "manager",
        "install-login",
        "--keep-stale",
        "--home",
        str(qualification_home),
    ]


def normalized_launchagent_path(value: str | pathlib.Path) -> pathlib.PurePath:
    normalized = os.path.normpath(os.fspath(value))
    require(os.path.isabs(normalized), "LaunchAgent path must be absolute")
    if normalized == "/tmp" or normalized.startswith("/tmp/"):
        normalized = "/private" + normalized
    return pathlib.PurePath(normalized)


def qualification_environment(home: pathlib.Path, label: str) -> dict[str, str]:
    environment = dict(os.environ)
    for key in (
        "FORGE_OPERATOR_UI_TEST_PORT",
        "FORGE_RUNTIME_LIMIT_CORE_BYTES",
        "FORGE_RUNTIME_LIMIT_CPU_SECONDS",
        "FORGE_RUNTIME_LIMIT_FILE_BYTES",
        "FORGE_RUNTIME_LIMIT_OPEN_FILES",
    ):
        environment.pop(key, None)
    environment.update(
        FORGE_CONDUCTOR_HOME=str(home),
        FORGE_DEPLOYMENT_ID=f"signed-manager-{label}",
    )
    return environment


def validate_login_plist(path: pathlib.Path, qualification_home: pathlib.Path) -> dict[str, Any]:
    value = read_plist(path)
    expected_program = qualification_home / APP_NAME / "Contents/MacOS/Forge Conductor"
    arguments = value.get("ProgramArguments")
    require(value.get("Label") == LABEL, "installed LaunchAgent has the wrong label")
    require(
        isinstance(arguments, list)
        and len(arguments) == 5
        and all(isinstance(argument, str) for argument in arguments),
        "installed LaunchAgent arguments changed",
    )
    require(arguments[1:4] == ["manager", "run", "--home"], "installed LaunchAgent arguments changed")
    require(
        normalized_launchagent_path(arguments[0]) == normalized_launchagent_path(expected_program),
        "installed LaunchAgent program changed",
    )
    require(
        normalized_launchagent_path(arguments[4]) == normalized_launchagent_path(qualification_home),
        "installed LaunchAgent home argument changed",
    )
    require(value.get("RunAtLoad") is True and value.get("KeepAlive") is True, "manager persistence changed")
    environment = value.get("EnvironmentVariables")
    require(isinstance(environment, dict), "installed LaunchAgent has no environment")
    environment_home = environment.get("FORGE_CONDUCTOR_HOME")
    require(isinstance(environment_home, str), "LaunchAgent home changed")
    require(
        normalized_launchagent_path(environment_home)
        == normalized_launchagent_path(qualification_home),
        "LaunchAgent home changed",
    )
    working_directory = value.get("WorkingDirectory")
    require(isinstance(working_directory, str), "LaunchAgent working directory changed")
    require(
        normalized_launchagent_path(working_directory)
        == normalized_launchagent_path(qualification_home),
        "LaunchAgent working directory changed",
    )
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "label": LABEL,
        "program_arguments": arguments,
        "working_directory": working_directory,
    }


def process_executable(pid: int) -> pathlib.Path:
    if platform.system() != "Darwin":
        raise QualificationError("process identity inspection requires macOS")
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    function = library.proc_pidpath
    function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    function.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    count = function(pid, buffer, len(buffer))
    require(count > 0, f"cannot resolve executable for PID {pid}")
    return pathlib.Path(os.fsdecode(buffer.value)).resolve()


def process_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_until(predicate: Callable[[], Any], timeout: float, message: str) -> Any:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.15)
    raise QualificationError(message)


def manager_process_identity(uid: int, expected_executable: pathlib.Path, timeout: float) -> dict[str, Any]:
    def ready() -> dict[str, Any] | None:
        job = launchctl_job(uid)
        if job is None or not isinstance(job.get("pid"), int):
            return None
        return job

    job = wait_until(ready, timeout, "manager LaunchAgent did not reach a running PID")
    pid = int(job["pid"])
    executable = process_executable(pid)
    require(executable == expected_executable.resolve(), "manager PID is running an unexpected executable")
    arguments = run_command(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="], timeout=5)
    require(arguments.returncode == 0 and arguments.stdout.strip(), "cannot inspect manager process arguments")
    return {
        "pid": pid,
        "executable": str(executable),
        "arguments": arguments.stdout.strip(),
        "launchctl_program": job.get("program"),
        "launchctl_state": job.get("state"),
        "launchctl_output_sha256": job.get("output_sha256"),
    }


def manager_request(
    method: str,
    path: str,
    *,
    home: pathlib.Path,
    body: dict[str, Any] | None = None,
    timeout: float = 3,
) -> dict[str, Any]:
    request = urllib.request.Request(f"http://127.0.0.1:7788{path}", method=method)
    request.add_header("Accept", "application/json")
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        request.data = data
        request.add_header("Content-Type", "application/json")
    if method != "GET":
        token = read_manager_credential(home)
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read())
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        raise QualificationError(f"manager request failed: {method} {path}: {error}") from error
    require(isinstance(payload, dict), f"manager returned a non-object: {path}")
    return payload


def read_manager_credential(home: pathlib.Path) -> str:
    credential = home / "manager-control.secret"
    require(credential.exists() and not credential.is_symlink(), "manager credential is unavailable")
    metadata = credential.stat()
    require(stat.S_ISREG(metadata.st_mode), "manager credential is not a regular file")
    require(stat.S_IMODE(metadata.st_mode) == 0o600, "manager credential permissions changed")
    require(metadata.st_uid == os.geteuid(), "manager credential owner changed")
    try:
        token = credential.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise QualificationError("manager credential is not readable ASCII") from error
    require(re.fullmatch(r"[0-9a-f]{64}", token) is not None, "manager credential format changed")
    return token


def prime_manager_credential(home: pathlib.Path, timeout: float) -> dict[str, Any]:
    credential = home / "manager-control.secret"
    if credential.exists():
        read_manager_credential(home)
        return {
            "status": "passed",
            "path": str(credential),
            "created_by_manager": False,
            "unauthorized_probe_status": "not_needed",
        }

    request = urllib.request.Request(
        "http://127.0.0.1:7788/api/manager/settings",
        method="POST",
        data=json.dumps(
            {"settings": {}, "apply": False},
            separators=(",", ":"),
        ).encode("utf-8"),
    )
    request.add_header("Accept", "application/json")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer invalid")
    try:
        with urllib.request.urlopen(request, timeout=min(timeout, 3)):
            raise QualificationError("unauthorized manager credential probe unexpectedly succeeded")
    except urllib.error.HTTPError as error:
        try:
            denial_body = error.read(MANAGER_DENIAL_MAXIMUM_BYTES + 1)
            require(
                len(denial_body) <= MANAGER_DENIAL_MAXIMUM_BYTES,
                "manager credential probe denial exceeded its byte bound",
            )
            payload = json.loads(denial_body)
        except (OSError, json.JSONDecodeError, UnicodeDecodeError) as decode_error:
            raise QualificationError("manager credential probe returned invalid JSON") from decode_error
        require(error.code == 401, f"manager credential probe returned HTTP {error.code}")
        require(
            isinstance(payload, dict)
            and payload.get("code") == "manager_mutation_unauthorized",
            "manager credential probe returned the wrong denial",
        )
    except (OSError, urllib.error.URLError) as error:
        raise QualificationError(f"manager credential probe failed: {error}") from error

    wait_until(
        lambda: credential.exists(),
        timeout,
        "manager did not create its control credential after the denied mutation probe",
    )
    read_manager_credential(home)
    return {
        "status": "passed",
        "path": str(credential),
        "created_by_manager": True,
        "unauthorized_probe_status": 401,
        "unauthorized_probe_code": "manager_mutation_unauthorized",
    }


def wait_for_manager_api(home: pathlib.Path, timeout: float) -> dict[str, Any]:
    def ready() -> dict[str, Any] | None:
        try:
            return manager_request("GET", "/api/manager/status", home=home, timeout=1)
        except QualificationError:
            return None

    return wait_until(ready, timeout, "manager control API did not become ready")


def settings_shell(value: dict[str, Any]) -> dict[str, Any]:
    shell = value.get("shell")
    require(isinstance(shell, dict), "manager settings contain no shell policy")
    return shell


def validate_single_allowed_root(
    value: dict[str, Any],
    expected: pathlib.Path,
) -> dict[str, str]:
    roots = value.get("allowed_roots")
    require(
        isinstance(roots, list)
        and len(roots) == 1
        and isinstance(roots[0], str),
        "manager settings did not expose exactly one allowed project root",
    )
    observed = pathlib.Path(roots[0])
    require(observed.is_absolute(), "manager returned a relative allowed project root")
    observed_normalized = normalized_launchagent_path(observed)
    expected_normalized = normalized_launchagent_path(expected)
    require(
        observed_normalized == expected_normalized,
        "manager did not persist the canonical allowed project root",
    )
    try:
        observed_resolved = observed.resolve(strict=True)
        expected_resolved = expected.resolve(strict=True)
    except (OSError, RuntimeError, ValueError) as error:
        raise QualificationError(f"allowed project root cannot be resolved: {error}") from error
    require(
        observed_resolved == expected_resolved,
        "allowed project root resolved to an unexpected directory",
    )
    return {
        "configured": str(observed),
        "normalized": str(observed_normalized),
        "resolved": str(observed_resolved),
    }


def update_settings(home: pathlib.Path, patch: dict[str, Any]) -> dict[str, Any]:
    return manager_request(
        "POST",
        "/api/manager/settings",
        home=home,
        body={"settings": patch, "apply": True},
    )


def validate_tools_list(response: dict[str, Any]) -> dict[str, Any]:
    validate_endpoint_response(response, "tools/list", 2)
    tools = tool_map(response, "signed manager qualification")
    require("shell_exec" in tools, "shell_exec is absent from MCP tools/list")
    return {"tool_count": len(tools), "shell_exec_count": list(tools).count("shell_exec")}


def validate_shell_result(payload: dict[str, Any], cwd: pathlib.Path) -> dict[str, Any]:
    missing = sorted(SHELL_RESULT_KEYS - set(payload))
    require(not missing, f"shell_exec result contract is missing keys: {missing}")
    require(payload.get("ok") is True, "shell_exec payload is not successful")
    require(payload.get("exit_code") == 0, "shell_exec returned a nonzero exit")
    require(payload.get("stdout") == SHELL_MARKER, "shell_exec stdout changed")
    require(payload.get("stderr") == "", "shell_exec emitted stderr")
    require(payload.get("timed_out") is False, "shell_exec unexpectedly timed out")
    require(payload.get("stdout_truncated") is False, "shell_exec stdout was truncated")
    require(payload.get("stderr_truncated") is False, "shell_exec stderr was truncated")
    require(payload.get("command") == SHELL_COMMAND, "shell_exec did not echo the exact command")
    require(pathlib.Path(str(payload.get("cwd"))).resolve() == cwd.resolve(), "shell_exec cwd changed")
    return {
        "contract_keys": sorted(SHELL_RESULT_KEYS),
        "command": payload["command"],
        "cwd": payload["cwd"],
        "stdout": payload["stdout"],
        "exit_code": payload["exit_code"],
        "timed_out": payload["timed_out"],
        "requested_timeout_sec": 999,
        "login_bash_proof": "shopt login_shell and $0=/bin/bash checks exited zero",
    }


def validate_shell_denial(payload: dict[str, Any]) -> dict[str, Any]:
    require(payload.get("ok") is False, "disabled shell_exec unexpectedly succeeded")
    require(payload.get("code") == "shell_disabled_by_user", "explicit opt-out denial code changed")
    require(isinstance(payload.get("message"), str) and payload["message"], "denial message is missing")
    require(isinstance(payload.get("retryable"), bool), "denial retryability is missing")
    return {
        "ok": False,
        "code": payload["code"],
        "retryable": payload["retryable"],
    }


def mcp_shell_probe(
    binary: pathlib.Path,
    home: pathlib.Path,
    project: pathlib.Path,
    *,
    expect_enabled: bool,
    label: str,
    response_timeout: float,
) -> dict[str, Any]:
    process = None
    requests: list[dict[str, Any]] = []
    responses: list[dict[str, Any]] = []
    try:
        process, requests, responses = initialize_process(binary, home, label, response_timeout)
        pid = process.process.pid
        require(process_executable(pid) == binary.resolve(), "MCP process executable identity changed")

        listed_request = {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
        requests.append(listed_request)
        process.send(listed_request)
        listed_response = process.receive(2, "tools/list", response_timeout)
        responses.append(listed_response)
        listing = validate_tools_list(listed_response)

        start_request = {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "agent_run_start",
                "arguments": {
                    "agent_id": "test",
                    "goal": "Qualify signed shell policy and restart behavior",
                    "cwd": str(project),
                },
            },
        }
        requests.append(start_request)
        process.send(start_request)
        start_response = process.receive(3, "agent_run_start", response_timeout)
        responses.append(start_response)
        started = validate_tool_call_envelope(start_response, expected_error=False, expected_id=3)
        session_id = started.get("session_id")
        require(isinstance(session_id, str) and session_id, "agent_run_start returned no session")

        shell_request = {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {
                "name": "shell_exec",
                "arguments": {
                    "command": SHELL_COMMAND,
                    "cwd": str(project),
                    "timeout_sec": 999,
                },
            },
        }
        requests.append(shell_request)
        process.send(shell_request)
        shell_response = process.receive(4, "shell_exec", response_timeout)
        responses.append(shell_response)
        if expect_enabled:
            shell_payload = validate_tool_call_envelope(shell_response, expected_error=False, expected_id=4)
            shell_result = validate_shell_result(shell_payload, project)
            outcome = "passed"
        else:
            shell_payload = validate_tool_call_envelope(
                shell_response,
                expected_error=True,
                expected_code="shell_disabled_by_user",
                expected_id=4,
            )
            shell_result = validate_shell_denial(shell_payload)
            outcome = "denied_by_explicit_opt_out"

        complete_request = {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {
                "name": "agent_run_complete",
                "arguments": {
                    "session_id": session_id,
                    "report": {
                        "commands": [SHELL_COMMAND],
                        "results": [outcome],
                        "gaps": [],
                        "follow_ups": [],
                    },
                },
            },
        }
        requests.append(complete_request)
        process.send(complete_request)
        complete_response = process.receive(5, "agent_run_complete", response_timeout)
        responses.append(complete_response)
        completed = validate_tool_call_envelope(complete_response, expected_error=False, expected_id=5)
        require(completed.get("schema_complete") is True, "agent session completion schema changed")
        stderr, return_code = process.close(10)
        process = None
        require(return_code == 0, f"MCP server exited {return_code}")
        return {
            "status": "passed",
            "pid": pid,
            "executable": str(binary.resolve()),
            "response_ids": [response.get("id") for response in responses],
            "request_methods": [request.get("method") for request in requests],
            "tools_list": listing,
            "shell": shell_result,
            "stderr": bounded_text(stderr),
        }
    except (CompatibilityError, QualificationError) as error:
        raise QualificationError(f"MCP {label} failed: {error}") from error
    finally:
        if process is not None:
            process.abort()


def launch_and_close_gui(
    binary: pathlib.Path,
    home: pathlib.Path,
    label: str,
    hold_seconds: float,
) -> dict[str, Any]:
    log_directory = home / "qualification-logs"
    log_directory.mkdir(parents=True, exist_ok=True)
    stdout_path = log_directory / f"{label}.stdout.log"
    stderr_path = log_directory / f"{label}.stderr.log"
    with stdout_path.open("wb") as stdout_stream, stderr_path.open("wb") as stderr_stream:
        process = subprocess.Popen(
            [str(binary)],
            stdout=stdout_stream,
            stderr=stderr_stream,
            env=qualification_environment(home, label),
        )
        try:
            wait_until(
                lambda: process.poll() is None and process_executable(process.pid) == binary.resolve(),
                8,
                f"GUI {label} did not remain running",
            )
            time.sleep(hold_seconds)
            require(process.poll() is None, f"GUI {label} exited before close")
            pid = process.pid
            process.send_signal(signal.SIGTERM)
            forced = False
            try:
                return_code = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                forced = True
                process.kill()
                return_code = process.wait(timeout=5)
            require(not forced, f"GUI {label} required SIGKILL")
            require(not process_is_alive(pid), f"GUI {label} PID remained alive")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
    return {
        "status": "passed",
        "pid": pid,
        "executable": str(binary.resolve()),
        "close_signal": "SIGTERM",
        "return_code": return_code,
        "stdout_log": str(stdout_path),
        "stderr_log": str(stderr_path),
        "stderr_tail": bounded_text(stderr_path.read_bytes()),
    }


def read_clean_default_config(home: pathlib.Path) -> dict[str, Any]:
    path = home / "config.json"
    require(path.exists() and not path.is_symlink(), "clean install config is missing")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise QualificationError(f"cannot read clean install config: {error}") from error
    require(isinstance(value, dict), "clean install config is not an object")
    shell = value.get("shell")
    require(isinstance(shell, dict), "clean install config has no shell policy")
    require(shell.get("enabled") is True, "clean install did not enable shell access")
    require(shell.get("user_disabled") is False, "clean install recorded a false opt-out")
    require(shell.get("policy_origin") == "default_enabled", "clean shell policy origin changed")
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "enabled": shell["enabled"],
        "user_disabled": shell["user_disabled"],
        "policy_origin": shell["policy_origin"],
        "policy_version": shell.get("policy_version"),
    }


def validate_staged_artifacts(home: pathlib.Path, source: dict[str, Any]) -> dict[str, Any]:
    installed_app = home / APP_NAME
    staged = validate_application_bundle(installed_app)
    source_signatures = source["signatures"]
    for key in ("embedded_cli", "runtime_launcher", "filesystem_daemon"):
        require(
            staged["signatures"][key]["cdhash"] == source_signatures[key]["cdhash"],
            f"staged {key} no longer matches the signed source app",
        )
    raw_cli = home / "bin/forge-conductor"
    require_regular_executable(raw_cli, "installed raw CLI")
    raw_signature = inspect_signature(
        raw_cli,
        expected_identifier=CLI_IDENTIFIER,
        expected_team=source["team_identifier"],
    )
    require(
        raw_signature["cdhash"] == source_signatures["embedded_cli"]["cdhash"],
        "installed raw CLI does not match the source embedded CLI",
    )
    sibling_framework = home / "bin/ForgeConductorCore.framework"
    require(sibling_framework.is_dir(), "installed raw CLI has no sibling framework")
    framework_signature = inspect_signature(
        sibling_framework,
        expected_identifier=FRAMEWORK_IDENTIFIER,
        expected_team=source["team_identifier"],
    )
    raw_launcher = home / "bin/forge-runtime-launcher"
    standalone_runtime = {
        "path": str(raw_launcher),
        "status": "present_unqualified" if raw_launcher.exists() else "blocked",
        "reason": (
            "runtime launcher is present but standalone raw-CLI shell execution was not part of this bounded scenario"
            if raw_launcher.exists()
            else "installed raw CLI has no adjacent forge-runtime-launcher; use the installed app main executable for this qualification"
        ),
    }
    if raw_launcher.exists():
        require_regular_executable(raw_launcher, "installed raw CLI runtime launcher")
        standalone_runtime["signature"] = inspect_signature(
            raw_launcher,
            expected_identifier=RUNTIME_LAUNCHER_IDENTIFIER,
            expected_team=source["team_identifier"],
        )
    return {
        "application": staged,
        "raw_cli": raw_signature,
        "raw_cli_sibling_framework": framework_signature,
        "standalone_raw_cli_runtime": standalone_runtime,
    }


class QualificationRun:
    def __init__(
        self,
        *,
        uid: int,
        source: dict[str, Any],
        shared_snapshot: dict[str, Any],
        home: pathlib.Path,
        startup_timeout: float,
        response_timeout: float,
        gui_hold_seconds: float,
    ) -> None:
        self.uid = uid
        self.source = source
        self.shared_snapshot = shared_snapshot
        self.home = home
        self.startup_timeout = startup_timeout
        self.response_timeout = response_timeout
        self.gui_hold_seconds = gui_hold_seconds
        self.account_home = account_home()
        self.plist = self.account_home / "Library/LaunchAgents" / f"{LABEL}.plist"
        self.command_link = self.account_home / ".local/bin/forge-conductor-swift"
        self.link_snapshot = SymlinkSnapshot.capture(self.command_link)
        require(
            self.link_snapshot.as_dictionary() == shared_snapshot["command_link"],
            "shared command link changed after preflight",
        )
        self.parent_existence = {
            str(self.command_link.parent): self.command_link.parent.exists(),
            str(self.plist.parent): self.plist.parent.exists(),
        }
        self.install_started = False
        self.expected_app_main = self.home / APP_NAME / "Contents/MacOS/Forge Conductor"

    def execute(self) -> dict[str, Any]:
        require(not self.home.exists(), f"qualification home already exists: {self.home}")
        self.home.mkdir(parents=True, mode=0o700)
        project = self.home / "project"
        project.mkdir(mode=0o700)

        deny_probe = run_command(
            [
                str(SANDBOX_EXEC),
                "-p",
                INSTALL_SANDBOX_PROFILE,
                FIREWALL_TOOL,
                "--getglobalstate",
            ],
            timeout=10,
        )
        require(deny_probe.returncode != 0, "install sandbox did not deny the firewall executable")

        source_cli = pathlib.Path(self.source["paths"]["embedded_cli"])
        install_command = sandboxed_install_command(source_cli, self.home)
        self.install_started = True
        installed = run_command(
            install_command,
            timeout=max(self.startup_timeout + 60, 90),
            environment=qualification_environment(self.home, "install"),
        )
        require(
            installed.returncode == 0,
            f"signed login-agent install failed: {bounded_text(installed.stdout + installed.stderr)}",
        )

        login_plist = validate_login_plist(self.plist, self.home)
        staged = validate_staged_artifacts(self.home, self.source)
        manager_initial = manager_process_identity(self.uid, self.expected_app_main, self.startup_timeout)
        manager_status = wait_for_manager_api(self.home, self.startup_timeout)
        manager_credential = prime_manager_credential(self.home, self.response_timeout)

        clean_default = read_clean_default_config(self.home)
        default_settings = manager_request("GET", "/api/manager/settings", home=self.home)
        default_shell = settings_shell(default_settings)
        require(default_shell.get("enabled") is True, "manager did not expose clean enabled shell state")
        require(default_shell.get("user_disabled") is False, "manager exposed a clean opt-out")
        require(default_shell.get("policy_origin") == "default_enabled", "manager clean policy origin changed")

        configured = update_settings(self.home, {"allowed_roots": [str(project)]})
        configured_root = validate_single_allowed_root(configured, project)
        persisted_root = validate_single_allowed_root(
            manager_request("GET", "/api/manager/settings", home=self.home),
            project,
        )
        first_success = mcp_shell_probe(
            self.expected_app_main,
            self.home,
            project,
            expect_enabled=True,
            label="clean-default",
            response_timeout=self.response_timeout,
        )

        disabled = update_settings(self.home, {"shell": {"enabled": False}})
        disabled_shell = settings_shell(disabled)
        require(disabled_shell.get("enabled") is False, "explicit opt-out did not disable shell")
        require(disabled_shell.get("user_disabled") is True, "explicit opt-out metadata is missing")
        require(disabled_shell.get("policy_origin") == "user_disabled", "explicit opt-out origin changed")
        first_denial = mcp_shell_probe(
            self.expected_app_main,
            self.home,
            project,
            expect_enabled=False,
            label="explicit-opt-out",
            response_timeout=self.response_timeout,
        )

        gui_first = launch_and_close_gui(
            self.expected_app_main,
            self.home,
            "gui-first",
            self.gui_hold_seconds,
        )
        persisted_after_close = settings_shell(
            manager_request("GET", "/api/manager/settings", home=self.home)
        )
        require(persisted_after_close.get("user_disabled") is True, "opt-out changed after app close")
        gui_reopened = launch_and_close_gui(
            self.expected_app_main,
            self.home,
            "gui-reopened",
            self.gui_hold_seconds,
        )
        require(gui_reopened["pid"] != gui_first["pid"], "app reopen did not create a new PID")
        persisted_after_reopen = settings_shell(
            manager_request("GET", "/api/manager/settings", home=self.home)
        )
        require(persisted_after_reopen.get("user_disabled") is True, "opt-out changed after app reopen")

        old_pid = int(manager_initial["pid"])
        restarted = run_command(
            ["/bin/launchctl", "kickstart", "-kp", f"gui/{self.uid}/{LABEL}"],
            timeout=20,
        )
        require(restarted.returncode == 0, f"manager kickstart failed: {bounded_text(restarted.stderr)}")
        manager_restarted = manager_process_identity(self.uid, self.expected_app_main, self.startup_timeout)
        new_pid = int(manager_restarted["pid"])
        require(new_pid != old_pid, "launchd manager PID did not change")
        wait_until(lambda: not process_is_alive(old_pid), 10, "predecessor manager PID remained alive")
        wait_for_manager_api(self.home, self.startup_timeout)
        restarted_settings = settings_shell(
            manager_request("GET", "/api/manager/settings", home=self.home)
        )
        require(restarted_settings.get("user_disabled") is True, "opt-out did not survive manager restart")
        restarted_denial = mcp_shell_probe(
            self.expected_app_main,
            self.home,
            project,
            expect_enabled=False,
            label="post-manager-restart-opt-out",
            response_timeout=self.response_timeout,
        )

        gui_after_manager_restart = launch_and_close_gui(
            self.expected_app_main,
            self.home,
            "gui-after-manager-restart",
            self.gui_hold_seconds,
        )
        enabled = update_settings(self.home, {"shell": {"enabled": True}})
        enabled_shell = settings_shell(enabled)
        require(enabled_shell.get("enabled") is True, "shell re-enable failed")
        require(enabled_shell.get("user_disabled") is False, "shell re-enable retained opt-out metadata")
        require(enabled_shell.get("policy_origin") == "user_enabled", "shell re-enable origin changed")
        final_success = mcp_shell_probe(
            self.expected_app_main,
            self.home,
            project,
            expect_enabled=True,
            label="post-manager-restart-enabled",
            response_timeout=self.response_timeout,
        )

        return {
            "status": "passed",
            "qualification_home": str(self.home),
            "install": {
                "status": "passed",
                "command": install_command,
                "exit_code": installed.returncode,
                "stdout_tail": bounded_text(installed.stdout),
                "stderr_tail": bounded_text(installed.stderr),
                "firewall_exec_denied_by_profile": True,
                "stale_launchagent_cleanup_skipped": True,
            },
            "launchagent_plist": login_plist,
            "staged_artifacts": staged,
            "clean_install_default": clean_default,
            "manager_status": manager_status,
            "manager_control_credential": manager_credential,
            "shell_probes": {
                "clean_default_success": first_success,
                "explicit_opt_out_denial": first_denial,
                "post_manager_restart_opt_out_denial": restarted_denial,
                "post_manager_restart_reenabled_success": final_success,
            },
            "app_process_restart": {
                "status": "passed",
                "first": gui_first,
                "reopened": gui_reopened,
                "after_manager_restart": gui_after_manager_restart,
            },
            "manager_process_restart": {
                "status": "passed",
                "predecessor": manager_initial,
                "successor": manager_restarted,
                "predecessor_gone": True,
                "successor_pid_changed": True,
                "opt_out_survived": True,
            },
            "settings_control_plane": {
                "status": "passed",
                "clean_default_enabled": True,
                "explicit_opt_out": True,
                "opt_out_survived_app_restart": True,
                "opt_out_survived_manager_restart": True,
                "reenabled": True,
                "allowed_project_root": {
                    "update_response": configured_root,
                    "persisted_readback": persisted_root,
                },
            },
            "settings_ui": {
                "status": "blocked",
                "reason": (
                    "the ordinary signed app exposes no supported production UI-test hook; "
                    "synthetic --uitesting manager fixtures cannot qualify this installed manager"
                ),
            },
        }

    def cleanup(self) -> dict[str, Any]:
        result: dict[str, Any] = {"status": "restored", "steps": [], "residuals": []}
        if not self.install_started:
            return result

        try:
            job = launchctl_job(self.uid)
            if job is not None:
                program = normalized_launchagent_path(str(job.get("program", "")))
                require(
                    program == normalized_launchagent_path(self.expected_app_main),
                    "loaded manager job is not qualification-owned",
                )
                bootout = run_command(
                    ["/bin/launchctl", "bootout", f"gui/{self.uid}/{LABEL}"],
                    timeout=15,
                )
                require(bootout.returncode == 0, f"qualification manager bootout failed: {bootout.stderr}")
                wait_until(lambda: launchctl_job(self.uid) is None, 10, "qualification manager job remained loaded")
                result["steps"].append("booted_out_qualification_manager")
        except QualificationError as error:
            result["status"] = "blocked"
            result["residuals"].append(str(error))

        try:
            if os.path.lexists(self.plist):
                validate_login_plist(self.plist, self.home)
                self.plist.unlink()
                result["steps"].append("removed_qualification_launchagent_plist")
        except (OSError, QualificationError) as error:
            result["status"] = "blocked"
            result["residuals"].append(f"LaunchAgent plist not restored: {error}")

        try:
            installed_binary = self.home / "bin/forge-conductor"
            result["command_link"] = self.link_snapshot.restore(installed_binary)
        except (OSError, QualificationError) as error:
            result["status"] = "blocked"
            result["residuals"].append(f"command link not restored: {error}")

        before_disabled = self.shared_snapshot["launchd_disabled"]["value"]
        try:
            if before_disabled is True:
                restored = run_command(
                    ["/bin/launchctl", "disable", f"gui/{self.uid}/{LABEL}"],
                    timeout=10,
                )
                require(restored.returncode == 0, "launchd disabled state restore failed")
            else:
                restored = run_command(
                    ["/bin/launchctl", "enable", f"gui/{self.uid}/{LABEL}"],
                    timeout=10,
                )
                require(restored.returncode == 0, "launchd enabled state restore failed")
            after_disabled = launchctl_disabled_snapshot(self.uid)["value"]
            exact = after_disabled == before_disabled
            result["launchd_disabled"] = {
                "before": before_disabled,
                "after": after_disabled,
                "exact_relevant_entry_restored": exact,
            }
            if not exact:
                result["status"] = "blocked"
                result["residuals"].append("launchd enablement override could not be restored exactly")
        except QualificationError as error:
            result["status"] = "blocked"
            result["residuals"].append(str(error))

        for raw, existed in self.parent_existence.items():
            path = pathlib.Path(raw)
            if existed or not path.exists():
                continue
            try:
                path.rmdir()
                result["steps"].append(f"removed_empty_parent:{path}")
            except OSError:
                result["residuals"].append(f"new parent retained because it is not empty: {path}")

        result["qualification_home_retained"] = str(self.home)
        result["residuals"].append(
            "macOS Background Task Management may retain display history until logout even after scoped bootout and plist removal"
        )
        try:
            final_job = launchctl_job(self.uid)
            require(final_job is None, "canonical manager job is still loaded after cleanup")
            require(not os.path.lexists(self.plist), "canonical manager plist remains after cleanup")
            result["final_canonical_job"] = "absent"
            result["final_canonical_plist"] = "absent"
        except QualificationError as error:
            result["status"] = "blocked"
            result["residuals"].append(str(error))
        result["status"] = "partial" if result["status"] == "restored" else result["status"]
        return result


def repository_identity() -> dict[str, Any]:
    branch = run_command(["/usr/bin/git", "-C", str(REPOSITORY_ROOT), "branch", "--show-current"])
    head = run_command(["/usr/bin/git", "-C", str(REPOSITORY_ROOT), "rev-parse", "HEAD"])
    return {
        "path": str(REPOSITORY_ROOT),
        "branch": branch.stdout.strip() if branch.returncode == 0 else None,
        "head": head.stdout.strip() if head.returncode == 0 else None,
    }


def initial_report(mode: str, app_argument: pathlib.Path) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "kind": "signed-shell-installed-manager-qualification",
        "generated_at": utc_now(),
        "mode": mode,
        "overall_status": "preflight",
        "source_application_argument": str(app_argument),
        "repository": repository_identity(),
        "scenario": {"status": "not_run"},
        "cleanup": {"status": "not_needed"},
        "blocking_reasons": [],
        "open_release_gates": OPEN_GATES,
        "claims": {
            "p10_complete": False,
            "g10_complete": False,
            "native_ui_signing_complete": False,
            "filesystem_e2_complete": False,
            "autonomous_continuity_complete": False,
        },
    }


def emit_report(report: dict[str, Any], output: pathlib.Path | None) -> None:
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if output is not None:
        output = output.resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
        temporary_path = pathlib.Path(temporary)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary_path, output)
        finally:
            if temporary_path.exists():
                temporary_path.unlink()
    sys.stdout.write(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Preflight or execute the bounded signed shell/installed-manager scenario. "
            "Without --execute, no product install, launch, settings mutation, or restart occurs."
        )
    )
    parser.add_argument("--app", required=True, type=pathlib.Path, help="ordinary signed Forge Conductor.app")
    parser.add_argument("--execute", action="store_true", help="authorize the guarded state-changing scenario")
    parser.add_argument(
        "--qualification-home",
        type=pathlib.Path,
        help="new isolated Forge home; must not exist (default: unique directory under the system temp root)",
    )
    parser.add_argument("--output", type=pathlib.Path, help="optional atomic JSON report destination")
    parser.add_argument("--startup-timeout", type=float, default=30.0)
    parser.add_argument("--response-timeout", type=float, default=30.0)
    parser.add_argument("--gui-hold-seconds", type=float, default=2.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report = initial_report("execute" if args.execute else "preflight_only", args.app)
    uid = os.getuid()
    try:
        require(platform.system() == "Darwin", "signed manager qualification requires macOS")
        require(os.geteuid() != 0, "signed manager qualification must run as the logged-in user")
        require(args.startup_timeout > 0 and args.response_timeout > 0, "timeouts must be positive")
        require(args.gui_hold_seconds >= 0, "GUI hold time cannot be negative")
        require(SANDBOX_EXEC.is_file() and os.access(SANDBOX_EXEC, os.X_OK), "sandbox-exec is unavailable")
        source = validate_application_bundle(args.app)
        shared = preflight_shared_state(uid, account_home())
        report["source_application"] = source
        report["shared_state_preflight"] = shared
        report["overall_status"] = "ready"
    except QualificationError as error:
        report["overall_status"] = "blocked"
        report["blocking_reasons"].append(str(error))
        emit_report(report, args.output)
        return 2

    if not args.execute:
        report["overall_status"] = "not_run"
        report["blocking_reasons"].append(
            "state-changing installation and lifecycle checks require an explicit --execute"
        )
        report["blocking_reasons"].append(
            "Settings UI visibility is not safely automatable against the ordinary installed app"
        )
        emit_report(report, args.output)
        return 3

    if args.qualification_home is None:
        qualification_home = pathlib.Path(tempfile.gettempdir()) / (
            f"forge-signed-shell-manager-{os.getpid()}-{int(time.time())}"
        )
    else:
        qualification_home = args.qualification_home.expanduser().resolve(strict=False)
    require(qualification_home.is_absolute(), "qualification home must be absolute")

    try:
        run = QualificationRun(
            uid=uid,
            source=source,
            shared_snapshot=shared,
            home=qualification_home,
            startup_timeout=args.startup_timeout,
            response_timeout=args.response_timeout,
            gui_hold_seconds=args.gui_hold_seconds,
        )
    except QualificationError as error:
        report["overall_status"] = "blocked"
        report["blocking_reasons"].append(str(error))
        emit_report(report, args.output)
        return 2
    scenario_error: str | None = None
    try:
        report["scenario"] = run.execute()
    except (QualificationError, OSError) as error:
        scenario_error = str(error)
        report["scenario"] = {"status": "blocked", "reason": scenario_error}
        report["blocking_reasons"].append(scenario_error)
    finally:
        report["cleanup"] = run.cleanup()

    settings = report.get("scenario", {}).get("settings_ui", {})
    if settings.get("status") == "blocked":
        report["blocking_reasons"].append(settings["reason"])
    standalone = report.get("scenario", {}).get("staged_artifacts", {}).get(
        "standalone_raw_cli_runtime", {}
    )
    if standalone.get("status") == "blocked":
        report["blocking_reasons"].append(standalone["reason"])
    if report["cleanup"].get("status") != "restored":
        report["blocking_reasons"].extend(report["cleanup"].get("residuals", []))

    report["blocking_reasons"] = list(dict.fromkeys(report["blocking_reasons"]))
    if scenario_error is not None or report["cleanup"].get("status") == "blocked":
        report["overall_status"] = "blocked"
        exit_code = 2
    else:
        report["overall_status"] = "partial"
        exit_code = 4
    emit_report(report, args.output)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
