#!/usr/bin/env bash
set -euo pipefail

# Backward-compat: if DEVELOPMENT_TEAM not set, fall back to APPLE_TEAM_ID
if [[ -z "${DEVELOPMENT_TEAM:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  export DEVELOPMENT_TEAM="${APPLE_TEAM_ID}"
fi

: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is required}"
: "${DEVELOPER_ID_NAME:?DEVELOPER_ID_NAME is required}"
: "${VERSION:?VERSION is required}"

echo "Building ARM64 version (default)..."

# Normalize identity: allow DEVELOPER_ID_NAME with or without the product prefix
CODE_SIGN_IDENTITY_VALUE="${DEVELOPER_ID_NAME}"
if [[ "${CODE_SIGN_IDENTITY_VALUE}" != Developer\ ID\ Application:* ]]; then
  CODE_SIGN_IDENTITY_VALUE="Developer ID Application: ${CODE_SIGN_IDENTITY_VALUE}"
fi

xcodebuild -project App/osaurus.xcodeproj \
  -scheme osaurus \
  -configuration Release \
  -derivedDataPath build \
  ARCHS=arm64 \
  VALID_ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${VERSION}" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY_VALUE}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Manual \
  clean archive -archivePath build/osaurus.xcarchive

cat > ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath build/osaurus.xcarchive \
  -exportPath build_output \
  -exportOptionsPlist ExportOptions.plist
