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
    def test_blocked_scenario_retains_completed_production_path_evidence(self) -> None:
        run = object.__new__(subject.QualificationRun)
        run.scenario = {
            "status": "running",
            "clean_install_default": {"status": "passed"},
            "shell_probes": {"installed_raw_cli_success": {"status": "passed"}},
        }

        result = run.blocked_scenario("Settings control was not visible")

        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "Settings control was not visible")
        self.assertEqual(result["clean_install_default"]["status"], "passed")
        self.assertEqual(
            result["shell_probes"]["installed_raw_cli_success"]["status"],
            "passed",
        )

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
        self.assertEqual(subject.signing_leaf_authority(parsed), "Apple Development: Example")

    def test_product_signing_requirement_maps_each_team_to_only_its_certificate_class(
        self,
    ) -> None:
        development = subject.product_signing_requirement(
            subject.RUNTIME_LAUNCHER_IDENTIFIER,
            subject.DEVELOPMENT_TEAM_IDENTIFIER,
        )
        self.assertIn("anchor apple generic", development)
        self.assertIn("9AQ2C2838M", development)
        self.assertIn("1.2.840.113635.100.6.1.12", development)
        self.assertNotIn("1.2.840.113635.100.6.1.13", development)

        distribution = subject.product_signing_requirement(
            subject.FRAMEWORK_IDENTIFIER,
            subject.DISTRIBUTION_TEAM_IDENTIFIER,
        )
        self.assertIn("2Y25RTLZET", distribution)
        self.assertIn("1.2.840.113635.100.6.1.13", distribution)
        self.assertNotIn("1.2.840.113635.100.6.1.12", distribution)
        with self.assertRaisesRegex(subject.QualificationError, "signing team"):
            subject.product_signing_requirement(subject.APP_IDENTIFIER, "UNAPPROVED1")
        with self.assertRaisesRegex(subject.QualificationError, "product identifier"):
            subject.product_signing_requirement(
                "com.forge-conductor.unrecognized",
                subject.DEVELOPMENT_TEAM_IDENTIFIER,
            )

    def test_signature_inspection_enforces_explicit_requirement_for_all_architectures(
        self,
    ) -> None:
        path = pathlib.Path("/private/tmp/Forge Conductor.app")
        details = "\n".join(
            [
                f"Identifier={subject.APP_IDENTIFIER}",
                "CodeDirectory v=20500 flags=0x10000(runtime) hashes=1+1 location=embedded",
                "CDHash=ABCDEF0123456789",
                "Authority=Apple Development: Example",
                f"TeamIdentifier={subject.DEVELOPMENT_TEAM_IDENTIFIER}",
            ]
        )
        displayed = subprocess.CompletedProcess(
            ["/usr/bin/codesign"],
            0,
            stdout="",
            stderr=details,
        )
        verified = subprocess.CompletedProcess(
            ["/usr/bin/codesign"],
            0,
            stdout="",
            stderr="",
        )
        with mock.patch.object(subject, "run_command", side_effect=[displayed, verified]) as run:
            inspected = subject.inspect_signature(
                path,
                expected_identifier=subject.APP_IDENTIFIER,
                expected_team=subject.DEVELOPMENT_TEAM_IDENTIFIER,
                expected_authority="Apple Development: Example",
                deep=True,
            )

        self.assertEqual(inspected["team_identifier"], subject.DEVELOPMENT_TEAM_IDENTIFIER)
        self.assertIn("1.2.840.113635.100.6.1.12", inspected["signing_requirement"])
        verification = run.call_args_list[1].args[0]
        self.assertIn("--deep", verification)
        self.assertIn("--strict", verification)
        self.assertIn("--all-architectures", verification)
        self.assertIn(
            f"-R={inspected['signing_requirement']}",
            verification,
        )
        self.assertEqual(verification[-1], str(path))

    def test_expected_signing_identity_is_an_explicit_portable_constraint(self) -> None:
        arguments = [
            "qualify_signed_shell_manager.py",
            "--app",
            "/tmp/Forge Conductor.app",
            "--expected-team-identifier",
            "TEAM123",
            "--expected-signing-authority",
            "Apple Development: Example",
        ]
        with mock.patch.object(sys, "argv", arguments):
            parsed = subject.parse_args()
        self.assertEqual(parsed.expected_team_identifier, "TEAM123")
        self.assertEqual(parsed.expected_signing_authority, "Apple Development: Example")
        self.assertFalse(parsed.allow_system_events_ui)
        self.assertFalse(hasattr(subject, "EXPECTED_TEAM_IDENTIFIER"))
        self.assertFalse(hasattr(subject, "EXPECTED_SIGNING_AUTHORITY"))

    def test_system_events_settings_route_requires_explicit_authorization(self) -> None:
        arguments = [
            "qualify_signed_shell_manager.py",
            "--app",
            "/tmp/Forge Conductor.app",
            "--allow-system-events-ui",
        ]
        with mock.patch.object(sys, "argv", arguments):
            parsed = subject.parse_args()
        self.assertTrue(parsed.allow_system_events_ui)

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

    def test_manager_identity_waits_for_xpcproxy_exec_transition(self) -> None:
        expected = pathlib.Path("/private/tmp/qualification/Forge Conductor")
        job = {
            "pid": 4123,
            "program": str(expected),
            "state": "running",
            "output_sha256": "a" * 64,
        }
        process = subprocess.CompletedProcess(
            ["ps"],
            0,
            stdout=f"{expected} manager run --home /private/tmp/qualification\n",
            stderr="",
        )
        with mock.patch.object(subject, "launchctl_job", return_value=job), mock.patch.object(
            subject,
            "process_executable",
            side_effect=[pathlib.Path("/usr/libexec/xpcproxy"), expected],
        ), mock.patch.object(subject, "run_command", return_value=process), mock.patch.object(
            subject.time,
            "sleep",
        ):
            identity = subject.manager_process_identity(501, expected, timeout=1)
        self.assertEqual(identity["pid"], 4123)
        self.assertEqual(identity["executable"], str(expected))

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

    def test_manager_credential_rejects_non_ascii_storage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            credential = home / "manager-control.secret"
            credential.write_bytes(b"\xff" * 64)
            credential.chmod(0o600)
            with self.assertRaisesRegex(subject.QualificationError, "readable ASCII"):
                subject.read_manager_credential(home)

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

    def test_allowed_root_validation_accepts_only_fixed_tmp_alias(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
            observed = pathlib.Path(temporary)
            expected = observed.resolve(strict=True)
            validated = subject.validate_single_allowed_root(
                {"allowed_roots": [str(observed)]},
                expected,
            )
            self.assertEqual(validated["configured"], str(observed))
            self.assertEqual(pathlib.Path(validated["normalized"]), expected)
            self.assertEqual(pathlib.Path(validated["resolved"]), expected.resolve())

            alias = observed.parent / f"{observed.name}-alias"
            alias.symlink_to(expected, target_is_directory=True)
            self.addCleanup(lambda: alias.unlink(missing_ok=True))
            with self.assertRaisesRegex(subject.QualificationError, "canonical"):
                subject.validate_single_allowed_root(
                    {"allowed_roots": [str(alias)]},
                    expected,
                )

            wrong = observed / "wrong"
            wrong.mkdir()
            with self.assertRaisesRegex(subject.QualificationError, "canonical"):
                subject.validate_single_allowed_root(
                    {"allowed_roots": [str(wrong)]},
                    expected,
                )

    def test_default_qualification_home_resolves_system_temp_alias(self) -> None:
        with mock.patch.object(subject.tempfile, "gettempdir", return_value="/tmp"):
            home = subject.default_qualification_home()
        self.assertEqual(home.parent, pathlib.Path("/tmp").resolve(strict=True))
        self.assertTrue(home.name.startswith("forge-signed-shell-manager-"))

    def test_qualification_home_cannot_overlap_default_forge_home(self) -> None:
        account = pathlib.Path("/private/tmp/forge-account-fixture")
        default_home = account / ".forge-conductor"
        with mock.patch.object(subject, "account_home", return_value=account):
            accepted = subject.validate_qualification_home_isolation(
                pathlib.Path("/private/tmp/forge-qualification-fixture")
            )
            self.assertEqual(accepted["default_forge_home"], str(default_home))
            for rejected in (default_home, default_home / "child", account):
                with self.subTest(rejected=rejected):
                    with self.assertRaises(subject.QualificationError):
                        subject.validate_qualification_home_isolation(rejected)

    def test_accessibility_scripts_target_exact_pid_and_stable_identifiers(self) -> None:
        ready = subject.accessibility_script(4321, "process_ready")
        opened = subject.accessibility_script(4321, "open_settings")
        queried = subject.accessibility_script(4321, "query", "settings-shell-enabled")
        pressed = subject.accessibility_script(4321, "press", "settings-save")
        for script in (ready, opened, queried, pressed):
            self.assertIn("whose unix id is 4321", script)
        self.assertIn('return "NOT_READY"', ready)
        self.assertIn('keystroke "," using command down', opened)
        self.assertIn('"settings-shell-enabled"', queried)
        self.assertIn('perform action "AXPress"', pressed)
        with self.assertRaisesRegex(subject.QualificationError, "identifier"):
            subject.accessibility_script(4321, "query", 'bad"identifier')

    def test_accessibility_scripts_compile_on_macos(self) -> None:
        compiler = pathlib.Path("/usr/bin/osacompile")
        if sys.platform != "darwin" or not compiler.exists():
            self.skipTest("AppleScript compilation requires macOS")
        scripts = [
            subject.accessibility_script(4321, "process_ready"),
            subject.accessibility_script(4321, "open_settings"),
            subject.accessibility_script(4321, "query", "settings-shell-enabled"),
            subject.accessibility_script(4321, "press", "settings-save"),
        ]
        with tempfile.TemporaryDirectory() as temporary:
            for index, script in enumerate(scripts):
                result = subprocess.run(
                    [
                        str(compiler),
                        "-o",
                        str(pathlib.Path(temporary) / f"script-{index}.scpt"),
                        "-e",
                        script,
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_accessibility_snapshot_preserves_visible_role_state_and_title(self) -> None:
        snapshot = subject.parse_accessibility_snapshot(
            "FOUND\tAXCheckBox\ttrue\t0\tEnable project shell tools",
            "settings-shell-enabled",
        )
        self.assertEqual(snapshot["role"], "AXCheckBox")
        self.assertTrue(snapshot["enabled"])
        self.assertFalse(subject.accessibility_value_is_enabled(snapshot))
        snapshot["value"] = "1"
        self.assertTrue(subject.accessibility_value_is_enabled(snapshot))

    def test_legacy_disabled_fixture_and_receipt_validation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            home = root / "legacy"
            project = root / "project"
            project.mkdir()
            fixture = subject.write_legacy_disabled_fixture(home, project)
            self.assertEqual((home / "config.json").stat().st_mode & 0o777, 0o600)

            migrations = home / "config-migrations"
            migrations.mkdir()
            backup = migrations / "config.pre-v2.fixture.json"
            backup.write_bytes((home / "config.json").read_bytes())
            target = migrations / "config.schema-v2.fixture.json"
            migrated = {
                "config_schema_version": 2,
                "allowed_roots": [str(project)],
                "shell": {
                    "enabled": True,
                    "user_disabled": False,
                    "policy_version": 2,
                    "policy_origin": "legacy_disabled_default_migrated",
                    "default_timeout_sec": 41,
                },
            }
            encoded_target = (json.dumps(migrated, sort_keys=True) + "\n").encode("utf-8")
            target.write_bytes(encoded_target)
            (home / "config.json").write_bytes(encoded_target)
            receipt = {
                "status": "completed",
                "backup_filename": backup.name,
                "backup_sha256": fixture["sha256"],
                "target_filename": target.name,
                "target_sha256": subject.sha256_bytes(encoded_target),
            }
            (migrations / "shell-policy-v2.json").write_text(
                json.dumps(receipt),
                encoding="utf-8",
            )

            result = subject.validate_legacy_disabled_migration(home, fixture)
            self.assertEqual(result["status"], "passed")
            self.assertTrue(result["config"]["enabled"])
            self.assertEqual(
                result["config"]["policy_origin"],
                "legacy_disabled_default_migrated",
            )

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

    def test_shell_probe_completion_report_fills_every_required_field(self) -> None:
        for outcome in ("passed", "denied_by_explicit_opt_out"):
            with self.subTest(outcome=outcome):
                report = subject.shell_probe_completion_report(outcome)
                self.assertEqual(set(report), {"commands", "results", "gaps", "follow_ups"})
                self.assertTrue(
                    all(
                        isinstance(value, list)
                        and value
                        and all(isinstance(item, str) and item for item in value)
                        for value in report.values()
                    )
                )
                self.assertEqual(report["commands"], [subject.SHELL_COMMAND])
                self.assertEqual(report["results"], [outcome])

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

    def test_launchagent_path_normalizes_var_and_tmp_system_aliases_only(self) -> None:
        self.assertEqual(
            subject.normalized_launchagent_path("/var/folders/fixture"),
            pathlib.PurePath("/private/var/folders/fixture"),
        )
        self.assertEqual(
            subject.normalized_launchagent_path("/tmp/fixture"),
            pathlib.PurePath("/private/tmp/fixture"),
        )
        self.assertEqual(
            subject.normalized_launchagent_path("/Users/example/fixture"),
            pathlib.PurePath("/Users/example/fixture"),
        )

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
