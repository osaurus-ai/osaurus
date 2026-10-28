#!/bin/bash
#
# Example installer for the "Acme Support Starter" Osaurus bundle.
# Walkthrough: docs/OSAURUS_BUNDLES.md, "Writing the installer script".
#
#   ./install.sh [--secrets-file FILE] [--open]
#
# Secrets come from the environment (ACME_TICKETS_TOKEN,
# ACME_TICKETS_WORKSPACE_KEY, GITHUB_TOKEN), from --secrets-file (KEY=VALUE
# lines), or from a prompt when run in a terminal. Set OSAURUS_APP_SOURCE to
# an Osaurus.app (for example on a mounted DMG) to install the app first.
#
# Exit codes: 0 installed or queued, 1 failed, 3 installed but the user must
# finish a step in Osaurus.

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="com.example.acme-support"
KEYCHAIN_SERVICE="com.example.acme-support"
APP_PATH="${OSAURUS_APP:-/Applications/Osaurus.app}"
APP_SOURCE="${OSAURUS_APP_SOURCE:-}"
OSAURUS_TEAM_ID="4W8QF9VR2F"
MIN_OSAURUS_VERSION="0.26.0"

SECRETS_FILE=""
OPEN_APP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --secrets-file) SECRETS_FILE="$2"; shift 2 ;;
    --open) OPEN_APP=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# --- 1. Install Osaurus.app (optional) -------------------------------------
# Verify the signature before copying: a notarized build from the expected
# team, accepted by Gatekeeper.
verify_app() {
  local app="$1"
  codesign --verify --deep --strict "$app" 2>/dev/null || die "$app is not validly signed."
  spctl --assess --type execute "$app" 2>/dev/null || die "Gatekeeper rejects $app."
  local team
  team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ "$team" = "$OSAURUS_TEAM_ID" ] || die "$app is signed by team '$team', expected $OSAURUS_TEAM_ID."
}

if [ -n "$APP_SOURCE" ]; then
  verify_app "$APP_SOURCE"
  log "Installing Osaurus to $APP_PATH"
  rm -rf "$APP_PATH"
  ditto "$APP_SOURCE" "$APP_PATH"
fi

# --- 2. Run as the logged-in user ------------------------------------------
# Osaurus keeps its data in the user's home folder and its secrets in the
# user's login Keychain, and `osaurus import` refuses to run as root. From a
# .pkg postinstall (root), hand the secrets over in a file only the user can
# read, then re-run this script as the console user.
if [ "$(id -u)" -eq 0 ]; then
  CONSOLE_USER="$(stat -f %Su /dev/console)"
  case "$CONSOLE_USER" in
    ""|root|loginwindow) die "No user is logged in. Run this script again as the user after they log in." ;;
  esac
  CONSOLE_UID="$(id -u "$CONSOLE_USER")"
  HANDOFF="$(mktemp /tmp/acme-osaurus-secrets.XXXXXX)"
  chmod 600 "$HANDOFF"
  {
    [ -n "$SECRETS_FILE" ] && cat "$SECRETS_FILE"
    [ -n "${ACME_TICKETS_TOKEN:-}" ] && printf 'ACME_TICKETS_TOKEN=%s\n' "$ACME_TICKETS_TOKEN"
    [ -n "${ACME_TICKETS_WORKSPACE_KEY:-}" ] && printf 'ACME_TICKETS_WORKSPACE_KEY=%s\n' "$ACME_TICKETS_WORKSPACE_KEY"
    [ -n "${GITHUB_TOKEN:-}" ] && printf 'GITHUB_TOKEN=%s\n' "$GITHUB_TOKEN"
    true
  } > "$HANDOFF"
  chown "$CONSOLE_USER" "$HANDOFF"
  ARGS=(--secrets-file "$HANDOFF")
  [ "$OPEN_APP" -eq 1 ] && ARGS+=(--open)
  log "Running as $CONSOLE_USER"
  exec launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" -H \
    env OSAURUS_APP="$APP_PATH" "$0" "${ARGS[@]}"
fi

# --- 3. Check the installed app --------------------------------------------
[ -d "$APP_PATH" ] || die "Osaurus is not installed at $APP_PATH."
verify_app "$APP_PATH"

# The CLI ships inside the app. Do not rely on /usr/local/bin/osaurus: that
# link is optional and may point at another copy.
CLI="$APP_PATH/Contents/Helpers/osaurus"
[ -x "$CLI" ] || die "$CLI is missing. This Osaurus is too old for bundles."

version_at_least() {
  local -a have want
  local i
  IFS=. read -r -a have <<< "$1"
  IFS=. read -r -a want <<< "$2"
  for i in 0 1 2; do
    local h="${have[$i]:-0}" w="${want[$i]:-0}"
    h="${h%%[!0-9]*}"; w="${w%%[!0-9]*}"
    [ "${h:-0}" -gt "${w:-0}" ] && return 0
    [ "${h:-0}" -lt "${w:-0}" ] && return 1
  done
  return 0
}
INSTALLED_VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)"
version_at_least "$INSTALLED_VERSION" "$MIN_OSAURUS_VERSION" \
  || die "Osaurus $INSTALLED_VERSION is installed; this bundle needs $MIN_OSAURUS_VERSION or newer."

# --- 4. Store the secrets in the login Keychain ----------------------------
if [ -n "$SECRETS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      ACME_TICKETS_TOKEN|ACME_TICKETS_WORKSPACE_KEY|GITHUB_TOKEN) export "$key=$value" ;;
    esac
  done < "$SECRETS_FILE"
  # A root hand-off file has done its job.
  case "$SECRETS_FILE" in /tmp/acme-osaurus-secrets.*) rm -f "$SECRETS_FILE" ;; esac
fi

ask_secret() {
  local var="$1" prompt="$2"
  if [ -z "${!var:-}" ] && [ -t 0 ]; then
    local value
    read -r -s -p "$prompt: " value; echo >&2
    printf -v "$var" '%s' "$value"
    export "${var?}"
  fi
  [ -n "${!var:-}" ] || die "$var is not set. Pass it in the environment or with --secrets-file."
}

# -T trusts Osaurus to read the item without a prompt. Osaurus reads with
# prompts turned off, so an item without it is silently unreadable. The
# value goes in on stdin (`-w` last), never on the command line where other
# processes could see it. `-U` updates an existing item, so re-running
# rotates the secret.
store_secret() {
  local account="$1" value="$2"
  printf '%s\n%s\n' "$value" "$value" \
    | security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$account" -T "$APP_PATH" -w >/dev/null 2>&1 \
    || die "Could not store $KEYCHAIN_SERVICE/$account in the login Keychain."
  log "Stored keychain:$KEYCHAIN_SERVICE/$account"
}

ask_secret ACME_TICKETS_TOKEN "Acme Tickets API token"
ask_secret ACME_TICKETS_WORKSPACE_KEY "Acme Tickets workspace key"
ask_secret GITHUB_TOKEN "GitHub personal access token"
store_secret tickets-token "$ACME_TICKETS_TOKEN"
store_secret tickets-workspace-key "$ACME_TICKETS_WORKSPACE_KEY"
store_secret github-token "$GITHUB_TOKEN"
unset ACME_TICKETS_TOKEN ACME_TICKETS_WORKSPACE_KEY GITHUB_TOKEN

# --- 5. Validate, then install ---------------------------------------------
LOG_DIR="$HOME/Library/Logs/AcmeSupport"
mkdir -p "$LOG_DIR"

if ! "$CLI" import validate --from "$BUNDLE_DIR" --json > "$LOG_DIR/validate.json"; then
  die "The bundle did not validate. See $LOG_DIR/validate.json."
fi

# --yes confirms the high-risk items: two new MCP servers, one of them a
# local process (npx). Read the risks in validate.json before shipping.
set +e
"$CLI" import install --from "$BUNDLE_DIR" --yes --json > "$LOG_DIR/install.json"
STATUS=$?
set -e

STATE="$(plutil -extract state raw -o - "$LOG_DIR/install.json" 2>/dev/null || echo unknown)"
case "$STATUS" in
  0)
    if [ "$STATE" = "queued" ]; then
      log "Queued. Osaurus sets up the Acme agents the next time it opens."
    else
      log "Installed into the running Osaurus."
    fi
    ;;
  3)
    log "Installed. Something needs finishing in Osaurus (a secret it could not read, or a sign-in)."
    log "Details: $LOG_DIR/install.json, or run: $CLI import list --bundle $BUNDLE_ID"
    ;;
  *)
    die "Install failed ($STATE). Details: $LOG_DIR/install.json"
    ;;
esac

# --- 6. Open Osaurus (optional) --------------------------------------------
if [ "$OPEN_APP" -eq 1 ]; then
  open -a "$APP_PATH"
fi
exit "$STATUS"
