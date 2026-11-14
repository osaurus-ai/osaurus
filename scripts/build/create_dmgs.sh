#!/usr/bin/env bash
set -euo pipefail

# Build a signed DMG for one distribution variant.
#
#   DMG_VARIANT=light (default)  build_output/Osaurus.app
#                                -> build_output/Osaurus-${VERSION}.dmg (+ Osaurus.dmg copy)
#                                UDZO (zlib): the ~70 MB app compresses well.
#   DMG_VARIANT=full             build_output/full/Osaurus.app
#                                -> build_output/Osaurus-${VERSION}-full.dmg
#                                ULFO (lzfse): the bundled JANG_6M weights are
#                                incompressible, so zlib would spend minutes
#                                for no size gain; lzfse is the fast path.
#
# Only the light DMG feeds Sparkle/Homebrew (see generate_and_deploy_appcast.sh).

: "${VERSION:?VERSION is required}"
: "${DEVELOPER_ID_NAME:?DEVELOPER_ID_NAME is required}"

DMG_VARIANT="${DMG_VARIANT:-light}"
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

case "$DMG_VARIANT" in
  light)
    APP_PATH="build_output/Osaurus.app"
    DMG_PATH="build_output/Osaurus-${VERSION}.dmg"
    DMG_FORMAT="UDZO"
    ;;
  full)
    APP_PATH="build_output/full/Osaurus.app"
    DMG_PATH="build_output/Osaurus-${VERSION}-full.dmg"
    DMG_FORMAT="ULFO"
    ;;
  *)
    echo "ERROR: DMG_VARIANT must be 'light' or 'full' (got '${DMG_VARIANT}')" >&2
    exit 1
    ;;
esac

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: app not found at ${APP_PATH}" >&2
  exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
  brew install create-dmg
fi

# create-dmg expects a source folder containing only the app so the DMG
# root does not pick up sibling build artifacts.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP_PATH" "${STAGING}/Osaurus.app"

rm -f "$DMG_PATH"
create-dmg \
  --background "${WORKSPACE}/assets/dmg-bg.tiff" \
  --volname "Osaurus" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Osaurus.app" 150 185 \
  --hide-extension "Osaurus.app" \
  --app-drop-link 450 185 \
  --format "$DMG_FORMAT" \
  "$DMG_PATH" \
  "$STAGING" || true

if [[ ! -f "$DMG_PATH" ]]; then
  echo "create-dmg failed, using basic DMG creation"
  hdiutil create -volname "Osaurus" \
    -srcfolder "$STAGING" \
    -ov -format "$DMG_FORMAT" \
    "$DMG_PATH"
fi

# Normalize identity: allow DEVELOPER_ID_NAME with or without the product prefix
CODE_SIGN_IDENTITY_VALUE="${DEVELOPER_ID_NAME}"
if [[ "${CODE_SIGN_IDENTITY_VALUE}" != Developer\ ID\ Application:* ]]; then
  CODE_SIGN_IDENTITY_VALUE="Developer ID Application: ${CODE_SIGN_IDENTITY_VALUE}"
fi

codesign --force --sign "${CODE_SIGN_IDENTITY_VALUE}" "$DMG_PATH"

if [[ "$DMG_VARIANT" == "light" ]]; then
  cp "$DMG_PATH" "build_output/Osaurus.dmg"
fi

echo "Created ${DMG_VARIANT} DMG at ${DMG_PATH} ($(stat -f %z "$DMG_PATH") bytes, ${DMG_FORMAT})"
