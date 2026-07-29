#!/usr/bin/env bash
set -euo pipefail

APP="build_output/Osaurus.app"

echo "Verifying ARM64 app (default)..."
codesign -vvv --deep --strict "$APP"

echo "Checking Sparkle framework (ARM64)..."
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
if [ -f "$SPARKLE" ]; then
  codesign -d --entitlements - "$SPARKLE" 2>&1 | grep -q "<dict/>" && echo "✅ Sparkle has no entitlements" || echo "⚠️ Sparkle might have entitlements"
else
  echo "ℹ️ Sparkle.framework not found in app bundle (skipping check)"
fi

echo "Checking bundled imsg helper..."
IMSG="$APP/Contents/Helpers/imsg"
IMSG_DYLIB="$APP/Contents/Helpers/imsg-bridge-helper.dylib"
if [ -f "$IMSG" ]; then
  # The release pipeline must have re-signed the helper with our identity;
  # a failed/foreign signature here means the runtime trust gate will refuse
  # to spawn it and the iMessage channel ships broken.
  codesign -vvv --strict "$IMSG"
  codesign -d --entitlements - "$IMSG" 2>&1 | grep -q "com.apple.security.automation.apple-events" \
    && echo "✅ imsg keeps the Apple Events entitlement" \
    || { echo "❌ imsg lost the Apple Events entitlement — Messages sends will fail" >&2; exit 1; }
  APP_TEAM=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
  IMSG_TEAM=$(codesign -dvv "$IMSG" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
  if [ "$APP_TEAM" = "$IMSG_TEAM" ]; then
    echo "✅ imsg is signed by the app's team ($IMSG_TEAM)"
  else
    echo "❌ imsg TeamIdentifier ($IMSG_TEAM) does not match the app ($APP_TEAM) — the runtime trust gate will reject it" >&2
    exit 1
  fi
  if [ -f "$IMSG_DYLIB" ]; then
    codesign -vvv --strict "$IMSG_DYLIB"
    echo "✅ imsg bridge dylib signature verifies"
  else
    echo "❌ imsg-bridge-helper.dylib missing next to imsg" >&2
    exit 1
  fi
else
  # A release app without the helper ships a broken iMessage channel that
  # can only be repaired by the runtime download. The build lane stages it
  # unconditionally (build_arm64.sh), so absence here is a pipeline bug.
  echo "❌ imsg helper not found at $IMSG — the release bundle must include it" >&2
  exit 1
fi
