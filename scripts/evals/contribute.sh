#!/usr/bin/env bash
set -uo pipefail

# Crowdsource model compatibility — run the per-model LLM suites for ONE model
# on YOUR Mac and emit a single, self-contained contribution file under
# reports/community/. One file per contribution = zero merge conflicts (you
# only ever ADD a file, never edit a shared blob), so many contributors can
# open PRs in parallel. A maintainer folds every contribution into the
# committed COMPATIBILITY.md leaderboard (`make evals-compat`).
#
#   run (your hardware) ──▶ reports/community/<chip>-<model>-<date>.json ──▶ PR
#
# Usage:
#   bash scripts/evals/contribute.sh mlx-community/Qwen3-4B-4bit
#   MODEL=mlx-community/Qwen3-4B-4bit make evals-contribute
#
# Notes:
#   - For LLM-judged suites, export a strong judge key (e.g. XAI_API_KEY) or
#     JUDGE_MODEL so your run isn't self-judged; the contribution records which
#     judge graded it. Without one, rubric grades are weaker (flagged as a
#     caveat in the leaderboard).
#   - Set KV_REGIME=memory-only|disk-l2|paged to record the cache regime.
#   - Remote models (e.g. xai/grok-4.3) need the matching <PREFIX>_API_KEY.

MODEL="${1:-${MODEL:-}}"
if [[ -z "${MODEL}" ]]; then
  printf 'usage: bash scripts/evals/contribute.sh <model-id>\n' >&2
  printf '   e.g. bash scripts/evals/contribute.sh mlx-community/Qwen3-4B-4bit\n' >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EVALS_PKG="${REPO_ROOT}/Packages/OsaurusEvals"
COMMUNITY_DIR="${REPO_ROOT}/reports/community"
LOOP_OUT_ROOT="${REPO_ROOT}/build/evals/contribute"

log() { printf '[contribute] %s\n' "$*"; }

# Provenance the run path stamps into every report's environment block.
OSAURUS_EVALS_COMMIT="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || true)"
export OSAURUS_EVALS_COMMIT
if [[ -n "${KV_REGIME:-}" ]]; then
  export OSAURUS_EVALS_KV_REGIME="${KV_REGIME}"
fi

# Drive the existing loop for exactly this one model, skipping the
# model-independent deterministic suites and the maintainer snapshot/history.
log "Running LLM suites for ${MODEL} (this can take a while)…"
MODELS="${MODEL}" SKIP_DET=1 RECORD=0 LOOP_OUT_ROOT="${LOOP_OUT_ROOT}" \
  bash "${SCRIPT_DIR}/optimization-loop.sh"

MATRIX="${LOOP_OUT_ROOT}/latest/matrix.json"
if [[ ! -s "${MATRIX}" ]]; then
  log "ERROR: no matrix.json produced at ${MATRIX}; the run failed before scoring."
  exit 1
fi

BIN="$(swift build --package-path "${EVALS_PKG}" --show-bin-path)/osaurus-evals"

# Validate provenance BEFORE writing the contribution: a row without chip /
# catalogHash is not trustworthy crowdsourced data and would fail the PR gate.
TMP_VALIDATE="$(mktemp -d)"
trap 'rm -rf "${TMP_VALIDATE}"' EXIT
cp "${MATRIX}" "${TMP_VALIDATE}/contribution.json"
if ! "${BIN}" compat "${TMP_VALIDATE}" --validate; then
  log "ERROR: the produced contribution is missing required provenance (see above)."
  exit 1
fi

# Filename: <chip>-<model>-<date>.json — descriptive and collision-resistant
# across contributors and machines.
chip_raw="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
[[ -z "${chip_raw}" ]] && chip_raw="$(sysctl -n hw.model 2>/dev/null || true)"
chip_label="$(printf '%s' "${chip_raw}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
chip_label="${chip_label#-}"; chip_label="${chip_label%-}"
[[ -z "${chip_label}" ]] && chip_label="mac"
model_label="$(printf '%s' "${MODEL}" | tr '/ ' '--')"
stamp="$(date +%Y%m%d)"
filename="${chip_label}-${model_label}-${stamp}.json"

mkdir -p "${COMMUNITY_DIR}"
cp "${MATRIX}" "${COMMUNITY_DIR}/${filename}"
rel="reports/community/${filename}"

log "Wrote contribution → ${rel}"
"${BIN}" compat "${COMMUNITY_DIR}" || true

cat <<EOF

Thanks for contributing! To share your result, open a PR with just this file:

  git checkout -b evals/compat-${chip_label}-${model_label}
  git add ${rel}
  git commit -m "evals(community): ${MODEL} on ${chip_raw:-this Mac}"
  git push -u origin HEAD
  gh pr create --title "evals(community): ${MODEL} on ${chip_raw:-Mac}" \\
    --body "Crowdsourced model-compatibility run. One contribution file; no other changes."

Prefer not to use git? Open a "Model compatibility report" issue and paste the
contents of ${rel} — a maintainer will commit it for you.

A maintainer regenerates the committed leaderboard from all contributions:
  make evals-compat
EOF
