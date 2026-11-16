#!/usr/bin/env bash
set -euo pipefail

# Produce the "full" distribution app: the already-exported, signed light
# app plus the bundled onboarding model under
# Contents/Resources/BundledModels, re-signed so the model is sealed into
# the bundle signature. The light app is never modified in place.
#
# Inputs:
#   $1  source app (default build_output/Osaurus.app — the light export)
#   $2  destination app (default build_output/full/Osaurus.app)
#
# Environment:
#   DEVELOPER_ID_NAME   Developer ID Application identity (with or without prefix).
#   BUNDLED_MODEL_*     forwarded to fetch_bundled_model.sh.

: "${DEVELOPER_ID_NAME:?DEVELOPER_ID_NAME is required}"

SRC_APP="${1:-build_output/Osaurus.app}"
DEST_APP="${2:-build_output/full/Osaurus.app}"
ENTITLEMENTS="App/osaurus/osaurus.entitlements"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "$SRC_APP" ]]; then
  echo "ERROR: source app not found at ${SRC_APP}" >&2
  exit 1
fi

CODE_SIGN_IDENTITY_VALUE="${DEVELOPER_ID_NAME}"
if [[ "${CODE_SIGN_IDENTITY_VALUE}" != Developer\ ID\ Application:* ]]; then
  CODE_SIGN_IDENTITY_VALUE="Developer ID Application: ${CODE_SIGN_IDENTITY_VALUE}"
fi

echo "Copying ${SRC_APP} -> ${DEST_APP}"
rm -rf "$DEST_APP"
mkdir -p "$(dirname "$DEST_APP")"
# ditto preserves symlinks (Sparkle.framework/Versions/Current), resource
# forks and permissions; cp -R would flatten the framework symlinks.
ditto "$SRC_APP" "$DEST_APP"

BUNDLED_DIR="${DEST_APP}/Contents/Resources/BundledModels"
echo "Staging bundled model into ${BUNDLED_DIR}"
"${SCRIPT_DIR}/fetch_bundled_model.sh" "$BUNDLED_DIR"

# Re-sign the whole bundle: adding resources invalidates the export-time
# seal. Same flags as the archive re-sign in build_arm64.sh so the hardened
# runtime and entitlements are unchanged.
echo "Re-signing full app..."
codesign --force --deep --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "${CODE_SIGN_IDENTITY_VALUE}" \
  "$DEST_APP"

echo "Verifying full app..."
APP="$DEST_APP" bash "${SCRIPT_DIR}/verify_signing.sh"
bash "${SCRIPT_DIR}/verify_launch.sh" "$DEST_APP"

# Prove the seal covers the model: the manifest must be listed in the
# sealed resources, otherwise Gatekeeper would accept a tampered bundle.
if ! codesign -d -r- --verbose=4 "$DEST_APP" >/dev/null 2>&1; then
  echo "ERROR: codesign could not read the full app signature" >&2
  exit 1
fi
CODE_RESOURCES="${DEST_APP}/Contents/_CodeSignature/CodeResources"
if ! grep -q "BundledModels/manifest.json" "$CODE_RESOURCES"; then
  echo "ERROR: BundledModels/manifest.json is not sealed in ${CODE_RESOURCES}" >&2
  exit 1
fi

APP_BYTES="$(du -sk "$DEST_APP" | awk '{print $1 * 1024}')"
echo "Full app ready at ${DEST_APP} (${APP_BYTES} bytes)"
