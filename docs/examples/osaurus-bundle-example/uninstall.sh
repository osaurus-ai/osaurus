#!/bin/bash
#
# Removes everything the "Acme Support Starter" bundle installed, then the
# Keychain items its installer stored. Walkthrough: docs/OSAURUS_BUNDLES.md,
# "Updating and uninstalling".
#
# Osaurus removes only what this bundle installed. Agents, skills and
# servers the user made are never touched. When Osaurus is not running the
# removal is queued and happens the next time it opens.

set -euo pipefail

BUNDLE_ID="com.example.acme-support"
KEYCHAIN_SERVICE="com.example.acme-support"
APP_PATH="${OSAURUS_APP:-/Applications/Osaurus.app}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  CONSOLE_USER="$(stat -f %Su /dev/console)"
  case "$CONSOLE_USER" in
    ""|root|loginwindow) die "No user is logged in. Run this script again as the user." ;;
  esac
  exec launchctl asuser "$(id -u "$CONSOLE_USER")" sudo -u "$CONSOLE_USER" -H \
    env OSAURUS_APP="$APP_PATH" "$0" "$@"
fi

CLI="$APP_PATH/Contents/Helpers/osaurus"
[ -x "$CLI" ] || die "$CLI is missing."

LOG_DIR="$HOME/Library/Logs/AcmeSupport"
mkdir -p "$LOG_DIR"

set +e
"$CLI" import remove --bundle "$BUNDLE_ID" --json > "$LOG_DIR/uninstall.json"
STATUS=$?
set -e
[ "$STATUS" -eq 0 ] || die "Removal failed. Details: $LOG_DIR/uninstall.json"

# Osaurus copied the secrets into its own Keychain items when it set the
# servers up, and drops those with the servers. These are the installer's
# copies.
for account in tickets-token tickets-workspace-key github-token; do
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1 || true
done

STATE="$(plutil -extract state raw -o - "$LOG_DIR/uninstall.json" 2>/dev/null || echo unknown)"
if [ "$STATE" = "queued" ]; then
  log "Queued. The Acme agents are removed the next time Osaurus opens."
else
  log "Removed."
fi
