#!/usr/bin/env python3
"""Failure-control tests; synthetic servers are never product evidence."""

from __future__ import annotations

import json
import os
import pathlib
import sys
import tempfile
import time
import unittest
from unittest import mock

import p10_mcp_memory as driver


class MemoryDriverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="forge-memory-driver-test-")
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def server(self, code: str) -> pathlib.Path:
        path = self.root / "fixture-server"
        path.write_text("#!" + sys.executable + "\n" + code, encoding="utf-8")
        path.chmod(0o700)
        return path

    def process(self, code: str, seconds: float = 3) -> driver.ObservedMCPProcess:
        return driver.ObservedMCPProcess(self.server(code), self.home, "control-test",
                                         time.monotonic() + seconds, {})

    def test_exact_raw_wire_and_isolated_environment(self) -> None:
        code = """import json,sys
for line in sys.stdin:
    request=json.loads(line)
    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{}}),flush=True)
"""
        with mock.patch.dict(os.environ, {"FORGE_OPERATOR_UI_TEST_PORT": "1", "SECRET_FIXTURE": "not-forwarded"}):
            process = self.process(code)
        try:
            self.assertEqual(process.call("ping", {}), {})
            process.stop()
        finally:
            if process.process.poll() is None:
                process.stop(failed=True)
        self.assertEqual(process.observation["exit_code"], 0)
        self.assertNotIn("SECRET_FIXTURE", process.environment)
        self.assertNotIn("FORGE_OPERATOR_UI_TEST_PORT", process.environment)
        self.assertEqual(process.environment["HOME"], str(self.home))
        self.assertEqual(process.observation["stdin"], driver.raw_artifact(bytes(process.raw_input)))
        self.assertEqual(json.loads(process.raw_output), process.responses[0])

    def test_stalled_response_has_deadline_and_reaped_process(self) -> None:
        process = self.process("import time\ntime.sleep(30)\n", seconds=0.15)
        started = time.monotonic()
        try:
            with self.assertRaisesRegex(driver.CompatibilityError, "deadline"):
                process.call("ping", {})
        finally:
            process.stop(failed=True)
        self.assertLess(time.monotonic() - started, 4)
        self.assertIsNotNone(process.process.poll())
        self.assertTrue(process.observation["timed_out"])

    def test_stderr_flood_is_bounded_and_cannot_pass(self) -> None:
        process = self.process("import os,time\nos.write(2,b'x'*8192)\ntime.sleep(30)\n")
        with mock.patch.object(driver, "MAXIMUM_STREAM_BYTES", 1024):
            try:
                with self.assertRaisesRegex(driver.CompatibilityError, "byte bound"):
                    process.call("ping", {})
            finally:
                process.stop(failed=True)
        self.assertEqual(len(process.raw_error), 1024)
        self.assertIsNotNone(process.process.poll())
        self.assertTrue(process.observation["stream_limit_exceeded"])

    def test_unterminated_stdout_is_bounded_and_cannot_pass(self) -> None:
        process = self.process("import os,time\nos.write(1,b'x'*8192)\ntime.sleep(30)\n")
        with mock.patch.object(driver, "MAXIMUM_STREAM_BYTES", 1024):
            try:
                with self.assertRaisesRegex(driver.CompatibilityError, "byte bound"):
                    process.call("ping", {})
            finally:
                process.stop(failed=True)
        self.assertEqual(len(process.raw_output), 1024)

    def test_success_envelope_cannot_satisfy_required_denial(self) -> None:
        code = """import json,sys
for line in sys.stdin:
    request=json.loads(line)
    payload={'ok':True}
    result={'isError':False,'structuredContent':payload,'content':[{'type':'text','text':json.dumps(payload)}]}
    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
"""
        process = self.process(code)
        try:
            with self.assertRaisesRegex(driver.CompatibilityError, "isError"):
                process.tool("project_memory.get", {}, error="project_scope_mismatch")
        finally:
            process.stop(failed=True)

    def test_wrong_response_correlation_fails(self) -> None:
        code = "import sys\nsys.stdin.readline()\nprint('{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}',flush=True)\n"
        process = self.process(code)
        try:
            with self.assertRaisesRegex(driver.CompatibilityError, "correlation"):
                process.call("ping", {})
        finally:
            process.stop(failed=True)

    def test_duplicate_and_false_counts_are_rejected(self) -> None:
        for result in ({"count": 2, "records": [{"id": "same"}, {"id": "same"}]},
                       {"count": 2, "records": [{"id": "only"}]},
                       {"count": 1, "records": [{"id": None}]}):
            with self.subTest(result=result), self.assertRaises(driver.CompatibilityError):
                driver.record_ids(result)

    def test_export_checksum_and_scope_are_verified_from_file(self) -> None:
        path = self.root / "export.json"
        records = [{"id": "record", "summary": "fixture"}]
        value = {"records": records, "checksum": driver.normalized_hash(records)}
        path.write_bytes(driver.output_bytes(value))
        self.assertEqual(driver.read_export(path, self.root)[1], value)
        value["records"][0]["summary"] = "changed"
        path.write_bytes(driver.output_bytes(value))
        with self.assertRaisesRegex(driver.CompatibilityError, "checksum"):
            driver.read_export(path, self.root)
        with self.assertRaisesRegex(driver.CompatibilityError, "escaped"):
            driver.read_export(path, self.home)

    def test_capture_failure_retains_error_and_removes_fixture_without_acceptance(self) -> None:
        binary = self.server("pass\n")
        roots = []

        def failed_exercise(_binary, root, report):
            roots.append(root)
            (root / "fixture-note").write_text("disposable")
            report["observations"].append({"postcondition": "prior observed outcome"})
            raise driver.CompatibilityError("deliberate control failure")

        with mock.patch.object(driver, "source_manifest", return_value={}), \
             mock.patch.object(driver, "git_source_state", return_value={}), \
             mock.patch.object(driver, "exercise", side_effect=failed_exercise):
            report = driver.capture(self.root, binary)
        self.assertEqual(report["status"], "failed")
        self.assertIn("deliberate control failure", report["failure"])
        self.assertTrue(report["fixture_removed"])
        self.assertFalse(roots[0].exists())
        self.assertEqual(report["accepted_p10_assertions"], [])
        self.assertFalse(report["build_provenance_assessed"])
        self.assertEqual(report["binary_origin"], "explicit_component_binary")

    def test_app_cannot_use_an_external_helper_symlink(self) -> None:
        binary = self.server("pass\n")
        app = self.root / "Fixture.app"
        helper = app / "Contents/Helpers/forge-conductor"
        helper.parent.mkdir(parents=True)
        helper.symlink_to(binary)
        with self.assertRaisesRegex(driver.CompatibilityError, "embedded helper"):
            driver.capture(self.root, helper, app=app)

    @unittest.skipUnless(os.environ.get("FORGE_TEST_MCP_MEMORY_BINARY"), "explicit local CLI required")
    def test_real_cli_semantics_and_process_restart(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[2]
        report = driver.capture(repository, pathlib.Path(os.environ["FORGE_TEST_MCP_MEMORY_BINARY"]))
        self.assertEqual(report["status"], "passed", report.get("failure"))
        self.assertEqual(set(report["successful_tool_members"]), driver.LEGACY_TOOLS | driver.PROJECT_TOOLS)
        self.assertEqual(len(report["processes"]), 5)
        self.assertTrue(all(process["exit_code"] == 0 for process in report["processes"]))
        self.assertEqual(report["accepted_p10_assertions"], [])
        self.assertTrue(report["fixture_removed"])


if __name__ == "__main__":
    unittest.main()
