from __future__ import annotations

import hashlib
import pathlib
import tempfile
import unittest

import scan_attribution


WORKFLOW_PATH = ".github/workflows/no-ai-attribution.yml"
REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
PINNED_POSITIONS = (100, 184, 231, 272, 326)
# Construct a detection fixture without putting a credit in this source file.
CREDIT = b"# Written " + b"by Open" + b"AI\n"


class AttributionPolicyExampleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.original = (REPOSITORY / WORKFLOW_PATH).read_bytes()
        self.lines = self.original.splitlines(keepends=True)
        self.temp = tempfile.TemporaryDirectory(prefix="attribution-policy-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)

    def scan(self, raw: bytes, path: str = WORKFLOW_PATH) -> list[dict[str, object]]:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
        return scan_attribution.scan_repository(self.root)

    def test_exact_reviewed_workflow_is_accepted(self) -> None:
        self.assertEqual(self.scan(self.original), [])
        pinned = scan_attribution.PINNED_POLICY_EXAMPLE_LINES[WORKFLOW_PATH]
        self.assertEqual(tuple(pinned), PINNED_POSITIONS)
        for number in PINNED_POSITIONS:
            self.assertEqual(hashlib.sha256(self.lines[number - 1]).hexdigest(), pinned[number])

    def test_appended_credit_is_detected_at_the_same_workflow_path(self) -> None:
        hits = self.scan(self.original + CREDIT)
        self.assertTrue(any(hit["path"] == WORKFLOW_PATH and hit["line"] == len(self.lines) + 1
                            for hit in hits))

    def test_credit_appended_to_each_pinned_line_is_detected(self) -> None:
        for number in PINNED_POSITIONS:
            with self.subTest(line=number):
                changed = list(self.lines)
                changed[number - 1] = changed[number - 1].rstrip(b"\n") + b" " + CREDIT
                hits = self.scan(b"".join(changed))
                self.assertTrue(any(hit["line"] == number for hit in hits))

    def test_credit_replacing_each_pinned_line_is_detected(self) -> None:
        for number in PINNED_POSITIONS:
            with self.subTest(line=number):
                changed = list(self.lines)
                changed[number - 1] = CREDIT
                hits = self.scan(b"".join(changed))
                self.assertTrue(any(hit["line"] == number for hit in hits))

    def test_identical_policy_lines_at_another_path_are_not_exempted(self) -> None:
        other = ".github/workflows/other-policy.yml"
        hits = self.scan(self.original, other)
        self.assertEqual({hit["line"] for hit in hits}, set(PINNED_POSITIONS))
        self.assertEqual({hit["path"] for hit in hits}, {other})

    def test_identical_line_at_another_position_is_not_exempted(self) -> None:
        hits = self.scan(self.lines[PINNED_POSITIONS[0] - 1])
        self.assertTrue(any(hit["line"] == 1 for hit in hits))

    def test_changed_whitespace_and_line_endings_are_not_exempted(self) -> None:
        number = PINNED_POSITIONS[0]
        for replacement in (b" " + self.lines[number - 1],
                            self.lines[number - 1].replace(b"\n", b"\r\n")):
            with self.subTest(replacement=replacement):
                changed = list(self.lines)
                changed[number - 1] = replacement
                hits = self.scan(b"".join(changed))
                self.assertTrue(any(hit["line"] == number for hit in hits))

    def test_new_pattern_assignment_does_not_bypass_scanning(self) -> None:
        hits = self.scan(self.original + b"PATTERN='" + CREDIT.rstrip(b"\n") + b"'\n")
        self.assertTrue(any(hit["line"] == len(self.lines) + 1 for hit in hits))


if __name__ == "__main__":
    unittest.main()
