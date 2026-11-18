#!/usr/bin/env bash
# Clean-install proof of the first run: a fresh data root, the proof app's
# defaults domain cleared, and its macOS privacy entries reset, so every
# dialog, the walkthrough, and the first asks behave as they do for a new
# user. Builds on build-keychain-free-osaurus.sh and
# launch-keychain-free-osaurus.sh, then writes the checklist for what a
# script cannot do (answering macOS dialogs, the walkthrough, Skip setup).
#
# Usage: run-first-run-golden-path.sh light|full [--skip-build] [--onboarded]
#   light        no bundled model: onboarding downloads Raptor 0.7 (~3.7 GB
#                into the proof's own models folder).
#   full         Raptor 0.7 staged as the full DMG stages it and seeded on
#                launch through OSAURUS_BUNDLED_MODELS_DIR.
#   --skip-build reuse the app already built at FIRSTRUN_DERIVED_DATA.
#   --onboarded  preset hasCompletedOnboarding (the reinstall / upgrade row).
#
# Environment:
#   FIRSTRUN_BUNDLE_ID      proof bundle id (default com.dinoki.osaurus.firstrunproof).
#                           Never the shipping id: the reset below would wipe
#                           the real app's grants and settings.
#   FIRSTRUN_DERIVED_DATA   absolute DerivedData path (default <repo>/build/firstrun-derived).
#   FIRSTRUN_RAPTOR_SOURCE  local Raptor 0.7 bundle for `full`
#                           (default ~/MLXModels/OsaurusAI/Raptor-0.7-4B-JANG_6M;
#                           downloaded at the pinned revision when absent).
#   FIRSTRUN_ALLOW_KEYCHAIN=1  launch with the login Keychain enabled. Osaurus
#                           Cloud sign-in needs it (the Osaurus identity is a
#                           Keychain item); without it the Cloud rows are BLOCKED.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/live-proof"

VARIANT="${1:-}"
shift || true
SKIP_BUILD=0
ONBOARDED=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --onboarded) ONBOARDED=1 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done
if [[ "$VARIANT" != "light" && "$VARIANT" != "full" ]]; then
  echo "usage: $0 light|full [--skip-build] [--onboarded]" >&2
  exit 64
fi

BUNDLE_ID="${FIRSTRUN_BUNDLE_ID:-com.dinoki.osaurus.firstrunproof}"
if [[ ! "$BUNDLE_ID" =~ ^com\.dinoki\.osaurus\.[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  echo "FIRSTRUN_BUNDLE_ID must be a unique com.dinoki.osaurus.* id, never the shipping one: $BUNDLE_ID" >&2
  exit 64
fi
DERIVED_DATA="${FIRSTRUN_DERIVED_DATA:-$ROOT/build/firstrun-derived}"
RAPTOR_SOURCE="${FIRSTRUN_RAPTOR_SOURCE:-$HOME/MLXModels/OsaurusAI/Raptor-0.7-4B-JANG_6M}"
APP="$DERIVED_DATA/Build/Products/Release/osaurus.app"
STAMP="$(date +%Y%m%d-%H%M%S)"
TEST_ROOT="/tmp/osaurus-firstrun-$VARIANT-$STAMP"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  "$HERE/build-keychain-free-osaurus.sh" "$DERIVED_DATA" "$BUNDLE_ID"
fi
if [[ ! -x "$APP/Contents/MacOS/osaurus" ]]; then
  echo "no built app at $APP (drop --skip-build)" >&2
  exit 66
fi
BUILT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [[ "$BUILT_ID" != "$BUNDLE_ID" ]]; then
  echo "built app is $BUILT_ID, expected $BUNDLE_ID (rebuild without --skip-build)" >&2
  exit 65
fi

# A first run starts with no proof app running, no settings, and no grants.
pkill -f "$APP/Contents/MacOS/osaurus" 2>/dev/null || true
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset All "$BUNDLE_ID" >/dev/null
if [[ "$ONBOARDED" -eq 1 ]]; then
  defaults write "$BUNDLE_ID" hasCompletedOnboarding -bool true
fi

mkdir -p "$TEST_ROOT/models"
unset OSAURUS_BUNDLED_MODELS_DIR
# Keychain-free launches are headless (HTTP server only) unless asked to
# present the onboarding and chat windows a person sees.
export OSAURUS_KEYCHAIN_FREE_SHOW_UI=1
if [[ "$VARIANT" == "full" ]]; then
  if [[ -d "$RAPTOR_SOURCE" ]]; then
    BUNDLED_MODEL_SOURCE_DIR="$RAPTOR_SOURCE" "$ROOT/scripts/build/fetch_bundled_model.sh" "$TEST_ROOT/BundledModels"
  else
    "$ROOT/scripts/build/fetch_bundled_model.sh" "$TEST_ROOT/BundledModels"
  fi
  export OSAURUS_BUNDLED_MODELS_DIR="$TEST_ROOT/BundledModels"
fi

SOURCE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
DIRTY="$(git -C "$ROOT" status --porcelain | wc -l | tr -d ' ')"
APP_HASH="$(/usr/bin/codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/{print $2}')"
cat > "$TEST_ROOT/proof.env" <<EOF
variant=$VARIANT
onboarded_preset=$ONBOARDED
source_sha=$SOURCE_SHA
dirty_files=$DIRTY
bundle_id=$BUNDLE_ID
app=$APP
app_cdhash=$APP_HASH
keychain=$([[ "${FIRSTRUN_ALLOW_KEYCHAIN:-}" == "1" ]] && echo enabled || echo disabled)
bundled_models_dir=${OSAURUS_BUNDLED_MODELS_DIR:-}
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

cat > "$TEST_ROOT/checklist.md" <<'EOF'
# First-run golden path

Fill in every row. A row without its evidence is PARTIAL; a row that could
not run is BLOCKED with the reason. Record token/s for every generation.

## Launch
- [ ] Onboarding opens (or, with --onboarded, the app opens straight to chat)
- [ ] light: Raptor 0.7 download starts and finishes; note the time
- [ ] full: Raptor 0.7 is seeded at launch and Configure AI is skipped
- [ ] The team exists after onboarding (Management → Agents shows Planner,
      Courier, Keeper, Scout); with Skip setup, the Create your team card shows

## Walkthrough, each card on Raptor 0.7
For each ask: the macOS dialog shown (or none), your answer, the panel
shown (or none), the teammate that ran, the final text, token/s.
- [ ] Planner: Allow Calendar and Reminders, then all three asks
- [ ] Courier: all three asks; the Automation dialog for Mail appears before
      the first script runs, not as a timeout
- [ ] Keeper: the Downloads dialog, then all three asks
- [ ] Scout: both examples and one typed topic
- [ ] Builder: pick a project folder, then all three asks
- [ ] Osaurus: all three asks

## Typed first questions (Orchestrator, before any card)
- [ ] "What's on my calendar today?" routes to Planner, never "I don't have the tools"
- [ ] "What's due today?" routes to Planner
- [ ] "Any unread mail?" routes to Courier

## Permission dialogs
For Calendar (EventKit), Mail (Automation), and Messages (Full Disk Access):
- [ ] Not decided: the macOS dialog appears before the tool runs
- [ ] Don't Allow: the Osaurus panel names the agent, the tool, and the
      System Settings path; Not Now returns a clear message
- [ ] Turned off in System Settings: Open System Settings, turn it on,
      come back: Try Again (or returning to Osaurus) lets the call run
- [ ] Full Disk Access (never asked by macOS): the panel appears at once
- [ ] Left unanswered for 10 minutes: the panel closes, chat gets a clear
      message, a workflow node showed Waiting for you meanwhile
- [ ] Same flows through Planner via the Orchestrator and in a scheduled workflow

## Osaurus Cloud (needs FIRSTRUN_ALLOW_KEYCHAIN=1, else BLOCKED)
- [ ] Skip setup, sign in, DeepSeek selected; typed questions and one ask per card
- [ ] Switch the Orchestrator to Raptor 0.7; typed questions again
- [ ] Architect on Raptor 0.7 shows the model notice; both choices work and
      "keep local" stays dismissed after relaunch

## Edge cases (Planner and Courier, permission granted)
- [ ] Mail with no account: "Mail has no account set up…"
- [ ] Mail not running: Mail's own error, not a permission message
- [ ] No calendars / iCloud not synced: "Calendar has no calendars on this Mac yet…"
- [ ] Calendar Add Only: the panel says choose Full Access
- [ ] Calendar denied, Reminders allowed: the reminders half still answers
- [ ] First ask while Raptor 0.7 is still loading

## Finish
- [ ] Every turn closes: reasoning done, cards settled, Stop gone, input
      unlocked, and a follow-up turn completes
- [ ] Relaunch: grants and answers above persist
EOF

if [[ "${FIRSTRUN_ALLOW_KEYCHAIN:-}" == "1" ]]; then
  BIN="$APP/Contents/MacOS/osaurus"
  nohup env OSAURUS_TEST_ROOT="$TEST_ROOT" OSU_MODELS_DIR="$TEST_ROOT/models" \
    "$BIN" >"$TEST_ROOT/osaurus.log" 2>&1 &
  echo "$!" > "$TEST_ROOT/osaurus.pid"
  echo "pid=$(cat "$TEST_ROOT/osaurus.pid")"
  echo "test_root=$TEST_ROOT"
  echo "log=$TEST_ROOT/osaurus.log"
  echo "keychain=enabled (Osaurus Cloud rows can run)"
else
  "$HERE/launch-keychain-free-osaurus.sh" "$APP" "$TEST_ROOT"
  echo "keychain=disabled (Osaurus Cloud rows are BLOCKED; rerun with FIRSTRUN_ALLOW_KEYCHAIN=1)"
fi
echo "proof=$TEST_ROOT/proof.env"
echo "checklist=$TEST_ROOT/checklist.md"
