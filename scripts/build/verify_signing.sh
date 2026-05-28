#!/usr/bin/env bash
set -euo pipefail

echo "Verifying ARM64 app (default)..."
codesign -vvv --deep --strict "build_output/osaurus.app"

echo "Checking keychain-access-groups is team-prefixed (not an unresolved build variable)..."
APP_ENTITLEMENTS="$(codesign -d --entitlements - "build_output/osaurus.app" 2>/dev/null || true)"
if ! echo "$APP_ENTITLEMENTS" | grep -q "keychain-access-groups"; then
  echo "❌ keychain-access-groups entitlement is missing — data-protection keychain will fail (errSecMissingEntitlement) and prompt in production"
  exit 1
fi
if echo "$APP_ENTITLEMENTS" | grep -q 'AppIdentifierPrefix'; then
  echo "❌ keychain-access-groups still contains an unresolved \$(AppIdentifierPrefix) — the access group is invalid and the data-protection keychain will fall back to the legacy login keychain (password prompt returns)"
  exit 1
fi
if ! echo "$APP_ENTITLEMENTS" | grep -Eq '[A-Z0-9]{10}\.com\.dinoki\.osaurus'; then
  echo "❌ keychain-access-groups is not team-prefixed (expected <TeamID>.com.dinoki.osaurus)"
  exit 1
fi
echo "✅ keychain-access-groups is team-prefixed"

echo "Checking Sparkle framework (ARM64)..."
if [ -f "build_output/osaurus.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]; then
  codesign -d --entitlements - "build_output/osaurus.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" 2>&1 | grep -q "<dict/>" && echo "✅ Sparkle has no entitlements" || echo "⚠️ Sparkle might have entitlements"
else
  echo "ℹ️ Sparkle.framework not found in app bundle (skipping check)"
fi


