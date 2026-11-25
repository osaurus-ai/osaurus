#!/usr/bin/env bash
# Vendors the Osaurus Swarm master library into Packages/Vendor/OsaurusSwarm.
#
#   scripts/update-osaurus-swarm.sh 0.1.0 [SHA256]          # from the private GitHub release
#   scripts/update-osaurus-swarm.sh --local ~/dev/osaurus-swarm
#   OSAURUS_SWARM_PREBUILT=1 scripts/update-osaurus-swarm.sh --local ~/dev/osaurus-swarm
#
# Unlike OsaurusSync, the Swarm package is NOT committed: Packages/Vendor/OsaurusSwarm and
# OsaurusSwarm.version are gitignored, and OsaurusCore's Package.swift adds the dependency
# only when Packages/Vendor/OsaurusSwarm/Package.swift exists. Without it the app builds
# normally and the Swarm feature stays hidden.
#
# The release form downloads OsaurusSwarm-swift-<version>.zip (needs access to the private
# repo) and, when SHA256 is given, refuses a zip with a different digest. The --local form runs
# the checkout's bindings/swift/build-xcframework.sh (skipped with OSAURUS_SWARM_PREBUILT=1 when
# the xcframework is already built) and copies its bindings/swift package.
# Either way the digest or source commit is recorded in Packages/Vendor/OsaurusSwarm.version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Packages/Vendor"
DEST="$VENDOR/OsaurusSwarm"
REPO="osaurus-ai/osaurus-swarm"

usage() {
  sed -n '2,16p' "$0" >&2
  exit 2
}

[ $# -ge 1 ] || usage
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ "$1" = --local ]; then
  [ $# -eq 2 ] || usage
  SRC="$(cd "$2" && pwd)"
  PKG="$SRC/bindings/swift"
  [ -f "$PKG/Package.swift" ] || { echo "no bindings/swift package in $SRC" >&2; exit 1; }
  if [ "${OSAURUS_SWARM_PREBUILT:-}" != 1 ]; then
    "$PKG/build-xcframework.sh"
  fi
  [ -d "$PKG/OsaurusSwarmFFI.xcframework" ] && [ -f "$PKG/Sources/OsaurusSwarm/Generated/OsaurusSwarm.swift" ] \
    || { echo "bindings/swift is not built (run its build-xcframework.sh)" >&2; exit 1; }
  mkdir -p "$WORK/OsaurusSwarm"
  (cd "$PKG" && tar cf - Package.swift Sources Tests OsaurusSwarmFFI.xcframework) | (cd "$WORK/OsaurusSwarm" && tar xf -)
  VERSION="$(git -C "$SRC" describe --tags --always --dirty)"
  RECORD="source $(git -C "$SRC" rev-parse HEAD)$(git -C "$SRC" diff --quiet || echo ' (dirty)')"
else
  VERSION="${1#v}"
  EXPECTED="${2:-}"
  ZIP="OsaurusSwarm-swift-$VERSION.zip"
  gh release download "v$VERSION" -R "$REPO" -p "$ZIP" -D "$WORK"
  DIGEST="$(shasum -a 256 "$WORK/$ZIP" | awk '{print $1}')"
  if [ -n "$EXPECTED" ] && [ "$DIGEST" != "$EXPECTED" ]; then
    echo "checksum mismatch for $ZIP: expected $EXPECTED, got $DIGEST" >&2
    exit 1
  fi
  (cd "$WORK" && unzip -q "$ZIP")
  RECORD="sha256 $DIGEST"
fi

[ -f "$WORK/OsaurusSwarm/Package.swift" ] || { echo "package not found" >&2; exit 1; }
rm -rf "$DEST"
mkdir -p "$VENDOR"
mv "$WORK/OsaurusSwarm" "$DEST"
printf 'version %s\n%s\n' "$VERSION" "$RECORD" > "$VENDOR/OsaurusSwarm.version"
if git -C "$ROOT" ls-files --error-unmatch "Packages/Vendor/OsaurusSwarm" >/dev/null 2>&1; then
  echo "error: Packages/Vendor/OsaurusSwarm is tracked by git; it must stay out of this repo" >&2
  exit 1
fi
# SwiftPM caches manifest evaluation by content, and Package.swift only checks whether this
# directory exists: drop the cached manifests so the next build picks the dependency up.
rm -rf "$ROOT/Packages/OsaurusCore/.build/manifest.db" "$HOME/Library/Caches/org.swift.swiftpm/manifests" 2>/dev/null || true
echo "vendored OsaurusSwarm $VERSION ($RECORD); rebuild OsaurusCore to enable Swarm"
