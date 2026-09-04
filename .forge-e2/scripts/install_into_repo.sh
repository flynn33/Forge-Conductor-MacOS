#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/Forge-Conductor-MacOS" >&2
  exit 64
fi

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
REPO="$1"

if [[ ! -d "$REPO/.git" ]]; then
  echo "destination is not a Git checkout: $REPO" >&2
  exit 66
fi

REPO="$(cd "$REPO" && pwd -P)"
HEAD="$(git -C "$REPO" rev-parse --verify HEAD)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE="$REPO/.forge-e2.stage.$STAMP.$$"
TARGET="$REPO/.forge-e2"
BACKUP="$REPO/.forge-e2.backup.$STAMP"

cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

python3 "$SOURCE_DIR/scripts/validate_package.py"

mkdir -p "$STAGE"
(
  cd "$SOURCE_DIR"
  # The historical source archive is evidence only and is intentionally not copied
  # into the repository. The manifest validator permits exactly this omission.
  tar --exclude='./inputs/Forge-Conductor-MacOS-main.zip' -cf - .
) | (
  cd "$STAGE"
  tar -xf -
)

printf '%s\n' "$HEAD" > "$STAGE/INSTALLED_FROM_REPOSITORY_HEAD"
python3 "$STAGE/scripts/validate_package.py" \
  --root "$STAGE" \
  --allow-missing-input-archive

if [[ -e "$TARGET" ]]; then
  mv "$TARGET" "$BACKUP"
fi
mv "$STAGE" "$TARGET"
trap - EXIT

mkdir -p "$REPO/.forge-e2-state"
if [[ ! -f "$REPO/.forge-e2-state/run-state.json" ]]; then
  cp "$TARGET/work/state-template.json" "$REPO/.forge-e2-state/run-state.json"
fi

cat > "$REPO/.forge-e2-state/installation.json" <<EOF_JSON
{
  "schema_version": 1,
  "installed_at": "$STAMP",
  "repository_head": "$HEAD",
  "package_path": "$TARGET",
  "backup_path": "$BACKUP"
}
EOF_JSON

printf 'Installed E2 package into %s\n' "$TARGET"
printf 'Next: cd %q && ./.forge-e2/scripts/bootstrap.sh\n' "$REPO"
