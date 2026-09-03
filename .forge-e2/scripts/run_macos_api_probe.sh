#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS host required" >&2
  exit 69
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="${TMPDIR:-/tmp}/forge-e2-api-probe.$$"
trap 'rm -f "$OUT"' EXIT

xcrun --sdk macosx clang \
  -Wall -Wextra -Werror \
  -mmacosx-version-min=26.0 \
  "$ROOT/scripts/macos_api_probe.c" \
  -o "$OUT"

"$OUT"
