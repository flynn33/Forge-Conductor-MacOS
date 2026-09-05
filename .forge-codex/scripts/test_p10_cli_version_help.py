#!/usr/bin/env python3
"""Supporting CLI fixtures exercise the adapter and never qualify the product."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import p10_cli_version_help as cli
import qualify_p10_features as qualifier


REPO = pathlib.Path(__file__).resolve().parents[2]
HELP = "Forge-Conductor 0.9.0 — native Swift MCP orchestrator\n\nUsage:\n  forge-conductor <command> [options]\n\nCommands:\n" + "".join(f"  {command}  description\n" for command in cli.COMMANDS)


class CLIHelpSupportingTests(unittest.TestCase):
    def fixture_app(self, root: pathlib.Path) -> pathlib.Path:
        source = root / cli.SOURCE_VERSION_PATH
        source.parent.mkdir(parents=True)
        source.write_text('public static let productVersion = "0.9.0"\n')
        app = root / "Forge Conductor.app"
        for definition in cli.EXPECTED_SIGNING_ARTIFACTS.values():
            artifact = app / definition["relative_path"]
            artifact.parent.mkdir(parents=True, exist_ok=True)
            artifact.write_bytes(b"\xcf\xfa\xed\xfe fixture bytes")
            artifact.chmod(0o755)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString":"0.9.0", "CFBundleVersion":"1"}))
        return app

    def simulated_command(self, argv, cwd, stdout_path, stderr_path, timeout, stream_limit, environment, *, process_metadata):
        self.assertEqual(timeout, cli.MAXIMUM_CASE_SECONDS)
        self.assertEqual(stream_limit, cli.MAXIMUM_STREAM_BYTES)
        self.assertEqual(environment["HOME"], str(cwd))
        self.assertNotIn("DYLD_INSERT_LIBRARIES", environment)
        process_metadata["pid"] = 4321
        arguments = argv[1:]
        unknown = arguments == [cli.UNKNOWN_COMMAND]
        stdout_path.write_text("0.9.0\n" if arguments in (["version"], ["--version"]) else HELP)
        stderr_path.write_text(f"Unknown command: {cli.UNKNOWN_COMMAND}\n\n" if unknown else "")
        return 2 if unknown else 0, False, False

    def capture_fixture(self, root, app, command=None):
        with mock.patch.object(cli, "execute_command", side_effect=command or self.simulated_command):
            summary = cli.capture(root, app, evidence_id="EVID-help-fixture", challenge_nonce="a" * 64)
        return summary, json.loads((root / cli.OBSERVATION_PATH).read_bytes())

    def test_all_seven_cases_use_original_embedded_path_without_gui_or_installation_claim(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            app = self.fixture_app(root)
            with mock.patch.dict(os.environ, {"DYLD_INSERT_LIBRARIES":"must-not-inherit"}):
                summary, document = self.capture_fixture(root, app)
            self.assertTrue(summary["passed"], document["failures"])
            self.assertEqual(summary["executed_case_count"], 7)
            self.assertEqual(summary["accepted_p10_assertions"], [])
            self.assertEqual(document["bundle_before"], document["bundle_after"])
            self.assertEqual({row["argv"][0] for row in document["cases"]}, {str(app / "Contents/Helpers/forge-conductor")})
            self.assertEqual({row["pid"] for row in document["cases"]}, {4321})
            for field in ("installation_assessed", "signing_assessed", "build_provenance_assessed", "configuration_assessed"):
                self.assertIs(document[field], False)
            self.assertFalse(pathlib.Path(document["cases"][0]["cwd"]).exists())
            self.assertEqual(summary["sha256"], hashlib.sha256((root / cli.OBSERVATION_PATH).read_bytes()).hexdigest())

    def test_mutated_transcripts_fail_semantic_revalidation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            app = self.fixture_app(root)
            _, document = self.capture_fixture(root, app)
            cases = document["cases"]
            mutations = {
                "zero": lambda rows: rows.clear(),
                "missing": lambda rows: rows.pop(),
                "duplicate": lambda rows: rows.__setitem__(1, copy.deepcopy(rows[0])),
                "malformed": lambda rows: rows.__setitem__(0, None),
                "wrong-command": lambda rows: rows[0]["argv"].append("install"),
                "wrong-version": lambda rows: rows[4].__setitem__("stdout", cli.stream_binding(b"0.8.0\n")),
                "help-omits-command": lambda rows: rows[0].__setitem__("stdout", cli.stream_binding(HELP.replace("  manager  description\n", "").encode())),
                "alias-differs": lambda rows: rows[1].__setitem__("stdout", cli.stream_binding((HELP + "extra\n").encode())),
                "unknown-exit": lambda rows: rows[6].__setitem__("exit_code", 0),
                "unknown-stderr": lambda rows: rows[6].__setitem__("stderr", cli.stream_binding(b"")),
                "timeout": lambda rows: rows[0].__setitem__("timed_out", True),
                "truncation": lambda rows: rows[0].__setitem__("stream_limit_exceeded", True),
                "digest": lambda rows: rows[0]["stdout"].__setitem__("sha256", "0" * 64),
                "non-utf8": lambda rows: rows[0].__setitem__("stdout", cli.stream_binding(b"\xff")),
                "pid": lambda rows: rows[0].__setitem__("pid", True),
                "environment": lambda rows: rows[0]["environment"].__setitem__("DYLD_INSERT_LIBRARIES", "/fixture"),
                "duration": lambda rows: rows[0].__setitem__("ended_at", "2100-01-01T00:00:00+00:00"),
                "extra-success": lambda rows: rows[0].__setitem__("passed", True),
            }
            for label, mutation in mutations.items():
                with self.subTest(label=label):
                    altered = copy.deepcopy(cases)
                    mutation(altered)
                    self.assertTrue(cli.validate_cases(altered, executable=str(app / "Contents/Helpers/forge-conductor"), version="0.9.0"))

    def test_non_native_missing_artifacts_and_symlink_escape_fail_before_execution(self):
        for kind in ("script", "missing", "symlink", "version"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                app = self.fixture_app(root)
                executable = app / "Contents/Helpers/forge-conductor"
                if kind == "script":
                    executable.write_text("#!/bin/sh\nexit 0\n")
                elif kind == "missing":
                    executable.unlink()
                elif kind == "symlink":
                    (app / "Contents/escape").symlink_to(root)
                else:
                    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString":"0.8.0"}))
                with mock.patch.object(cli, "execute_command") as execute:
                    summary = cli.capture(root, app, evidence_id="EVID-help-fixture", challenge_nonce="a" * 64)
                execute.assert_not_called()
                self.assertFalse(summary["passed"])
                self.assertEqual(summary["executed_case_count"], 0)
                self.assertTrue(summary["failures"])

    def test_internal_framework_links_are_bound_and_library_mutation_rejects_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            app = self.fixture_app(root)
            library = app / "Contents/Frameworks/Fixture.framework/Versions/A/Fixture"
            library.parent.mkdir(parents=True)
            library.write_bytes(b"library")
            library.parent.with_name("Current").symlink_to("A")
            library.parents[2].joinpath("Fixture").symlink_to("Versions/Current/Fixture")
            self.assertTrue(any(row["kind"] == "symlink" for row in cli.bundle_manifest(app)))
            def mutating_command(*args, **kwargs):
                result = self.simulated_command(*args, **kwargs)
                library.write_bytes(b"changed library")
                return result
            summary, document = self.capture_fixture(root, app, mutating_command)
            self.assertFalse(summary["passed"])
            self.assertIn("CLI bundle changed during execution", document["failures"])

    def test_failure_retains_raw_output_and_cleans_isolated_home(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            app = self.fixture_app(root)
            def timeout(*args, **kwargs):
                self.simulated_command(*args, **kwargs)
                return 124, True, False
            summary, document = self.capture_fixture(root, app, timeout)
            self.assertFalse(summary["passed"])
            self.assertEqual(len(document["cases"]), 1)
            self.assertTrue(document["cases"][0]["stdout"]["bytes"])
            self.assertTrue(document["cleanup"]["temporary_home_removed"])

    def test_home_write_fails_readonly_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            app = self.fixture_app(root)
            def writes_home(argv, cwd, *args, **kwargs):
                (cwd / "unexpected").write_text("fixture")
                return self.simulated_command(argv, cwd, *args, **kwargs)
            summary, document = self.capture_fixture(root, app, writes_home)
            self.assertFalse(summary["passed"])
            self.assertFalse(document["isolated_home_unchanged"])

    @unittest.skipUnless(sys.platform == "darwin" and pathlib.Path("/usr/bin/clang").exists(), "native fixture requires macOS compiler")
    def test_real_child_process_capture_is_supporting_fixture_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            app = self.fixture_app(root)
            source = root / "fixture.c"
            source.write_text('#include <stdio.h>\n#include <string.h>\nint main(int argc, char **argv) {\n' +
                'if (argc == 2 && (!strcmp(argv[1], "version") || !strcmp(argv[1], "--version"))) { puts("0.9.0"); return 0; }\n' +
                f'fputs({json.dumps(HELP, ensure_ascii=False)}, stdout);\n' +
                f'if (argc == 2 && !strcmp(argv[1], "{cli.UNKNOWN_COMMAND}")) {{ fputs("Unknown command: {cli.UNKNOWN_COMMAND}\\n\\n", stderr); return 2; }}\nreturn 0; }}\n')
            executable = app / "Contents/Helpers/forge-conductor"
            subprocess.run(["/usr/bin/clang", str(source), "-o", str(executable)], check=True, capture_output=True, timeout=30)
            summary = cli.capture(root, app, evidence_id="EVID-native-fixture", challenge_nonce="b" * 64)
            document = json.loads((root / cli.OBSERVATION_PATH).read_bytes())
            self.assertTrue(summary["passed"], document["failures"])
            self.assertEqual(summary["accepted_p10_assertions"], [])
            self.assertTrue(all(row["pid"] > 1 and row["pid"] != os.getpid() for row in document["cases"]))


class PartialMatrixTests(unittest.TestCase):
    def test_empty_matrix_retains_all_gaps_and_never_passes(self):
        registry = {"features":[{"id":"CLI-VERSION-HELP", "category":"cli", "required_assertions":["CLI-VERSION-HELP.production-path", "CLI-VERSION-HELP.signed-product.forge-conductor-cli"]}]}
        probes = {"limits": {"maximum_matrix_seconds":1500,"maximum_probe_stream_bytes":65536,"maximum_observation_bytes_per_scenario":262144,"maximum_total_raw_output_bytes":8388608,"maximum_unique_runners":64},"implemented_scenarios":[]}
        manifest = {"schema_version":1,"sha256":"a"*64,"file_count":1,"bytes":1}
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            control = {qualifier.FEATURE_REGISTRY_PATH:registry,qualifier.PROBE_REGISTRY_PATH:probes,qualifier.FEATURE_BASELINE_PATH:{}}
            def load(_, path, __):
                return control[path], json.dumps(control[path]).encode()
            with mock.patch.object(sys, "argv", ["qualifier", "--repo", str(root)]), mock.patch.dict(os.environ, {"FORGE_EVIDENCE_ID":"EVID-partial-fixture"}), mock.patch.object(qualifier,"load_json",side_effect=load), mock.patch.object(qualifier,"source_manifest",return_value=manifest), mock.patch.object(qualifier,"current_git_head",return_value="b"*40):
                self.assertEqual(qualifier.main(), 2)
            report = json.loads((root / qualifier.REPORT_PATH).read_bytes())
            self.assertEqual(report["execution"]["count"], 0)
            self.assertEqual(report["coverage"]["missing_assertion_count"], 2)
            self.assertEqual(report["results"][0]["status"], "not_run")
            self.assertFalse(report["environment"]["installed_product"])
            self.assertEqual(json.loads((root / qualifier.OBSERVATION_PATH).read_bytes())["scenarios"], [])
            from jsonschema import Draft202012Validator
            partial = json.loads((REPO / ".forge-codex/schemas/p10-feature-partial-qualification.schema.json").read_bytes())
            full = json.loads((REPO / ".forge-codex/schemas/p10-feature-production-qualification.schema.json").read_bytes())
            self.assertEqual(list(Draft202012Validator(partial).iter_errors(report)), [])
            self.assertTrue(list(Draft202012Validator(full).iter_errors(report)))

            # --cli-app produces real command transcripts, but does not fill the
            # canonical matrix or assert installed/signed product provenance.
            helper = CLIHelpSupportingTests()
            app = helper.fixture_app(root)
            with mock.patch.object(sys, "argv", ["qualifier", "--repo", str(root), "--cli-app", str(app)]), mock.patch.dict(os.environ, {"FORGE_EVIDENCE_ID":"EVID-partial-fixture"}), mock.patch.object(qualifier,"load_json",side_effect=load), mock.patch.object(qualifier,"source_manifest",return_value=manifest), mock.patch.object(qualifier,"current_git_head",return_value="b"*40), mock.patch.object(cli,"execute_command",side_effect=helper.simulated_command):
                self.assertEqual(qualifier.main(), 2)
            report = json.loads((root / qualifier.REPORT_PATH).read_bytes())
            self.assertTrue(report["supporting_cli"]["passed"])
            self.assertEqual(report["supporting_cli"]["executed_case_count"], 7)
            self.assertEqual(report["supporting_cli"]["accepted_p10_assertions"], [])
            self.assertEqual(report["coverage"]["missing_assertion_count"], 2)
            self.assertEqual(report["execution"]["assertion_count"], 0)
            self.assertFalse(report["environment"]["installed_product"])
            self.assertEqual(list(Draft202012Validator(partial).iter_errors(report)), [])
            self.assertTrue(list(Draft202012Validator(full).iter_errors(report)))


if __name__ == "__main__":
    unittest.main()
