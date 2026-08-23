#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-}"
MAX_INVOCATIONS="${FORGE_CODEX_MAX_INVOCATIONS:-100}"

if [[ -z "$REPO" ]]; then
  echo "Usage: run_codex_autonomously.sh /absolute/path/to/Forge-Conductor" >&2
  exit 64
fi
REPO="$(cd "$REPO" && pwd)"
command -v codex >/dev/null 2>&1 || { echo "codex CLI is unavailable; run the package from a Codex workspace instead" >&2; exit 69; }
[[ -f "$REPO/AGENTS.md" && -f "$REPO/.forge-codex/CODEX_EXECUTION_PROMPT.md" ]] || { echo "Package is not installed in $REPO" >&2; exit 66; }

HELP="$(codex exec --help 2>&1 || true)"
ARGS=()
if grep -q -- '--full-auto' <<<"$HELP"; then ARGS+=(--full-auto); fi
if grep -q -- '--cd' <<<"$HELP"; then ARGS+=(--cd "$REPO"); fi
if grep -q -- '--sandbox' <<<"$HELP"; then ARGS+=(--sandbox workspace-write); fi

"$REPO/.forge-codex/scripts/initialize_run.sh"

previous_hash=""
no_progress=0
for ((i=1;i<=MAX_INVOCATIONS;i++)); do
  status="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$REPO/.forge-codex/state/run-state.json")"
  if [[ "$status" == "complete" ]]; then
    "$REPO/.forge-codex/scripts/verify_completion.py" --repo "$REPO"
    exit 0
  fi
  if [[ "$status" == "fatal_invariant" ]]; then
    echo "Run stopped on a fatal integrity invariant. See run-state and handoff." >&2
    exit 70
  fi

  before="$(shasum -a 256 "$REPO/.forge-codex/state/run-state.json" | awk '{print $1}')"
  prompt="$(cat "$REPO/.forge-codex/CODEX_EXECUTION_PROMPT.md")"$'\n\n'"This is autonomous invocation $i. Read the persistent state and current handoff, execute the highest-priority ready work, persist evidence, and create a handoff before this invocation ends."

  (
    cd "$REPO"
    codex exec "${ARGS[@]}" "$prompt"
  ) || true

  after="$(shasum -a 256 "$REPO/.forge-codex/state/run-state.json" | awk '{print $1}')"
  if [[ "$before" == "$after" ]]; then
    no_progress=$((no_progress+1))
    "$REPO/.forge-codex/scripts/statectl.py" --repo "$REPO" attempt "AUTORUN-$i" no_progress --signature "$after"
  else
    no_progress=0
    "$REPO/.forge-codex/scripts/statectl.py" --repo "$REPO" attempt "AUTORUN-$i" progress
  fi

  "$REPO/.forge-codex/scripts/make_handoff.py" --repo "$REPO" --predecessor-session "codex-exec-$i"

  if (( no_progress >= 3 )); then
    "$REPO/.forge-codex/scripts/statectl.py" --repo "$REPO" event diagnostic_mode --payload '{"reason":"three autonomous invocations made no ledger progress"}'
    no_progress=0
  fi
done

echo "Bounded autonomous invocation limit reached without completion; state and handoff are preserved." >&2
exit 75
