#!/usr/bin/env bash
set -euo pipefail

# Uploads this build's .dSYM bundles to Sentry so production crash reports
# symbolicate (function names + line numbers). Debug files are matched to crash
# reports by binary UUID, so this MUST run against the same archive that
# produced the shipped binary — run it right after package_dsyms.sh, before the
# archive is gone.
#
# Best-effort by design: when no auth token / org / project is configured (forks,
# local runs, or before the GitHub secrets are added) it logs a warning and
# exits 0 rather than failing the release. Symbolication just won't be available
# for that build.
#
# Required env (all three, or the step no-ops):
#   SENTRY_AUTH_TOKEN  — auth token with project:releases / project:write scope
#                        (Sentry → Settings → Account → Auth Tokens, or an
#                        org-level Internal Integration). Read directly by
#                        sentry-cli.
#   SENTRY_ORG         — org slug
#   SENTRY_PROJECT     — project slug
#
# Optional:
#   SENTRY_CLI_VERSION — pin the installed sentry-cli (default below)

SENTRY_ORG="${SENTRY_ORG:-}"
SENTRY_PROJECT="${SENTRY_PROJECT:-}"
SENTRY_CLI_VERSION="${SENTRY_CLI_VERSION:-2.39.1}"

if [[ -z "${SENTRY_AUTH_TOKEN:-}" || -z "${SENTRY_ORG}" || -z "${SENTRY_PROJECT}" ]]; then
  echo "::warning::SENTRY_AUTH_TOKEN/SENTRY_ORG/SENTRY_PROJECT not all set; skipping Sentry dSYM upload (crashes for this build won't symbolicate)."
  exit 0
fi

# Same sources package_dsyms.sh draws from (it only removes its own staging
# copy, not these originals).
ARCHIVE_DSYMS_DIR="build/osaurus.xcarchive/dSYMs"
CLI_BUILD_DIR="build/Build/Products/Release"

SOURCES=()
[[ -d "${ARCHIVE_DSYMS_DIR}" ]] && SOURCES+=("${ARCHIVE_DSYMS_DIR}")
[[ -d "${CLI_BUILD_DIR}" ]] && SOURCES+=("${CLI_BUILD_DIR}")

if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "::warning::No dSYM source directories found (${ARCHIVE_DSYMS_DIR}, ${CLI_BUILD_DIR}); nothing to upload to Sentry."
  exit 0
fi

# Install a pinned sentry-cli into a temp dir (no sudo) if it isn't already on
# PATH. The official installer honors INSTALL_DIR + SENTRY_CLI_VERSION.
if ! command -v sentry-cli >/dev/null 2>&1; then
  INSTALL_DIR="${RUNNER_TEMP:-/tmp}/sentry-cli-bin"
  mkdir -p "${INSTALL_DIR}"
  echo "Installing sentry-cli ${SENTRY_CLI_VERSION} into ${INSTALL_DIR} ..."
  curl -sL https://sentry.io/get-cli/ | INSTALL_DIR="${INSTALL_DIR}" SENTRY_CLI_VERSION="${SENTRY_CLI_VERSION}" bash
  export PATH="${INSTALL_DIR}:${PATH}"
fi

echo "sentry-cli $(sentry-cli --version)"
echo "Uploading dSYMs to Sentry (${SENTRY_ORG}/${SENTRY_PROJECT}) from: ${SOURCES[*]}"

# UUID-keyed symbol upload. We deliberately do NOT pass --include-sources: dSYMs
# alone give symbolicated stacks (names + line numbers), and we'd rather not
# ship source bundles. `--wait` so the CI log reflects the real result.
sentry-cli debug-files upload \
  --org "${SENTRY_ORG}" \
  --project "${SENTRY_PROJECT}" \
  --wait \
  "${SOURCES[@]}"

echo "✅ Sentry dSYM upload complete."
