#!/usr/bin/env python3
"""Revalidate one canonical CLI feature record without promoting the full matrix."""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

from evidence_support import BoundedReadBudget, EvidenceSupportError, current_git_head, decode_strict_json_object, source_manifest
import p10_feature_evidence as reader
import p10_native_cli_scenario as native
from p10_feature_baseline import EXPECTED_REGISTRY_SHA256, FEATURE_BASELINE_PATH, FEATURE_QUALIFICATION_SCHEMA_PATH, FEATURE_QUALIFIER_PATH, FEATURE_REGISTRY_PATH, PRODUCTION_PROBE_REGISTRY_PATH


def evaluate(repository: pathlib.Path, evidence_id: str) -> dict:
    repository = repository.resolve(strict=True)
    registry, registry_binding = native.load_json(repository, FEATURE_REGISTRY_PATH)
    native.require(registry_binding["sha256"] == EXPECTED_REGISTRY_SHA256, "selected CLI feature registry is not the pinned canonical authority")
    _, baseline_binding = native.load_json(repository, FEATURE_BASELINE_PATH)
    probes, probes_binding = native.load_json(repository, PRODUCTION_PROBE_REGISTRY_PATH)
    schema, _ = native.load_json(repository, FEATURE_QUALIFICATION_SCHEMA_PATH)
    qualifier_raw = (repository / FEATURE_QUALIFIER_PATH).read_bytes()
    features = {row["id"]: row for row in registry["features"]}
    failures, production_probes, missing = reader._validate_probe_registry(
        repository, probes, probe_registry_artifact=probes_binding,
        qualifier_artifact={"path": FEATURE_QUALIFIER_PATH, "sha256": hashlib.sha256(qualifier_raw).hexdigest(), "bytes": len(qualifier_raw)},
        registry_features=features, canonical_feature_registry=True,
    )
    # Coverage blockers remain explicit output. Only the already-reviewed CLI
    # feature is the acceptance scope of this command; no baseline is rewritten.
    expected_missing = sorted(assertion for row in features.values() if row["id"] != native.FEATURE_ID for assertion in row["required_assertions"])
    coverage_failures = {
        "P10 production scenarios do not execute signing qualification for every shipped artifact: signing.forge-conductor-app, signing.forge-filesystem-daemon, signing.forge-runtime-launcher",
        "P10 production probe registry has no concrete runner for 257 authoritative assertions",
    }
    if len(features) != 104 or len(expected_missing) != 257 or missing != expected_missing:
        failures.append("canonical CLI selection changed the full 104-feature/259-assertion requirement")
    failures = [item for item in failures if item not in coverage_failures]
    record, _ = native.record(repository, evidence_id, "p10-feature-production-qualification", exits={0})
    artifact_failures, artifacts, raw, report_path, observation_path = reader._validate_artifacts(repository, record, evidence_id=evidence_id, budget=BoundedReadBudget(reader.MAXIMUM_EVIDENCE_TOTAL_BYTES, "selected CLI evidence"))
    failures.extend(artifact_failures)
    stdout_path = f".forge-codex/evidence/{evidence_id}.stdout.txt"
    receipt_failures, receipts = reader._decode_probe_receipts(raw.get(stdout_path, b""), evidence_id=evidence_id)
    failures.extend(receipt_failures)
    observation_failures, observations = reader._decode_observation_aggregate(raw.get(observation_path, b""), evidence_id=evidence_id)
    failures.extend(observation_failures)
    report = decode_strict_json_object(raw.get(report_path, b""), label="selected canonical CLI report")
    failures.extend(reader._schema_failures(report, schema, label="selected canonical CLI report"))
    semantic_failures, rows = reader._validate_record_and_report(record, report, evidence_id=evidence_id, expected_features={native.FEATURE_ID}, registry_features=features, current_manifest=source_manifest(repository), current_git_head=current_git_head(repository), registry_sha256=registry_binding["sha256"], probe_registry_sha256=probes_binding["sha256"], qualifier_sha256=hashlib.sha256(qualifier_raw).hexdigest(), baseline_sha256=baseline_binding["sha256"], repository=repository, artifact_bindings=artifacts, qualification_report_path=report_path or "", stdout_artifact_path=stdout_path, observation_artifact_path=observation_path or "", production_probes=production_probes, probe_receipts=receipts, probe_observations=observations)
    failures.extend(semantic_failures)
    return {"schema_version": 1, "kind": "p10-selected-cli-revalidation", "evidence_id": evidence_id, "feature_id": native.FEATURE_ID, "accepted": not failures, "accepted_assertion_count": 2 if not failures else 0, "scope": native.SCOPE, "distribution_qualified": False, "full_matrix_complete": False, "full_required_assertion_count": 259, "missing_assertion_ids": missing, "failures": failures, "semantic_rows": rows}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=str(pathlib.Path(__file__).resolve().parents[2]))
    parser.add_argument("--evidence", required=True)
    args = parser.parse_args()
    try:
        result = evaluate(pathlib.Path(args.repo), args.evidence)
    except (EvidenceSupportError, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"accepted": False, "failures": [str(error)]}))
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["accepted"] else 1


if __name__ == "__main__":
    sys.exit(main())
