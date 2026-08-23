#!/usr/bin/env bash
set -euo pipefail

PROCESS_NAME="Forge Conductor"

case "${1:-}" in
  --prepare)
    pgrep -x "$PROCESS_NAME" >/dev/null
    ;;
  --execute)
    for _ in {1..12}; do
      pgrep -x "$PROCESS_NAME" >/dev/null
      sleep 1
    done
    ;;
  --cleanup)
    pgrep -x "$PROCESS_NAME" >/dev/null
    ;;
  *)
    echo "Expected --prepare, --execute, or --cleanup" >&2
    exit 64
    ;;
esac
