#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

# Target repository for release assets (keep in sync with generate_and_deploy_appcast.sh)
PUBLIC_REPO="${PUBLIC_REPO:-$GITHUB_REPOSITORY}"

IS_BETA="${IS_BETA:-false}"

git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"

RELEASE_FLAGS=()
if [ "$IS_BETA" = "true" ]; then
  RELEASE_FLAGS+=(--prerelease)
  RELEASE_FLAGS+=(--title "Osaurus ${VERSION} (Beta)")
else
  RELEASE_FLAGS+=(--latest)
  RELEASE_FLAGS+=(--title "Osaurus ${VERSION}")
fi

RELEASE_ASSETS=(
  "build_output/Osaurus-${VERSION}.dmg"
  "build_output/Osaurus.dmg"
)

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

echo "✅ Release published successfully"
if [ "$IS_BETA" = "true" ]; then
  echo "🧪 Beta release URL: https://github.com/${PUBLIC_REPO}/releases/tag/${VERSION}"
else
  echo "📥 Latest download URL: https://github.com/${PUBLIC_REPO}/releases/latest/download/Osaurus.dmg"
fi
