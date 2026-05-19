#!/usr/bin/env bash
# Validate required Osaurus string catalogs (used by CI and locally).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${ROOT}/scripts/i18n/check-localizations.py"
LOCALES="de,zh-Hans"

python3 "$PY" --catalog "$ROOT/Packages/OsaurusCore/Resources/Localizable.xcstrings" --required-locales "$LOCALES"
python3 "$PY" --catalog "$ROOT/App/osaurus/InfoPlist.xcstrings" --required-locales "$LOCALES"
