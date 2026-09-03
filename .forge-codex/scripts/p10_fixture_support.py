#!/usr/bin/env python3
"""Strict synthetic P10 authority used only by completion-control tests."""

from __future__ import annotations

from contextlib import contextmanager
import hashlib
import importlib.util
import json
import pathlib
import sys
from types import ModuleType
from typing import Iterator


FIXTURE_SENTINEL = "forge-p10-completion-fixture-v1"
FIXTURE_BASELINE_PATH = ".forge-codex/state/feature-baseline.json"
FIXTURE_BASELINE = {
    "schema_version": 1,
    "kind": "p10-completion-test-fixture",
    "sentinel": FIXTURE_SENTINEL,
    "runtime_completion_required": False,
    "parity_summary": {
        "preserved": 1,
        "additive": 0,
        "migrated": 0,
        "unknown": 0,
        "removed": 0,
        "untested": 0,
    },
    "features": [
        {
            "id": "FIXTURE-PRODUCTION-FEATURE",
            "parity_status": "preserved",
            "production_qualified": True,
            "sentinel": FIXTURE_SENTINEL,
        }
    ],
}


def canonical_json_sha256(value: object) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


FIXTURE_EVIDENCE_ID = canonical_json_sha256(
    {
        "kind": "p10-completion-test-evidence",
        "sentinel": FIXTURE_SENTINEL,
    }
)


_FIXTURE_EVALUATOR_SOURCE = f'''#!/usr/bin/env python3
"""Strict fixture-local P10 evaluator; never used by production repositories."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import pathlib
import re
from typing import Any

from evidence_support import (
    EvidenceSupportError,
    current_git_head as read_current_git_head,
    decode_strict_json_object,
    read_bounded_repository_bytes,
    source_manifest,
)


BASELINE_PATH = {FIXTURE_BASELINE_PATH!r}
EXPECTED_BASELINE = {FIXTURE_BASELINE!r}
EXPECTED_SENTINEL = {FIXTURE_SENTINEL!r}
EXPECTED_EVIDENCE_ID = {FIXTURE_EVIDENCE_ID!r}
MAXIMUM_BASELINE_BYTES = 64 * 1024
GIT_HEAD = re.compile(r"[0-9a-f]{{40}}")


@dataclass
class FixtureP10Evaluation:
    baseline: dict[str, Any]
    failures: list[str]
    binding: dict[str, Any]


def canonical_json_sha256(value: Any) -> str:
    raw = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def evaluate_p10_feature_evidence(
    repository: pathlib.Path,
    *,
    current_manifest: dict[str, Any],
    current_git_head: str,
    ledger_evidence_ids: set[str],
    expected_binding: Any | None = None,
) -> FixtureP10Evaluation:
    failures: list[str] = []
    baseline: dict[str, Any] = {{}}
    raw = b""
    try:
        repository = repository.resolve(strict=True)
        raw = read_bounded_repository_bytes(
            repository,
            BASELINE_PATH,
            label="fixture P10 baseline sentinel",
            maximum_bytes=MAXIMUM_BASELINE_BYTES,
            require_owner_controlled=True,
        )
        baseline = decode_strict_json_object(
            raw,
            label="fixture P10 baseline sentinel",
        )
    except (OSError, EvidenceSupportError) as error:
        failures.append(str(error))
    if baseline != EXPECTED_BASELINE:
        failures.append("fixture P10 baseline sentinel is not exact")

    observed_head = current_git_head if isinstance(current_git_head, str) else ""
    if GIT_HEAD.fullmatch(observed_head) is None:
        failures.append("fixture P10 Git HEAD is malformed")
    live_head = read_current_git_head(repository)
    if live_head != observed_head:
        failures.append("fixture P10 Git HEAD is stale")
    try:
        live_manifest = source_manifest(repository)
    except EvidenceSupportError as error:
        live_manifest = {{}}
        failures.append(str(error))
    if current_manifest != live_manifest:
        failures.append("fixture P10 source manifest is stale")
    if EXPECTED_EVIDENCE_ID not in ledger_evidence_ids:
        failures.append("fixture P10 evidence sentinel is absent from the ledger")

    baseline_binding = {{
        "path": BASELINE_PATH,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "bytes": len(raw),
    }}
    sentinel_row = {{
        "feature_id": "FIXTURE-PRODUCTION-FEATURE",
        "sentinel": EXPECTED_SENTINEL,
        "production_qualified": baseline == EXPECTED_BASELINE,
    }}
    payload = {{
        "schema_version": 1,
        "kind": "p10-feature-evidence-binding",
        "authority": "strict-synthetic-test-fixture-only",
        "source_identity": {{
            "git_head": observed_head,
            "source_manifest": current_manifest,
        }},
        "sentinel": {{
            **baseline_binding,
            "value": EXPECTED_SENTINEL,
            "semantic_row_sha256": canonical_json_sha256(sentinel_row),
        }},
        "ledger": {{
            "qualified_evidence_ids": [EXPECTED_EVIDENCE_ID],
            "qualified_evidence_ids_sha256": canonical_json_sha256(
                [EXPECTED_EVIDENCE_ID]
            ),
        }},
    }}
    binding = {{
        **payload,
        "binding_sha256": canonical_json_sha256(payload),
    }}
    if expected_binding is not None and expected_binding != binding:
        failures.append("fixture P10 sentinel binding changed after gate evaluation")
    return FixtureP10Evaluation(baseline, failures, binding)


def validate_p10_feature_binding(
    repository: pathlib.Path,
    binding: Any,
    *,
    current_manifest: dict[str, Any],
    current_git_head: str,
    ledger_evidence_ids: set[str],
) -> list[str]:
    return evaluate_p10_feature_evidence(
        repository,
        current_manifest=current_manifest,
        current_git_head=current_git_head,
        ledger_evidence_ids=ledger_evidence_ids,
        expected_binding=binding,
    ).failures
'''


def install_fixture_p10_evaluator(repository: pathlib.Path) -> pathlib.Path:
    scripts = repository / ".forge-codex/scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    path = scripts / "p10_feature_evidence.py"
    path.write_text(_FIXTURE_EVALUATOR_SOURCE, encoding="utf-8")
    path.chmod(0o755)
    return path


def fixture_python_command(
    repository: pathlib.Path,
    support_scripts: pathlib.Path,
    target: pathlib.Path,
    *arguments: str,
) -> list[str]:
    fixture_scripts = repository / ".forge-codex/scripts"
    wrapper = (
        "import importlib.util,runpy,sys;"
        "fixture=sys.argv.pop(1);support=sys.argv.pop(1);target=sys.argv.pop(1);"
        "sys.path.insert(0,support);"
        "spec=importlib.util.spec_from_file_location('p10_feature_evidence',"
        "fixture+'/p10_feature_evidence.py');"
        "module=importlib.util.module_from_spec(spec);"
        "sys.modules['p10_feature_evidence']=module;spec.loader.exec_module(module);"
        "sys.argv[0]=target;runpy.run_path(target,run_name='__main__')"
    )
    return [
        sys.executable,
        "-c",
        wrapper,
        str(fixture_scripts),
        str(support_scripts),
        str(target),
        *arguments,
    ]


@contextmanager
def fixture_p10_module(repository: pathlib.Path) -> Iterator[ModuleType]:
    path = repository / ".forge-codex/scripts/p10_feature_evidence.py"
    prior = sys.modules.get("p10_feature_evidence")
    spec = importlib.util.spec_from_file_location("p10_feature_evidence", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("fixture P10 evaluator cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules["p10_feature_evidence"] = module
    try:
        spec.loader.exec_module(module)
        yield module
    finally:
        if prior is None:
            sys.modules.pop("p10_feature_evidence", None)
        else:
            sys.modules["p10_feature_evidence"] = prior


def fixture_p10_binding(
    repository: pathlib.Path,
    *,
    current_manifest: dict[str, object],
    current_git_head: str,
    ledger_evidence_ids: set[str],
) -> dict[str, object]:
    with fixture_p10_module(repository) as module:
        evaluation = module.evaluate_p10_feature_evidence(
            repository,
            current_manifest=current_manifest,
            current_git_head=current_git_head,
            ledger_evidence_ids=ledger_evidence_ids,
        )
    if evaluation.failures:
        raise AssertionError("; ".join(evaluation.failures))
    return evaluation.binding
