#!/usr/bin/env bash
# Write-mode prune of Localizable.xcstrings. Invoked by the pre-commit hook,
# the i18n-autofix workflow, and the Xcode Debug build phase; also safe to
# run by hand if scripts/i18n/check.sh fails locally.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=./_paths.sh
. "$ROOT/scripts/i18n/_paths.sh"

python3 "$ROOT/scripts/i18n/prune-catalog.py" \
    "$CORE_CATALOG" \
    --required-locales "$REQUIRED_LOCALES" \
    --remove-stale \
    --swift-root "$CORE_SWIFT_ROOT"
