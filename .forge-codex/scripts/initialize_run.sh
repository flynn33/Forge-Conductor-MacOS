#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG="$ROOT/.forge-codex"

mkdir -p "$PKG/state/gate-handlers" "$PKG/state/gate-results" "$PKG/state/flow-handlers" "$PKG/evidence"

mkdir -p "$PKG/state/acceptance" "$PKG/state/baseline"
for file in findings-resolution.json host-capability-report.json decisions.md; do
  if [[ -f "$PKG/templates/$file" && ! -f "$PKG/state/$file" ]]; then
    cp "$PKG/templates/$file" "$PKG/state/$file"
  fi
done
if [[ -d "$PKG/templates/acceptance" ]]; then
  for file in "$PKG"/templates/acceptance/*.json; do
    [[ -e "$file" ]] || continue
    target="$PKG/state/acceptance/$(basename "$file")"
    [[ -e "$target" ]] || cp "$file" "$target"
  done
fi
if [[ -d "$PKG/templates/baseline" ]]; then
  for file in "$PKG"/templates/baseline/*.json; do
    [[ -e "$file" ]] || continue
    target="$PKG/state/baseline/$(basename "$file")"
    [[ -e "$target" ]] || cp "$file" "$target"
  done
fi
if [[ -d "$PKG/templates/gate-handlers" ]]; then
  for handler in "$PKG"/templates/gate-handlers/*.sh; do
    [[ -e "$handler" ]] || continue
    target="$PKG/state/gate-handlers/$(basename "$handler")"
    [[ -e "$target" ]] || cp "$handler" "$target"
    chmod +x "$target"
  done
fi

"$PKG/scripts/statectl.py" --repo "$ROOT" init
"$PKG/scripts/doctor.sh"
python3 "$PKG/scripts/test_p10_feature_baseline.py"
"$PKG/scripts/source_risk_scan.py" --repo "$ROOT"
"$PKG/scripts/statectl.py" --repo "$ROOT" validate
