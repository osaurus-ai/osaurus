#!/usr/bin/env bash
# Verifies the contract between Config/floors.json#caseFloors.capability_search
# and the actual cases in Packages/OsaurusEvals/Suites/CapabilitySearch/.
# Both lists must be in sync: every suite case must have a matching floor entry,
# and every floor entry must correspond to a real suite case. Drift in either
# direction is a silent recall-floor coverage gap (the eval runner's
# --fail-on-floor flag can't fail a case that has no floor at all).
#
# This is the caseFloors half of the drift hazard pattern. The other half
# (suitePassRates vs the Makefile's EVALS_DETERMINISTIC_SUITES list) is
# covered by assert-eval-floors-makefile-sync.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $1"; }
fail_msg() { echo "FAIL $1" >&2; fail=1; }

FLOORS="$ROOT/Packages/OsaurusEvals/Config/floors.json"
SUITE_DIR="$ROOT/Packages/OsaurusEvals/Suites/CapabilitySearch"
DOMAIN="capability_search"

if [[ ! -f "$FLOORS" ]]; then
  fail_msg "Config/floors.json missing at $FLOORS"
  exit "$fail"
fi
if [[ ! -d "$SUITE_DIR" ]]; then
  fail_msg "CapabilitySearch suite directory missing at $SUITE_DIR"
  exit "$fail"
fi
if ! command -v jq >/dev/null 2>&1; then
  fail_msg "jq not on PATH (caseFloors parsing needs it)"
  exit "$fail"
fi

# Read the suite case IDs. Each .json fixture's "id" field. Sort.
suite_ids="$(for f in "$SUITE_DIR"/*.json; do
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('id',''))" "$f" 2>/dev/null
done | grep -E "^${DOMAIN}\." | sort)"
if [[ -z "$suite_ids" ]]; then
  fail_msg "no $DOMAIN.* case fixtures in $SUITE_DIR (suite may have been moved/renamed)"
  exit "$fail"
fi
pass "CapabilitySearch suite has $(echo "$suite_ids" | wc -l | tr -d ' ') $DOMAIN.* cases"

# Read the floor keys. Use jq + a temp file to avoid SIGPIPE under pipefail
# (the same pattern as assert-eval-floors-makefile-sync.sh).
floor_keys="$(jq -r --arg d "$DOMAIN" '.caseFloors[$d] | keys[]' "$FLOORS" 2>/dev/null | sort)"
if [[ -z "$floor_keys" ]]; then
  fail_msg "Config/floors.json#caseFloors.$DOMAIN is empty (jq parse failed or key missing)"
  exit "$fail"
fi
pass "Config/floors.json#caseFloors.$DOMAIN has $(echo "$floor_keys" | wc -l | tr -d ' ') entries"

# Forward drift: suite cases missing from the floor block. These are the
# dangerous ones — the eval runner's --fail-on-floor has nothing to check
# against, so a case that regresses to 0% match passes the gate silently.
for id in $suite_ids; do
  if ! grep -qxF "$id" <<< "$floor_keys"; then
    fail_msg "$DOMAIN case '$id' is in the suite but missing from Config/floors.json#caseFloors.$DOMAIN"
  fi
done
[[ "$fail" -eq 0 ]] && pass "every suite case has a matching caseFloors entry"

# Reverse drift: floor entries with no matching suite case. Stale floors —
# the eval runner skips them at run time, but they pollute the floor list
# and confuse maintainers reading the contract.
for id in $floor_keys; do
  if ! grep -qxF "$id" <<< "$suite_ids"; then
    fail_msg "caseFloors.$DOMAIN entry '$id' has no matching case in $SUITE_DIR"
  fi
done
[[ "$fail" -eq 0 ]] && pass "every caseFloors entry has a matching suite case"

exit "$fail"
