#!/bin/bash
set -euo pipefail
REPO="${1:-.}"
cd "$REPO"
DESIGN=.forge-qwen-remediation
STATE=.forge-qwen-state

python3 "$DESIGN/scripts/qwen_preflight.py" --repo . --skip-smoke >/dev/null
python3 "$DESIGN/scripts/prepare_qwen_task.py" --repo . >/dev/null
model="$(python3 -c 'import json; print(json.load(open(".forge-qwen-state/qwen-provider.json"))["model_id"])')"
mkdir -p "$STATE/qwen-reviews" "$STATE/qwen-invocations"
invocation="$(
  python3 - "$STATE/qwen-invocations" <<'PY'
from pathlib import Path
import re
import sys
values=[]
for path in Path(sys.argv[1]).glob("*-record.json"):
    match=re.match(r"(\d+)-", path.name)
    if match: values.append(int(match.group(1)))
print(max(values, default=0)+1)
PY
)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$STATE/qwen-reviews/$stamp.stdout.json"
err="$STATE/qwen-reviews/$stamp.stderr.txt"
before_source="$(python3 "$DESIGN/scripts/source_manifest.py" --repo . --digest-only)"
before_state="$(shasum -a 256 "$STATE/run-state.json" | awk '{print $1}')"
before_handoff="$(shasum -a 256 "$STATE/current-handoff.json" | awk '{print $1}')"
prompt='Review the current selected remediation slice using .forge-qwen-state/current-task.md, git diff, focused tests, and the authoritative contracts. Do not edit files. Report only source-proven blockers, regressions, and missing tests. This review is advisory and cannot pass gates.'
set +e
FORGE_QWEN_LOCAL_API_KEY="${FORGE_QWEN_LOCAL_API_KEY:-local-only}" \
QWEN_CODE_SUPPRESS_YOLO_WARNING=1 \
qwen -p "$prompt" \
  --model "$model" \
  --approval-mode plan \
  --output-format json \
  --json-schema "$(cat "$DESIGN/schemas/qwen-review.schema.json")" \
  --max-session-turns 8 \
  --max-wall-time 12m \
  --max-tool-calls 12 \
  --exclude-tools agent \
  --append-system-prompt "Read-only advisory review. Do not edit, publish, pass gates, close findings, ship, or add model/tool attribution." \
  >"$out" 2>"$err"
code=$?
set -e
python3 "$DESIGN/scripts/finalize_qwen_invocation.py" \
  --repo . \
  --stdout "$out" \
  --stderr "$err" \
  --exit-code "$code" \
  --invocation "$invocation" \
  --kind review \
  --before-source "$before_source" \
  --before-state "$before_state" \
  --before-handoff "$before_handoff" \
  >/dev/null || true
exit "$code"
