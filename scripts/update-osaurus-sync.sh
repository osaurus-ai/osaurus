#!/usr/bin/env bash
# Replaces Packages/Vendor/OsaurusSync with an osaurus-sync Swift package.
#
#   scripts/update-osaurus-sync.sh 0.1.0-beta.4 [SHA256]   # from the GitHub release
#   scripts/update-osaurus-sync.sh --local ~/dev/osaurus-sync
#
# The release form downloads OsaurusSync-swift-local-<version>.zip and, when SHA256 is given,
# refuses a zip with a different digest. The --local form packages a checkout whose
# xcframework is already built (scripts/build-xcframework.sh there). Either way the digest or
# source commit is recorded in Packages/Vendor/OsaurusSync.version. The static libraries are
# tracked with Git LFS (see .gitattributes). The --local form also refreshes the app data
# fixtures in Packages/OsaurusCore/Tests/Sync/SyncFixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Packages/Vendor"
DEST="$VENDOR/OsaurusSync"
REPO="osaurus-ai/osaurus-sync"

usage() {
  sed -n '2,11p' "$0" >&2
  exit 2
}

[ $# -ge 1 ] || usage
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ "$1" = --local ]; then
  [ $# -eq 2 ] || usage
  SRC="$(cd "$2" && pwd)"
  "$SRC/scripts/make-swift-package.sh" --local "$WORK/OsaurusSync"
  VERSION="$(git -C "$SRC" describe --tags --always --dirty)"
  RECORD="source $(git -C "$SRC" rev-parse HEAD)$(git -C "$SRC" diff --quiet || echo ' (dirty)')"
else
  VERSION="${1#v}"
  EXPECTED="${2:-}"
  ZIP="OsaurusSync-swift-local-$VERSION.zip"
  gh release download "v$VERSION" -R "$REPO" -p "$ZIP" -D "$WORK"
  DIGEST="$(shasum -a 256 "$WORK/$ZIP" | awk '{print $1}')"
  if [ -n "$EXPECTED" ] && [ "$DIGEST" != "$EXPECTED" ]; then
    echo "checksum mismatch for $ZIP: expected $EXPECTED, got $DIGEST" >&2
    exit 1
  fi
  (cd "$WORK" && unzip -q "$ZIP")
  RECORD="sha256 $DIGEST"
fi

[ -f "$WORK/OsaurusSync/Package.swift" ] || { echo "package not found in the download" >&2; exit 1; }
rm -rf "$DEST"
mkdir -p "$VENDOR"
mv "$WORK/OsaurusSync" "$DEST"
printf 'version %s\n%s\n' "$VERSION" "$RECORD" > "$VENDOR/OsaurusSync.version"
if [ "$1" = --local ]; then
  # The app data contract's test vectors, read by the OsaurusCore sync tests.
  cp "$SRC"/tests/fixtures/app-data/*.json "$ROOT/Packages/OsaurusCore/Tests/Sync/SyncFixtures/"
fi
echo "vendored OsaurusSync $VERSION ($RECORD)"
