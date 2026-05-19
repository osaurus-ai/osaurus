# Shared config sourced by check.sh, format.sh, and .githooks/pre-commit.
# Callers must set `ROOT` to the repo root before sourcing.

# shellcheck shell=bash
# shellcheck disable=SC2034

CORE_CATALOG="$ROOT/Packages/OsaurusCore/Resources/Localizable.xcstrings"
INFOPLIST_CATALOG="$ROOT/App/osaurus/InfoPlist.xcstrings"
CORE_SWIFT_ROOT="$ROOT/Packages/OsaurusCore"
REQUIRED_LOCALES="de,zh-Hans"
