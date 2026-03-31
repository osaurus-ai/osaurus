#!/usr/bin/env bash
set -euo pipefail

# Create output directory
mkdir -p build_output

# Determine VERSION and export to GitHub environment and current shell
if [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
  TAG="${GITHUB_REF#refs/tags/}"
  VERSION_NO_V="${TAG#v}"
  echo "VERSION=${VERSION_NO_V}" >> "$GITHUB_ENV"
  echo "OSAURUS_VERSION=${VERSION_NO_V}" >> "$GITHUB_ENV"
  export VERSION="${VERSION_NO_V}"
  echo "Building version: ${VERSION_NO_V}"

  if [[ "$VERSION_NO_V" == *-beta* ]]; then
    echo "IS_BETA=true" >> "$GITHUB_ENV"
    echo "SPARKLE_CHANNEL=beta" >> "$GITHUB_ENV"
    echo "Detected beta release"
  else
    echo "IS_BETA=false" >> "$GITHUB_ENV"
    echo "SPARKLE_CHANNEL=release" >> "$GITHUB_ENV"
  fi
else
  echo "VERSION=1.0.0-dev" >> "$GITHUB_ENV"
  echo "OSAURUS_VERSION=1.0.0-dev" >> "$GITHUB_ENV"
  echo "IS_BETA=false" >> "$GITHUB_ENV"
  echo "SPARKLE_CHANNEL=release" >> "$GITHUB_ENV"
  export VERSION="1.0.0-dev"
  echo "Building version: 1.0.0-dev"
fi

echo "OSAURUS_BUILD_NUMBER=${GITHUB_RUN_NUMBER:-1}" >> "$GITHUB_ENV"
