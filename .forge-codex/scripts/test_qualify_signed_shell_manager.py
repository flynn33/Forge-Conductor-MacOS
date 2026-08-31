#!/usr/bin/env python3
"""Focused regressions for the guarded signed-manager qualification harness."""

from __future__ import annotations

import io
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_ROOT))

import qualify_signed_shell_manager as subject


class SignedShellManagerHarnessTests(unittest.TestCase):
    def test_codesign_parser_preserves_identity_team_hash_and_authorities(self) -> None:
        parsed = subject.parse_codesign_details(
            "\n".join(
                [
                    "Identifier=com.forge-conductor.cli",
                    "CodeDirectory v=20500 flags=0x10000(runtime) hashes=1+1 location=embedded",
                    "CDHash=ABCDEF0123",
                    "Authority=Apple Development: Example",
                    "Authority=Apple Root CA",
                    "TeamIdentifier=TEAM123",
                    "Runtime Version=26.5.0",
                ]
            )
        )
        self.assertEqual(parsed["identifier"], subject.CLI_IDENTIFIER)
        self.assertEqual(parsed["team_identifier"], "TEAM123")
        self.assertEqual(parsed["cdhash"], "abcdef0123")
        self.assertEqual(parsed["authorities"], ["Apple Development: Example", "Apple Root CA"])
        self.assertIn("runtime", parsed["code_directory"])

    def test_launchctl_parser_extracts_exact_process_identity(self) -> None:
        parsed = subject.parse_launchctl_job(
            """
            gui/501/com.forge-conductor.manager = {
                state = running
                program = /tmp/qualification/Forge Conductor.app/Contents/MacOS/Forge Conductor
                pid = 4123
            }
            """
        )
        self.assertEqual(parsed["pid"], 4123)
        self.assertEqual(
            parsed["program"],
            "/tmp/qualification/Forge Conductor.app/Contents/MacOS/Forge Conductor",
        )
        self.assertEqual(parsed["state"], "running")
        self.assertEqual(len(parsed["output_sha256"]), 64)

    def test_launchd_disabled_snapshot_distinguishes_absent_false_and_true(self) -> None:
        self.assertIsNone(subject.parse_disabled_entry('{ "unrelated" => true }'))
        self.assertFalse(
            subject.parse_disabled_entry('{ "com.forge-conductor.manager" => false }')
        )
        self.assertTrue(
            subject.parse_disabled_entry('{ "com.forge-conductor.manager" => true }')
        )
        self.assertFalse(
            subject.parse_disabled_entry('{ "com.forge-conductor.manager" => enabled }')
        )
        self.assertTrue(
            subject.parse_disabled_entry('{ "com.forge-conductor.manager" => disabled }')
        )

    def test_manager_credential_is_primed_by_exact_unauthorized_denial(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            credential = home / "manager-control.secret"

            def reject(request: object, timeout: float) -> object:
                self.assertGreater(timeout, 0)
                self.assertEqual(request.get_header("Authorization"), "Bearer invalid")
                credential.write_text("a" * 64, encoding="ascii")
                credential.chmod(0o600)
                raise urllib.error.HTTPError(
                    request.full_url,
                    401,
                    "Unauthorized",
                    {},
                    io.BytesIO(
                        json.dumps(
                            {
                                "ok": False,
                                "code": "manager_mutation_unauthorized",
                                "message": "authorization required",
                            }
                        ).encode("utf-8")
                    ),
                )

            with mock.patch.object(subject.urllib.request, "urlopen", side_effect=reject):
                result = subject.prime_manager_credential(home, timeout=1)

            self.assertTrue(result["created_by_manager"])
            self.assertEqual(result["unauthorized_probe_status"], 401)
            self.assertEqual(subject.read_manager_credential(home), "a" * 64)

    def test_manager_credential_prime_rejects_invalid_denial_bodies(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            for body in (b"{", b"\xff"):
                with self.subTest(body=body):
                    error = urllib.error.HTTPError(
                        "http://127.0.0.1:7788/api/manager/settings",
                        401,
                        "Unauthorized",
                        {},
                        io.BytesIO(body),
                    )
                    with mock.patch.object(
                        subject.urllib.request,
                        "urlopen",
                        side_effect=error,
                    ):
                        with self.assertRaisesRegex(
                            subject.QualificationError,
                            "invalid JSON",
                        ):
                            subject.prime_manager_credential(home, timeout=1)

    def test_manager_credential_prime_bounds_denial_body(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            error = urllib.error.HTTPError(
                "http://127.0.0.1:7788/api/manager/settings",
                401,
                "Unauthorized",
                {},
                io.BytesIO(b"x" * (subject.MANAGER_DENIAL_MAXIMUM_BYTES + 1)),
            )
            with mock.patch.object(subject.urllib.request, "urlopen", side_effect=error):
                with self.assertRaisesRegex(subject.QualificationError, "byte bound"):
                    subject.prime_manager_credential(home, timeout=1)

    def test_install_command_denies_firewall_and_preserves_stale_agents(self) -> None:
        cli = pathlib.Path("/tmp/Forge Conductor.app/Contents/Helpers/forge-conductor")
        home = pathlib.Path("/tmp/qualification")
        command = subject.sandboxed_install_command(cli, home)
        self.assertEqual(command[0], str(subject.SANDBOX_EXEC))
        self.assertIn("(allow job-creation)", command[2])
        self.assertIn(subject.FIREWALL_TOOL, command[2])
        self.assertIn("(deny process-exec", command[2])
        self.assertEqual(command[3], str(cli))
        self.assertIn("--keep-stale", command)
        self.assertEqual(command[-2:], ["--home", str(home)])

    def test_install_profile_compiles_and_denies_exact_firewall_executable(self) -> None:
        expected = (
            '(version 1) (allow default) (allow job-creation) '
            f'(deny process-exec (literal "{subject.FIREWALL_TOOL}"))'
        )
        self.assertEqual(subject.INSTALL_SANDBOX_PROFILE, expected)
        if sys.platform != "darwin" or not subject.SANDBOX_EXEC.exists():
            self.skipTest("sandbox-exec semantic probe requires macOS")
        allowed = subprocess.run(
            [str(subject.SANDBOX_EXEC), "-p", expected, "/usr/bin/true"],
            capture_output=True,
            check=False,
            timeout=5,
        )
        denied = subprocess.run(
            [
                str(subject.SANDBOX_EXEC),
                "-p",
                expected,
                subject.FIREWALL_TOOL,
                "--getglobalstate",
            ],
            capture_output=True,
            check=False,
            timeout=5,
        )
        self.assertEqual(allowed.returncode, 0)
        self.assertNotEqual(denied.returncode, 0)

    def test_shell_success_validator_requires_full_legacy_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cwd = pathlib.Path(temporary)
            payload = {
                "ok": True,
                "exit_code": 0,
                "stdout": subject.SHELL_MARKER,
                "stderr": "",
                "timed_out": False,
                "stdout_truncated": False,
                "stderr_truncated": False,
                "command": subject.SHELL_COMMAND,
                "cwd": str(cwd),
            }
            validated = subject.validate_shell_result(payload, cwd)
            self.assertEqual(validated["requested_timeout_sec"], 999)
            self.assertEqual(validated["stdout"], subject.SHELL_MARKER)

            del payload["stderr_truncated"]
            with self.assertRaisesRegex(subject.QualificationError, "missing keys"):
                subject.validate_shell_result(payload, cwd)

    def test_shell_denial_validator_requires_explicit_opt_out_code(self) -> None:
        validated = subject.validate_shell_denial(
            {
                "ok": False,
                "code": "shell_disabled_by_user",
                "message": "disabled",
                "retryable": False,
            }
        )
        self.assertEqual(validated["code"], "shell_disabled_by_user")
        with self.assertRaisesRegex(subject.QualificationError, "denial code"):
            subject.validate_shell_denial(
                {
                    "ok": False,
                    "code": "shell_disabled",
                    "message": "disabled",
                    "retryable": False,
                }
            )

    def test_tools_list_requires_shell_exec(self) -> None:
        response = {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "tools": [
                    {
                        "name": "shell_exec",
                        "description": "Execute the established shell tool.",
                        "inputSchema": {"type": "object"},
                    }
                ]
            },
        }
        self.assertEqual(subject.validate_tools_list(response)["shell_exec_count"], 1)
        response["result"]["tools"] = []
        with self.assertRaisesRegex(subject.QualificationError, "absent"):
            subject.validate_tools_list(response)

    def test_symlink_snapshot_restores_absence_without_touching_decoy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            link = root / "forge-conductor-swift"
            installed = root / "isolated/bin/forge-conductor"
            installed.parent.mkdir(parents=True)
            installed.write_text("fixture", encoding="utf-8")
            snapshot = subject.SymlinkSnapshot.capture(link)
            os.symlink(installed, link)
            restored = snapshot.restore(installed)
            self.assertEqual(restored["status"], "restored")
            self.assertFalse(os.path.lexists(link))

            snapshot = subject.SymlinkSnapshot.capture(link)
            decoy = root / "decoy"
            decoy.write_text("fixture", encoding="utf-8")
            os.symlink(decoy, link)
            with self.assertRaisesRegex(subject.QualificationError, "changed concurrently"):
                snapshot.restore(installed)
            self.assertEqual(link.resolve(), decoy.resolve())

    def test_symlink_snapshot_recreates_original_target_exactly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            original = root / "original"
            installed = root / "installed"
            original.write_text("original", encoding="utf-8")
            installed.write_text("installed", encoding="utf-8")
            link = root / "link"
            os.symlink("original", link)
            snapshot = subject.SymlinkSnapshot.capture(link)
            link.unlink()
            os.symlink(installed, link)
            snapshot.restore(installed)
            self.assertEqual(os.readlink(link), "original")

    def test_non_symlink_command_link_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "forge-conductor-swift"
            path.write_text("do not replace", encoding="utf-8")
            with self.assertRaisesRegex(subject.QualificationError, "not a symlink"):
                subject.SymlinkSnapshot.capture(path)

    def test_login_plist_validation_rejects_wrong_home(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            home = root / "qualification"
            plist = root / "manager.plist"
            program = home / subject.APP_NAME / "Contents/MacOS/Forge Conductor"
            value = {
                "Label": subject.LABEL,
                "ProgramArguments": [
                    str(program),
                    "manager",
                    "run",
                    "--home",
                    str(home),
                ],
                "RunAtLoad": True,
                "KeepAlive": True,
                "WorkingDirectory": str(home),
                "EnvironmentVariables": {"FORGE_CONDUCTOR_HOME": str(home)},
            }
            plist.write_bytes(plistlib.dumps(value))
            self.assertEqual(subject.validate_login_plist(plist, home)["label"], subject.LABEL)
            value["ProgramArguments"][-1] = str(root / "decoy")
            plist.write_bytes(plistlib.dumps(value))
            with self.assertRaisesRegex(subject.QualificationError, "home argument changed"):
                subject.validate_login_plist(plist, home)

    def test_login_plist_validation_accepts_resolved_tmp_alias(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            plist = pathlib.Path(temporary) / "manager.plist"
            canonical_home = pathlib.Path("/private/tmp/forge-signed-shell-alias-fixture")
            plist_home = pathlib.Path("/tmp/forge-signed-shell-alias-fixture")
            program = plist_home / subject.APP_NAME / "Contents/MacOS/Forge Conductor"
            value = {
                "Label": subject.LABEL,
                "ProgramArguments": [
                    str(program),
                    "manager",
                    "run",
                    "--home",
                    str(plist_home),
                ],
                "RunAtLoad": True,
                "KeepAlive": True,
                "WorkingDirectory": str(plist_home),
                "EnvironmentVariables": {"FORGE_CONDUCTOR_HOME": str(plist_home)},
            }
            plist.write_bytes(plistlib.dumps(value))
            validated = subject.validate_login_plist(plist, canonical_home)
            self.assertEqual(validated["program_arguments"], value["ProgramArguments"])

    def test_login_plist_validation_rejects_user_controlled_symlink_alias(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            canonical_home = root / "canonical"
            canonical_home.mkdir()
            alias_home = root / "alias"
            alias_home.symlink_to(canonical_home, target_is_directory=True)
            plist = root / "manager.plist"
            program = alias_home / subject.APP_NAME / "Contents/MacOS/Forge Conductor"
            value = {
                "Label": subject.LABEL,
                "ProgramArguments": [
                    str(program),
                    "manager",
                    "run",
                    "--home",
                    str(alias_home),
                ],
                "RunAtLoad": True,
                "KeepAlive": True,
                "WorkingDirectory": str(alias_home),
                "EnvironmentVariables": {"FORGE_CONDUCTOR_HOME": str(alias_home)},
            }
            plist.write_bytes(plistlib.dumps(value))
            with self.assertRaisesRegex(subject.QualificationError, "program changed"):
                subject.validate_login_plist(plist, canonical_home)

    def test_report_can_never_claim_open_release_gates_complete(self) -> None:
        report = subject.initial_report("preflight_only", pathlib.Path("/tmp/Forge Conductor.app"))
        self.assertEqual(report["scenario"]["status"], "not_run")
        self.assertTrue(report["open_release_gates"])
        self.assertTrue(all(value is False for value in report["claims"].values()))
        json.dumps(report)


if __name__ == "__main__":
    unittest.main()
