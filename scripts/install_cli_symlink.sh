#!/bin/bash
set -euo pipefail

# install_cli_symlink.sh
# Creates a convenient `osaurus` symlink to the app's embedded CLI.
#
# Usage:
#   scripts/install_cli_symlink.sh [path-to-Osaurus.app]
#
# If no path is provided, the script will try common install locations.

APP_PATH="${1:-}"

if [[ -z "${APP_PATH}" ]]; then
  CANDIDATES=(
    "/Applications/Osaurus.app"
    "$HOME/Applications/Osaurus.app"
  )
  for c in "${CANDIDATES[@]}"; do
    if [[ -x "$c/Contents/Helpers/osaurus" ]]; then
      APP_PATH="$c"
      break
    fi
  done
fi

if [[ -z "${APP_PATH}" ]]; then
  echo "Could not locate Osaurus.app. Provide the path explicitly." >&2
  echo "Example: scripts/install_cli_symlink.sh '/Applications/Osaurus.app'" >&2
  exit 1
fi

CLI_SRC="$APP_PATH/Contents/Helpers/osaurus"
if [[ ! -x "$CLI_SRC" ]]; then
  echo "CLI binary not found at: $CLI_SRC" >&2
  echo "Build the app so the CLI is embedded, then retry." >&2
  exit 1
fi

# Preferred location
TARGET_DIR="/usr/local/bin"
TARGET_LINK="$TARGET_DIR/osaurus"

if [[ -w "$TARGET_DIR" ]]; then
  ln -sf "$CLI_SRC" "$TARGET_LINK"
  echo "Installed symlink: $TARGET_LINK -> $CLI_SRC"
  exit 0
fi

# Fallback to user-local bin
TARGET_DIR="$HOME/.local/bin"
mkdir -p "$TARGET_DIR"
TARGET_LINK="$TARGET_DIR/osaurus"
ln -sf "$CLI_SRC" "$TARGET_LINK"

echo "Installed symlink: $TARGET_LINK -> $CLI_SRC"
echo "Make sure $TARGET_DIR is on your PATH (e.g., add to your shell profile)."


