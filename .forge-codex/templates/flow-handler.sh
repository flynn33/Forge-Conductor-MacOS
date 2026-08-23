#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-}"
case "$MODE" in
  --prepare)
    # Reset the app/fixture to a deterministic precondition.
    ;;
  --execute)
    # Drive the exact semantic flow through accessibility identifiers, test hooks,
    # or an in-app deterministic debug harness. Do not use pixel coordinates.
    ;;
  --cleanup)
    # End at the defined release/quiescence boundary and preserve evidence.
    ;;
  *)
    echo "Expected --prepare, --execute, or --cleanup" >&2
    exit 64
    ;;
esac
