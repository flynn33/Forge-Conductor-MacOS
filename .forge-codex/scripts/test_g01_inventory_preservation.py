#!/usr/bin/env python3
"""Exercise G01 discovery without replacing historical or current authority."""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

from p10_feature_baseline import (
    EXPECTED_HISTORICAL_STATIC_FEATURE_COUNT,
    EXPECTED_HISTORICAL_STATIC_INVENTORY_SHA256,
    FEATURE_BASELINE_PATH,
    HISTORICAL_STATIC_INVENTORY_PATH,
)

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
CURRENT_DISCOVERY = '.forge-codex/state/gate-results/G01.current-static-inventory.json'


class G01InventoryPreservationTests(unittest.TestCase):
    def exercise_handler(self, relative):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            for path in (FEATURE_BASELINE_PATH, HISTORICAL_STATIC_INVENTORY_PATH, '.forge-codex/scripts/feature_inventory.py'):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(REPOSITORY / path, target)
            (root / '.forge-codex/scripts/feature_inventory.py').chmod(0o755)
            historical = (root / HISTORICAL_STATIC_INVENTORY_PATH).read_bytes()
            baseline = (root / FEATURE_BASELINE_PATH).read_bytes()
            self.assertEqual(hashlib.sha256(historical).hexdigest(), EXPECTED_HISTORICAL_STATIC_INVENTORY_SHA256)
            self.assertEqual(len(json.loads(historical)['features']), EXPECTED_HISTORICAL_STATIC_FEATURE_COUNT)
            self.assertIs(json.loads(baseline)['runtime_completion_required'], True)
            source = root / 'Sources/DiscoveryFixture.swift'
            source.parent.mkdir()
            source.write_text('import Foundation\nlet process = Process()\n')
            # These satisfy the other handler predicates only inside this fixture.
            fixtures = {
                'mcp-capabilities.json': {'captured_at': 'fixture', 'initialize_transcript_artifact': 'fixture', 'tools': ['fixture']},
                'persistence-inventory.json': {'captured_at': 'fixture', 'files_and_directories': ['fixture'], 'databases': ['fixture']},
                'characterization-tests.json': {'captured_at': 'fixture', 'tests': ['fixture'], 'affected_feature_coverage_complete': True},
            }
            for name, document in fixtures.items():
                path = root / '.forge-codex/state/baseline' / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(document))
            result = subprocess.run(
                ['/bin/bash', str(REPOSITORY / relative)], cwd=root,
                env={**os.environ, 'FORGE_GATE_REPOSITORY_ROOT': str(root), 'PYTHONDONTWRITEBYTECODE': '1'},
                capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertEqual((root / HISTORICAL_STATIC_INVENTORY_PATH).read_bytes(), historical)
            self.assertEqual((root / FEATURE_BASELINE_PATH).read_bytes(), baseline)
            discovery = json.loads((root / CURRENT_DISCOVERY).read_bytes())
            self.assertEqual(discovery['schema_version'], 1)
            self.assertIs(discovery['runtime_completion_required'], True)
            self.assertTrue(any(item['source']['path'] == 'Sources/DiscoveryFixture.swift' for item in discovery['features']))
            criteria = json.loads((root / '.forge-codex/state/gate-results/G01.criteria.json').read_bytes())['criteria_results']
            authority = json.loads((REPOSITORY / '.forge-codex/plans/gates.json').read_bytes())
            required = next(gate['criteria'] for gate in authority['gates'] if gate['id'] == 'G01')
            self.assertEqual([item['criterion'] for item in criteria], required)
            self.assertIs(criteria[0]['passed'], False)
            self.assertTrue(all(item['passed'] for item in criteria[1:]))
            self.assertEqual(criteria[0]['evidence'], [{'path': str(root / FEATURE_BASELINE_PATH), 'sha256': hashlib.sha256(baseline).hexdigest()}])

    def test_installed_handler_preserves_pinned_inventory_and_runtime_gate(self):
        self.exercise_handler('.forge-codex/state/gate-handlers/G01.sh')

    def test_template_handler_preserves_pinned_inventory_and_runtime_gate(self):
        self.exercise_handler('.forge-codex/templates/gate-handlers/G01.sh')


if __name__ == '__main__':
    unittest.main()
