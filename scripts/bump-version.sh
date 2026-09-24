#!/usr/bin/env bash
# Bump the app version and write the release notes that go with it.
#
# Versions live only in Config/Version.xcconfig: MARKETING_VERSION (public, the git tag)
# and CURRENT_PROJECT_VERSION (the build number, which only ever goes up: TestFlight
# rejects a reused one). The same text goes to fastlane/changelogs/<build>.txt (history)
# and fastlane/metadata/en-US/release_notes.txt (what TestFlight and the App Store show).
# CI (changelog-files) fails when they are missing or differ.
#
# Usage:
#   scripts/bump-version.sh 0.2.0 "One or two sentences about what changed."
#   scripts/bump-version.sh 0.2.0 < notes.txt
#
# Leaves everything staged-but-uncommitted so the diff can be read before committing.
set -euo pipefail

cd "$(dirname "$0")/.."

CFG="Config/Version.xcconfig"
CHANGELOG_DIR="fastlane/changelogs"
RELEASE_NOTES="fastlane/metadata/en-US/release_notes.txt"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version> [release notes]" >&2
    exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: '$VERSION' is not a three-part version like 0.2.0" >&2
    exit 2
fi

if [[ $# -ge 2 ]]; then
    TEXT="$2"
else
    TEXT="$(cat)"
fi
TEXT="$(printf '%s' "$TEXT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ -z "$TEXT" ]]; then
    echo "error: no release notes given" >&2
    exit 2
fi
if [[ ${#TEXT} -gt 4000 ]]; then
    echo "error: release notes are ${#TEXT} characters; the App Store allows 4000." >&2
    exit 2
fi
if [[ ${#TEXT} -gt 500 ]]; then
    echo "warning: release notes are ${#TEXT} characters; keep them under about 500." >&2
fi

CURRENT_NAME="$(grep -oE '^MARKETING_VERSION[[:space:]]*=[[:space:]]*[0-9.]+' "$CFG" | grep -oE '[0-9.]+$')"
CURRENT_BUILD="$(grep -oE '^CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*[0-9]+' "$CFG" | grep -oE '[0-9]+$')"
if [[ -z "$CURRENT_NAME" || -z "$CURRENT_BUILD" ]]; then
    echo "error: could not read the current version from $CFG (both values must be literal)." >&2
    exit 1
fi

NEW_BUILD=$((CURRENT_BUILD + 1))
echo "  $CURRENT_NAME ($CURRENT_BUILD)  ->  $VERSION ($NEW_BUILD)"

sed -i.bak -E "s/^(MARKETING_VERSION[[:space:]]*=[[:space:]]*)[0-9.]+/\1${VERSION}/" "$CFG"
sed -i.bak -E "s/^(CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*)[0-9]+/\1${NEW_BUILD}/" "$CFG"
rm -f "$CFG.bak"

mkdir -p "$CHANGELOG_DIR" "$(dirname "$RELEASE_NOTES")"
printf '%s\n' "$TEXT" > "$CHANGELOG_DIR/${NEW_BUILD}.txt"
printf '%s\n' "$TEXT" > "$RELEASE_NOTES"
echo "  release notes: $CHANGELOG_DIR/${NEW_BUILD}.txt and $RELEASE_NOTES"

git add "$CFG" "$CHANGELOG_DIR" "$RELEASE_NOTES"

cat <<EOF

Staged. Read the diff, then:

  git diff --cached
  git -c user.name="Kyriakos Papadopoulos" -c user.email="ncpjfuzl@mxmx.email" \\
      commit -m "chore: bump version to v${VERSION}"
  git push origin main            # wait for the main pipeline to be green, then:
  git -c user.name="Kyriakos Papadopoulos" -c user.email="ncpjfuzl@mxmx.email" \\
      tag -a "v${VERSION}" -m "MeshSat iOS v${VERSION}"
  git push origin "v${VERSION}"
EOF
