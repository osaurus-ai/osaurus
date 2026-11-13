#!/usr/bin/env bash
# Phase 2 local lanes: every suite in SUITES on every model in MODELS.
# Reports land in OUT/<label>/<suite>/<model>.json with the full log beside
# each. Run from the checkout whose code is under test.
#   MODELS="mlx-community/Qwen3-4B-4bit OsaurusAI/Raptor-0.6-4B-JANG_6M" \
#   SUITES="Orchestrator ArchitectInline" LABEL=baseline bash scripts/evals/phase2-run-lanes.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LABEL="${LABEL:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT="${OUT:-${REPO_ROOT}/build/evals/phase2}/${LABEL}"
HOST_VERSION="$(sed -n 's:.*<sparkle\:shortVersionString>\(.*\)</sparkle\:shortVersionString>.*:\1:p' "${REPO_ROOT}/docs/appcast.xml" | head -1)"

mkdir -p "${OUT}"
{
  echo "sha=$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  echo "dirty_files=$(git -C "${REPO_ROOT}" status --porcelain | wc -l | tr -d ' ')"
  echo "vmlx=$(grep -A6 '"identity": "vmlx-swift"' "${REPO_ROOT}/Packages/OsaurusCore/Package.resolved" | grep -E '"(revision|version)"' | tr -d ' ,"' | tr '\n' ' ')"
  echo "host_version=${HOST_VERSION}"
  echo "models=${MODELS}"
  echo "suites=${SUITES}"
  echo "started=$(date -u +%FT%TZ)"
} >>"${OUT}/run.meta"

for model in ${MODELS}; do
  slug="${model//\//__}"
  for suite in ${SUITES}; do
    mkdir -p "${OUT}/${suite}"
    echo "== ${model} ${suite} $(date -u +%T)"
    OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test-phase2 \
      OSAURUS_HOST_VERSION="${HOST_VERSION}" \
      swift run --skip-build --package-path "${REPO_ROOT}/Packages/OsaurusEvals" osaurus-evals run \
      --suite "${REPO_ROOT}/Packages/OsaurusEvals/Suites/${suite}" \
      --model "${model}" \
      ${EXTRA_ARGS:-} \
      --out "${OUT}/${suite}/${slug}.json" >"${OUT}/${suite}/${slug}.log" 2>&1
    echo "   exit=$? $(grep -m1 'totals:' "${OUT}/${suite}/${slug}.log")"
  done
done
echo "finished=$(date -u +%FT%TZ)" >>"${OUT}/run.meta"
