#!/usr/bin/env bash
set -euo pipefail

brew install create-dmg

# ARM64 DMG (no arch suffix)
create-dmg \
  --background "$GITHUB_WORKSPACE/assets/dmg-bg.tiff" \
  --volname "Osaurus" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "osaurus.app" 150 185 \
  --hide-extension "osaurus.app" \
  --app-drop-link 450 185 \
  "build_output/Osaurus-${VERSION}.dmg" \
  "build_output/osaurus.app" || true

if [ ! -f "build_output/Osaurus-${VERSION}.dmg" ]; then
  echo "create-dmg failed, using basic DMG creation"
  hdiutil create -volname "Osaurus" \
    -srcfolder "build_output/osaurus.app" \
    -ov -format UDZO \
    "build_output/Osaurus-${VERSION}.dmg"
fi

# Normalize identity: allow DEVELOPER_ID_NAME with or without the product prefix
CODE_SIGN_IDENTITY_VALUE="${DEVELOPER_ID_NAME}"
if [[ "${CODE_SIGN_IDENTITY_VALUE}" != Developer\ ID\ Application:* ]]; then
  CODE_SIGN_IDENTITY_VALUE="Developer ID Application: ${CODE_SIGN_IDENTITY_VALUE}"
fi

codesign --force --sign "${CODE_SIGN_IDENTITY_VALUE}" \
  "build_output/Osaurus-${VERSION}.dmg"

cp "build_output/Osaurus-${VERSION}.dmg" "build_output/Osaurus.dmg"


