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
#   PR=1 MODEL=mlx-community/Qwen3-4B-4bit make evals-contribute   # auto-PR
#
# Notes:
#   - For LLM-judged suites, export a strong judge key (e.g. XAI_API_KEY) or
#     JUDGE_MODEL so your run isn't self-judged; the contribution records which
#     judge graded it. Without one, rubric grades are weaker (flagged as a
#     caveat in the leaderboard).
#   - Set KV_REGIME=memory-only|disk-l2|paged to record the cache regime.
#   - Remote models (e.g. xai/grok-4.3) need the matching <PREFIX>_API_KEY.
#   - PR=1 automates the submission end-to-end with the GitHub CLI (`gh`):
#     branch → commit (ONLY the contribution file) → push (forking first when
#     you don't have push access) → `gh pr create`. See COMMUNITY_EVALS.md.

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

# Contributor identity for attribution + the leaderboard's contributor
# ranking. Override with CONTRIBUTOR=<handle>; otherwise resolved from the
# GitHub CLI login (preferred — matches the PR author) or git config.
if [[ -z "${CONTRIBUTOR:-}" ]]; then
  CONTRIBUTOR="$(gh api user --jq .login 2>/dev/null || true)"
fi
if [[ -z "${CONTRIBUTOR:-}" ]]; then
  CONTRIBUTOR="$(git -C "${REPO_ROOT}" config github.user 2>/dev/null || true)"
fi
if [[ -z "${CONTRIBUTOR:-}" ]]; then
  CONTRIBUTOR="$(git -C "${REPO_ROOT}" config user.name 2>/dev/null || true)"
fi
if [[ -n "${CONTRIBUTOR:-}" ]]; then
  export OSAURUS_EVALS_CONTRIBUTOR="${CONTRIBUTOR}"
  log "Contributing as: ${CONTRIBUTOR} (override with CONTRIBUTOR=<handle>)"
fi

# Filename: <chip>-<model>-<date>.json — descriptive and collision-resistant
# across contributors and machines. Computed up front so a PR=1 re-run can
# submit today's already-produced file without re-running the whole suite.
chip_raw="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
[[ -z "${chip_raw}" ]] && chip_raw="$(sysctl -n hw.model 2>/dev/null || true)"
chip_label="$(printf '%s' "${chip_raw}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
chip_label="${chip_label#-}"; chip_label="${chip_label%-}"
[[ -z "${chip_label}" ]] && chip_label="mac"
model_label="$(printf '%s' "${MODEL}" | tr '/ ' '--')"
stamp="$(date +%Y%m%d)"
filename="${chip_label}-${model_label}-${stamp}.json"
rel="reports/community/${filename}"

if [[ "${PR:-0}" == "1" && -s "${COMMUNITY_DIR}/${filename}" ]]; then
  log "Re-using today's contribution ${rel} (delete it to force a fresh run)."
else
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

  mkdir -p "${COMMUNITY_DIR}"
  cp "${MATRIX}" "${COMMUNITY_DIR}/${filename}"
  log "Wrote contribution → ${rel}"
  "${BIN}" compat "${COMMUNITY_DIR}" || true
fi

# ---------------------------------------------------------------------------
# PR=1 — automated submission. Creates a branch containing ONLY the
# contribution file, pushes it (forking first when the contributor has no
# push access to the upstream repo), and opens the PR with `gh`.
# ---------------------------------------------------------------------------
branch="evals/compat-${chip_label}-${model_label}-${stamp}"
pr_title="evals(community): ${MODEL} on ${chip_raw:-Mac}"
env_summary="$(
  /usr/bin/python3 - "${COMMUNITY_DIR}/${filename}" <<'PY' 2>/dev/null || true
import json, sys
m = json.load(open(sys.argv[1]))
env = (m.get("models") or [{}])[0].get("environment") or {}
parts = []
for key in ("chip", "totalRamMb", "osVersion", "commit", "judge", "kvRegime", "catalogHash", "contributor"):
    v = env.get(key)
    if v is None:
        continue
    if key == "totalRamMb":
        parts.append(f"RAM {round(v / 1024)}GB")
    else:
        parts.append(f"{key}={v}")
print(" · ".join(parts))
PY
)"

if [[ "${PR:-0}" == "1" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    log "ERROR: PR=1 needs the GitHub CLI (brew install gh; gh auth login)."
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    log "ERROR: gh is not authenticated. Run: gh auth login"
    exit 1
  fi

  upstream="$(git -C "${REPO_ROOT}" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
  push_remote="origin"
  permission="$(gh repo view "${upstream}" --json viewerPermission --jq .viewerPermission 2>/dev/null || echo NONE)"
  if [[ "${permission}" != "ADMIN" && "${permission}" != "MAINTAIN" && "${permission}" != "WRITE" ]]; then
    log "No push access to ${upstream}; forking (once) and pushing there…"
    gh repo fork "${upstream}" --remote --remote-name fork >/dev/null 2>&1 || true
    if git -C "${REPO_ROOT}" remote get-url fork >/dev/null 2>&1; then
      push_remote="fork"
    else
      log "ERROR: could not create/attach a fork remote. Fork manually, then re-run."
      exit 1
    fi
  fi

  # Head ref for `gh pr create`: "owner:branch" for fork PRs, bare branch
  # name when pushing straight to the upstream repo.
  head_ref="${branch}"
  if [[ "${push_remote}" == "fork" ]]; then
    gh_login="$(gh api user --jq .login 2>/dev/null || true)"
    if [[ -z "${gh_login}" ]]; then
      log "ERROR: could not resolve your GitHub login for the fork PR head."
      exit 1
    fi
    head_ref="${gh_login}:${branch}"
  fi

  # Isolated worktree so the PR contains ONLY the contribution file — the
  # contributor's checkout may have unrelated local changes we must not ship.
  base_ref="$(git -C "${REPO_ROOT}" ls-remote origin -q --symref HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2}')"
  base_ref="${base_ref:-main}"
  worktree="$(mktemp -d)/contrib"
  git -C "${REPO_ROOT}" fetch origin "${base_ref}" --quiet
  git -C "${REPO_ROOT}" worktree add --quiet -b "${branch}" "${worktree}" "origin/${base_ref}"
  mkdir -p "${worktree}/reports/community"
  cp "${COMMUNITY_DIR}/${filename}" "${worktree}/${rel}"
  git -C "${worktree}" add "${rel}"
  git -C "${worktree}" commit --quiet -m "${pr_title}"
  if git -C "${worktree}" push -u "${push_remote}" "${branch}"; then
    pr_url="$(gh pr create \
      --repo "${upstream}" \
      --base "${base_ref}" \
      --head "${head_ref}" \
      --title "${pr_title}" \
      --body "$(printf 'Crowdsourced model-compatibility run (see COMMUNITY_EVALS.md).\n\nOne contribution file; no other changes.\n\nEnvironment: %s' "${env_summary:-see contribution file}")" \
      2>&1 | tail -1)" || true
    log "PR: ${pr_url}"
  else
    log "ERROR: push failed. Push ${branch} manually and open the PR."
  fi
  git -C "${REPO_ROOT}" worktree remove --force "${worktree}" >/dev/null 2>&1 || true
  git -C "${REPO_ROOT}" branch -D "${branch}" >/dev/null 2>&1 || true
  exit 0
fi

cat <<EOF

Thanks for contributing! To share your result automatically:

  PR=1 MODEL=${MODEL} make evals-contribute      # re-uses this run's file

Or open the PR yourself with just this file:

  git checkout -b ${branch}
  git add ${rel}
  git commit -m "${pr_title}"
  git push -u origin HEAD
  gh pr create --title "${pr_title}" \\
    --body "Crowdsourced model-compatibility run. One contribution file; no other changes."

Prefer not to use git? Open a "Model compatibility report" issue and paste the
contents of ${rel} — a maintainer will commit it for you.

A maintainer regenerates the committed leaderboard from all contributions:
  make evals-compat
EOF
