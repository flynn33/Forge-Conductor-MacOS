#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest import mock

import statectl
import run_gate


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parent
GATE_RUNNER = SCRIPT_ROOT / "run_gate.py"
GATE_BATCH_RUNNER = SCRIPT_ROOT / "run_gates.sh"
EVIDENCE_SUPPORT = SCRIPT_ROOT / "evidence_support.py"
ACTIVE_GATE_HANDLERS = SCRIPT_ROOT.parent / "state/gate-handlers"
TEMPLATE_GATE_HANDLERS = SCRIPT_ROOT.parent / "templates/gate-handlers"
GATE_PLAN = json.loads(
    (SCRIPT_ROOT.parent / "plans/gates.json").read_text(encoding="utf-8")
)


class GateRunnerHardeningTests(unittest.TestCase):
    def write_json(self, path: pathlib.Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def initialize_git_fixture(self, root: pathlib.Path) -> None:
        for command in (
            ["git", "init", "-q"],
            ["git", "config", "user.name", "Fixture"],
            ["git", "config", "user.email", "fixture@example.invalid"],
            ["git", "add", "."],
            ["git", "commit", "-qm", "fixture"],
        ):
            completed = subprocess.run(
                command,
                cwd=root,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(
                completed.returncode,
                0,
                completed.stdout + completed.stderr,
            )

    def install_gate_fixture(
        self,
        root: pathlib.Path,
        *,
        gate: str = "GX",
        statectl_exit: int = 0,
        handler_body: str | None = None,
        initialize_git: bool = True,
    ) -> pathlib.Path:
        self.write_json(
            root / ".forge-codex/plans/gates.json",
            {"gates": [{"id": gate, "criteria": ["exact criterion"]}]},
        )
        scripts = root / ".forge-codex/scripts"
        scripts.mkdir(parents=True, exist_ok=True)
        statectl = scripts / "statectl.py"
        statectl.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            f"sys.stderr.write('state fixture exit {statectl_exit}\\n')\n"
            f"raise SystemExit({statectl_exit})\n",
            encoding="utf-8",
        )
        statectl.chmod(0o755)

        handler = root / f".forge-codex/state/gate-handlers/{gate}.sh"
        handler.parent.mkdir(parents=True, exist_ok=True)
        if handler_body is None:
            criteria = root / f".forge-codex/state/gate-results/{gate}.criteria.json"
            handler_body = (
                "#!/usr/bin/env python3\n"
                "import json, pathlib\n"
                f"path = pathlib.Path({str(criteria)!r})\n"
                "path.parent.mkdir(parents=True, exist_ok=True)\n"
                "path.write_text(json.dumps({'criteria_results': "
                "[{'criterion': 'exact criterion', 'passed': True, "
                "'evidence': 'fixture'}]}) + '\\n', encoding='utf-8')\n"
            )
        handler.write_text(handler_body, encoding="utf-8")
        handler.chmod(0o755)
        if initialize_git:
            self.initialize_git_fixture(root)
        return handler

    def install_real_statectl_fixture(self, root: pathlib.Path) -> None:
        self.install_gate_fixture(root)
        scripts = root / ".forge-codex/scripts"
        (scripts / "statectl.py").write_bytes(
            (SCRIPT_ROOT / "statectl.py").read_bytes()
        )
        (scripts / "statectl.py").chmod(0o755)
        (scripts / "evidence_support.py").write_bytes(EVIDENCE_SUPPORT.read_bytes())
        self.write_json(
            root / ".forge-codex/plans/phases.json",
            {"phases": []},
        )
        initialized = subprocess.run(
            [
                sys.executable,
                str(scripts / "statectl.py"),
                "--repo",
                str(root),
                "init",
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(
            initialized.returncode,
            0,
            initialized.stdout + initialized.stderr,
        )

    def install_active_handler_fixture(
        self,
        root: pathlib.Path,
        gate: str,
    ) -> pathlib.Path:
        gate_definition = next(item for item in GATE_PLAN["gates"] if item["id"] == gate)
        self.write_json(
            root / ".forge-codex/plans/gates.json",
            {"gates": [gate_definition]},
        )
        scripts = root / ".forge-codex/scripts"
        scripts.mkdir(parents=True, exist_ok=True)
        statectl_path = scripts / "statectl.py"
        statectl_path.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "if 'validate' in sys.argv:\n"
            "    print('valid')\n",
            encoding="utf-8",
        )
        statectl_path.chmod(0o755)
        handler = root / f".forge-codex/state/gate-handlers/{gate}.sh"
        handler.parent.mkdir(parents=True, exist_ok=True)
        handler.write_bytes((ACTIVE_GATE_HANDLERS / f"{gate}.sh").read_bytes())
        handler.chmod(0o755)
        self.initialize_git_fixture(root)
        return handler

    def install_statectl_swap_fixture(
        self,
        root: pathlib.Path,
        swap_mode: str,
    ) -> pathlib.Path:
        self.install_gate_fixture(root)
        scripts = root / ".forge-codex/scripts"
        (scripts / "run_gates.sh").write_bytes(GATE_BATCH_RUNNER.read_bytes())
        (scripts / "run_gates.sh").chmod(0o755)
        (scripts / "evidence_support.py").write_bytes(EVIDENCE_SUPPORT.read_bytes())
        self.write_json(
            root / ".forge-codex/plans/phases.json",
            {
                "phases": [
                    {
                        "id": "PX",
                        "priority": 1,
                        "dependencies": [],
                        "hard_gates": ["GX"],
                    }
                ]
            },
        )
        self.write_json(
            root / ".forge-codex/state/run-state.json",
            {
                "phases": {"PX": {"status": "passed"}},
                "gates": {
                    "GX": {
                        "status": "not_started",
                        "operation_id": None,
                    }
                },
            },
        )
        statectl_path = scripts / "statectl.py"
        statectl_path.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            f"root = pathlib.Path({str(root)!r})\n"
            f"swap_mode = {swap_mode!r}\n"
            "arguments = sys.argv[1:]\n"
            "if arguments[-1:] == ['show']:\n"
            "    print((root / '.forge-codex/state/run-state.json').read_text(encoding='utf-8'))\n"
            "    raise SystemExit(0)\n"
            "status = arguments[arguments.index('GX') + 1]\n"
            "operation_id = arguments[arguments.index('--operation-id') + 1]\n"
            "state_path = root / '.forge-codex/state/run-state.json'\n"
            "state = json.loads(state_path.read_text(encoding='utf-8'))\n"
            "state['gates']['GX'] = {'status': status, 'operation_id': operation_id}\n"
            "state_path.write_text(json.dumps(state) + '\\n', encoding='utf-8')\n"
            "if status == 'passed' and swap_mode == 'lock':\n"
            "    results = root / '.forge-codex/state/gate-results'\n"
            "    replacement = results / '.replacement.lock'\n"
            "    replacement.write_text('', encoding='utf-8')\n"
            "    replacement.chmod(0o600)\n"
            "    os.replace(replacement, results / '.GX.lock')\n"
            "elif status == 'passed' and swap_mode == 'directory':\n"
            "    state_directory = root / '.forge-codex/state'\n"
            "    results = state_directory / 'gate-results'\n"
            "    results.rename(state_directory / 'moved-gate-results')\n"
            "    results.mkdir(mode=0o700)\n",
            encoding="utf-8",
        )
        statectl_path.chmod(0o755)
        return root / "batch-runner-invoked"

    def run_gate(
        self,
        root: pathlib.Path,
        gate: str = "GX",
        *extra: str,
        timeout: float = 10,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(GATE_RUNNER),
                "--repo",
                str(root),
                *extra,
                "--",
                gate,
            ],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )

    def wait_for_line(self, path: pathlib.Path, prefix: str) -> None:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                if any(
                    line.startswith(prefix)
                    for line in path.read_text(encoding="utf-8").splitlines()
                ):
                    return
            except FileNotFoundError:
                pass
            time.sleep(0.01)
        self.fail(f"timed out waiting for {prefix!r} in {path}")

    def test_passing_handler_fails_closed_when_state_control_rejects_update(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.install_gate_fixture(root, statectl_exit=9)

            result = self.run_gate(root)

            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["commands"][0]["exit_code"], 0)
            self.assertTrue(payload["evaluator"]["criteria_results"][0]["passed"])
            self.assertEqual(payload["status"], "failed")
            self.assertIn("State control failed closed", payload["notes"])
            self.assertIn("exited 9", payload["notes"])
            persisted = json.loads(
                (root / ".forge-codex/state/gate-results/GX.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(persisted, payload)

    def test_gate_result_serialization_accepts_exact_bound_and_rejects_plus_one(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary).resolve()
            descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                empty = {"padding": ""}
                empty_size = len(
                    (json.dumps(empty, indent=2, sort_keys=True) + "\n").encode(
                        "utf-8"
                    )
                )
                payload = {
                    "padding": "x"
                    * (run_gate.MAXIMUM_GATE_RESULT_JSON_BYTES - empty_size)
                }
                encoded = (
                    json.dumps(payload, indent=2, sort_keys=True) + "\n"
                ).encode("utf-8")
                self.assertEqual(
                    len(encoded),
                    run_gate.MAXIMUM_GATE_RESULT_JSON_BYTES,
                )

                run_gate.atomic_write_json_at(
                    descriptor,
                    "result.json",
                    payload,
                    label="test gate result",
                )
                self.assertEqual(
                    (directory / "result.json").stat().st_size,
                    run_gate.MAXIMUM_GATE_RESULT_JSON_BYTES,
                )
                payload["padding"] += "x"
                with self.assertRaisesRegex(
                    run_gate.EvidenceSupportError,
                    "serialization bound",
                ):
                    run_gate.atomic_write_json_at(
                        descriptor,
                        "result.json",
                        payload,
                        label="test gate result",
                    )
            finally:
                os.close(descriptor)

    def test_retained_snapshot_writer_is_detected_after_execution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            handler_path = self.install_gate_fixture(root)
            retained: list[int] = []
            original_unlink = os.unlink

            def retain_before_unlink(path, *arguments, **keywords):
                if str(path).endswith(".snapshot") and not retained:
                    os.chmod(
                        path,
                        0o700,
                        dir_fd=keywords.get("dir_fd"),
                    )
                    retained.append(
                        os.open(
                            path,
                            os.O_RDWR,
                            dir_fd=keywords.get("dir_fd"),
                        )
                    )
                return original_unlink(path, *arguments, **keywords)

            try:
                with run_gate.open_gate_result_directory(root) as result_directory:
                    with run_gate.open_gate_handler(
                        result_directory,
                        "GX",
                        handler_path,
                    ) as handler:
                        self.assertIsNotNone(handler)
                    assert handler is not None
                    with mock.patch.object(
                        run_gate.os,
                        "unlink",
                        side_effect=retain_before_unlink,
                    ):
                        with self.assertRaisesRegex(
                            run_gate.EvidenceSupportError,
                            "snapshot changed during execution",
                        ):
                            with run_gate.open_unlinked_handler_snapshot(
                                result_directory,
                                handler,
                            ):
                                os.pwrite(retained[0], b"X", 0)
                                os.fsync(retained[0])
            finally:
                for descriptor in retained:
                    os.close(descriptor)

    def test_result_is_durable_before_state_control_and_operation_id_matches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.install_gate_fixture(root)
            marker = root / "state-control-observation.json"
            statectl_path = root / ".forge-codex/scripts/statectl.py"
            statectl_path.write_text(
                "#!/usr/bin/env python3\n"
                "import json, pathlib, sys\n"
                "arguments = sys.argv[1:]\n"
                "operation_id = arguments[arguments.index('--operation-id') + 1]\n"
                "evaluator = pathlib.Path(arguments[arguments.index('--evaluator') + 1])\n"
                "payload = json.loads(evaluator.read_text(encoding='utf-8'))\n"
                "if payload.get('status') != 'passed':\n"
                "    raise SystemExit('result was not passed before state control')\n"
                "if payload.get('operation_id') != operation_id:\n"
                "    raise SystemExit('operation identifiers differ')\n"
                f"pathlib.Path({str(marker)!r}).write_text(json.dumps({{'operation_id': operation_id, 'result': payload}}), encoding='utf-8')\n",
                encoding="utf-8",
            )
            statectl_path.chmod(0o755)

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            payload = json.loads(completed.stdout)
            uuid.UUID(payload["operation_id"])
            observed = json.loads(marker.read_text(encoding="utf-8"))
            self.assertEqual(observed["operation_id"], payload["operation_id"])
            self.assertEqual(observed["result"], payload)
            persisted = json.loads(
                (root / ".forge-codex/state/gate-results/GX.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(persisted, payload)

    def test_gate_result_binds_the_exact_source_manifest_and_git_head(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.install_gate_fixture(root)
            (root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
            for command in (
                ["git", "init", "-q"],
                ["git", "config", "user.name", "Fixture"],
                ["git", "config", "user.email", "fixture@example.invalid"],
                ["git", "add", "."],
                ["git", "commit", "-qm", "fixture"],
            ):
                completed = subprocess.run(
                    command,
                    cwd=root,
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    completed.stdout + completed.stderr,
                )
            expected_head = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=root,
                capture_output=True,
                text=True,
                timeout=10,
                check=True,
            ).stdout.strip()

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            payload = json.loads(completed.stdout)
            self.assertEqual(payload["source_head"], expected_head)
            self.assertEqual(
                payload["source_manifest"],
                run_gate.source_manifest(root),
            )

    def test_gate_runner_fails_closed_without_a_current_git_head(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.install_gate_fixture(root, initialize_git=False)
            marker = root / "state-control-invoked"
            statectl_path = root / ".forge-codex/scripts/statectl.py"
            statectl_path.write_text(
                "#!/usr/bin/env python3\n"
                "import pathlib\n"
                f"pathlib.Path({str(marker)!r}).write_text('called', encoding='utf-8')\n",
                encoding="utf-8",
            )
            statectl_path.chmod(0o755)

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
            self.assertIn("Git HEAD is unavailable or invalid", completed.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse(
                (root / ".forge-codex/state/gate-results/GX.json").exists()
            )

    def test_source_mutation_during_handler_fails_before_state_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            package = root / "Package.swift"
            package.write_text("// before\n", encoding="utf-8")
            criteria = root / ".forge-codex/state/gate-results/GX.criteria.json"
            marker = root / "state-control-invoked"
            handler_body = (
                "#!/usr/bin/env python3\n"
                "import json, pathlib\n"
                f"package = pathlib.Path({str(package)!r})\n"
                "package.write_text(package.read_text(encoding='utf-8') + '// changed\\n', encoding='utf-8')\n"
                f"criteria = pathlib.Path({str(criteria)!r})\n"
                "criteria.parent.mkdir(parents=True, exist_ok=True)\n"
                "criteria.write_text(json.dumps({'criteria_results': "
                "[{'criterion': 'exact criterion', 'passed': True, "
                "'evidence': 'fixture'}]}) + '\\n', encoding='utf-8')\n"
            )
            self.install_gate_fixture(root, handler_body=handler_body)
            statectl_path = root / ".forge-codex/scripts/statectl.py"
            statectl_path.write_text(
                "#!/usr/bin/env python3\n"
                "import pathlib\n"
                f"pathlib.Path({str(marker)!r}).write_text('called', encoding='utf-8')\n",
                encoding="utf-8",
            )
            statectl_path.chmod(0o755)

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
            self.assertIn("source identity changed", completed.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse(
                (root / ".forge-codex/state/gate-results/GX.json").exists()
            )

    def test_crash_before_final_state_commit_leaves_operation_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.install_gate_fixture(root)
            previous_operation = "previous-gate-operation"
            state_path = root / ".forge-codex/state/run-state.json"
            self.write_json(
                state_path,
                {
                    "gates": {
                        "GX": {
                            "status": "passed",
                            "operation_id": previous_operation,
                        }
                    }
                },
            )
            statectl_path = root / ".forge-codex/scripts/statectl.py"
            statectl_path.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, signal, sys\n"
                "arguments = sys.argv[1:]\n"
                "evaluator = pathlib.Path(arguments[arguments.index('--evaluator') + 1])\n"
                "payload = json.loads(evaluator.read_text(encoding='utf-8'))\n"
                "if payload.get('status') != 'passed' or payload.get('finalized') is not True:\n"
                "    raise SystemExit('result was not finalized before state control')\n"
                "os.kill(os.getppid(), signal.SIGKILL)\n",
                encoding="utf-8",
            )
            statectl_path.chmod(0o755)

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, -signal.SIGKILL)
            result = json.loads(
                (root / ".forge-codex/state/gate-results/GX.json").read_text(
                    encoding="utf-8"
                )
            )
            state = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(result["status"], "passed")
            self.assertIs(result["finalized"], True)
            self.assertNotEqual(
                result["operation_id"],
                state["gates"]["GX"]["operation_id"],
            )
            self.assertEqual(
                state["gates"]["GX"]["operation_id"],
                previous_operation,
            )

    def test_symlinked_result_directory_is_rejected_without_redirected_writes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary).resolve()
            root = base / "repository"
            outside = base / "outside"
            outside.mkdir()
            self.install_gate_fixture(root)
            (root / ".forge-codex/state/gate-results").symlink_to(
                outside,
                target_is_directory=True,
            )

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 1)
            self.assertIn("contains a symlink", completed.stderr)
            self.assertEqual(list(outside.iterdir()), [])

    def test_final_symlink_is_rejected_and_post_lock_failure_releases_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary).resolve()
            root = base / "repository"
            self.install_gate_fixture(root)
            result_directory = root / ".forge-codex/state/gate-results"
            result_directory.mkdir(mode=0o700)
            victim = base / "victim.json"
            victim.write_text("unchanged\n", encoding="utf-8")
            result_path = result_directory / "GX.json"
            result_path.symlink_to(victim)

            rejected = self.run_gate(root)

            self.assertEqual(rejected.returncode, 1)
            self.assertIn("GX gate result is not a regular file", rejected.stderr)
            self.assertEqual(victim.read_text(encoding="utf-8"), "unchanged\n")

            result_path.unlink()
            retry = self.run_gate(root, "GX", "--lock-timeout", "0.05")
            self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)

    def test_hardlinked_mutable_output_is_rejected_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary).resolve()
            root = base / "repository"
            self.install_gate_fixture(root)
            result_directory = root / ".forge-codex/state/gate-results"
            result_directory.mkdir(mode=0o700)
            victim = base / "victim.txt"
            victim.write_text("unchanged\n", encoding="utf-8")
            victim.chmod(0o600)
            os.link(victim, result_directory / "GX.stdout.txt")

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 1)
            self.assertIn("multiple hard links", completed.stderr)
            self.assertEqual(victim.read_text(encoding="utf-8"), "unchanged\n")

    def test_symlinked_handler_is_rejected_without_execution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary).resolve()
            root = base / "repository"
            handler = self.install_gate_fixture(root)
            marker = base / "handler-ran"
            outside = base / "outside-handler.sh"
            outside.write_text(
                "#!/bin/sh\n" f"touch {str(marker)!r}\n",
                encoding="utf-8",
            )
            outside.chmod(0o755)
            handler.unlink()
            handler.symlink_to(outside)

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 1)
            self.assertIn("symbolic link", completed.stderr)
            self.assertFalse(marker.exists())

    def test_active_and_template_handlers_support_the_pinned_repository_root(self) -> None:
        expected = 'ROOT="${FORGE_GATE_REPOSITORY_ROOT:-'
        for directory in (ACTIVE_GATE_HANDLERS, TEMPLATE_GATE_HANDLERS):
            for handler in sorted(directory.glob("G*.sh")):
                with self.subTest(handler=str(handler)):
                    self.assertIn(
                        expected,
                        handler.read_text(encoding="utf-8"),
                    )

    def test_unlinked_snapshots_preserve_g00_g02_and_g10_root_resolution(self) -> None:
        for gate in ("G00", "G02", "G10"):
            with self.subTest(gate=gate), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                self.install_active_handler_fixture(root, gate)
                scripts = root / ".forge-codex/scripts"
                marker = root / f"{gate}.root-observation.json"

                if gate == "G00":
                    doctor = scripts / "doctor.sh"
                    doctor.write_text(
                        "#!/usr/bin/env python3\n"
                        "import json, os, pathlib\n"
                        "root = pathlib.Path(os.environ['FORGE_GATE_REPOSITORY_ROOT'])\n"
                        "path = root / '.forge-codex/state/environment.json'\n"
                        "path.parent.mkdir(parents=True, exist_ok=True)\n"
                        "path.write_text(json.dumps({'root': str(root)}) + '\\n', encoding='utf-8')\n"
                        "print(root)\n",
                        encoding="utf-8",
                    )
                    doctor.chmod(0o755)
                    validate_package = scripts / "validate_package.py"
                    validate_package.write_text(
                        "#!/usr/bin/env python3\n"
                        "import json, pathlib, sys\n"
                        "package = pathlib.Path(sys.argv[sys.argv.index('--root') + 1])\n"
                        "(package / 'PACKAGE_VALIDATION.json').write_text(json.dumps({'valid': True}) + '\\n', encoding='utf-8')\n"
                        "print(package)\n",
                        encoding="utf-8",
                    )
                    validate_package.chmod(0o755)
                    self.write_json(
                        root / ".forge-codex/state/run-state.json",
                        {"repository": str(root)},
                    )
                    build_script = root / "script/build_and_run.sh"
                    build_script.parent.mkdir(parents=True)
                    build_script.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
                    build_script.chmod(0o755)
                else:
                    validator = scripts / "validate_acceptance.py"
                    validator.write_text(
                        "#!/usr/bin/env python3\n"
                        "import json, os, pathlib, sys\n"
                        "root = pathlib.Path(sys.argv[sys.argv.index('--repo') + 1])\n"
                        "output = pathlib.Path(sys.argv[sys.argv.index('--criteria-output') + 1])\n"
                        "plan = json.loads((root / '.forge-codex/plans/gates.json').read_text(encoding='utf-8'))\n"
                        "criteria = plan['gates'][0]['criteria']\n"
                        "output.parent.mkdir(parents=True, exist_ok=True)\n"
                        "output.write_text(json.dumps({'criteria_results': [{'criterion': item, 'passed': True, 'evidence': str(root)} for item in criteria]}) + '\\n', encoding='utf-8')\n"
                        f"pathlib.Path({str(marker)!r}).write_text(json.dumps({{'root': str(root), 'pinned': os.environ.get('FORGE_GATE_REPOSITORY_ROOT')}}), encoding='utf-8')\n",
                        encoding="utf-8",
                    )
                    validator.chmod(0o755)
                    if gate == "G10":
                        checker = scripts / "check_p10_completion.py"
                        checker.write_text(
                            "#!/usr/bin/env python3\n"
                            "import os, pathlib\n"
                            f"pathlib.Path({str(root / 'G10.check-root')!r}).write_text(os.environ.get('FORGE_P10_REPOSITORY', ''), encoding='utf-8')\n",
                            encoding="utf-8",
                        )
                        checker.chmod(0o755)

                completed = self.run_gate(root, gate)

                self.assertEqual(
                    completed.returncode,
                    1 if gate == "G10" else 0,
                    completed.stdout + completed.stderr,
                )
                if gate == "G00":
                    environment = json.loads(
                        (root / ".forge-codex/state/environment.json").read_text(
                            encoding="utf-8"
                        )
                    )
                    self.assertEqual(environment["root"], str(root))
                else:
                    observation = json.loads(marker.read_text(encoding="utf-8"))
                    self.assertEqual(observation["root"], str(root))
                    self.assertEqual(observation["pinned"], str(root))
                    if gate == "G10":
                        self.assertEqual(
                            (root / "G10.check-root").read_text(encoding="utf-8"),
                            str(root),
                        )
                        self.assertIn("no exact P10 feature binding", completed.stdout)

    def test_handler_swap_and_restore_cannot_change_executed_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            handler = root / ".forge-codex/state/gate-handlers/GX.sh"
            saved = handler.with_suffix(".saved")
            displaced = handler.with_suffix(".displaced")
            trace = root / "snapshot-trace.txt"
            malicious_marker = root / "malicious-handler-ran"
            criteria = root / ".forge-codex/state/gate-results/GX.criteria.json"
            handler_body = (
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                f"mv {str(handler)!r} {str(saved)!r}\n"
                f"printf '%s\\n' '#!/usr/bin/env bash' 'touch {str(malicious_marker)!r}' > {str(handler)!r}\n"
                f"chmod 700 {str(handler)!r}\n"
                f"printf '%s\\n%s\\n' \"${{BASH_SOURCE[0]}}\" \"${{FORGE_GATE_REPOSITORY_ROOT}}\" > {str(trace)!r}\n"
                f"mv {str(handler)!r} {str(displaced)!r}\n"
                f"mv {str(saved)!r} {str(handler)!r}\n"
                f"touch {str(handler)!r}\n"
                f"printf '%s\\n' '{{\"criteria_results\":[{{\"criterion\":\"exact criterion\",\"passed\":true,\"evidence\":\"snapshot\"}}]}}' > {str(criteria)!r}\n"
            )
            self.install_gate_fixture(root, handler_body=handler_body)

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 1)
            self.assertIn("gate handler pathname identity changed", completed.stderr)
            self.assertFalse(malicious_marker.exists())
            source, pinned_root = trace.read_text(encoding="utf-8").splitlines()
            self.assertTrue(source.startswith("/dev/fd/"), source)
            self.assertEqual(pinned_root, str(root))

    def test_lock_path_replacement_is_detected_before_state_control(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            result_directory = root / ".forge-codex/state/gate-results"
            criteria = result_directory / "GX.criteria.json"
            lock = result_directory / ".GX.lock"
            replacement = result_directory / ".replacement.lock"
            handler_body = (
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib\n"
                f"criteria = pathlib.Path({str(criteria)!r})\n"
                "criteria.parent.mkdir(parents=True, exist_ok=True)\n"
                "criteria.write_text(json.dumps({'criteria_results': "
                "[{'criterion': 'exact criterion', 'passed': True, "
                "'evidence': 'fixture'}]}) + '\\n', encoding='utf-8')\n"
                f"replacement = pathlib.Path({str(replacement)!r})\n"
                "replacement.write_text('', encoding='utf-8')\n"
                "replacement.chmod(0o600)\n"
                f"os.replace(replacement, pathlib.Path({str(lock)!r}))\n"
            )
            self.install_gate_fixture(root, handler_body=handler_body)

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 1)
            self.assertIn(
                "gate serialization lock pathname identity changed",
                completed.stderr,
            )

    def test_result_directory_replacement_is_detected_before_state_control(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            result_directory = root / ".forge-codex/state/gate-results"
            moved_directory = root / ".forge-codex/state/moved-gate-results"
            criteria = result_directory / "GX.criteria.json"
            handler_body = (
                "#!/usr/bin/env python3\n"
                "import json, pathlib\n"
                f"criteria = pathlib.Path({str(criteria)!r})\n"
                "criteria.parent.mkdir(parents=True, exist_ok=True)\n"
                "criteria.write_text(json.dumps({'criteria_results': "
                "[{'criterion': 'exact criterion', 'passed': True, "
                "'evidence': 'fixture'}]}) + '\\n', encoding='utf-8')\n"
                f"results = pathlib.Path({str(result_directory)!r})\n"
                f"moved = pathlib.Path({str(moved_directory)!r})\n"
                "results.rename(moved)\n"
                "results.mkdir(mode=0o700)\n"
            )
            self.install_gate_fixture(root, handler_body=handler_body)

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 1)
            self.assertIn(
                "gate-results directory pathname identity changed",
                completed.stderr,
            )
            self.assertEqual(list(result_directory.iterdir()), [])

    def test_real_statectl_recovers_interrupted_transaction_before_gate_update(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.install_real_statectl_fixture(root)
            original_atomic_json = statectl.atomic_json_at

            def fail_state_publication(
                directory_descriptor: int,
                final_name: str,
                staging_name: str,
                value: object,
                *,
                label: str,
                maximum_bytes: int,
            ) -> None:
                if final_name == statectl.STATE_FILE_NAME:
                    raise statectl.EvidenceSupportError(
                        "injected interrupted state publication"
                    )
                original_atomic_json(
                    directory_descriptor,
                    final_name,
                    staging_name,
                    value,
                    label=label,
                    maximum_bytes=maximum_bytes,
                )

            with mock.patch.object(
                statectl,
                "atomic_json_at",
                side_effect=fail_state_publication,
            ):
                with self.assertRaisesRegex(
                    statectl.EvidenceSupportError,
                    "interrupted state publication",
                ):
                    statectl.mutate(
                        root,
                        "fixture_interruption",
                        {"value": 1},
                        lambda run_state: None,
                        operation_id="fixture-interrupted-operation",
                    )

            transaction = root / ".forge-codex/state/.state-transaction.json"
            self.assertTrue(transaction.is_file())

            completed = self.run_gate(root)

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            result = json.loads(completed.stdout)
            run_state = json.loads(
                (root / ".forge-codex/state/run-state.json").read_text(
                    encoding="utf-8"
                )
            )
            gate_state = run_state["gates"]["GX"]
            self.assertEqual(gate_state["status"], "passed")
            self.assertEqual(gate_state["operation_id"], result["operation_id"])
            self.assertFalse(transaction.exists())
            events = [
                json.loads(line)
                for line in (
                    root / ".forge-codex/state/events.jsonl"
                ).read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(
                [event["type"] for event in events].count("fixture_interruption"),
                1,
            )
            self.assertEqual(
                [event["type"] for event in events].count("gate_status"),
                1,
            )

            validated = subprocess.run(
                [
                    sys.executable,
                    str(root / ".forge-codex/scripts/statectl.py"),
                    "--repo",
                    str(root),
                    "validate",
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(
                validated.returncode,
                0,
                validated.stdout + validated.stderr,
            )

    def test_overlapping_gate_runs_are_serialized_and_each_uses_its_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            trace = root / "handler-trace.txt"
            criteria = root / ".forge-codex/state/gate-results/GX.criteria.json"
            handler_body = (
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, time\n"
                f"trace = pathlib.Path({str(trace)!r})\n"
                f"criteria = pathlib.Path({str(criteria)!r})\n"
                "with trace.open('a', encoding='utf-8') as stream:\n"
                "    stream.write(f'start:{os.getpid()}\\n')\n"
                "    stream.flush()\n"
                "    os.fsync(stream.fileno())\n"
                "time.sleep(0.35)\n"
                "criteria.parent.mkdir(parents=True, exist_ok=True)\n"
                "criteria.write_text(json.dumps({'criteria_results': "
                "[{'criterion': 'exact criterion', 'passed': True, "
                "'evidence': str(os.getpid())}]}) + '\\n', encoding='utf-8')\n"
                "with trace.open('a', encoding='utf-8') as stream:\n"
                "    stream.write(f'end:{os.getpid()}\\n')\n"
                "    stream.flush()\n"
                "    os.fsync(stream.fileno())\n"
            )
            self.install_gate_fixture(root, handler_body=handler_body)
            command = [
                sys.executable,
                str(GATE_RUNNER),
                "--repo",
                str(root),
                "--",
                "GX",
            ]
            first = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.wait_for_line(trace, "start:")
            second = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            first_stdout, first_stderr = first.communicate(timeout=10)
            second_stdout, second_stderr = second.communicate(timeout=10)

            self.assertEqual(first.returncode, 0, first_stdout + first_stderr)
            self.assertEqual(second.returncode, 0, second_stdout + second_stderr)
            lines = trace.read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                [line.split(":", 1)[0] for line in lines],
                ["start", "end", "start", "end"],
            )
            self.assertEqual(lines[0].split(":", 1)[1], lines[1].split(":", 1)[1])
            self.assertEqual(lines[2].split(":", 1)[1], lines[3].split(":", 1)[1])
            self.assertNotEqual(lines[0].split(":", 1)[1], lines[2].split(":", 1)[1])
            first_payload = json.loads(first_stdout)
            second_payload = json.loads(second_stdout)
            self.assertEqual(first_payload["status"], "passed")
            self.assertEqual(second_payload["status"], "passed")
            self.assertEqual(
                first_payload["evaluator"]["criteria_results"][0]["evidence"],
                lines[0].split(":", 1)[1],
            )
            self.assertEqual(
                second_payload["evaluator"]["criteria_results"][0]["evidence"],
                lines[2].split(":", 1)[1],
            )

    def test_overlapping_gate_run_has_a_bounded_lock_wait(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            trace = root / "handler-trace.txt"
            criteria = root / ".forge-codex/state/gate-results/GX.criteria.json"
            handler_body = (
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, time\n"
                f"trace = pathlib.Path({str(trace)!r})\n"
                f"criteria = pathlib.Path({str(criteria)!r})\n"
                "trace.write_text(f'start:{os.getpid()}\\n', encoding='utf-8')\n"
                "time.sleep(0.6)\n"
                "criteria.parent.mkdir(parents=True, exist_ok=True)\n"
                "criteria.write_text(json.dumps({'criteria_results': "
                "[{'criterion': 'exact criterion', 'passed': True, "
                "'evidence': 'fixture'}]}) + '\\n', encoding='utf-8')\n"
            )
            self.install_gate_fixture(root, handler_body=handler_body)
            first = subprocess.Popen(
                [
                    sys.executable,
                    str(GATE_RUNNER),
                    "--repo",
                    str(root),
                    "--",
                    "GX",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.wait_for_line(trace, "start:")

            started = time.monotonic()
            blocked = self.run_gate(root, "GX", "--lock-timeout", "0.05")
            elapsed = time.monotonic() - started
            first_stdout, first_stderr = first.communicate(timeout=10)

            self.assertEqual(first.returncode, 0, first_stdout + first_stderr)
            self.assertEqual(blocked.returncode, 1, blocked.stdout + blocked.stderr)
            self.assertLess(elapsed, 1)
            self.assertIn("gate serialization bound", blocked.stderr)

    def test_gate_runner_rejects_invalid_and_traversal_identifiers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            for gate in ("../GX", "G/../../GX", "-option", "G" * 65):
                with self.subTest(gate=gate):
                    result = self.run_gate(root, gate)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("invalid gate identifier", result.stderr)
            self.assertFalse((root / ".forge-codex/state/gate-results").exists())

    def install_batch_fixture(
        self,
        root: pathlib.Path,
        gate_ids: list[str],
        *,
        runner_exit: int,
        initialize_git: bool = True,
    ) -> pathlib.Path:
        scripts = root / ".forge-codex/scripts"
        scripts.mkdir(parents=True, exist_ok=True)
        runner = scripts / "run_gates.sh"
        runner.write_bytes(GATE_BATCH_RUNNER.read_bytes())
        runner.chmod(0o755)
        (scripts / "evidence_support.py").write_bytes(EVIDENCE_SUPPORT.read_bytes())
        marker = root / "gate-invocations.txt"
        gate_runner = scripts / "run_gate.py"
        gate_runner.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$*\" >> {str(marker)!r}\n"
            f"exit {runner_exit}\n",
            encoding="utf-8",
        )
        gate_runner.chmod(0o755)
        self.write_json(
            root / ".forge-codex/state/run-state.json",
            {
                "phases": {"PX": {"status": "passed"}},
                "gates": {
                    gate: {"status": "not_started"}
                    for gate in gate_ids
                },
            },
        )
        self.write_json(
            root / ".forge-codex/plans/phases.json",
            {
                "phases": [
                    {
                        "id": "PX",
                        "priority": 1,
                        "dependencies": [],
                        "hard_gates": gate_ids,
                    }
                ]
            },
        )
        if initialize_git:
            self.initialize_git_fixture(root)
        return marker

    def test_batch_runner_rejects_invalid_identifier_before_invocation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            marker = self.install_batch_fixture(
                root,
                ["../GX"],
                runner_exit=0,
            )

            result = subprocess.run(
                ["bash", str(root / ".forge-codex/scripts/run_gates.sh"), "--all"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("invalid gate identifier", result.stderr)
            self.assertFalse(marker.exists())

    def test_batch_runner_returns_failure_for_exactly_256_failed_gates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            gate_ids = [f"G{index:03d}" for index in range(256)]
            marker = self.install_batch_fixture(root, gate_ids, runner_exit=1)

            result = subprocess.run(
                ["bash", str(root / ".forge-codex/scripts/run_gates.sh"), "--all"],
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )

            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertEqual(
                len(marker.read_text(encoding="utf-8").splitlines()),
                256,
            )

    def test_batch_runner_skips_only_a_matching_passed_result_operation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            marker = self.install_batch_fixture(root, ["GX"], runner_exit=0)
            operation_id = "matching-operation"
            state_path = root / ".forge-codex/state/run-state.json"
            run_state = json.loads(state_path.read_text(encoding="utf-8"))
            run_state["gates"]["GX"].update(
                {"status": "passed", "operation_id": operation_id}
            )
            self.write_json(state_path, run_state)
            result_path = root / ".forge-codex/state/gate-results/GX.json"
            source_head = run_gate.current_git_head(root)
            source_manifest = run_gate.source_manifest(root)
            self.write_json(
                result_path,
                {
                    "gate_id": "GX",
                    "status": "passed",
                    "operation_id": operation_id,
                    "finalized": True,
                    "source_head": source_head,
                    "source_manifest": source_manifest,
                },
            )

            matching = subprocess.run(
                ["bash", str(root / ".forge-codex/scripts/run_gates.sh"), "--ready"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(matching.returncode, 0, matching.stdout + matching.stderr)
            self.assertFalse(marker.exists())

            self.write_json(
                result_path,
                {
                    "gate_id": "GX",
                    "status": "passed",
                    "operation_id": "different-operation",
                    "finalized": True,
                    "source_head": source_head,
                    "source_manifest": source_manifest,
                },
            )
            mismatched = subprocess.run(
                ["bash", str(root / ".forge-codex/scripts/run_gates.sh"), "--ready"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(
                mismatched.returncode,
                0,
                mismatched.stdout + mismatched.stderr,
            )
            self.assertEqual(
                len(marker.read_text(encoding="utf-8").splitlines()),
                1,
            )

    def test_batch_runner_fails_closed_without_a_current_git_head(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            marker = self.install_batch_fixture(
                root,
                ["GX"],
                runner_exit=0,
                initialize_git=False,
            )
            operation_id = "matching-operation"
            state_path = root / ".forge-codex/state/run-state.json"
            run_state = json.loads(state_path.read_text(encoding="utf-8"))
            run_state["gates"]["GX"].update(
                {"status": "passed", "operation_id": operation_id}
            )
            self.write_json(state_path, run_state)
            self.write_json(
                root / ".forge-codex/state/gate-results/GX.json",
                {
                    "gate_id": "GX",
                    "status": "passed",
                    "operation_id": operation_id,
                    "finalized": True,
                    "source_head": None,
                    "source_manifest": run_gate.source_manifest(root),
                },
            )

            completed = subprocess.run(
                ["bash", str(root / ".forge-codex/scripts/run_gates.sh"), "--ready"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
            self.assertIn("Git HEAD is unavailable or invalid", completed.stderr)
            self.assertFalse(marker.exists())

    def test_batch_runner_reruns_a_matching_operation_after_source_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            marker = self.install_batch_fixture(root, ["GX"], runner_exit=0)
            operation_id = "matching-operation"
            state_path = root / ".forge-codex/state/run-state.json"
            run_state = json.loads(state_path.read_text(encoding="utf-8"))
            run_state["gates"]["GX"].update(
                {"status": "passed", "operation_id": operation_id}
            )
            self.write_json(state_path, run_state)
            self.write_json(
                root / ".forge-codex/state/gate-results/GX.json",
                {
                    "gate_id": "GX",
                    "status": "passed",
                    "operation_id": operation_id,
                    "finalized": True,
                    "source_head": run_gate.current_git_head(root),
                    "source_manifest": run_gate.source_manifest(root),
                },
            )
            phases_path = root / ".forge-codex/plans/phases.json"
            phases = json.loads(phases_path.read_text(encoding="utf-8"))
            phases["source_change"] = True
            self.write_json(phases_path, phases)

            completed = subprocess.run(
                ["bash", str(root / ".forge-codex/scripts/run_gates.sh"), "--ready"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(
                marker.read_text(encoding="utf-8").splitlines(),
                ["--repo " + str(root) + " -- GX"],
            )


if __name__ == "__main__":
    unittest.main()
