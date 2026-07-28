#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 /absolute/DerivedData com.dinoki.osaurus.uniqueproofid" >&2
  exit 64
fi

DERIVED_DATA="$1"
BUNDLE_ID="$2"

if [[ "$DERIVED_DATA" != /* ]]; then
  echo "DerivedData path must be absolute: $DERIVED_DATA" >&2
  exit 64
fi
if [[ ! "$BUNDLE_ID" =~ ^com\.dinoki\.osaurus\.[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  echo "proof bundle id must be a unique com.dinoki.osaurus.* domain: $BUNDLE_ID" >&2
  exit 64
fi

mkdir -p "$(dirname "$DERIVED_DATA")"

echo "derived_data=$DERIVED_DATA"
echo "configuration=Release"
echo "xcode_signing=disabled"
echo "bundle_seal=ad-hoc-keychain-free"
echo "bundle_id=$BUNDLE_ID"
echo "user_defaults_domain=$BUNDLE_ID"

env \
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
  xcodebuild \
    -workspace "$ROOT/osaurus.xcworkspace" \
    -scheme osaurus \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    AD_HOC_CODE_SIGNING_ALLOWED=NO \
    ENABLE_USER_SCRIPT_SANDBOXING=NO \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    build

APP="$DERIVED_DATA/Build/Products/Release/osaurus.app"
BIN="$APP/Contents/MacOS/osaurus"

if [[ ! -x "$BIN" ]]; then
  echo "missing built app executable: $BIN" >&2
  exit 66
fi

BUILT_BUNDLE_ID="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
)"
if [[ "$BUILT_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "built bundle id mismatch: expected $BUNDLE_ID, got $BUILT_BUNDLE_ID" >&2
  exit 65
fi

# macOS 26 rejects the raw CODE_SIGNING_ALLOWED=NO bundle for UI launch
# because app resources are not sealed. This ad-hoc seal uses no identity,
# certificate, timestamp, notarization, or login Keychain item.
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP"

echo "app=$APP"
