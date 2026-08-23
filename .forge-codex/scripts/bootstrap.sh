#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ARCHIVE="${PACKAGE_ROOT}/inputs/Forge-Conductor-MacOS-main.zip"
WORK_ROOT="${PACKAGE_ROOT}/work"
DESTINATION="${WORK_ROOT}/Forge-Conductor"

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap.sh [--source ARCHIVE] [--workspace DIRECTORY]

Extracts the included Forge Conductor source when needed, installs the autonomous
repair package into the repository, initializes the persistent run ledger, and
runs the environment doctor. Existing workspaces are preserved.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE_ARCHIVE="$2"; shift 2 ;;
    --workspace) DESTINATION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

mkdir -p "$(dirname "$DESTINATION")"

if [[ ! -d "$DESTINATION" ]]; then
  [[ -f "$SOURCE_ARCHIVE" ]] || { echo "Source archive not found: $SOURCE_ARCHIVE" >&2; exit 66; }
  command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; exit 69; }

  STAGING="$(mktemp -d "${TMPDIR:-/tmp}/forge-conductor-bootstrap.XXXXXX")"
  trap 'rm -rf "$STAGING"' EXIT
  unzip -q "$SOURCE_ARCHIVE" -d "$STAGING"

  REPO_CANDIDATE=""
  while IFS= read -r marker; do
    candidate="$(dirname "$marker")"
    if [[ "$marker" == *.xcodeproj/project.pbxproj ]]; then
      candidate="$(dirname "$(dirname "$marker")")"
    fi
    REPO_CANDIDATE="$candidate"
    break
  done < <(find "$STAGING" \( -name Package.swift -o -path '*/project.pbxproj' \) -print | sort)

  [[ -n "$REPO_CANDIDATE" ]] || { echo "Could not locate a Swift/Xcode repository in $SOURCE_ARCHIVE" >&2; exit 65; }
  mkdir -p "$DESTINATION"
  cp -a "${REPO_CANDIDATE}/." "$DESTINATION/"
fi

"${PACKAGE_ROOT}/scripts/install_into_repo.sh" "$DESTINATION"
(
  cd "$DESTINATION"
  ./.forge-codex/scripts/doctor.sh
  ./.forge-codex/scripts/statectl.py init
  ./.forge-codex/scripts/validate_package.py --root .forge-codex
)

printf 'Forge Conductor workspace prepared at: %s\n' "$DESTINATION"
printf 'Codex entry instructions: %s/AGENTS.md\n' "$DESTINATION"
