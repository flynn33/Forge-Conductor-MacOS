#!/bin/bash
set -euo pipefail

REPO="${1:-.}"
MAX_INVOCATIONS="${MAX_INVOCATIONS:-160}"
NO_PROGRESS_LIMIT="${NO_PROGRESS_LIMIT:-3}"

cd "$REPO"
DESIGN=.forge-qwen-remediation
STATE=.forge-qwen-state

if [[ ! -d "$DESIGN" || ! -f "$DESIGN/QWEN-START-HERE.md" ]]; then
  echo "Qwen remediation package is not installed in this repository" >&2
  exit 66
fi

mkdir -p \
  "$STATE/qwen-invocations" \
  "$STATE/qwen-plans" \
  "$STATE/qwen-reviews"

python3 "$DESIGN/scripts/qwen_preflight.py" --repo .
export FORGE_QWEN_LOCAL_API_KEY="${FORGE_QWEN_LOCAL_API_KEY:-local-only}"
export QWEN_CODE_SUPPRESS_YOLO_WARNING=1

start_invocation="$(
  python3 - "$STATE/qwen-invocations" <<'PY_START'
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
numbers = []
for path in root.glob("*-record.json"):
    match = re.match(r"(\d+)-", path.name)
    if match:
        numbers.append(int(match.group(1)))
print(max(numbers, default=0) + 1)
PY_START
)"

no_progress=0
last_progress_fingerprint=""

for ((offset=0; offset<MAX_INVOCATIONS; offset++)); do
  invocation=$((start_invocation + offset))

  if python3 "$DESIGN/scripts/verify_completion.py" --repo . >/dev/null 2>&1; then
    echo "Forge Conductor is locally ready to ship and remains unshipped."
    exit 0
  fi

  python3 "$DESIGN/scripts/doctor.py" --repo . >/dev/null
  selector_output="$STATE/selected-work.raw.json"
  if ! python3 "$DESIGN/scripts/select_next_work.py" \
      --repo . >"$selector_output"; then
    python3 "$DESIGN/scripts/statectl.py" \
      --repo . \
      handoff \
      --summary "No ready work package was selected; release completion is not proven." \
      --next "Inspect dependency, gate, and blocked-work state; reconcile the earliest unresolved package without bypassing gates." \
      >/dev/null
    exit 75
  fi

  python3 - "$selector_output" "$STATE/selected-work.json" <<'PY_SELECT'
import json
import sys
from pathlib import Path
source = Path(sys.argv[1])
destination = Path(sys.argv[2])
value = json.loads(source.read_text())
destination.write_text(json.dumps(value, indent=2) + "\n")
PY_SELECT

  python3 "$DESIGN/scripts/prepare_qwen_task.py" --repo . >/dev/null

  model="$(
    python3 -c 'import json; print(json.load(open(".forge-qwen-state/qwen-provider.json"))["model_id"])'
  )"
  tools="$(
    python3 -c 'import json; print(json.load(open(".forge-qwen-state/qwen-provider.json"))["max_tool_calls"])'
  )"
  turns="$(
    python3 -c 'import json; print(json.load(open(".forge-qwen-state/qwen-provider.json"))["max_session_turns"])'
  )"
  before_source="$(
    python3 "$DESIGN/scripts/source_manifest.py" --repo . --digest-only
  )"
  before_progress="$(
    python3 "$DESIGN/scripts/state_progress_fingerprint.py" --repo .
  )"
  before_state="$(
    shasum -a 256 "$STATE/run-state.json" | awk '{print $1}'
  )"
  before_handoff="$(
    shasum -a 256 "$STATE/current-handoff.json" | awk '{print $1}'
  )"
  work_package="$(
    python3 -c 'import json; d=json.load(open(".forge-qwen-state/selected-work.json")); print((d.get("work_package") or d.get("selected") or {})["id"])'
  )"
  plan="$STATE/qwen-plans/${work_package}-${before_source:0:16}-${before_handoff:0:16}.json"

  # Each slice receives a fresh read-only planning session.
  plan_out="$STATE/qwen-invocations/$(printf '%04d' "$invocation")-plan.stdout.json"
  plan_err="$STATE/qwen-invocations/$(printf '%04d' "$invocation")-plan.stderr.txt"
  plan_prompt="Read .forge-qwen-state/current-task.md, its work-package card, the current handoff, and only the exact referenced evidence and source. Produce a narrow plan for one coherent implementation slice. Do not edit files or run mutating commands. Normally limit the slice to six production files plus focused tests. If a wider atomic change is required, justify it explicitly."
  set +e
  qwen -p "$plan_prompt" \
    --model "$model" \
    --approval-mode plan \
    --output-format json \
    --json-schema "$(cat "$DESIGN/schemas/qwen-slice-plan.schema.json")" \
    --max-session-turns 8 \
    --max-wall-time 12m \
    --max-tool-calls 12 \
    --exclude-tools agent \
    >"$plan_out" 2>"$plan_err"
  plan_code=$?
  set -e

  python3 "$DESIGN/scripts/finalize_qwen_invocation.py" \
    --repo . \
    --stdout "$plan_out" \
    --stderr "$plan_err" \
    --exit-code "$plan_code" \
    --invocation "$invocation" \
    --kind plan \
    --before-source "$before_source" \
    --before-state "$before_state" \
    --before-handoff "$before_handoff" \
    >/dev/null || true

  plan_normalized="$plan.normalized.json"
  rm -f "$plan" "$plan_normalized"
  if python3 "$DESIGN/scripts/extract_qwen_structured.py" \
      "$plan_out" --output "$plan_normalized"; then
    python3 - "$plan_normalized" "$plan" "$work_package" <<'PY_PLAN'
import json
import sys
from pathlib import Path
source = Path(sys.argv[1])
destination = Path(sys.argv[2])
expected = sys.argv[3]
value = json.loads(source.read_text()).get("structured")
if isinstance(value, dict) and value.get("work_package_id") == expected:
    destination.write_text(json.dumps(value, indent=2) + "\n")
PY_PLAN
  fi

  if [[ "$plan_code" -ne 0 || ! -s "$plan" ]]; then
    python3 "$DESIGN/scripts/statectl.py" \
      --repo . \
      handoff \
      --summary "The bounded Qwen planning session failed or did not produce a schema-valid plan for ${work_package}." \
      --next "Inspect the preserved plan stdout/stderr, narrow the evidence set, and retry in a fresh read-only session." \
      >/dev/null
    no_progress=$((no_progress + 1))
    if (( no_progress >= NO_PROGRESS_LIMIT )); then
      exit 75
    fi
    continue
  fi

  out="$STATE/qwen-invocations/$(printf '%04d' "$invocation")-implement.stdout.json"
  err="$STATE/qwen-invocations/$(printf '%04d' "$invocation")-implement.stderr.txt"
  prompt="Execute exactly one coherent slice from .forge-qwen-state/current-task.md and ${plan}. Inspect source before editing. Preserve every current feature, shell_exec compatibility, project isolation, canonical continuity, resource bounds, and the do-not-ship boundary. Run the smallest relevant tests and debug failures. Record command evidence with package scripts. Update the durable handoff before exit. Return the required structured report. Never claim a gate passed; only its registered validator may do that."
  if (( no_progress > 0 )); then
    prompt+=" Earlier bounded slices made no authoritative progress. Do not repeat the same command sequence. Isolate a deterministic reproducer or choose a different reversible design consistent with the contracts."
  fi

  set +e
  qwen -p "$prompt" \
    --model "$model" \
    --approval-mode yolo \
    --output-format json \
    --json-schema "$(cat "$DESIGN/schemas/qwen-invocation-result.schema.json")" \
    --max-session-turns "$turns" \
    --max-wall-time 45m \
    --max-tool-calls "$tools" \
    --exclude-tools agent \
    --append-system-prompt "Bounded local remediation slice. Model output is not validation evidence. Do not publish, push, merge, tag, upload, submit, notarize for distribution, ship, or add model/tool attribution." \
    >"$out" 2>"$err"
  code=$?
  set -e

  python3 "$DESIGN/scripts/finalize_qwen_invocation.py" \
    --repo . \
    --stdout "$out" \
    --stderr "$err" \
    --exit-code "$code" \
    --invocation "$invocation" \
    --kind implement \
    --before-source "$before_source" \
    --before-state "$before_state" \
    --before-handoff "$before_handoff" \
    >/dev/null || true

  after_source="$(
    python3 "$DESIGN/scripts/source_manifest.py" --repo . --digest-only
  )"
  after_progress="$(
    python3 "$DESIGN/scripts/state_progress_fingerprint.py" --repo .
  )"
  progress_fingerprint="$after_source:$after_progress"

  if [[ "$before_source:$before_progress" == "$progress_fingerprint" \
        || "$progress_fingerprint" == "$last_progress_fingerprint" ]]; then
    no_progress=$((no_progress + 1))
  else
    no_progress=0
  fi
  last_progress_fingerprint="$progress_fingerprint"

  if (( no_progress >= NO_PROGRESS_LIMIT )); then
    python3 "$DESIGN/scripts/statectl.py" \
      --repo . \
      handoff \
      --summary "The bounded Qwen driver detected three slices without product-source or authoritative-ledger progress. No completion claim was accepted." \
      --next "Discard the prior strategy, isolate the smallest deterministic reproducer, inspect ownership and durable state, and choose a reversible alternate implementation." \
      >/dev/null
    rm -f "$plan"
    no_progress=1
  fi
done

echo "Bounded Qwen invocation limit reached. Durable state and handoff are preserved; no shipping action occurred." >&2
exit 75
