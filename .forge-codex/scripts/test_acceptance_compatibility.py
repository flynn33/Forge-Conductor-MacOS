#!/usr/bin/env python3
"""Focused regressions for bounded acceptance compatibility."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import pathlib
import stat
import tempfile
import unittest
from unittest import mock

import validate_acceptance
from evidence_support import EvidenceSupportError, source_manifest


class AcceptanceCompatibilityTests(unittest.TestCase):
    @staticmethod
    def write_json(path: pathlib.Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def make_acceptance(
        self,
        root: pathlib.Path,
        *,
        gate: str,
        evidence_path: str,
        evidence_bytes: bytes,
    ) -> None:
        self.write_json(
            root / ".forge-codex/plans/gates.json",
            {"gates": [{"id": gate, "criteria": ["exact criterion"]}]},
        )
        self.write_json(
            root / f".forge-codex/state/acceptance/{gate}.json",
            {
                "gate_id": gate,
                "current_release_authority": True,
                "criteria_results": [
                    {
                        "criterion": "exact criterion",
                        "passed": True,
                        "evidence": [
                            {
                                "path": evidence_path,
                                "sha256": hashlib.sha256(evidence_bytes).hexdigest(),
                            }
                        ],
                    }
                ],
                "commands": [
                    {
                        "command": "fixture",
                        "exit_code": 0,
                        "evidence": evidence_path,
                    }
                ],
            },
        )

    @staticmethod
    def validate(
        root: pathlib.Path,
        gate: str,
        *,
        criteria_output: pathlib.Path | None = None,
    ) -> tuple[int, str]:
        output = io.StringIO()
        arguments = [gate, "--repo", str(root)]
        if criteria_output is not None:
            arguments.extend(("--criteria-output", str(criteria_output)))
        with contextlib.redirect_stdout(output):
            result = validate_acceptance.main(arguments)
        return result, output.getvalue()

    def make_valid_fixture(self, root: pathlib.Path, *, gate: str = "GX") -> None:
        artifact_bytes = b"proof"
        artifact = root / "proof.txt"
        artifact.write_bytes(artifact_bytes)
        self.make_acceptance(
            root,
            gate=gate,
            evidence_path=artifact.name,
            evidence_bytes=artifact_bytes,
        )

    def test_non_g10_accepts_absolute_external_evidence_at_exact_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as external:
            root = pathlib.Path(temporary).resolve()
            artifact = pathlib.Path(external).resolve() / "proof.txt"
            artifact_bytes = b"proof"
            artifact.write_bytes(artifact_bytes)
            self.make_acceptance(
                root,
                gate="GX",
                evidence_path=str(artifact),
                evidence_bytes=artifact_bytes,
            )

            with mock.patch(
                "validate_acceptance.MAXIMUM_EVIDENCE_FILE_BYTES",
                len(artifact_bytes),
            ), mock.patch(
                "validate_acceptance.MAXIMUM_EVIDENCE_TOTAL_BYTES",
                len(artifact_bytes) * 2,
            ):
                result, output = self.validate(root, "GX")

            self.assertEqual(result, 0, output)
            self.assertIn('"valid": true', output)

            with mock.patch(
                "validate_acceptance.MAXIMUM_EVIDENCE_FILE_BYTES",
                len(artifact_bytes) - 1,
            ), mock.patch(
                "validate_acceptance.MAXIMUM_EVIDENCE_TOTAL_BYTES",
                len(artifact_bytes) * 2,
            ):
                result, output = self.validate(root, "GX")

            self.assertEqual(result, 1, output)
            self.assertIn("file read bound", output)

            with mock.patch(
                "validate_acceptance.MAXIMUM_EVIDENCE_FILE_BYTES",
                len(artifact_bytes),
            ), mock.patch(
                "validate_acceptance.MAXIMUM_EVIDENCE_TOTAL_BYTES",
                len(artifact_bytes) * 2 - 1,
            ):
                result, output = self.validate(root, "GX")

            self.assertEqual(result, 1, output)
            self.assertIn("aggregate read bound", output)

    def test_g10_requires_repository_evidence_and_enforces_exact_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as external:
            root = pathlib.Path(temporary).resolve()
            artifact_bytes = b"proof"
            external_artifact = pathlib.Path(external).resolve() / "proof.txt"
            external_artifact.write_bytes(artifact_bytes)
            self.make_acceptance(
                root,
                gate="G10",
                evidence_path=str(external_artifact),
                evidence_bytes=artifact_bytes,
            )

            result, output = self.validate(root, "G10")

            self.assertEqual(result, 1, output)
            self.assertIn("malformed evidence", output)
            self.assertNotIn(f"{external_artifact}#", output)

            repository_artifact = root / "proof.txt"
            repository_artifact.write_bytes(artifact_bytes)
            self.make_acceptance(
                root,
                gate="G10",
                evidence_path=repository_artifact.name,
                evidence_bytes=artifact_bytes,
            )
            with mock.patch(
                "validate_acceptance.MAXIMUM_G10_EVIDENCE_FILE_BYTES",
                len(artifact_bytes),
            ), mock.patch(
                "validate_acceptance.MAXIMUM_G10_EVIDENCE_TOTAL_BYTES",
                len(artifact_bytes) * 2,
            ):
                result, output = self.validate(root, "G10")

            self.assertEqual(result, 0, output)
            self.assertIn('"valid": true', output)

            with mock.patch(
                "validate_acceptance.MAXIMUM_G10_EVIDENCE_FILE_BYTES",
                len(artifact_bytes) - 1,
            ), mock.patch(
                "validate_acceptance.MAXIMUM_G10_EVIDENCE_TOTAL_BYTES",
                len(artifact_bytes) * 2,
            ):
                result, output = self.validate(root, "G10")

            self.assertEqual(result, 1, output)
            self.assertIn("file read bound", output)

            with mock.patch(
                "validate_acceptance.MAXIMUM_G10_EVIDENCE_FILE_BYTES",
                len(artifact_bytes),
            ), mock.patch(
                "validate_acceptance.MAXIMUM_G10_EVIDENCE_TOTAL_BYTES",
                len(artifact_bytes) * 2 - 1,
            ):
                result, output = self.validate(root, "G10")

            self.assertEqual(result, 1, output)
            self.assertIn("aggregate read bound", output)

    def test_acceptance_requires_exact_gate_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_valid_fixture(root, gate="G09")
            acceptance = root / ".forge-codex/state/acceptance/G09.json"
            record = json.loads(acceptance.read_text(encoding="utf-8"))
            record["gate_id"] = "G08"
            self.write_json(acceptance, record)

            result, output = self.validate(root, "G09")

            self.assertEqual(result, 1, output)
            self.assertIn("gate_id must be exactly G09", output)

    def test_acceptance_requires_literal_current_release_authority(self) -> None:
        invalid_values = ("missing", None, False, 1, "true")
        for invalid_value in invalid_values:
            with self.subTest(invalid_value=invalid_value), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                self.make_valid_fixture(root, gate="G09")
                acceptance = root / ".forge-codex/state/acceptance/G09.json"
                record = json.loads(acceptance.read_text(encoding="utf-8"))
                if invalid_value == "missing":
                    record.pop("current_release_authority")
                else:
                    record["current_release_authority"] = invalid_value
                self.write_json(acceptance, record)

                result, output = self.validate(root, "G09")

                self.assertEqual(result, 1, output)
                self.assertIn("not current release authority", output)

    def test_non_g10_rejects_final_external_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as external:
            root = pathlib.Path(temporary).resolve()
            artifact_bytes = b"proof"
            target = pathlib.Path(external).resolve() / "target.txt"
            target.write_bytes(artifact_bytes)
            link = target.with_name("proof-link.txt")
            link.symlink_to(target.name)
            self.make_acceptance(
                root,
                gate="GX",
                evidence_path=str(link),
                evidence_bytes=artifact_bytes,
            )

            result, output = self.validate(root, "GX")

            self.assertEqual(result, 1, output)
            self.assertIn("symbolic link", output)

    def test_exact_canonical_criteria_output_is_atomically_published(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_valid_fixture(root)
            output = root / ".forge-codex/state/gate-results/GX.criteria.json"

            result, rendered = self.validate(
                root,
                "GX",
                criteria_output=output,
            )

            self.assertEqual(result, 0, rendered)
            self.assertTrue(output.is_file())
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(output.stat().st_nlink, 1)
            self.assertTrue(json.loads(output.read_text(encoding="utf-8"))["valid"])

    def test_criteria_output_rejects_outside_path_without_writing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as outside:
            root = pathlib.Path(temporary).resolve()
            self.make_valid_fixture(root)
            sentinel = pathlib.Path(outside).resolve() / "sentinel.txt"
            sentinel.write_text("preserve", encoding="utf-8")

            with self.assertRaisesRegex(
                SystemExit,
                "exact canonical per-gate repository path",
            ):
                self.validate(root, "GX", criteria_output=sentinel)

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")
            self.assertFalse(
                (root / ".forge-codex/state/gate-results/GX.criteria.json").exists()
            )

    def test_criteria_output_rejects_final_symlink_without_following_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as outside:
            root = pathlib.Path(temporary).resolve()
            self.make_valid_fixture(root)
            gate_results = root / ".forge-codex/state/gate-results"
            gate_results.mkdir(parents=True)
            sentinel = pathlib.Path(outside).resolve() / "sentinel.txt"
            sentinel.write_text("preserve", encoding="utf-8")
            output = gate_results / "GX.criteria.json"
            output.symlink_to(sentinel)

            with self.assertRaisesRegex(
                SystemExit,
                "not a regular non-symlink file",
            ):
                self.validate(root, "GX")

            self.assertTrue(output.is_symlink())
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")

    def test_criteria_output_rejects_parent_symlink_without_writing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as outside:
            root = pathlib.Path(temporary).resolve()
            self.make_valid_fixture(root)
            external_results = pathlib.Path(outside).resolve() / "gate-results"
            external_results.mkdir()
            sentinel = external_results / "GX.criteria.json"
            sentinel.write_text("preserve", encoding="utf-8")
            (root / ".forge-codex/state/gate-results").symlink_to(
                external_results,
                target_is_directory=True,
            )

            with self.assertRaisesRegex(
                SystemExit,
                "unavailable or contains a symbolic link",
            ):
                self.validate(root, "GX")

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")

    def test_criteria_output_rejects_multiply_linked_existing_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.make_valid_fixture(root)
            gate_results = root / ".forge-codex/state/gate-results"
            gate_results.mkdir(parents=True)
            sentinel = root / "sentinel.txt"
            sentinel.write_text("preserve", encoding="utf-8")
            output = gate_results / "GX.criteria.json"
            os.link(sentinel, output)

            with self.assertRaisesRegex(SystemExit, "exactly one hard link"):
                self.validate(root, "GX")

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")
            self.assertEqual(output.stat().st_nlink, 2)

    def test_criteria_output_enforces_exact_byte_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            (root / ".forge-codex/state").mkdir(parents=True)
            output = root / ".forge-codex/state/gate-results/GX.criteria.json"
            exact = b"x" * validate_acceptance.MAXIMUM_CRITERIA_OUTPUT_BYTES

            published = validate_acceptance.write_criteria_output(
                root,
                "GX",
                exact,
                str(output),
            )

            self.assertEqual(published, output)
            self.assertEqual(output.read_bytes(), exact)
            with self.assertRaisesRegex(
                EvidenceSupportError,
                f"{validate_acceptance.MAXIMUM_CRITERIA_OUTPUT_BYTES}-byte bound",
            ):
                validate_acceptance.write_criteria_output(
                    root,
                    "GX",
                    exact + b"x",
                    str(output),
                )
            self.assertEqual(output.read_bytes(), exact)

    def test_criteria_output_write_interruption_fails_without_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            (root / ".forge-codex/state").mkdir(parents=True)
            output = root / ".forge-codex/state/gate-results/GX.criteria.json"

            with mock.patch(
                "validate_acceptance.os.write",
                side_effect=InterruptedError("injected interruption"),
            ), self.assertRaisesRegex(EvidenceSupportError, "cannot be published"):
                validate_acceptance.write_criteria_output(
                    root,
                    "GX",
                    b"payload",
                    str(output),
                )

            self.assertFalse(output.exists())
            self.assertEqual(
                list((root / ".forge-codex/state/gate-results").glob("*.tmp")),
                [],
            )

    def test_source_manifest_rejects_nonempty_all_zero_byte_source_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            sources = root / "Sources"
            sources.mkdir()
            (sources / "Empty.swift").write_bytes(b"")

            with self.assertRaisesRegex(
                EvidenceSupportError,
                "source manifest has no source bytes",
            ):
                source_manifest(root)


if __name__ == "__main__":
    unittest.main()
