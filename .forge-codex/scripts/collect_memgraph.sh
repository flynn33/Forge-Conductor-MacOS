#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROCESS="${1:-${FORGE_PROCESS_NAME:-Forge Conductor}}"
FLOW="${2:-manual}"
OUT_ROOT="${FORGE_EVIDENCE_ROOT:-$ROOT/.forge-codex/evidence/runtime}"
mkdir -p "$OUT_ROOT"

[[ "$(uname -s)" == "Darwin" ]] || { echo "memgraph capture requires macOS" >&2; exit 69; }
PID="$(pgrep -x "$PROCESS" | head -1 || true)"
[[ -n "$PID" ]] || { echo "Process not running: $PROCESS" >&2; exit 66; }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_ROOT/${STAMP}-${FLOW}.memgraph"
if command -v vmmap >/dev/null 2>&1; then
  vmmap --wide "$PID" > "$OUT_ROOT/${STAMP}-${FLOW}.vmmap.txt"
fi
if command -v leaks >/dev/null 2>&1; then
  leaks --outputGraph="$OUT" "$PID" > "$OUT_ROOT/${STAMP}-${FLOW}.leaks.txt" 2>&1 || true
else
  echo "leaks tool unavailable" >&2
  exit 69
fi
echo "$OUT"
