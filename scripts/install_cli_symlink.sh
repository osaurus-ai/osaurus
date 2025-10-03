#!/bin/bash
set -euo pipefail

# install_cli_symlink.sh
# Creates/updates a convenient `osaurus` symlink to either:
#   1) the app's embedded CLI at Osaurus.app/Contents/Helpers/osaurus, or
#   2) a locally built CLI binary in DerivedData (dev mode).
#
# Usage:
#   scripts/install_cli_symlink.sh [--dev] [--prefix <dir>] [<path-to-Osaurus.app>]
#
# Notes:
# - When no path is provided, common install locations are checked.
# - On Apple Silicon, Homebrew typically lives at /opt/homebrew; we auto-detect it.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DEV_MODE=0
PREFIX_OVERRIDE=""
APP_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)
      DEV_MODE=1
      shift
      ;;
    --prefix)
      PREFIX_OVERRIDE="${2:-}"
      if [[ -z "$PREFIX_OVERRIDE" ]]; then
        echo "--prefix requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      # Positional: optional path to .app
      APP_PATH="$1"
      shift
      ;;
  esac
done

resolve_cli_from_app() {
  local app_path="$1"
  local cli_path
  cli_path="$app_path/Contents/Helpers/osaurus"
  if [[ -x "$cli_path" ]]; then
    echo "$cli_path"
    return 0
  fi
  return 1
}

resolve_cli_from_dev() {
  # Try common DerivedData product locations
  local base="$REPO_ROOT/build/DerivedData/Build/Products/Release"
  for candidate in \
    "$base/osaurus" \
    "$base/osaurus-cli" \
    "$base/osaurus.app/Contents/Helpers/osaurus" \
    "$REPO_ROOT/build/DerivedData/Build/Products/Debug/osaurus" \
    "$REPO_ROOT/build/DerivedData/Build/Products/Debug/osaurus-cli"
  do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_target_bin_dir() {
  # Priority: explicit --prefix, Homebrew prefix/bin, /usr/local/bin, ~/.local/bin
  if [[ -n "$PREFIX_OVERRIDE" ]]; then
    echo "$PREFIX_OVERRIDE/bin"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [[ -n "$brew_prefix" ]]; then
      echo "$brew_prefix/bin"
      return 0
    fi
  fi

  if [[ -d "/usr/local/bin" ]]; then
    echo "/usr/local/bin"
    return 0
  fi

  echo "$HOME/.local/bin"
}

# Determine CLI source
CLI_SRC=""
if [[ "$DEV_MODE" == "1" ]]; then
  if CLI_SRC="$(resolve_cli_from_dev)"; then :; else
    echo "Could not locate a built CLI in DerivedData. Build it first: 'make cli'" >&2
    exit 1
  fi
else
  if [[ -z "$APP_PATH" ]]; then
    CANDIDATES=(
      "/Applications/Osaurus.app"
      "$HOME/Applications/Osaurus.app"
      "/Applications/osaurus.app"
      "$HOME/Applications/osaurus.app"
    )
    for c in "${CANDIDATES[@]}"; do
      if CLI_SRC="$(resolve_cli_from_app "$c")"; then
        APP_PATH="$c"
        break
      fi
    done
  else
    if CLI_SRC="$(resolve_cli_from_app "$APP_PATH")"; then :; else
      echo "CLI binary not found in: $APP_PATH" >&2
      echo "Expected at: $APP_PATH/Contents/Helpers/osaurus" >&2
      exit 1
    fi
  fi

  if [[ -z "$CLI_SRC" ]]; then
    echo "Could not locate Osaurus.app automatically. Provide the path explicitly." >&2
    echo "Example: scripts/install_cli_symlink.sh '/Applications/Osaurus.app'" >&2
    exit 1
  fi
fi

TARGET_DIR="$(resolve_target_bin_dir)"
TARGET_LINK="$TARGET_DIR/osaurus"

mkdir -p "$TARGET_DIR"

if [[ -w "$TARGET_DIR" ]]; then
  ln -sf "$CLI_SRC" "$TARGET_LINK"
  echo "Installed symlink: $TARGET_LINK -> $CLI_SRC"
else
  # Fallback to user-local, avoid sudo prompts
  TARGET_DIR="$HOME/.local/bin"
  mkdir -p "$TARGET_DIR"
  TARGET_LINK="$TARGET_DIR/osaurus"
  ln -sf "$CLI_SRC" "$TARGET_LINK"
  echo "Installed symlink (user): $TARGET_LINK -> $CLI_SRC"
  echo "Make sure $TARGET_DIR is on your PATH (e.g., add to your shell profile)."
fi


