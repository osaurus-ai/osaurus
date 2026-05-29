#!/usr/bin/env bash
set -euo pipefail

echo "Verifying ARM64 app (default)..."
codesign -vvv --deep --strict "build_output/osaurus.app"

echo "Checking keychain-access-groups is team-prefixed (not an unresolved build variable)..."
# Parse the entitlements plist and inspect ONLY the keychain-access-groups
# array. Matching against the raw entitlements text is unsafe: the team-prefixed
# string also appears in com.apple.application-identifier, so a broad regex would
# pass even when keychain-access-groups is empty/wrong.
ENT_PLIST="$(mktemp -t osaurus-entitlements)"
trap 'rm -f "$ENT_PLIST"' EXIT
if ! codesign -d --entitlements :- --xml "build_output/osaurus.app" 2>/dev/null \
  | plutil -convert xml1 -o "$ENT_PLIST" - 2>/dev/null; then
  echo "❌ could not read/parse entitlements from app bundle"
  exit 1
fi

# Extract the keychain-access-groups array specifically. `plutil -extract`
# fails when the key is absent; an empty array yields no <string> entries.
KEYCHAIN_GROUPS="$(plutil -extract keychain-access-groups xml1 -o - "$ENT_PLIST" 2>/dev/null \
  | sed -n 's,.*<string>\(.*\)</string>.*,\1,p')"
if [ -z "$KEYCHAIN_GROUPS" ]; then
  echo "❌ keychain-access-groups entitlement is missing or empty — data-protection keychain will fail (errSecMissingEntitlement) and prompt in production"
  exit 1
fi

# Every declared group must be a resolved, team-prefixed com.dinoki.osaurus group.
while IFS= read -r group; do
  [ -z "$group" ] && continue
  echo "  keychain-access-group: $group"
  if printf '%s' "$group" | grep -q 'AppIdentifierPrefix'; then
    echo "❌ keychain-access-group '$group' contains an unresolved \$(AppIdentifierPrefix) — the access group is invalid and the data-protection keychain will fall back to the legacy login keychain (password prompt returns)"
    exit 1
  fi
  if ! printf '%s' "$group" | grep -Eq '^[A-Z0-9]{10}\.com\.dinoki\.osaurus$'; then
    echo "❌ keychain-access-group '$group' is not team-prefixed (expected <TeamID>.com.dinoki.osaurus)"
    exit 1
  fi
done <<< "$KEYCHAIN_GROUPS"
echo "✅ keychain-access-groups is team-prefixed: $KEYCHAIN_GROUPS"

echo "Checking Sparkle framework (ARM64)..."
if [ -f "build_output/osaurus.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]; then
  codesign -d --entitlements - "build_output/osaurus.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" 2>&1 | grep -q "<dict/>" && echo "✅ Sparkle has no entitlements" || echo "⚠️ Sparkle might have entitlements"
else
  echo "ℹ️ Sparkle.framework not found in app bundle (skipping check)"
fi


