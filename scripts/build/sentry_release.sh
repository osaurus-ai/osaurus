#!/usr/bin/env bash
set -euo pipefail

# Registers this build as a Sentry Release and associates commits + a deploy
# with it, so release triage can see which commits shipped, diff regressions
# between releases ("suspect commits"), and read adoption/crash-free rates
# against a real deploy timestamp. The 0.22.6 triage had none of this — no
# commits, no deploys — so regressions couldn't be attributed.
#
# The release name MUST match what the Sentry Cocoa SDK reports at runtime,
# which is its default "<bundle id>@<marketing version>+<build>". Our build
# sets MARKETING_VERSION and CURRENT_PROJECT_VERSION to the same ${VERSION}
# (see build_arm64.sh), so the runtime release is:
#   com.dinoki.osaurus@${VERSION}+${VERSION}
#
# Best-effort by design, same contract as upload_dsyms_sentry.sh: missing
# secrets (forks, local runs) log a warning and exit 0 rather than failing
# the release.
#
# Required env (all three, or the step no-ops):
#   SENTRY_AUTH_TOKEN — token with project:releases scope
#   SENTRY_ORG        — org slug
#   SENTRY_PROJECT    — project slug
#   VERSION           — marketing/build version (from setup_env.sh, tag-derived)
#
# Optional:
#   SENTRY_CLI_VERSION — pin the installed sentry-cli (default below)

SENTRY_ORG="${SENTRY_ORG:-}"
SENTRY_PROJECT="${SENTRY_PROJECT:-}"
SENTRY_CLI_VERSION="${SENTRY_CLI_VERSION:-2.39.1}"

if [[ -z "${SENTRY_AUTH_TOKEN:-}" || -z "${SENTRY_ORG}" || -z "${SENTRY_PROJECT}" ]]; then
  echo "::warning::SENTRY_AUTH_TOKEN/SENTRY_ORG/SENTRY_PROJECT not all set; skipping Sentry release registration (release health won't have commits/deploys for this build)."
  exit 0
fi

if [[ -z "${VERSION:-}" ]]; then
  echo "::warning::VERSION not set; skipping Sentry release registration."
  exit 0
fi

BUNDLE_ID="com.dinoki.osaurus"
RELEASE="${BUNDLE_ID}@${VERSION}+${VERSION}"

# Install a pinned sentry-cli (no sudo) if it isn't already on PATH — the
# dSYM step usually ran first and left one installed.
if ! command -v sentry-cli >/dev/null 2>&1; then
  INSTALL_DIR="${RUNNER_TEMP:-/tmp}/sentry-cli-bin"
  mkdir -p "${INSTALL_DIR}"
  echo "Installing sentry-cli ${SENTRY_CLI_VERSION} into ${INSTALL_DIR} ..."
  curl -sL https://sentry.io/get-cli/ | INSTALL_DIR="${INSTALL_DIR}" SENTRY_CLI_VERSION="${SENTRY_CLI_VERSION}" bash
  export PATH="${INSTALL_DIR}:${PATH}"
fi

echo "Registering Sentry release ${RELEASE} (${SENTRY_ORG}/${SENTRY_PROJECT})"

sentry-cli releases new "${RELEASE}" \
  --org "${SENTRY_ORG}" \
  --project "${SENTRY_PROJECT}"

# Commit association. `--auto` uses the org's linked repo integration; when
# the repo isn't linked, fall back to `--local`, which reads the checked-out
# git history directly (the workflow checks out with fetch-depth: 0).
# `--ignore-missing` keeps the very first tracked release from failing when
# the previous release has no commit recorded to diff against.
if ! sentry-cli releases set-commits "${RELEASE}" \
  --org "${SENTRY_ORG}" \
  --project "${SENTRY_PROJECT}" \
  --auto --ignore-missing; then
  echo "::warning::set-commits --auto failed (repo not linked in Sentry?); falling back to --local."
  sentry-cli releases set-commits "${RELEASE}" \
    --org "${SENTRY_ORG}" \
    --project "${SENTRY_PROJECT}" \
    --local --ignore-missing
fi

sentry-cli releases finalize "${RELEASE}" \
  --org "${SENTRY_ORG}" \
  --project "${SENTRY_PROJECT}"

# Deploy marker: stamps when this release actually went out to production, so
# adoption and crash-free graphs have a real starting point.
sentry-cli deploys new \
  --org "${SENTRY_ORG}" \
  --project "${SENTRY_PROJECT}" \
  --release "${RELEASE}" \
  --env production \
  --name "github-release"

echo "✅ Sentry release ${RELEASE} registered with commits + production deploy."
