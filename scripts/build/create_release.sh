#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

# Target repository for release assets (keep in sync with generate_and_deploy_appcast.sh)
PUBLIC_REPO="${PUBLIC_REPO:-$GITHUB_REPOSITORY}"

IS_BETA="${IS_BETA:-false}"
RELEASE_LANE_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../release" && pwd)/release_lane.py"
RELEASE_LANE="$(python3 "$RELEASE_LANE_PY" field --version "$VERSION" name)"
MARKS_LATEST="$(python3 "$RELEASE_LANE_PY" field --version "$VERSION" marks_latest)"

git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"

# Latest is what releases/latest/download/Osaurus.dmg, the website and the
# Homebrew cask resolve to, so a Classic patch must never take it. GitHub
# marks a new non-prerelease Latest unless told otherwise.
RELEASE_FLAGS=(--title "$(python3 "$RELEASE_LANE_PY" field --version "$VERSION" title)")
if [ "$IS_BETA" = "true" ]; then
  RELEASE_FLAGS+=(--prerelease)
fi
if [ "$MARKS_LATEST" = "true" ]; then
  RELEASE_FLAGS+=(--latest)
else
  RELEASE_FLAGS+=(--latest=false)
fi

RELEASE_ASSETS=("build_output/Osaurus-${VERSION}.dmg")
if [ "$RELEASE_LANE" = "main" ]; then
  RELEASE_ASSETS+=("build_output/Osaurus.dmg")
fi

# Attach dSYMs if package_dsyms.sh produced them. Required for symbolicating
# field crash reports — without the matching dSYM, the binary's UUID becomes
# unrecoverable as soon as the build runner is recycled.
DSYM_ZIP="build_output/Osaurus-${VERSION}-dSYMs.zip"
if [[ -f "${DSYM_ZIP}" ]]; then
  RELEASE_ASSETS+=("${DSYM_ZIP}")
else
  echo "::warning::${DSYM_ZIP} not found — release will ship without dSYMs."
fi

if EXISTING_IS_DRAFT="$(gh release view "${VERSION}" --repo "${PUBLIC_REPO}" --json isDraft --jq .isDraft 2>/dev/null)"; then
  # Immutable releases reject asset uploads once published, so assets must be
  # attached while the release is still a draft.
  if [ "${EXISTING_IS_DRAFT}" != "true" ]; then
    EXISTING_IS_IMMUTABLE="$(gh api "repos/${PUBLIC_REPO}/releases/tags/${VERSION}" --jq '.immutable // false')"
    if [ "${EXISTING_IS_IMMUTABLE}" = "true" ]; then
      echo "::error::Release ${VERSION} is already published and immutable; assets cannot be attached. Delete it and cut a new version."
      exit 1
    fi
  fi
  echo "Release ${VERSION} already exists; uploading assets before publishing."
  gh release upload "${VERSION}" \
    "${RELEASE_ASSETS[@]}" \
    --repo "${PUBLIC_REPO}" \
    --clobber
  gh release edit "${VERSION}" \
    --repo "${PUBLIC_REPO}" \
    --draft=false \
    --notes-file RELEASE_NOTES.md \
    "${RELEASE_FLAGS[@]}"
else
  gh release create "${VERSION}" \
    "${RELEASE_ASSETS[@]}" \
    --repo "${PUBLIC_REPO}" \
    --notes-file RELEASE_NOTES.md \
    "${RELEASE_FLAGS[@]}"
fi

echo "✅ Release published successfully (${RELEASE_LANE} lane)"
if [ "$MARKS_LATEST" = "true" ]; then
  echo "📥 Latest download URL: https://github.com/${PUBLIC_REPO}/releases/latest/download/Osaurus.dmg"
else
  echo "Release URL (not Latest): https://github.com/${PUBLIC_REPO}/releases/tag/${VERSION}"
fi
