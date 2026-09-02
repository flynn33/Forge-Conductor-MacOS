#!/usr/bin/env python3
"""Focused regressions for the project-memory process conformance fixture."""

from __future__ import annotations

import json
import pathlib
import stat
import tempfile
import unittest

from check_p07_project_memory import (
    CONFIG_SCHEMA_VERSION,
    PROJECT_MEMORY_CAPABILITY_VERSION,
    PROJECT_MEMORY_SCHEMA_VERSION,
    configure_allowed_roots,
    validate_project_memory_capability,
    validate_project_memory_scope,
)


class ProjectMemoryConformanceFixtureTests(unittest.TestCase):
    def test_trusted_root_config_is_schema_v2_canonical_and_private(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            home = root / "home"
            project = root / "project"
            project.mkdir()

            configure_allowed_roots(home, [project])

            config_path = home / "config.json"
            config = json.loads(config_path.read_text(encoding="utf-8"))
            self.assertEqual(config["config_schema_version"], CONFIG_SCHEMA_VERSION)
            self.assertEqual(config["allowed_roots"], [str(project.resolve())])
            self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)

    def test_trusted_root_config_rejects_invalid_fixture_policy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            home = root / "home"
            project = root / "project"
            project.mkdir()
            regular_file = root / "not-a-directory"
            regular_file.write_text("fixture\n", encoding="utf-8")

            with self.assertRaisesRegex(AssertionError, "at least one"):
                configure_allowed_roots(home, [])
            with self.assertRaisesRegex(AssertionError, "duplicates"):
                configure_allowed_roots(home, [project, project])
            with self.assertRaisesRegex(AssertionError, "directories"):
                configure_allowed_roots(home, [regular_file])

    def test_project_memory_capability_requires_schema_v2(self) -> None:
        capability = {
            "projectMemory": {
                "capabilityVersion": PROJECT_MEMORY_CAPABILITY_VERSION,
                "schemaVersion": PROJECT_MEMORY_SCHEMA_VERSION,
                "limits": {"page_count": 100},
            },
        }
        self.assertEqual(
            validate_project_memory_capability(capability)["schemaVersion"],
            PROJECT_MEMORY_SCHEMA_VERSION,
        )

        stale = json.loads(json.dumps(capability))
        stale["projectMemory"]["schemaVersion"] = 1
        with self.assertRaisesRegex(AssertionError, "schema version"):
            validate_project_memory_capability(stale)

    def test_project_memory_scope_requires_schema_v2(self) -> None:
        scope = {
            "ok": True,
            "capability_version": PROJECT_MEMORY_CAPABILITY_VERSION,
            "schema_version": PROJECT_MEMORY_SCHEMA_VERSION,
        }
        self.assertIs(validate_project_memory_scope(scope), scope)

        stale = dict(scope, schema_version=1)
        with self.assertRaisesRegex(AssertionError, "schema version"):
            validate_project_memory_scope(stale)


if __name__ == "__main__":
    unittest.main()
