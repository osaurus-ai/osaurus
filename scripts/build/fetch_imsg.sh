#!/usr/bin/env bash
set -euo pipefail

# Stage the pinned `imsg` helper (and its bridge dylib + resource bundles)
# into the app bundle so the native iMessage channel drives a reproducible,
# digest-verified binary instead of anything fetched at runtime.
#
# All pins are read from scripts/build/imsg-helper-manifest.json — the single
# source of truth shared with `IMessageRuntimeAssets` (a unit test locks the
# Swift constants to the manifest, so a pin bump that touches only one side
# fails CI). `IMessageRuntimeAssets.verifyBundledExecutable()` verifies the
# executable again at spawn time (digest for unmodified staging, or a
# same-team code signature after the release re-sign), so a stale pin here
# degrades to a hard "helper unavailable" failure rather than a silently
# wrong binary.
#
# imsg is MIT licensed (https://github.com/openclaw/imsg); a provenance
# sidecar records release, digests, and license.
#
# Usage: fetch_imsg.sh <output-dir>
#   <output-dir> receives `imsg`, `imsg-bridge-helper.dylib`, the resource
#   bundles, and `imsg.provenance.json` (typically
#   <App>.app/Contents/Helpers).

MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/imsg-helper-manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: imsg helper manifest not found at $MANIFEST" >&2
  exit 1
fi

manifest_value() {
  /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$MANIFEST" "$1"
}

IMSG_VERSION="$(manifest_value version)"
ZIP_URL="$(manifest_value archiveURL)"
ZIP_SHA256="$(manifest_value archiveSHA256)"
IMSG_SHA256="$(manifest_value executableSHA256)"
DYLIB_SHA256="$(manifest_value bridgeDylibSHA256)"
UPSTREAM_REPOSITORY="$(manifest_value upstreamRepository)"
LICENSE="$(manifest_value license)"

RESOURCE_BUNDLES=()
while IFS= read -r bundle; do
  RESOURCE_BUNDLES+=("$bundle")
done < <(/usr/bin/python3 -c \
  'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["resourceBundles"]))' \
  "$MANIFEST")

OUT_DIR="${1:?output directory required (e.g. Osaurus.app/Contents/Helpers)}"
CACHE_DIR="${IMSG_CACHE_DIR:-${HOME}/.cache/osaurus-imsg}"
CACHED_STAGE="${CACHE_DIR}/stage-${IMSG_VERSION}"

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_slice() {
  local file="$1" slice="$2"
  if ! lipo "$file" -verify_arch "$slice"; then
    echo "ERROR: $file is missing the required ${slice} slice" >&2
    exit 1
  fi
}

stage_is_valid() {
  [[ -f "$CACHED_STAGE/imsg" && -f "$CACHED_STAGE/imsg-bridge-helper.dylib" ]] \
    && [[ "$(sha256_of "$CACHED_STAGE/imsg")" == "$IMSG_SHA256" ]] \
    && [[ "$(sha256_of "$CACHED_STAGE/imsg-bridge-helper.dylib")" == "$DYLIB_SHA256" ]]
}

mkdir -p "$OUT_DIR" "$CACHE_DIR"

if ! stage_is_valid; then
  echo "Fetching imsg ${IMSG_VERSION} release archive..."
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  curl -fL --retry 3 -o "$WORK_DIR/imsg-macos.zip" "$ZIP_URL"
  ACTUAL_ZIP_SHA="$(sha256_of "$WORK_DIR/imsg-macos.zip")"
  if [[ "$ACTUAL_ZIP_SHA" != "$ZIP_SHA256" ]]; then
    echo "ERROR: imsg archive SHA-256 mismatch (expected $ZIP_SHA256, got $ACTUAL_ZIP_SHA)" >&2
    exit 1
  fi

  unzip -o -q "$WORK_DIR/imsg-macos.zip" -d "$WORK_DIR/extracted"

  ACTUAL_IMSG_SHA="$(sha256_of "$WORK_DIR/extracted/imsg")"
  if [[ "$ACTUAL_IMSG_SHA" != "$IMSG_SHA256" ]]; then
    echo "ERROR: imsg executable SHA-256 mismatch (expected $IMSG_SHA256, got $ACTUAL_IMSG_SHA)" >&2
    exit 1
  fi
  ACTUAL_DYLIB_SHA="$(sha256_of "$WORK_DIR/extracted/imsg-bridge-helper.dylib")"
  if [[ "$ACTUAL_DYLIB_SHA" != "$DYLIB_SHA256" ]]; then
    echo "ERROR: imsg bridge dylib SHA-256 mismatch (expected $DYLIB_SHA256, got $ACTUAL_DYLIB_SHA)" >&2
    exit 1
  fi

  # The helper must run on Apple silicon; the bridge additionally needs an
  # arm64e slice because Messages.app runs arm64e and dylib injection
  # requires a matching ABI.
  require_slice "$WORK_DIR/extracted/imsg" arm64
  require_slice "$WORK_DIR/extracted/imsg-bridge-helper.dylib" arm64
  require_slice "$WORK_DIR/extracted/imsg-bridge-helper.dylib" arm64e

  for bundle in "${RESOURCE_BUNDLES[@]}"; do
    if [[ ! -d "$WORK_DIR/extracted/$bundle" ]]; then
      echo "ERROR: expected resource bundle $bundle missing from imsg archive" >&2
      exit 1
    fi
  done

  rm -rf "$CACHED_STAGE"
  mkdir -p "$CACHED_STAGE"
  cp "$WORK_DIR/extracted/imsg" "$CACHED_STAGE/imsg"
  cp "$WORK_DIR/extracted/imsg-bridge-helper.dylib" "$CACHED_STAGE/imsg-bridge-helper.dylib"
  for bundle in "${RESOURCE_BUNDLES[@]}"; do
    cp -R "$WORK_DIR/extracted/$bundle" "$CACHED_STAGE/$bundle"
  done
fi

cp "$CACHED_STAGE/imsg" "$OUT_DIR/imsg"
chmod +x "$OUT_DIR/imsg"
cp "$CACHED_STAGE/imsg-bridge-helper.dylib" "$OUT_DIR/imsg-bridge-helper.dylib"
for bundle in "${RESOURCE_BUNDLES[@]}"; do
  rm -rf "$OUT_DIR/$bundle"
  cp -R "$CACHED_STAGE/$bundle" "$OUT_DIR/$bundle"
done

cat > "$OUT_DIR/imsg.provenance.json" <<EOF
{
  "artifact": "imsg",
  "version": "${IMSG_VERSION}",
  "executableSHA256": "${IMSG_SHA256}",
  "bridgeDylibSHA256": "${DYLIB_SHA256}",
  "archive": "${ZIP_URL}",
  "archiveSHA256": "${ZIP_SHA256}",
  "upstreamRepository": "${UPSTREAM_REPOSITORY}",
  "license": "${LICENSE}"
}
EOF

echo "imsg ${IMSG_VERSION} staged at ${OUT_DIR}"
