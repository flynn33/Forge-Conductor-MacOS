#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:-}"

if [[ -z "$REPO" ]]; then
  echo "Usage: ./scripts/install_into_repo.sh /absolute/path/to/repository" >&2
  exit 64
fi

REPO="$(cd "$REPO" && pwd)"
if [[ ! -f "$REPO/Package.swift" && -z "$(find "$REPO" \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) -print | sed -n '1p')" ]]; then
  echo "Target does not appear to be a Swift/Xcode repository: $REPO" >&2
  exit 65
fi

DEST="$REPO/.forge-codex"
mkdir -p "$DEST" "$DEST/state" "$DEST/evidence" "$DEST/backups"

for item in VERSION CODEX_EXECUTION_PROMPT.md docs architecture specifications schemas plans templates scripts audit evidence; do
  if [[ -e "$PACKAGE_ROOT/$item" ]]; then
    source_path="$PACKAGE_ROOT/$item"
    destination_path="$DEST/$item"
    if [[ "$(cd "$(dirname "$source_path")" && pwd)/$(basename "$source_path")" == "$(cd "$(dirname "$destination_path")" && pwd)/$(basename "$destination_path")" ]]; then
      continue
    fi
    rm -rf "$destination_path"
    cp -a "$source_path" "$destination_path"
  fi
done

chmod +x "$DEST/scripts/"*.sh "$DEST/scripts/"*.py 2>/dev/null || true

BEGIN_MARKER="<!-- FORGE-CONDUCTOR-AUTONOMOUS-CONTRACT:BEGIN -->"
END_MARKER="<!-- FORGE-CONDUCTOR-AUTONOMOUS-CONTRACT:END -->"
ROOT_AGENTS="$REPO/AGENTS.md"

if [[ ! -f "$ROOT_AGENTS" ]]; then
  {
    echo "$BEGIN_MARKER"
    cat "$PACKAGE_ROOT/AGENTS.md"
    echo "$END_MARKER"
  } > "$ROOT_AGENTS"
elif ! grep -Fq "$BEGIN_MARKER" "$ROOT_AGENTS"; then
  cp "$ROOT_AGENTS" "$DEST/backups/AGENTS.md.pre-forge"
  TMP="$(mktemp "${TMPDIR:-/tmp}/forge-agents.XXXXXX")"
  {
    echo "$BEGIN_MARKER"
    cat "$PACKAGE_ROOT/AGENTS.md"
    echo "$END_MARKER"
    echo
    echo "# Pre-existing repository instructions"
    cat "$ROOT_AGENTS"
  } > "$TMP"
  mv "$TMP" "$ROOT_AGENTS"
fi

if [[ -d "$PACKAGE_ROOT/codex-skills" ]]; then
  mkdir -p "$REPO/.agents/skills"
  for skill in "$PACKAGE_ROOT"/codex-skills/*; do
    [[ -d "$skill" ]] || continue
    target="$REPO/.agents/skills/$(basename "$skill")"
    rm -rf "$target"
    cp -a "$skill" "$target"
  done
fi

if [[ ! -f "$REPO/script/build_and_run.sh" ]]; then
  mkdir -p "$REPO/script"
  cp "$PACKAGE_ROOT/templates/build_and_run.sh" "$REPO/script/build_and_run.sh"
  chmod +x "$REPO/script/build_and_run.sh"
fi

(
  cd "$REPO"
  "$DEST/scripts/initialize_run.sh"
)

echo "Installed autonomous repair package into $DEST"
