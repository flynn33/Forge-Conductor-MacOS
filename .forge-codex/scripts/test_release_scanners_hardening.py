#!/usr/bin/env python3
from __future__ import annotations

import os
import pathlib
import tempfile
import time
import unittest
from unittest import mock

import evidence_support
import scan_attribution
import scan_secrets
import validate_package
from evidence_support import EvidenceSupportError


class ReleaseScannerHardeningTests(unittest.TestCase):
    def write_bytes(self, root: pathlib.Path, relative: str, raw: bytes) -> pathlib.Path:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return path

    def test_attribution_scan_accepts_exact_file_and_aggregate_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.write_bytes(root, "clean.txt", b"bounded clean text")

            hits = scan_attribution.scan_repository(
                root,
                maximum_file_bytes=18,
                maximum_total_bytes=18,
                maximum_entries=1,
            )

            self.assertEqual(hits, [])

    def test_attribution_scan_rejects_file_and_aggregate_plus_one(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.write_bytes(root, "oversized.txt", b"123456789")

            with self.assertRaisesRegex(EvidenceSupportError, "file read bound"):
                scan_attribution.scan_repository(
                    root,
                    maximum_file_bytes=8,
                    maximum_total_bytes=32,
                    maximum_entries=1,
                )

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.write_bytes(root, "first.txt", b"12345")
            self.write_bytes(root, "second.txt", b"6789")

            with self.assertRaisesRegex(EvidenceSupportError, "aggregate read bound"):
                scan_attribution.scan_repository(
                    root,
                    maximum_file_bytes=8,
                    maximum_total_bytes=8,
                    maximum_entries=2,
                )

    def test_traversal_counts_skipped_entries_and_rejects_plus_one(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            (root / ".git").mkdir()
            self.write_bytes(root, "clean.txt", b"clean")

            with self.assertRaisesRegex(
                EvidenceSupportError,
                "repository traversal exceeds 1 entries",
            ):
                scan_attribution.scan_repository(
                    root,
                    maximum_file_bytes=8,
                    maximum_total_bytes=8,
                    maximum_entries=1,
                )

    def test_scanners_reject_symlink_and_hardlink_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            target = self.write_bytes(root, "target.txt", b"clean")
            (root / "linked.txt").symlink_to(target)

            for scanner in (
                scan_attribution.scan_repository,
                scan_secrets.scan_repository,
            ):
                with self.subTest(scanner=scanner.__module__):
                    with self.assertRaisesRegex(
                        EvidenceSupportError,
                        "symbolic link",
                    ):
                        scanner(root)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            target = self.write_bytes(root, "target.txt", b"clean")
            os.link(target, root / "hardlink.txt")

            with self.assertRaisesRegex(EvidenceSupportError, "multiple hard links"):
                scan_secrets.scan_repository(root)

    def test_scan_detects_equal_content_path_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            target = self.write_bytes(root, "target.txt", b"clean")
            original_open = evidence_support._open_repository_relative_file
            open_count = 0

            def replace_before_verification(
                repository_root: pathlib.Path,
                relative_path: pathlib.PurePosixPath,
            ) -> int:
                nonlocal open_count
                open_count += 1
                if open_count == 2:
                    replacement = target.with_name("replacement.txt")
                    replacement.write_bytes(target.read_bytes())
                    os.replace(replacement, target)
                return original_open(repository_root, relative_path)

            with mock.patch.object(
                evidence_support,
                "_open_repository_relative_file",
                side_effect=replace_before_verification,
            ):
                with self.assertRaisesRegex(
                    EvidenceSupportError,
                    "pathname no longer names the opened file",
                ):
                    scan_attribution.scan_repository(root)

    def test_secret_scan_retains_detection_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.write_bytes(
                root,
                "credential.txt",
                b"access_" + b"token = " + b"abcdefghijklmnopqrstuvwxyz123456\n",
            )

            hits = scan_secrets.scan_repository(root)

            self.assertEqual(len(hits), 1)
            self.assertEqual(hits[0][0:3], ("credential.txt", 1, "generic-token"))

    def test_attribution_scan_retains_detection_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.write_bytes(
                root,
                "source.txt",
                b"This file was " + b"authored by " + b"Open" + b"AI.\n",
            )

            hits = scan_attribution.scan_repository(root)

            self.assertEqual(len(hits), 1)
            self.assertEqual(hits[0]["path"], "source.txt")
            self.assertEqual(hits[0]["line"], 1)

    def test_pinned_child_output_and_timeout_are_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            script = self.write_bytes(
                root,
                "scripts/scan_attribution.py",
                b"import os\nos.write(1, b'x' * 65)\n",
            )
            self.assertTrue(script.is_file())
            with mock.patch.object(
                validate_package,
                "MAXIMUM_CHILD_OUTPUT_BYTES",
                64,
            ):
                with self.assertRaisesRegex(EvidenceSupportError, "failed closed"):
                    validate_package.run_pinned_python_script(
                        root,
                        pathlib.PurePosixPath("scripts/scan_attribution.py"),
                        label="oversized child",
                    )

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            self.write_bytes(
                root,
                "scripts/scan_attribution.py",
                b"import time\ntime.sleep(10)\n",
            )
            started = time.monotonic()
            with mock.patch.object(
                validate_package,
                "MAXIMUM_CHILD_SECONDS",
                0.1,
            ):
                with self.assertRaisesRegex(EvidenceSupportError, "failed closed"):
                    validate_package.run_pinned_python_script(
                        root,
                        pathlib.PurePosixPath("scripts/scan_attribution.py"),
                        label="timed child",
                    )
            self.assertLess(time.monotonic() - started, 3.0)

    def test_shell_syntax_uses_the_bounded_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()

            self.assertEqual(
                validate_package.validate_shell_bytes(
                    root,
                    b"#!/bin/bash\nvalue=ok\n",
                    label="valid shell",
                ),
                "syntax valid",
            )
            with self.assertRaisesRegex(EvidenceSupportError, "exited"):
                validate_package.validate_shell_bytes(
                    root,
                    b"#!/bin/bash\nif true; then\n",
                    label="invalid shell",
                )


if __name__ == "__main__":
    unittest.main()
