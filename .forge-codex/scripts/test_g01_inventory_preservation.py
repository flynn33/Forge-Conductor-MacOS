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

from evidence_support import source_manifest
from p10_feature_baseline import (
    EXPECTED_HISTORICAL_STATIC_FEATURE_COUNT,
    EXPECTED_HISTORICAL_STATIC_INVENTORY_SHA256,
    FEATURE_BASELINE_PATH,
    FEATURE_REGISTRY_PATH,
    FEATURE_QUALIFICATION_SCHEMA_PATH,
    FEATURE_QUALIFIER_PATH,
    HISTORICAL_STATIC_INVENTORY_PATH,
    PRODUCTION_PROBE_REGISTRY_PATH,
)
from p10_feature_evidence import evaluate_p10_feature_evidence

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
CURRENT_DISCOVERY = '.forge-codex/state/gate-results/G01.current-static-inventory.json'


class G01InventoryPreservationTests(unittest.TestCase):
    def exercise_handler(self, relative, mutation=None, expected_valid=True):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            for path in (
                FEATURE_BASELINE_PATH, HISTORICAL_STATIC_INVENTORY_PATH,
                FEATURE_REGISTRY_PATH, FEATURE_QUALIFICATION_SCHEMA_PATH,
                FEATURE_QUALIFIER_PATH, PRODUCTION_PROBE_REGISTRY_PATH,
                '.forge-codex/scripts/feature_inventory.py',
                '.forge-codex/scripts/evidence_support.py',
                '.forge-codex/scripts/p10_feature_baseline.py',
            ):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(REPOSITORY / path, target)
            (root / '.forge-codex/scripts/feature_inventory.py').chmod(0o755)
            historical = (root / HISTORICAL_STATIC_INVENTORY_PATH).read_bytes()
            baseline_document = json.loads((root / FEATURE_BASELINE_PATH).read_bytes())
            self.assertEqual(hashlib.sha256(historical).hexdigest(), EXPECTED_HISTORICAL_STATIC_INVENTORY_SHA256)
            self.assertEqual(len(json.loads(historical)['features']), EXPECTED_HISTORICAL_STATIC_FEATURE_COUNT)
            self.assertIs(baseline_document['runtime_completion_required'], True)
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
            baseline_document['source_snapshot']['manifest'] = source_manifest(
                root, excluded_paths=(FEATURE_BASELINE_PATH,),
            )
            if mutation:
                mutation(baseline_document)
            (root / FEATURE_BASELINE_PATH).write_text(json.dumps(baseline_document))
            baseline = (root / FEATURE_BASELINE_PATH).read_bytes()
            result = subprocess.run(
                ['/bin/bash', str(REPOSITORY / relative)], cwd=root,
                env={**os.environ, 'FORGE_GATE_REPOSITORY_ROOT': str(root), 'PYTHONDONTWRITEBYTECODE': '1'},
                capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(result.returncode, 0 if expected_valid else 1, result.stdout + result.stderr)
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
            self.assertIs(criteria[0]['passed'], expected_valid)
            self.assertTrue(all(item['passed'] for item in criteria[1:]))
            self.assertEqual(criteria[0]['evidence'], [{'path': str(root / FEATURE_BASELINE_PATH), 'sha256': hashlib.sha256(baseline).hexdigest()}])
            if expected_valid:
                # Inventory acceptance must not qualify this fixture at P10.
                evaluation = evaluate_p10_feature_evidence(
                    root, current_manifest=source_manifest(root),
                    current_git_head='a' * 40, ledger_evidence_ids=set(),
                )
                self.assertEqual(evaluation.baseline_evaluation.inventory_failures, [])
                self.assertEqual(evaluation.baseline_evaluation.feature_count, 104)
                self.assertIn('baseline requires outstanding runtime completion evidence', evaluation.failures)
                self.assertTrue(any('104 features without exact-current production qualification' in failure for failure in evaluation.failures))
                self.assertEqual(sum(len(feature['required_assertions']) for feature in evaluation.baseline_evaluation.registry_features.values()), 259)
                self.assertFalse(evaluation.baseline_evaluation.qualification_evidence_references)
                self.assertFalse(baseline_document['operability_summary']['release_ready'])

    def test_installed_handler_preserves_pinned_inventory_and_runtime_gate(self):
        self.exercise_handler('.forge-codex/state/gate-handlers/G01.sh')

    def test_template_handler_preserves_pinned_inventory_and_runtime_gate(self):
        self.exercise_handler('.forge-codex/templates/gate-handlers/G01.sh')

    def test_malformed_canonical_baselines_fail_inventory(self):
        mutations = {
            'schema': lambda d: d.update(schema_version=1),
            'runtime_boolean': lambda d: d.update(runtime_completion_required='true'),
            'missing_feature': lambda d: d['features'].pop(),
            'duplicate_feature': lambda d: d['features'].__setitem__(1, d['features'][0]),
            'unknown_parity': lambda d: d['features'][0].update(parity_status='unknown'),
            'empty_evidence': lambda d: d['features'][0].update(evidence=[]),
            'stale_snapshot': lambda d: d['source_snapshot']['manifest'].update(sha256='0' * 64),
            'stale_registry': lambda d: d['authoritative_registry'].update(sha256='0' * 64),
            'false_ready': lambda d: d['operability_summary'].update(release_ready=True),
        }
        for relative in ('.forge-codex/state/gate-handlers/G01.sh', '.forge-codex/templates/gate-handlers/G01.sh'):
            for name, mutation in mutations.items():
                with self.subTest(handler=relative, mutation=name):
                    self.exercise_handler(relative, mutation, expected_valid=False)


if __name__ == '__main__':
    unittest.main()
