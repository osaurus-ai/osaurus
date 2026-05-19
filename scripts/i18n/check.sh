#!/usr/bin/env bash
# Validate required Osaurus string catalogs (used by CI and locally). On a
# prune-required failure, surfaces the exact format.sh remediation so the
# CI log points straight at the fix.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=./_paths.sh
. "$ROOT/scripts/i18n/_paths.sh"
PY="$ROOT/scripts/i18n/check-localizations.py"

python3 "$PY" --catalog "$CORE_CATALOG" --required-locales "$REQUIRED_LOCALES"
python3 "$PY" --catalog "$INFOPLIST_CATALOG" --required-locales "$REQUIRED_LOCALES"

python3 "$ROOT/scripts/i18n/check-swift-catalog-keys.py" \
    --catalog "$CORE_CATALOG" \
    --swift-root "$CORE_SWIFT_ROOT"

# --swift-root preserves keys still referenced from Swift source even when
# Xcode flagged them stale, so the dry-run mirrors what format.sh would do.
if ! python3 "$ROOT/scripts/i18n/prune-catalog.py" \
        "$CORE_CATALOG" \
        --required-locales "$REQUIRED_LOCALES" \
        --remove-stale \
        --swift-root "$CORE_SWIFT_ROOT" \
        --dry-run \
        --fail-if-changed; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::error title=Localizable.xcstrings has unmaintained keys::Run: bash scripts/i18n/format.sh"
    else
        printf '\nLocalizable.xcstrings has unmaintained keys.\n  Fix: bash scripts/i18n/format.sh && git add -A && git commit\n\n' >&2
    fi
    exit 1
fi

bash "$ROOT/scripts/i18n/lint-swift-literals.sh"
