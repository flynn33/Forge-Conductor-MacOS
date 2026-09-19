#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'repository hygiene check failed: %s\n' "$1" >&2
  exit 1
}

VERSION_VALUE="$(tr -d '[:space:]' < VERSION)"
BUILD_VALUE="$(tr -d '[:space:]' < BUILD_NUMBER)"

[[ "$VERSION_VALUE" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || fail "VERSION must use release.feature.patch"
[[ "$BUILD_VALUE" =~ ^[1-9][0-9]*$ ]] || fail "BUILD_NUMBER must be a positive integer"

VERSION_SOURCE="Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift"
SOURCE_VERSION="$(sed -n 's/^[[:space:]]*public static let productVersion = "\([^"]*\)"[[:space:]]*$/\1/p' "$VERSION_SOURCE")"
SOURCE_BUILD="$(sed -n 's/^[[:space:]]*public static let productBuildVersion = "\([^"]*\)"[[:space:]]*$/\1/p' "$VERSION_SOURCE")"
[[ "$SOURCE_VERSION" = "$VERSION_VALUE" ]] || fail "compiled productVersion differs from VERSION"
[[ "$SOURCE_BUILD" = "$BUILD_VALUE" ]] || fail "compiled productBuildVersion differs from BUILD_NUMBER"

PROJECT_FILE="ForgeConductor.xcodeproj/project.pbxproj"
MARKETING_COUNT="$(grep -c "MARKETING_VERSION = $VERSION_VALUE;" "$PROJECT_FILE")"
BUILD_COUNT="$(grep -c "CURRENT_PROJECT_VERSION = $BUILD_VALUE;" "$PROJECT_FILE")"
[[ "$MARKETING_COUNT" -eq 12 ]] || fail "expected 12 Xcode marketing-version settings, found $MARKETING_COUNT"
[[ "$BUILD_COUNT" -eq 16 ]] || fail "expected 16 Xcode build-number settings, found $BUILD_COUNT"

for document in README.md CHANGELOG.md ROADMAP.md USER-GUIDE.md XCODE.md docs/*.md docs/decisions/*.md; do
  [[ -f "$document" ]] || continue
  FIRST_CONTENT="$(awk 'NF { print; exit }' "$document")"
  [[ "$FIRST_CONTENT" = \#\ * ]] || fail "$document must start with one level-one heading"
  H1_COUNT="$(awk '
    /^```/ { in_code = !in_code; next }
    !in_code && /^# / { count += 1 }
    END { print count + 0 }
  ' "$document")"
  [[ "$H1_COUNT" -eq 1 ]] || fail "$document must contain exactly one level-one heading"
  LAST_BYTE="$(tail -c 1 "$document" | od -An -t u1 | tr -d '[:space:]')"
  [[ "$LAST_BYTE" = "10" ]] || fail "$document must end with a newline"
done

if git ls-files | grep -Eq '(^|/)(\.DS_Store|DerivedData|\.build)(/|$)|\.xcuserstate$'; then
  fail "generated build or user-state files are tracked"
fi

WHITESPACE_REPORT="$(mktemp -t forge-repository-hygiene.XXXXXX)"
trap 'rm -f "$WHITESPACE_REPORT"' EXIT
if git grep -I -n -E '[[:blank:]]+$' -- \
  Sources Tests script .github docs ForgeConductor.xcodeproj \
  Package.swift README.md CHANGELOG.md ROADMAP.md USER-GUIDE.md XCODE.md \
  AGENTS.md CODE_OF_CONDUCT.md CONTRIBUTING.md SECURITY.md >"$WHITESPACE_REPORT"; then
  sed -n '1,40p' "$WHITESPACE_REPORT" >&2
  fail "tracked text files contain trailing whitespace"
fi

printf 'Repository hygiene checks passed for version %s build %s.\n' \
  "$VERSION_VALUE" "$BUILD_VALUE"
