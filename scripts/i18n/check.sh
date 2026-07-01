#!/usr/bin/env bash
# Validate required Osaurus string catalogs (used by CI and locally).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${ROOT}/scripts/i18n/check-localizations.py"
LOCALES="de,zh-Hans,ko,ru"

python3 "$PY" --catalog "$ROOT/Packages/OsaurusCore/Resources/Localizable.xcstrings" --required-locales "$LOCALES"
python3 "$PY" --catalog "$ROOT/App/osaurus/InfoPlist.xcstrings" --required-locales "$LOCALES"
python3 "$ROOT/scripts/i18n/check-swift-catalog-keys.py" \
    --catalog "$ROOT/Packages/OsaurusCore/Resources/Localizable.xcstrings" \
    --swift-root "$ROOT/Packages/OsaurusCore"

bash "$ROOT/scripts/i18n/lint-swift-literals.sh"
