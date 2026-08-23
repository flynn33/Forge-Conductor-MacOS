#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:---list}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS runtime profiling requires Darwin" >&2
  exit 69
fi
command -v xcrun >/dev/null || { echo "xcrun unavailable" >&2; exit 69; }

if [[ "$MODE" == "--list" ]]; then
  xcrun xctrace list templates
  exit 0
fi

FLOW=""
APP=""
DURATION=30
OUTPUT_ROOT="${FORGE_EVIDENCE_ROOT:-$ROOT/.forge-codex/evidence/runtime}"
TEMPLATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flow) FLOW="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --output-root) OUTPUT_ROOT="$2"; shift 2 ;;
    --capture) shift ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$FLOW" && -n "$APP" ]] || {
  echo "Usage: profile_macos.sh --capture --flow FLOW-ID --app /path/to/App.app [--duration seconds] [--template name]" >&2
  exit 64
}
[[ -d "$APP" ]] || { echo "App bundle not found: $APP" >&2; exit 66; }

mkdir -p "$OUTPUT_ROOT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SAFE_FLOW="$(printf '%s' "$FLOW" | tr -c 'A-Za-z0-9._-' '_')"

select_template() {
  local desired="$1"
  xcrun xctrace list templates 2>/dev/null | sed -n "s/^[[:space:]]*${desired}[[:space:]]*$/${desired}/p" | head -1
}

if [[ -z "$TEMPLATE" ]]; then
  case "$FLOW" in
    *GAUGE*) TEMPLATE="$(select_template "Metal System Trace")" ;;
    *TELEMETRY*|*PROJECT*|*PROCESS*|*MEMORY*) TEMPLATE="$(select_template "Allocations")" ;;
    *ROLLOVER*) TEMPLATE="$(select_template "Time Profiler")" ;;
  esac
fi
[[ -n "$TEMPLATE" ]] || TEMPLATE="$(xcrun xctrace list templates 2>/dev/null | sed -n 's/^[[:space:]]*\([^[:space:]].*\)$/\1/p' | grep -E 'Time Profiler|Allocations' | head -1)"
[[ -n "$TEMPLATE" ]] || { echo "No supported xctrace template discovered" >&2; exit 69; }

EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
BINARY="$APP/Contents/MacOS/$EXECUTABLE"
OUT="$OUTPUT_ROOT/${STAMP}-${SAFE_FLOW}-$(printf '%s' "$TEMPLATE" | tr ' /' '__').trace"

# The flow driver must be deterministic and supplied as an executable handler.
DRIVER="$ROOT/.forge-codex/state/flow-handlers/${FLOW}.sh"
if [[ ! -x "$DRIVER" ]]; then
  echo "Missing executable deterministic flow handler: $DRIVER" >&2
  exit 66
fi

PREEXISTING_PIDS=" $(pgrep -x "$EXECUTABLE" 2>/dev/null | tr '\n' ' ' || true)"
LAUNCHED_PID=""

cleanup_launched_process() {
  [[ -n "$LAUNCHED_PID" ]] || return 0
  if kill -0 "$LAUNCHED_PID" 2>/dev/null; then
    kill "$LAUNCHED_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$LAUNCHED_PID" 2>/dev/null || return 0
      sleep 0.2
    done
    kill -9 "$LAUNCHED_PID" 2>/dev/null || true
  fi
}
trap cleanup_launched_process EXIT INT TERM

open -n "$APP"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  for CANDIDATE in $(pgrep -x "$EXECUTABLE" 2>/dev/null || true); do
    if [[ "$PREEXISTING_PIDS" != *" $CANDIDATE "* ]]; then
      LAUNCHED_PID="$CANDIDATE"
      break 2
    fi
  done
  sleep 0.2
done
[[ -n "$LAUNCHED_PID" ]] || { echo "Unable to identify launched process" >&2; exit 70; }
sleep 2
"$DRIVER" --prepare

xcrun xctrace record \
  --template "$TEMPLATE" \
  --time-limit "${DURATION}s" \
  --output "$OUT" \
  --attach "$LAUNCHED_PID" &
TRACE_PID=$!

"$DRIVER" --execute
wait "$TRACE_PID"
"$DRIVER" --cleanup
cleanup_launched_process
trap - EXIT INT TERM

echo "$OUT"
