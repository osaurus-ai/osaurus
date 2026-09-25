#!/usr/bin/env bash
set -euo pipefail

# Defaults to the light export; build_full_app.sh points APP at the full app.
APP="${APP:-build_output/Osaurus.app}"

echo "Verifying ARM64 app at ${APP}..."
codesign -vvv --deep --strict "$APP"

echo "Checking Sparkle framework (ARM64)..."
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
if [ -f "$SPARKLE" ]; then
  codesign -d --entitlements - "$SPARKLE" 2>&1 | grep -q "<dict/>" && echo "✅ Sparkle has no entitlements" || echo "⚠️ Sparkle might have entitlements"
else
  echo "ℹ️ Sparkle.framework not found in app bundle (skipping check)"
fi
