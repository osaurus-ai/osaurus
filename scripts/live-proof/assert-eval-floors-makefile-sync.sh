#!/usr/bin/env bash
# Verifies the contract between Makefile's EVALS_DETERMINISTIC_SUITES and
# Packages/OsaurusEvals/Config/floors.json#suitePassRates. Both list the
# same token-free deterministic suites; this guard catches a contributor
# who adds a key to floors.json but forgets a Suites/<name>/ directory,
# who hand-edits the Makefile list, or who breaks the jq derivation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $1"; }
fail_msg() { echo "FAIL $1" >&2; fail=1; }

FLOORS="$ROOT/Packages/OsaurusEvals/Config/floors.json"
SUITES_DIR="$ROOT/Packages/OsaurusEvals/Suites"

if [[ ! -f "$FLOORS" ]]; then
  fail_msg "Config/floors.json missing at $FLOORS"
  exit "$fail"
fi

if ! command -v jq >/dev/null 2>&1; then
  fail_msg "jq not on PATH (Makefile derivation needs it)"
  exit "$fail"
fi

# Read the JSON keys. Tr/normalize to a single space-separated line.
json_keys="$(jq -r '.suitePassRates | keys[]' "$FLOORS" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
if [[ -z "$json_keys" ]]; then
  fail_msg "Config/floors.json suitePassRates has no keys (or jq parse failed)"
  exit "$fail"
fi
pass "Config/floors.json suitePassRates has $(echo "$json_keys" | wc -w | tr -d ' ') keys"

# Read the Makefile's resolved value. `make -p` prints the database; filter
# for the exact variable and take the right-hand side. The pipe to awk
# would SIGPIPE on a multi-MB database (awk exits after the first match);
# write the db to a temp file first and read it from there.
make_db="$(mktemp)"
trap 'rm -f "$make_db"' EXIT
make -n -p 2>/dev/null > "$make_db" || true
make_keys="$(awk -F' := ' '
  /^EVALS_DETERMINISTIC_SUITES := / { sub(/\r$/, ""); print $2; exit }
' "$make_db")"
if [[ -z "$make_keys" ]]; then
  fail_msg "Makefile did not resolve EVALS_DETERMINISTIC_SUITES (jq derivation produced empty value?)"
  exit "$fail"
fi
pass "Makefile resolved EVALS_DETERMINISTIC_SUITES = $make_keys"

# Both are sorted by jq, so a direct string compare is enough. If a future
# PR unsorts one side, sort here and compare; the failure message is the
# same and the contract is the same.
if [[ "$json_keys" != "$make_keys" ]]; then
  fail_msg "EVALS_DETERMINISTIC_SUITES drift between Makefile and Config/floors.json"
  echo "  floors.json suitePassRates keys: $json_keys" >&2
  echo "  Makefile EVALS_DETERMINISTIC_SUITES:  $make_keys" >&2
fi

# Every key in suitePassRates must have a Suites/<name>/ directory. Catches
# a contributor who adds a deterministic suite to floors.json but forgets
# the actual suite directory; the Makefile lane would then fail at the
# first iteration of `evals-deterministic` with a confusing "no such path"
# error instead of a clear drift report here.
for name in $json_keys; do
  if [[ ! -d "$SUITES_DIR/$name" ]]; then
    fail_msg "floors.json suitePassRates key '$name' has no matching $SUITES_DIR/$name directory"
  fi
done
[[ "$fail" -eq 0 ]] && pass "every suitePassRates key has a matching Suites/<name>/ directory"

exit "$fail"
