#!/usr/bin/env python3
"""Focused regressions for the privileged-filesystem H0 runner."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import pathlib
import plistlib
import signal
import stat
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_ROOT))

import run_privileged_filesystem_h0 as subject


def make_executable(path: pathlib.Path, source: str = "#!/bin/sh\nexit 0\n") -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(0o700)


def protocol_source() -> str:
    return textwrap.dedent(
        """
        public enum ForgeFilesystemProtocolConstants {
            public static let appIdentifier = "com.forge-conductor.app"
            public static let managerIdentifier = "com.forge-conductor.cli"
            public static let developmentTeamIdentifier = "TEAMDEV123"
            public static let productionTeamIdentifier = "TEAMREL456"

            public static var requiredAppCodeSigningRequirement: String {
                requirement(
                    identifier: appIdentifier,
                    teamIdentifier: activeTeamIdentifier,
                    allowDevelopmentCertificate: isDevelopmentBuild
                )
            }

            public static var requiredClientCodeSigningRequirement: String {
                let managerRequirement = requirement(
                    identifier: managerIdentifier,
                    teamIdentifier: activeTeamIdentifier,
                    allowDevelopmentCertificate: isDevelopmentBuild
                )
                return "(\\(requiredAppCodeSigningRequirement)) or (\\(managerRequirement))"
            }

            private static func requirement(
                identifier: String,
                teamIdentifier: String,
                allowDevelopmentCertificate: Bool
            ) -> String {
                let certificateRequirement = allowDevelopmentCertificate
                    ? "certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
                    : "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                return "anchor apple generic and identifier \\(identifier) "
                    + "and certificate leaf[subject.OU] = \\(teamIdentifier) "
                    + certificateRequirement
            }
        }
        """
    )


class PrivilegedFilesystemH0RunnerTests(unittest.TestCase):
    def test_executable_paths_must_be_absolute_regular_distinct_and_nonsymlinked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            harness = root / "harness"
            adversary = root / "adversary"
            make_executable(harness)
            make_executable(adversary)
            validated = subject.validate_executable_paths(harness, adversary)
            self.assertEqual(validated["harness"], harness.resolve())
            self.assertEqual(validated["adversary"], adversary.resolve())

            with self.assertRaisesRegex(subject.H0Error, "absolute"):
                subject.validate_executable_paths(pathlib.Path("harness"), adversary)
            with self.assertRaisesRegex(subject.H0Error, "distinct paths"):
                subject.validate_executable_paths(harness, harness)

            hardlink = root / "hardlink"
            os.link(harness, hardlink)
            with self.assertRaisesRegex(subject.H0Error, "distinct filesystem objects"):
                subject.validate_executable_paths(harness, hardlink)

            symlink = root / "symlink"
            symlink.symlink_to(adversary)
            with self.assertRaisesRegex(subject.H0Error, "must not be a symlink"):
                subject.validate_executable_paths(harness, symlink)

            directory = root / "directory"
            directory.mkdir()
            with self.assertRaisesRegex(subject.H0Error, "regular file"):
                subject.validate_executable_paths(harness, directory)

    def test_logged_in_user_rejects_root_and_console_mismatch(self) -> None:
        with mock.patch.object(subject.platform, "system", return_value="Darwin"), mock.patch.object(
            subject.os, "getuid", return_value=0
        ), mock.patch.object(subject.os, "geteuid", return_value=0):
            with self.assertRaisesRegex(subject.H0Error, "non-root"):
                subject.validate_logged_in_user()

        account = mock.Mock(pw_name="owner")
        result = subject.BoundedCommandResult(
            arguments=("/usr/bin/stat",),
            pid=101,
            returncode=0,
            stdout=b"someone-else\n",
            stderr=b"",
            timed_out=False,
            process_group_cleanup="already_empty",
        )
        with mock.patch.object(subject.platform, "system", return_value="Darwin"), mock.patch.object(
            subject.os, "getuid", return_value=501
        ), mock.patch.object(subject.os, "geteuid", return_value=501), mock.patch.object(
            subject.pwd, "getpwuid", return_value=account
        ), mock.patch.object(subject, "run_bounded", return_value=result):
            with self.assertRaisesRegex(subject.H0Error, "logged-in console user"):
                subject.validate_logged_in_user()

    def test_protocol_source_builds_exact_daemon_requirement_for_each_team(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary) / "ForgeFilesystemProtocol.swift"
            source.write_text(protocol_source(), encoding="utf-8")
            development = subject.read_daemon_client_requirement(source, "TEAMDEV123")
            self.assertEqual(development["certificate_class"], "development")
            self.assertIn('identifier "com.forge-conductor.app"', development["requirement"])
            self.assertIn('identifier "com.forge-conductor.cli"', development["requirement"])
            self.assertIn("1.2.840.113635.100.6.1.12", development["requirement"])
            self.assertNotIn(subject.HARNESS_IDENTIFIER, development["requirement"])
            self.assertNotIn(subject.ADVERSARY_IDENTIFIER, development["requirement"])

            distribution = subject.read_daemon_client_requirement(source, "TEAMREL456")
            self.assertEqual(distribution["certificate_class"], "distribution")
            self.assertIn("1.2.840.113635.100.6.1.13", distribution["requirement"])

            with self.assertRaisesRegex(subject.H0Error, "protocol-defined"):
                subject.read_daemon_client_requirement(source, "OTHER12345")

    def test_protocol_source_rejects_h0_admission(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary) / "ForgeFilesystemProtocol.swift"
            source.write_text(
                protocol_source() + f'let forbidden = "{subject.HARNESS_IDENTIFIER}"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(subject.H0Error, "unexpectedly names"):
                subject.read_daemon_client_requirement(source, "TEAMDEV123")

    def test_canonical_qualification_template_is_strictly_nonpassing(self) -> None:
        snapshot, contract = subject.validate_nonpassing_qualification_template(
            subject.QUALIFICATION_TEMPLATE
        )
        self.assertEqual(snapshot.sha256, subject.EXPECTED_QUALIFICATION_TEMPLATE_SHA256)
        self.assertEqual(contract["matrix_rows_required"], 57)
        self.assertEqual(contract["matrix_rows_executed"], 0)
        self.assertEqual(contract["formal_predicates_required"], 12)
        self.assertEqual(contract["formal_predicates_proven"], 0)
        self.assertEqual(contract["status"], "partial")
        self.assertFalse(contract["ok"])
        self.assertEqual(contract["residual_disposition"], "open_release_blocker")

    def test_qualification_template_rejects_advanced_or_noncanonical_claims(self) -> None:
        canonical = json.loads(subject.QUALIFICATION_TEMPLATE.read_text(encoding="utf-8"))
        first_case = sorted(canonical["matrix"])[0]
        first_predicate = sorted(subject.EXPECTED_FORMAL_PREDICATE_KEYS)[0]

        mutations = []
        advanced_row = json.loads(json.dumps(canonical))
        advanced_row["matrix"][first_case]["status"] = "passed"
        mutations.append((advanced_row, "qualification row was advanced"))
        advanced_predicate = json.loads(json.dumps(canonical))
        advanced_predicate["formal_closure"][first_predicate] = True
        mutations.append((advanced_predicate, "formal predicate was advanced"))
        bound_repository = json.loads(json.dumps(canonical))
        bound_repository["repository"]["branch"] = "unexpected"
        mutations.append((bound_repository, "binds repository identity"))
        digest_only_change = json.loads(json.dumps(canonical))
        digest_only_change["remaining_requirements"][0] = "placeholder"
        mutations.append((digest_only_change, "template digest changed"))

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            for index, (value, message) in enumerate(mutations):
                with self.subTest(message=message):
                    candidate = root / f"mutation-{index}.json"
                    candidate.write_text(
                        json.dumps(value, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )
                    with self.assertRaisesRegex(subject.H0Error, message):
                        subject.validate_nonpassing_qualification_template(candidate)

    def test_qualification_template_rejects_malformed_and_duplicate_json(self) -> None:
        raw = subject.QUALIFICATION_TEMPLATE.read_text(encoding="utf-8")
        duplicate = raw.replace(
            "{\n",
            '{\n  "\\u0073chema_version": 2,\n',
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            malformed = root / "malformed.json"
            malformed.write_text("{", encoding="utf-8")
            with self.assertRaisesRegex(subject.H0Error, "malformed JSON"):
                subject.validate_nonpassing_qualification_template(malformed)

            duplicated = root / "duplicate.json"
            duplicated.write_text(duplicate, encoding="utf-8")
            with self.assertRaisesRegex(subject.H0Error, "duplicate key: schema_version"):
                subject.validate_nonpassing_qualification_template(duplicated)

    def test_codesign_and_designated_requirement_parsers_are_strict(self) -> None:
        parsed = subject.parse_codesign_details(
            "\n".join(
                [
                    "Identifier=com.forge-conductor.qualification-harness",
                    "CodeDirectory v=20500 flags=0x10000(runtime) hashes=1+1 location=embedded",
                    "CDHash=ABCDEF0123456789ABCDEF0123456789ABCDEF01",
                    "Authority=Apple Development: Example (TEAMDEV123)",
                    "TeamIdentifier=TEAMDEV123",
                ]
            )
        )
        self.assertEqual(parsed["identifier"], subject.HARNESS_IDENTIFIER)
        self.assertEqual(parsed["team_identifier"], "TEAMDEV123")
        self.assertEqual(parsed["cdhash"], "abcdef0123456789abcdef0123456789abcdef01")
        with self.assertRaisesRegex(subject.H0Error, "no single identifier"):
            subject.parse_codesign_details(
                "Identifier=one\nIdentifier=two\nTeamIdentifier=T\nCDHash=a\n"
                "CodeDirectory flags=runtime\nAuthority=A\n"
            )

        requirement = subject.parse_designated_requirement(
            "Executable=/tmp/harness\n# designated => identifier \"example\" and anchor apple\n"
        )
        self.assertEqual(requirement, 'identifier "example" and anchor apple')
        with self.assertRaisesRegex(subject.H0Error, "no single"):
            subject.parse_designated_requirement("no requirement\n")

    def test_entitlements_allow_only_exact_application_identifier(self) -> None:
        identifier = subject.HARNESS_IDENTIFIER
        expected = {"com.apple.application-identifier": f"TEAMDEV123.{identifier}"}
        encoded = plistlib.dumps(expected)
        self.assertEqual(subject.parse_entitlements(encoded, identifier, "TEAMDEV123"), expected)
        self.assertEqual(subject.parse_entitlements(b"", identifier, "TEAMDEV123"), {})

        unexpected = dict(expected)
        unexpected["com.apple.security.get-task-allow"] = True
        with self.assertRaisesRegex(subject.H0Error, "unexpected entitlements"):
            subject.parse_entitlements(plistlib.dumps(unexpected), identifier, "TEAMDEV123")
        with self.assertRaisesRegex(subject.H0Error, "wrong application-identifier"):
            subject.parse_entitlements(
                plistlib.dumps({"com.apple.application-identifier": "wrong"}),
                identifier,
                "TEAMDEV123",
            )

    def readiness_payload(
        self,
        *,
        command: str,
        role: str,
        executable: pathlib.Path,
        cdhash: str,
        pid: int,
        parent_pid: int,
    ) -> dict[str, object]:
        return {
            "schema_version": 1,
            "command": command,
            "role": role,
            "process_id": pid,
            "parent_process_id": parent_pid,
            "effective_user_id": os.geteuid(),
            "executable_path": str(executable.resolve()),
            "bundle_identifier": subject.EXPECTED_IDENTIFIERS[role],
            "signing_team_identifier": "TEAMDEV123",
            "signing_entitlements": {
                "com.apple.application-identifier":
                    f"TEAMDEV123.{subject.EXPECTED_IDENTIFIERS[role]}",
            },
            "code_directory_hash": cdhash,
            "hardened_runtime": True,
            "self_identity_requirement_satisfied": True,
            "daemon_client_requirement_sha256": "d" * 64,
            "daemon_client_requirement_satisfied": False,
            "team_only_admission_probe_satisfied": True,
            "recorder_context_present": command == "self-check",
            "supported_commands": ["describe", "self-check"],
            "production_mutation_exercised": False,
            "qualification_status": "not_run",
            "rows_updated": 0,
            "formal_predicates_updated": 0,
            "completion_claims": subject.false_completion_claims(),
        }

    def ready_report(self, *, execute: bool) -> dict[str, object]:
        report = subject.initial_report(argparse.Namespace(execute=execute))
        report["overall_status"] = "ready"
        report["matrix"] = {"required_rows": 57, "executed_rows": 0}
        report["formal_closure"] = {"required_predicates": 12, "proven_predicates": 0}
        report["repository"] = {
            "path": "/tmp/forge-h0-repository",
            "branch": "security/e2-harness-controls",
            "head": "a" * 40,
            "base_branch": "main",
            "base_sha": "b" * 40,
        }
        report["operator"] = {"uid": 501, "name": "operator", "console_user": "operator"}
        report["canonical_qualification_template"] = {
            "path": "/tmp/forge-h0-repository/qualification.json",
            "before_sha256": "c" * 64,
            "after_sha256": "c" * 64,
            "byte_stable": True,
            "nonpassing_contract": {
                "matrix_rows_required": 57,
                "matrix_rows_executed": 0,
                "formal_predicates_required": 12,
                "formal_predicates_proven": 0,
                "status": "partial",
                "ok": False,
                "residual_disposition": "open_release_blocker",
            },
        }
        source_snapshot = {
            "path": "/tmp/forge-h0-repository/ForgeFilesystemProtocol.swift",
            "device": 1,
            "inode": 2,
            "mode": 0o644,
            "owner_uid": 501,
            "link_count": 1,
            "size": 100,
            "modification_time_ns": 1,
            "change_time_ns": 1,
            "sha256": "d" * 64,
        }
        report["daemon_client_admission"] = {
            "source": source_snapshot,
            "app_identifier": "com.forge-conductor.app",
            "manager_identifier": "com.forge-conductor.cli",
            "development_team_identifier": "TEAMDEV123",
            "production_team_identifier": "TEAMREL456",
            "certificate_class": "development",
            "authority_prefix": "Apple Development:",
            "certificate_requirement": "development certificate requirement",
            "requirement": "exact daemon client requirement",
            "requirement_sha256": "d" * 64,
        }
        filesystem = {
            "type": "apfs",
            "local": True,
            "mount_point": "/System/Volumes/Data",
            "mount_source": "/dev/disk-test",
            "mount_flags": subject.MNT_LOCAL,
            "identity_replacement_detection": "inode_and_ctime_on_local_apfs",
        }
        signatures: dict[str, dict[str, object]] = {}
        for index, role in enumerate(("harness", "adversary"), start=1):
            identifier = subject.EXPECTED_IDENTIFIERS[role]
            signatures[role] = {
                "path": str(pathlib.Path(f"/tmp/{role}").resolve()),
                "sha256": str(index) * 64,
                "filesystem": filesystem,
                "identifier": identifier,
                "team_identifier": "TEAMDEV123",
                "code_directory_hash": str(index) * 40,
                "hardened_runtime": True,
                "authorities": ["Apple Development: Operator"],
                "designated_requirement": f'identifier "{identifier}" and anchor apple generic',
                "entitlements": {
                    "com.apple.application-identifier": f"TEAMDEV123.{identifier}",
                },
                "exact_identity_requirement_satisfied": True,
                "daemon_client_requirement_rejected": True,
            }
        report["signatures"] = signatures
        if not execute:
            report["blocking_reasons"] = [
                "describe and self-check remain unexecuted without explicit --execute"
            ]
            return report

        report["blocking_reasons"] = []
        report["recorder_context_bound"] = True
        report["recorder_evidence_context"] = {
            "schema_version": 1,
            "binding_schema_version": 1,
            "evidence_id": "EVID-h0-test",
            "source_manifest": {
                "schema_version": 1,
                "sha256": "e" * 64,
                "file_count": 1,
                "bytes": 1,
            },
            "repository": {
                "branch": report["repository"]["branch"],
                "head_sha": report["repository"]["head"],
                "base_branch": report["repository"]["base_branch"],
                "base_sha": report["repository"]["base_sha"],
                "repository_path": report["repository"]["path"],
            },
            "test_environment": {
                "macos_build": "test-build",
                "machine_identifier": "test-machine",
                "platform": "macOS test",
                "architecture": "arm64",
            },
            "qualification_context_present": False,
        }
        commands: list[dict[str, object]] = []
        pid = 1000
        for role in ("harness", "adversary"):
            signature = signatures[role]
            for command in subject.EXPECTED_COMMANDS:
                pid += 1
                payload = self.readiness_payload(
                    command=command,
                    role=role,
                    executable=pathlib.Path(str(signature["path"])),
                    cdhash=str(signature["code_directory_hash"]),
                    pid=pid,
                    parent_pid=999,
                )
                commands.append({
                    "command": command,
                    "role": role,
                    "return_code": 0,
                    "timed_out": False,
                    "stdout_sha256": subject.sha256_bytes(subject.canonical_json_line(payload)),
                    "stderr_bytes": 0,
                    "process_group_cleanup": "already_empty",
                    "live_process_identity": {
                        "process_id": pid,
                        "stop_signal": int(signal.SIGSTOP),
                        "code_directory_hash": signature["code_directory_hash"],
                        "matches_inspected_executable": True,
                    },
                    "executable_snapshot_sha256": signature["sha256"],
                    "result": payload,
                })
        report["commands"] = commands
        return report

    def test_tool_output_requires_exact_canonical_nonclaim_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            executable = pathlib.Path(temporary) / "harness"
            make_executable(executable)
            payload = self.readiness_payload(
                command="self-check",
                role="harness",
                executable=executable,
                cdhash="a" * 40,
                pid=222,
                parent_pid=111,
            )
            raw = subject.canonical_json_line(payload)
            with mock.patch.object(subject.os, "geteuid", return_value=501):
                validated = subject.validate_tool_output(
                    raw,
                    command="self-check",
                    role="harness",
                    expected_path=executable,
                    expected_identifier=subject.HARNESS_IDENTIFIER,
                    expected_team="TEAMDEV123",
                    expected_entitlements={
                        "com.apple.application-identifier":
                            f"TEAMDEV123.{subject.HARNESS_IDENTIFIER}",
                    },
                    expected_cdhash="a" * 40,
                    expected_requirement_sha256="d" * 64,
                    expected_pid=222,
                    expected_parent_pid=111,
                )
            self.assertEqual(validated, payload)

            noncanonical = (json.dumps(payload, sort_keys=False) + "\n").encode("utf-8")
            with self.assertRaisesRegex(subject.H0Error, "not canonical"):
                subject.validate_tool_output(
                    noncanonical,
                    command="self-check",
                    role="harness",
                    expected_path=executable,
                    expected_identifier=subject.HARNESS_IDENTIFIER,
                    expected_team="TEAMDEV123",
                    expected_entitlements={
                        "com.apple.application-identifier":
                            f"TEAMDEV123.{subject.HARNESS_IDENTIFIER}",
                    },
                    expected_cdhash="a" * 40,
                    expected_requirement_sha256="d" * 64,
                    expected_pid=222,
                    expected_parent_pid=111,
                )

            advanced = dict(payload)
            advanced["rows_updated"] = 1
            with self.assertRaisesRegex(subject.H0Error, "rows advanced"):
                with mock.patch.object(subject.os, "geteuid", return_value=501):
                    subject.validate_tool_output(
                        subject.canonical_json_line(advanced),
                        command="self-check",
                        role="harness",
                        expected_path=executable,
                        expected_identifier=subject.HARNESS_IDENTIFIER,
                        expected_team="TEAMDEV123",
                        expected_entitlements={
                            "com.apple.application-identifier":
                                f"TEAMDEV123.{subject.HARNESS_IDENTIFIER}",
                        },
                        expected_cdhash="a" * 40,
                        expected_requirement_sha256="d" * 64,
                        expected_pid=222,
                        expected_parent_pid=111,
                    )

            unknown = dict(payload)
            unknown["extra"] = False
            with self.assertRaisesRegex(subject.H0Error, "unexpected fields"):
                subject.validate_tool_output(
                    subject.canonical_json_line(unknown),
                    command="self-check",
                    role="harness",
                    expected_path=executable,
                    expected_identifier=subject.HARNESS_IDENTIFIER,
                    expected_team="TEAMDEV123",
                    expected_entitlements={
                        "com.apple.application-identifier":
                            f"TEAMDEV123.{subject.HARNESS_IDENTIFIER}",
                    },
                    expected_cdhash="a" * 40,
                    expected_requirement_sha256="d" * 64,
                    expected_pid=222,
                    expected_parent_pid=111,
                )

            duplicate = raw.replace(
                b'{"bundle_identifier":',
                b'{"\\u0062undle_identifier":"duplicate","bundle_identifier":',
                1,
            )
            with self.assertRaisesRegex(subject.H0Error, "duplicate key: bundle_identifier"):
                subject.validate_tool_output(
                    duplicate,
                    command="self-check",
                    role="harness",
                    expected_path=executable,
                    expected_identifier=subject.HARNESS_IDENTIFIER,
                    expected_team="TEAMDEV123",
                    expected_entitlements={
                        "com.apple.application-identifier":
                            f"TEAMDEV123.{subject.HARNESS_IDENTIFIER}",
                    },
                    expected_cdhash="a" * 40,
                    expected_requirement_sha256="d" * 64,
                    expected_pid=222,
                    expected_parent_pid=111,
                )

            signing_mutations = {
                "signing_team_identifier": "WRONGTEAM0",
                "signing_entitlements": {},
                "hardened_runtime": False,
                "self_identity_requirement_satisfied": False,
            }
            for field, invalid in signing_mutations.items():
                with self.subTest(signing_field=field):
                    changed = dict(payload)
                    changed[field] = invalid
                    with self.assertRaises(subject.H0Error):
                        subject.validate_tool_output(
                            subject.canonical_json_line(changed),
                            command="self-check",
                            role="harness",
                            expected_path=executable,
                            expected_identifier=subject.HARNESS_IDENTIFIER,
                            expected_team="TEAMDEV123",
                            expected_entitlements={
                                "com.apple.application-identifier":
                                    f"TEAMDEV123.{subject.HARNESS_IDENTIFIER}",
                            },
                            expected_cdhash="a" * 40,
                            expected_requirement_sha256="d" * 64,
                            expected_pid=222,
                            expected_parent_pid=111,
                        )

    def test_bounded_runner_times_out_and_kills_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            pid_path = root / "child.pid"
            script = root / "timeout.py"
            make_executable(
                script,
                textwrap.dedent(
                    f"""\
                    #!{sys.executable}
                    import pathlib
                    import signal
                    import subprocess
                    import sys
                    import time

                    child = subprocess.Popen([
                        sys.executable,
                        "-c",
                        "import signal,time; signal.signal(signal.SIGTERM, lambda *_: None); time.sleep(30)",
                    ])
                    pathlib.Path({str(pid_path)!r}).write_text(str(child.pid), encoding="ascii")
                    signal.signal(signal.SIGTERM, lambda *_: None)
                    time.sleep(30)
                    """
                ),
            )
            result = subject.run_bounded([str(script)], timeout=0.3)
            self.assertTrue(result.timed_out)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(result.process_group_cleanup, {"already_empty", "terminated", "killed"})
            child_pid = int(pid_path.read_text(encoding="ascii"))
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.fail("bounded runner left a descendant alive")

    def test_bounded_runner_rejects_oversized_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            script = pathlib.Path(temporary) / "output.py"
            make_executable(
                script,
                f"#!{sys.executable}\nimport sys\nsys.stdout.write('x' * 2048)\n",
            )
            with self.assertRaisesRegex(subject.H0Error, "stdout exceeded"):
                subject.run_bounded([str(script)], timeout=2, maximum_output_bytes=1024)

    def make_readiness_tool(
        self,
        path: pathlib.Path,
        *,
        role: str,
        cdhash: str,
    ) -> None:
        make_executable(
            path,
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import json
                import os
                import pathlib
                import signal
                import sys

                if os.environ.get({subject.START_SUSPENDED_ENVIRONMENT_KEY!r}) == "1":
                    os.kill(os.getpid(), signal.SIGSTOP)
                command = sys.argv[1]
                value = {{
                    "schema_version": 1,
                    "command": command,
                    "role": {role!r},
                    "process_id": os.getpid(),
                    "parent_process_id": os.getppid(),
                    "effective_user_id": os.geteuid(),
                    "executable_path": str(pathlib.Path(__file__).resolve()),
                    "bundle_identifier": {subject.EXPECTED_IDENTIFIERS[role]!r},
                    "signing_team_identifier": "TEAMDEV123",
                    "signing_entitlements": {{
                        "com.apple.application-identifier":
                            "TEAMDEV123.{subject.EXPECTED_IDENTIFIERS[role]}",
                    }},
                    "code_directory_hash": {cdhash!r},
                    "hardened_runtime": True,
                    "self_identity_requirement_satisfied": True,
                    "daemon_client_requirement_sha256": "d" * 64,
                    "daemon_client_requirement_satisfied": False,
                    "team_only_admission_probe_satisfied": True,
                    "recorder_context_present": {subject.RECORDER_CONTEXT_ENVIRONMENT_KEY!r} in os.environ,
                    "supported_commands": ["describe", "self-check"],
                    "production_mutation_exercised": False,
                    "qualification_status": "not_run",
                    "rows_updated": 0,
                    "formal_predicates_updated": 0,
                    "completion_claims": {{
                        "e2": False,
                        "p10": False,
                        "g10": False,
                        "g12": False,
                        "release": False,
                    }},
                }}
                sys.stdout.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\\n")
                """
            ),
        )

    def test_temp_tools_leave_template_immutable_and_cannot_advance_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            template = root / "qualification-template.json"
            template.write_text('{"qualification_status":"not_run"}\n', encoding="utf-8")
            harness = root / "harness"
            adversary = root / "adversary"
            live_cdhash = subject.live_process_cdhash(os.getpid())
            self.make_readiness_tool(harness, role="harness", cdhash=live_cdhash)
            self.make_readiness_tool(adversary, role="adversary", cdhash=live_cdhash)
            before = subject.snapshot_regular_file(
                template,
                label="template",
                maximum_bytes=subject.MAXIMUM_TEMPLATE_BYTES,
            )
            signatures = {
                "harness": {
                    "code_directory_hash": live_cdhash,
                    "team_identifier": "TEAMDEV123",
                    "entitlements": {
                        "com.apple.application-identifier":
                            f"TEAMDEV123.{subject.HARNESS_IDENTIFIER}",
                    },
                    "sha256": subject.snapshot_regular_file(
                        harness,
                        label="harness",
                        maximum_bytes=subject.MAXIMUM_EXECUTABLE_BYTES,
                    ).sha256,
                },
                "adversary": {
                    "code_directory_hash": live_cdhash,
                    "team_identifier": "TEAMDEV123",
                    "entitlements": {
                        "com.apple.application-identifier":
                            f"TEAMDEV123.{subject.ADVERSARY_IDENTIFIER}",
                    },
                    "sha256": subject.snapshot_regular_file(
                        adversary,
                        label="adversary",
                        maximum_bytes=subject.MAXIMUM_EXECUTABLE_BYTES,
                    ).sha256,
                },
            }
            results = subject.execute_controls(
                {"harness": harness.resolve(), "adversary": adversary.resolve()},
                signatures,
                daemon_requirement_sha256="d" * 64,
                template_sha256=before.sha256,
                run_id="test-run",
                timeout=2,
            )
            after = subject.snapshot_regular_file(
                template,
                label="template",
                maximum_bytes=subject.MAXIMUM_TEMPLATE_BYTES,
            )
            self.assertEqual(before, after)
            self.assertEqual(len(results), 4)
            for result in results:
                payload = result["result"]
                self.assertFalse(payload["production_mutation_exercised"])
                self.assertEqual(payload["qualification_status"], "not_run")
                self.assertEqual(payload["rows_updated"], 0)
                self.assertEqual(payload["formal_predicates_updated"], 0)
                self.assertTrue(all(value is False for value in payload["completion_claims"].values()))

    def test_live_process_binding_rejects_atomic_executable_swap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            harness = root / "harness"
            replacement = root / "replacement"
            self.make_readiness_tool(harness, role="harness", cdhash="a" * 40)
            self.make_readiness_tool(replacement, role="harness", cdhash="b" * 40)
            harness_snapshot = subject.snapshot_regular_file(
                harness,
                label="harness",
                maximum_bytes=subject.MAXIMUM_EXECUTABLE_BYTES,
            )
            replacement_snapshot = subject.snapshot_regular_file(
                replacement,
                label="replacement",
                maximum_bytes=subject.MAXIMUM_EXECUTABLE_BYTES,
            )
            self.assertNotEqual(harness_snapshot.sha256, replacement_snapshot.sha256)
            signature = {
                "sha256": harness_snapshot.sha256,
                "code_directory_hash": "a" * 40,
                "team_identifier": "TEAMDEV123",
                "entitlements": {
                    "com.apple.application-identifier":
                        f"TEAMDEV123.{subject.HARNESS_IDENTIFIER}",
                },
                "daemon_requirement_sha256": "d" * 64,
            }
            original_runner = subject.run_bounded
            swapped = False
            launched_pid = None

            def swap_then_run(arguments, **kwargs):
                nonlocal swapped
                if not swapped:
                    os.replace(replacement, harness)
                    swapped = True
                return original_runner(arguments, **kwargs)

            def swapped_live_hash(process_id):
                nonlocal launched_pid
                launched_pid = process_id
                return ("b" if swapped else "a") * 40

            with mock.patch.object(subject, "run_bounded", side_effect=swap_then_run), mock.patch.object(
                subject,
                "live_process_cdhash",
                side_effect=swapped_live_hash,
            ):
                with self.assertRaisesRegex(subject.H0Error, "live process CDHash differs"):
                    subject.run_tool_command(
                        harness,
                        role="harness",
                        command="describe",
                        signature=signature,
                        template_sha256="c" * 64,
                        run_id="atomic-swap-test",
                        timeout=2,
                    )
            self.assertTrue(swapped)
            self.assertIsNotNone(launched_pid)
            with self.assertRaises(ProcessLookupError):
                os.kill(launched_pid, 0)

    def test_local_apfs_atomic_swap_and_restore_changes_snapshot_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            original = root / "original"
            replacement = root / "replacement"
            make_executable(original, "#!/bin/sh\nexit 0\n")
            make_executable(replacement, "#!/bin/sh\nexit 1\n")
            filesystem = subject.qualified_signing_filesystem(original)
            self.assertEqual(filesystem["type"], "apfs")
            self.assertTrue(filesystem["local"])
            before = subject.snapshot_regular_file(
                original,
                label="ABA original",
                maximum_bytes=subject.MAXIMUM_EXECUTABLE_BYTES,
                executable=True,
            )
            time.sleep(0.01)
            libc = ctypes.CDLL(None, use_errno=True)
            renamex_np = libc.renamex_np
            renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
            renamex_np.restype = ctypes.c_int
            rename_swap = 0x00000002
            original_bytes = os.fsencode(original)
            replacement_bytes = os.fsencode(replacement)
            first = renamex_np(original_bytes, replacement_bytes, rename_swap)
            self.assertEqual(first, 0, f"first RENAME_SWAP failed with errno {ctypes.get_errno()}")
            second = renamex_np(original_bytes, replacement_bytes, rename_swap)
            self.assertEqual(second, 0, f"second RENAME_SWAP failed with errno {ctypes.get_errno()}")
            after = subject.snapshot_regular_file(
                original,
                label="ABA original",
                maximum_bytes=subject.MAXIMUM_EXECUTABLE_BYTES,
                executable=True,
            )
            self.assertEqual((before.device, before.inode, before.sha256),
                             (after.device, after.inode, after.sha256))
            self.assertNotEqual(before.change_time_ns, after.change_time_ns)
            with self.assertRaisesRegex(subject.H0Error, "changed during H0 execution"):
                subject.require_unchanged(before, after, "ABA executable")

    def test_post_launch_snapshot_rejects_same_bytes_atomic_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            harness = root / "harness"
            replacement = root / "replacement"
            live_cdhash = subject.live_process_cdhash(os.getpid())
            self.make_readiness_tool(harness, role="harness", cdhash=live_cdhash)
            replacement.write_bytes(harness.read_bytes())
            replacement.chmod(0o700)
            signature = {
                "sha256": subject.snapshot_regular_file(
                    harness,
                    label="harness",
                    maximum_bytes=subject.MAXIMUM_EXECUTABLE_BYTES,
                ).sha256,
                "code_directory_hash": live_cdhash,
                "team_identifier": "TEAMDEV123",
                "entitlements": {
                    "com.apple.application-identifier":
                        f"TEAMDEV123.{subject.HARNESS_IDENTIFIER}",
                },
                "daemon_requirement_sha256": "d" * 64,
            }
            original_runner = subject.run_bounded

            def replace_after_run(arguments, **kwargs):
                result = original_runner(arguments, **kwargs)
                os.replace(replacement, harness)
                return result

            with mock.patch.object(subject, "run_bounded", side_effect=replace_after_run):
                with self.assertRaisesRegex(subject.H0Error, "launch binding changed"):
                    subject.run_tool_command(
                        harness,
                        role="harness",
                        command="describe",
                        signature=signature,
                        template_sha256="c" * 64,
                        run_id="post-launch-replacement-test",
                        timeout=2,
                    )

    def test_output_is_atomic_private_and_cannot_replace_canonical_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            protected = root / "protected.json"
            protected.write_text("protected\n", encoding="utf-8")
            output = root / "report.json"
            validated = subject.validate_output_path(output, protected_paths=[protected])
            report = subject.initial_report(argparse.Namespace(execute=False))
            subject.emit_report(report, validated)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), report)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(protected.read_text(encoding="utf-8"), "protected\n")

            with self.assertRaisesRegex(subject.H0Error, "protected input"):
                subject.validate_output_path(protected, protected_paths=[protected])
            relative = pathlib.Path("report.json")
            with self.assertRaisesRegex(subject.H0Error, "absolute"):
                subject.validate_output_path(relative, protected_paths=[])
            symlink = root / "symlink-report.json"
            symlink.symlink_to(output)
            with self.assertRaisesRegex(subject.H0Error, "symlink"):
                subject.validate_output_path(symlink, protected_paths=[])

    def test_execute_requires_exact_recorder_owned_nonsemantic_context(self) -> None:
        repository = {
            "path": str(subject.REPOSITORY_ROOT),
            "branch": "security/e2-harness-controls",
            "head": "a" * 40,
            "base_branch": "main",
            "base_sha": "b" * 40,
        }
        manifest = {
            "schema_version": 1,
            "sha256": "c" * 64,
            "file_count": 2,
            "bytes": 3,
        }
        environment = {
            "FORGE_EVIDENCE_ARCHITECTURE": "arm64",
            "FORGE_EVIDENCE_BASE_BRANCH": repository["base_branch"],
            "FORGE_EVIDENCE_BASE_SHA": repository["base_sha"],
            "FORGE_EVIDENCE_BINDING_SCHEMA_VERSION": "1",
            "FORGE_EVIDENCE_CONTEXT_SCHEMA_VERSION": "1",
            "FORGE_EVIDENCE_ID": "EVID-h0-test",
            "FORGE_EVIDENCE_MACOS_BUILD": "25A1",
            "FORGE_EVIDENCE_MACHINE_IDENTIFIER": "MacTest1,1",
            "FORGE_EVIDENCE_PLATFORM": "macOS-test",
            "FORGE_EVIDENCE_REPOSITORY_BRANCH": repository["branch"],
            "FORGE_EVIDENCE_REPOSITORY_HEAD_SHA": repository["head"],
            "FORGE_EVIDENCE_REPOSITORY_PATH": str(subject.REPOSITORY_ROOT),
            "FORGE_EVIDENCE_SOURCE_MANIFEST_JSON": json.dumps(
                manifest,
                sort_keys=True,
                separators=(",", ":"),
            ),
        }
        with mock.patch.object(subject, "evidence_source_manifest", return_value=manifest), mock.patch.object(
            subject.platform,
            "machine",
            return_value="arm64",
        ):
            context = subject.validate_recorder_evidence_context(
                environment,
                required=True,
                repository=repository,
            )
            self.assertEqual(context["evidence_id"], "EVID-h0-test")
            self.assertEqual(context["source_manifest"], manifest)
            self.assertFalse(context["qualification_context_present"])

            with self.assertRaisesRegex(subject.H0Error, "requires recorder-owned"):
                subject.validate_recorder_evidence_context(
                    {},
                    required=True,
                    repository=repository,
                )
            partial = dict(environment)
            partial.pop("FORGE_EVIDENCE_BASE_SHA")
            with self.assertRaisesRegex(subject.H0Error, "incomplete"):
                subject.validate_recorder_evidence_context(
                    partial,
                    required=True,
                    repository=repository,
                )
            semantic = dict(environment)
            semantic["FORGE_EVIDENCE_QUALIFICATION"] = "forbidden"
            with self.assertRaisesRegex(subject.H0Error, "must not receive semantic"):
                subject.validate_recorder_evidence_context(
                    semantic,
                    required=True,
                    repository=repository,
                )
            wrong_head = dict(environment)
            wrong_head["FORGE_EVIDENCE_REPOSITORY_HEAD_SHA"] = "d" * 40
            with self.assertRaisesRegex(subject.H0Error, "HEAD differs"):
                subject.validate_recorder_evidence_context(
                    wrong_head,
                    required=True,
                    repository=repository,
                )

    def test_readiness_schema_rejects_unknown_fields_and_completion_claims(self) -> None:
        report = subject.initial_report(argparse.Namespace(execute=False))
        subject.validate_readiness_report_schema(report)

        unknown = dict(report)
        unknown["unexpected"] = False
        with self.assertRaisesRegex(subject.H0Error, "Additional properties"):
            subject.validate_readiness_report_schema(unknown)

        advanced = json.loads(json.dumps(report))
        advanced["completion_claims"]["e2"] = True
        with self.assertRaisesRegex(subject.H0Error, "completion_claims"):
            subject.validate_readiness_report_schema(advanced)

        unsupported_ready = subject.initial_report(argparse.Namespace(execute=False))
        unsupported_ready["overall_status"] = "ready"
        with self.assertRaisesRegex(subject.H0Error, "required propert"):
            subject.validate_readiness_report_schema(unsupported_ready)

    def test_ready_schema_and_semantics_bind_exact_execute_inventory(self) -> None:
        preflight = self.ready_report(execute=False)
        subject.validate_readiness_report_schema(preflight)
        execute = self.ready_report(execute=True)
        subject.validate_readiness_report_schema(execute)

        tmp_alias = json.loads(json.dumps(execute))
        self.assertEqual(
            pathlib.Path("/tmp/harness").resolve(strict=False),
            pathlib.Path("/private/tmp/harness").resolve(strict=False),
        )
        tmp_alias["signatures"]["harness"]["path"] = "/private/tmp/harness"
        for command_result in tmp_alias["commands"][:2]:
            command_result["result"]["executable_path"] = "/tmp/harness"
            command_result["stdout_sha256"] = subject.sha256_bytes(
                subject.canonical_json_line(command_result["result"])
            )
        subject.validate_readiness_report_schema(tmp_alias)

        mutations = []
        reordered = json.loads(json.dumps(execute))
        reordered["commands"][0], reordered["commands"][1] = (
            reordered["commands"][1], reordered["commands"][0]
        )
        mutations.append(reordered)
        spliced_hash = json.loads(json.dumps(execute))
        spliced_hash["commands"][0]["live_process_identity"]["code_directory_hash"] = "2" * 40
        mutations.append(spliced_hash)
        spliced_repository = json.loads(json.dumps(execute))
        spliced_repository["recorder_evidence_context"]["repository"]["head_sha"] = "f" * 40
        mutations.append(spliced_repository)
        spliced_stdout = json.loads(json.dumps(execute))
        spliced_stdout["commands"][0]["stdout_sha256"] = "f" * 64
        mutations.append(spliced_stdout)
        for mutation in mutations:
            with self.subTest(index=mutations.index(mutation)):
                with self.assertRaises(subject.H0Error):
                    subject.validate_readiness_report_schema(mutation)

    def test_outer_report_never_advances_qualification_or_completion(self) -> None:
        for execute in (False, True):
            args = argparse.Namespace(execute=execute)
            report = subject.initial_report(args)
            self.assertEqual(report["overall_status"], "blocked")
            self.assertFalse(report["production_mutation_exercised"])
            self.assertEqual(report["qualification_status"], "not_run")
            self.assertEqual(report["rows_updated"], 0)
            self.assertEqual(report["formal_predicates_updated"], 0)
            self.assertEqual(report["matrix"], {"required_rows": None, "executed_rows": 0})
            self.assertEqual(
                report["formal_closure"],
                {"required_predicates": None, "proven_predicates": 0},
            )
            self.assertFalse(report["context_bound"])
            self.assertFalse(report["recorder_context_bound"])
            self.assertIsNone(report["recorder_evidence_context"])
            self.assertTrue(all(value is False for value in report["completion_claims"].values()))


if __name__ == "__main__":
    unittest.main()
