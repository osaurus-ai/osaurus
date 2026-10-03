#!/usr/bin/env bash
set -euo pipefail

# Notarize and staple one DMG.
#
#   notarize.sh                          -> build_output/Osaurus-${VERSION}.dmg (light, default)
#   notarize.sh <path/to.dmg> [timeout]  -> that DMG (the full variant passes 45m:
#                                           a ~4 GB upload plus Apple's processing
#                                           of a 3.7 GB payload regularly exceeds 30m)

: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_ID_PASSWORD:?APPLE_ID_PASSWORD is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${VERSION:?VERSION is required}"

LIGHT_DMG="build_output/Osaurus-${VERSION}.dmg"
DMG_PATH="${1:-$LIGHT_DMG}"
TIMEOUT="${2:-30m}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: DMG not found at ${DMG_PATH}" >&2
  exit 1
fi

xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_ID_PASSWORD"

echo "Submitting ${DMG_PATH} for notarization (timeout ${TIMEOUT})..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "AC_PASSWORD" \
  --wait \
  --timeout "$TIMEOUT"

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# The unversioned Osaurus.dmg alias only tracks the light build (Homebrew
# cask + README "latest" link).
if [[ "$DMG_PATH" == "$LIGHT_DMG" ]]; then
  cp "$DMG_PATH" "build_output/Osaurus.dmg"
fi
