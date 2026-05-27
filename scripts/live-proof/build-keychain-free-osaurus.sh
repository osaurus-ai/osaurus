#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA="${1:-$ROOT/build/DerivedData-keychain-free-nosign-$(git -C "$ROOT" rev-parse --short HEAD)}"

mkdir -p "$(dirname "$DERIVED_DATA")"

echo "derived_data=$DERIVED_DATA"
echo "configuration=Release"
echo "signing=disabled"

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
    build

APP="$DERIVED_DATA/Build/Products/Release/osaurus.app"
BIN="$APP/Contents/MacOS/osaurus"

if [[ ! -x "$BIN" ]]; then
  echo "missing built app executable: $BIN" >&2
  exit 66
fi

echo "app=$APP"
