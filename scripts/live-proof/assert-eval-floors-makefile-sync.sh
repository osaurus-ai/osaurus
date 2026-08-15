#!/usr/bin/env bash
# Guards the single-source-of-truth contract from issue #2266: the
# `evals-deterministic` CI lane must be DERIVED from
# `Config/floors.json#suitePassRates`, never a hand-maintained copy. A literal
# list silently ships a thinner lane than the floor gate enforces the moment a
# contributor adds a suite to one file and forgets the other.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAKEFILE="$ROOT/Makefile"
FLOORS="$ROOT/Packages/OsaurusEvals/Config/floors.json"
SUITES_DIR="$ROOT/Packages/OsaurusEvals/Suites"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

for f in "$MAKEFILE" "$FLOORS"; do
  if [[ -f "$f" ]]; then
    pass "exists: ${f#"$ROOT"/}"
  else
    fail_msg "missing: ${f#"$ROOT"/}"
    exit 1
  fi
done

# 1. The variable must be derived, not literal.
assignment="$(grep -E '^EVALS_DETERMINISTIC_SUITES[[:space:]]*:?=' "$MAKEFILE" || true)"
if [[ -z "$assignment" ]]; then
  fail_msg "EVALS_DETERMINISTIC_SUITES assignment not found in Makefile"
elif [[ "$assignment" == *'jq'*'suitePassRates'* ]]; then
  pass "EVALS_DETERMINISTIC_SUITES is derived from floors.json"
else
  fail_msg "EVALS_DETERMINISTIC_SUITES is hand-maintained again: $assignment"
fi

# 2. It must read the real floors file.
if grep -qE '^EVALS_FLOORS_JSON[[:space:]]*:?=[[:space:]]*Packages/OsaurusEvals/Config/floors.json' "$MAKEFILE"; then
  pass "EVALS_FLOORS_JSON points at the canonical floors.json"
else
  fail_msg "EVALS_FLOORS_JSON does not point at Packages/OsaurusEvals/Config/floors.json"
fi

# 3. Every declared deterministic suite must actually exist on disk —
#    otherwise the derived lane expands to a suite path the harness cannot run.
missing=""
while IFS= read -r suite; do
  [[ -n "$suite" ]] || continue
  if [[ -d "$SUITES_DIR/$suite" ]]; then
    pass "suite directory present: $suite"
  else
    missing="$missing $suite"
  fi
done < <(jq -r '.suitePassRates | keys_unsorted[]' "$FLOORS")
if [[ -n "$missing" ]]; then
  fail_msg "floors.json declares suites with no Suites/<name>/ directory:$missing"
fi

# 4. The derivation must expand to a non-empty list (a jq typo would yield
#    silence, and `make evals-deterministic` would then pass by running nothing).
derived="$(cd "$ROOT" && make -s print-evals-deterministic-suites 2>/dev/null | tr -s '[:space:]' '\n' | grep -v '^$' | sort)"
declared="$(jq -r '.suitePassRates | keys_unsorted[]' "$FLOORS" | sort)"
if [[ -z "$derived" ]]; then
  fail_msg "EVALS_DETERMINISTIC_SUITES expands to NOTHING — the lane would pass by running zero suites"
elif [[ "$derived" == "$declared" ]]; then
  pass "derived lane matches floors.json exactly ($(echo "$derived" | wc -l | tr -d ' ') suites)"
else
  fail_msg "derived lane != floors.json. derived: $(echo $derived) | declared: $(echo $declared)"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "eval-floors/Makefile sync: FAILED" >&2
  exit 1
fi
echo "eval-floors/Makefile sync: OK"
