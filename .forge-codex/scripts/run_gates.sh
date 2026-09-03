#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:---ready}"
STATE="$ROOT/.forge-codex/state/run-state.json"
PLAN="$ROOT/.forge-codex/plans/phases.json"

[[ -f "$STATE" ]] || "$ROOT/.forge-codex/scripts/statectl.py" init >/dev/null

if ! GATE_LIST="$(python3 - "$ROOT" "$MODE" <<'PY'
import pathlib
import re
import sys

repository = pathlib.Path(sys.argv[1]).resolve(strict=True)
sys.path.insert(0, str(repository / ".forge-codex/scripts"))

try:
    from evidence_support import (
        BoundedReadBudget,
        EvidenceSupportError,
        current_git_head,
        load_bounded_repository_json_object,
        source_manifest,
    )
except Exception as error:
    raise SystemExit(f"cannot load bounded gate control reader: {error}")

maximum_file_bytes = 1024 * 1024
budget = BoundedReadBudget(64 * 1024 * 1024, "gate control input")
mode = sys.argv[2]
gate_identifier = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
current_source_head = current_git_head(repository)
if current_source_head is None:
    raise SystemExit("current Git HEAD is unavailable or invalid")
current_source_manifest = source_manifest(repository)


def has_matching_pass(gate, state_item):
    if not isinstance(state_item, dict) or state_item.get("status") != "passed":
        return False
    operation_id = state_item.get("operation_id")
    if not isinstance(operation_id, str) or not operation_id:
        return False
    try:
        result = load_bounded_repository_json_object(
            repository,
            f".forge-codex/state/gate-results/{gate}.json",
            label=f"{gate} gate result",
            maximum_bytes=maximum_file_bytes,
            budget=budget,
            require_owner_controlled=True,
        )
    except EvidenceSupportError:
        return False
    return (
        result.get("gate_id") == gate
        and result.get("status") == "passed"
        and result.get("operation_id") == operation_id
        and result.get("finalized") is True
        and result.get("source_head") == current_source_head
        and result.get("source_manifest") == current_source_manifest
    )

try:
    state = load_bounded_repository_json_object(
        repository,
        ".forge-codex/state/run-state.json",
        label="run-state control input",
        maximum_bytes=maximum_file_bytes,
        budget=budget,
    )
    plan = load_bounded_repository_json_object(
        repository,
        ".forge-codex/plans/phases.json",
        label="phases plan control input",
        maximum_bytes=maximum_file_bytes,
        budget=budget,
    )
    passed = {
        phase_id
        for phase_id, value in state["phases"].items()
        if value["status"] == "passed"
    }
    selected = []
    for phase in sorted(
        plan["phases"],
        key=lambda value: (-value["priority"], value["id"]),
    ):
        if mode == "--all" or all(
            dependency in passed for dependency in phase["dependencies"]
        ):
            for gate in phase["hard_gates"]:
                if not isinstance(gate, str) or gate_identifier.fullmatch(gate) is None:
                    raise ValueError(f"invalid gate identifier in phase plan: {gate!r}")
                if mode == "--all" or not has_matching_pass(
                    gate,
                    state["gates"][gate],
                ):
                    selected.append(gate)
except (EvidenceSupportError, KeyError, TypeError, ValueError, AttributeError) as error:
    raise SystemExit(f"cannot select gates from bounded control inputs: {error}")

for gate in selected:
    print(gate)
PY
)"; then
  exit 1
fi

failures=0
while IFS= read -r gate; do
  [[ -n "$gate" ]] || continue
  "$ROOT/.forge-codex/scripts/run_gate.py" --repo "$ROOT" -- "$gate" || failures=1
done <<EOF
$GATE_LIST
EOF
exit "$failures"
