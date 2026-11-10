#!/usr/bin/env bash
# Declared-model screen for the routing flip: each installed text bundle must
# load, make one tool call with parseable JSON arguments, and answer from the
# result (AgentLoop/calculator-tip-percent). One report per bundle under OUT.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${OUT:-${REPO_ROOT}/build/evals/phase2/screen}"
HOST_VERSION="$(sed -n 's:.*<sparkle\:shortVersionString>\(.*\)</sparkle\:shortVersionString>.*:\1:p' "${REPO_ROOT}/docs/appcast.xml" | head -1)"
mkdir -p "${OUT}"

for model in "$@"; do
  slug="${model//\//__}"
  echo "== ${model}"
  OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test OSAURUS_HOST_VERSION="${HOST_VERSION}" \
    swift run --skip-build --package-path "${REPO_ROOT}/Packages/OsaurusEvals" osaurus-evals run \
    --suite "${REPO_ROOT}/Packages/OsaurusEvals/Suites/AgentLoop" \
    --filter calculator-tip-percent \
    --model "${model}" \
    --out "${OUT}/${slug}.json" >"${OUT}/${slug}.log" 2>&1
  echo "   exit=$?"
done
