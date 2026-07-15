#!/usr/bin/env bash
set -uo pipefail

# Osaurus AppleScript capability lab — the harness-variant sweep.
#
# Runs the AppleScript LIVE suite (the on-device 16B model + a side-effect-free
# mock executor) under several `HarnessOptions` variants and scoreboards which
# variant gets the most out of the FIXED model — the concrete "bring out the
# full potential" loop. The model is the constant; the harness is the variable.
#
#   sweep variants ──▶ per-variant reports ──▶ scoreboard (best variant)
#                                          └─▶ (optional) diff vs a baseline
#
# The variants are applied WITHOUT editing the suite: the runner reads the
# `OSAURUS_AS_*` env vars (prompt phrasing, literal-announcement style, verify
# read-back, desktop context) and layers them over each case. Unset env keeps
# shipped behavior, so `make evals` / CI are unaffected.
#
# Judge: Grok by default (JUDGE_MODEL=xai/grok-4.3). The xAI key is read ONLY
# from the XAI_API_KEY environment variable at run time (consumed by the CLI's
# EvalRemoteProviderBootstrap); it is never written to disk, the report, or this
# script. Rotate any key shared in plaintext after use.
#
# Env overrides:
#   MODEL          AppleScript model routed through the runner. Default "auto"
#                  (the currently configured local model). Live cases SKIP when
#                  no AppleScript model is installed.
#   FILTER         case-id substring filter. Default "live-" (the mock-world
#                  capability lane; the trailing hyphen keeps the substring
#                  match from also catching the liveproof-* cases). Use
#                  "liveproof" for the real-executor ground-truth lane
#                  (permission-gated, REAL side effects), or "" for all.
#                  The liveproof lane can intermittently wedge the CLI's
#                  concurrency runtime on a real-executor case; the per-case
#                  watchdog (OSAURUS_EVALS_CASE_TIMEOUT_SEC, default 600)
#                  records the row as `errored` and terminates the suite with
#                  a complete report, so a wedge never silently stalls a sweep
#                  — rerun the lane to get scores for the remaining rows.
#   SUITE          suite dir (relative to the OsaurusEvals package). Default
#                  "Suites/AppleScript".
#   VARIANTS       newline-separated "name|prompt|literal|verify|desktop" rows
#                  overriding the default sweep. Use "-" to leave a field at the
#                  case/shipped default. prompt ∈ {standard,concise}; literal ∈
#                  {namePreview,nameOnly,minimal}; verify/desktop ∈ {0,1,-}.
#   JUDGE_MODEL    judge slug. Default "xai/grok-4.3". Needs XAI_API_KEY.
#   BASELINE       a previous lab run dir; each variant is diffed against the
#                  same-named report in it.
#   LAB_OUT_ROOT   parent dir for timestamped runs. Default
#                  build/evals/applescript-capability-lab.
#   RECORD         "1" → also refresh SNAPSHOT.{md,json} + history.jsonl under
#                  SNAPSHOT_DIR (the committed AppleScript scoreboard).
#   SNAPSHOT_DIR   committed scoreboard dir. Default reports/applescript-capability.
#   LABEL          free-form note recorded in the history row (with RECORD=1).
#   SUITE_TIMEOUT_SEC  hard wall-clock cap per variant subprocess. Default 2700.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EVALS_PKG="${REPO_ROOT}/Packages/OsaurusEvals"

MODEL="${MODEL:-auto}"
FILTER="${FILTER:-live-}"
SUITE="${SUITE:-Suites/AppleScript}"
LAB_OUT_ROOT="${LAB_OUT_ROOT:-${REPO_ROOT}/build/evals/applescript-capability-lab}"
BASELINE="${BASELINE:-}"
RECORD="${RECORD:-0}"
LABEL="${LABEL:-}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-${REPO_ROOT}/reports/applescript-capability}"
JUDGE_MODEL="${JUDGE_MODEL:-xai/grok-4.3}"
SUITE_TIMEOUT_SEC="${SUITE_TIMEOUT_SEC:-2700}"
export JUDGE_MODEL

log() { printf '[as-lab] %s\n' "$*"; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '3,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

# Default sweep: each row isolates ONE lever against the shipped config so the
# scoreboard reads as a clean A/B. "name|prompt|literal|verify|desktop".
# `-` leaves a field at the shipped default; the shipped literal style is now
# `.nameOnly` (the sweep winner), so `shipped` inherits it and `name-preview`
# keeps the older previewed style as a regression/comparison row.
DEFAULT_VARIANTS="shipped|standard|-|1|1
name-preview|standard|namePreview|1|1
concise-prompt|concise|-|1|1
minimal-literals|standard|minimal|1|1
no-verify|standard|-|0|1"

VARIANTS_TEXT="${VARIANTS:-${DEFAULT_VARIANTS}}"

# Warn (don't fail) when the judge needs a key that isn't present: the run still
# produces structural scores, just no rubric grades.
if [[ "${JUDGE_MODEL}" == xai/* && -z "${XAI_API_KEY:-}" ]]; then
  log "WARNING: JUDGE_MODEL=${JUDGE_MODEL} but XAI_API_KEY is unset — rubric grades will be skipped."
fi

# Resolve a `timeout`-compatible command (macOS: gtimeout via coreutils).
TIMEOUT_BIN=""
if command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
fi

# ── Build ────────────────────────────────────────────────────────────────
if [[ "${OSAURUS_EVALS_SKIP_PREP:-0}" != "1" ]]; then
  log "Preparing eval assets (metallib + embedder)…"
  bash "${SCRIPT_DIR}/prepare-evals-env.sh" || log "prep step failed (non-fatal)"
fi
log "Building osaurus-evals…"
swift build --package-path "${EVALS_PKG}" >/dev/null || { log "ERROR: build failed"; exit 2; }
BIN="$(swift build --package-path "${EVALS_PKG}" --show-bin-path)/osaurus-evals"
if [[ ! -x "${BIN}" ]]; then
  log "ERROR: osaurus-evals binary not found at ${BIN}"
  exit 2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${LAB_OUT_ROOT}/${STAMP}"
mkdir -p "${OUT}"
log "Run dir:  ${OUT}"
log "Model:    ${MODEL}   Filter: ${FILTER:-<all>}   Judge: ${JUDGE_MODEL}"
# NOTE: AppleScript live cases ALWAYS generate with the installed catalog model
# (resolveInstalledModelId), independent of --model. So with --model auto the
# harness-nominal is just keepCurrent (often the remote judge), while the real
# model under test is the local AppleScript bundle — the scoreboard's
# "model (under test)" line reports that, with the nominal shown separately.
log "  (model under test = installed AppleScript catalog model; see scoreboard)"

filter_args=()
[[ -n "${FILTER}" ]] && filter_args=(--filter "${FILTER}")

timeout_cmd=()
if [[ -n "${TIMEOUT_BIN}" && "${SUITE_TIMEOUT_SEC}" != "0" ]]; then
  timeout_cmd=("${TIMEOUT_BIN}" --kill-after=30 "${SUITE_TIMEOUT_SEC}")
fi

VARIANT_NAMES=()

# ── Sweep ────────────────────────────────────────────────────────────────
while IFS= read -r row; do
  [[ -z "${row}" ]] && continue
  IFS='|' read -r name prompt literal verify desktop <<< "${row}"
  [[ -z "${name}" ]] && continue
  VARIANT_NAMES+=("${name}")

  # Build the per-variant env override list; "-" leaves the case/shipped value.
  env_args=()
  [[ "${prompt}"  != "-" && -n "${prompt}"  ]] && env_args+=("OSAURUS_AS_PROMPT_VARIANT=${prompt}")
  [[ "${literal}" != "-" && -n "${literal}" ]] && env_args+=("OSAURUS_AS_LITERAL_STYLE=${literal}")
  [[ "${verify}"  != "-" && -n "${verify}"  ]] && env_args+=("OSAURUS_AS_VERIFY_READBACK=${verify}")
  [[ "${desktop}" != "-" && -n "${desktop}" ]] && env_args+=("OSAURUS_AS_DESKTOP_CONTEXT=${desktop}")

  out_path="${OUT}/${name}.json"
  log_path="${OUT}/${name}.log"
  log "  variant '${name}'  [${env_args[*]:-shipped}] …"
  ( cd "${EVALS_PKG}" && env "${env_args[@]+${env_args[@]}}" \
      "${timeout_cmd[@]+${timeout_cmd[@]}}" "${BIN}" run \
      --suite "${SUITE}" \
      --model "${MODEL}" \
      --out "${out_path}" \
      ${filter_args[@]+"${filter_args[@]}"} ) >"${log_path}" 2>&1
  rc=$?
  if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
    log "    rc=${rc} (TIMEOUT after ${SUITE_TIMEOUT_SEC}s)"
  else
    log "    rc=${rc} → ${out_path##*/}"
  fi
  [[ -s "${out_path}" ]] || log "    WARNING: no report written for '${name}' — see ${log_path##*/}"

  # Optional per-variant diff vs the matching baseline report.
  if [[ -n "${BASELINE}" && -s "${BASELINE}/${name}.json" && -s "${out_path}" ]]; then
    "${BIN}" diff "${BASELINE}/${name}.json" "${out_path}" \
      --markdown "${OUT}/${name}.diff.md" >/dev/null 2>&1 \
      && log "    diff vs baseline → ${name}.diff.md" \
      || log "    diff vs baseline failed (non-fatal)"
  fi
done <<< "${VARIANTS_TEXT}"

# ── Scoreboard ─────────────────────────────────────────────────────────────
log "Building variant scoreboard…"
MODEL="${MODEL}" FILTER="${FILTER}" JUDGE_MODEL="${JUDGE_MODEL}" LABEL="${LABEL}" \
  python3 "${SCRIPT_DIR}/applescript_capability_scoreboard.py" \
  "${OUT}" "${VARIANT_NAMES[@]}" || log "scoreboard step failed (non-fatal)"

# ── Record committed snapshot + history (opt-in: RECORD=1) ─────────────────
if [[ "${RECORD}" == "1" && -s "${OUT}/scoreboard.json" ]]; then
  mkdir -p "${SNAPSHOT_DIR}"
  cp "${OUT}/scoreboard.json" "${SNAPSHOT_DIR}/SNAPSHOT.json"
  cp "${OUT}/scoreboard.md" "${SNAPSHOT_DIR}/SNAPSHOT.md"
  rec_commit="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || true)"
  # Append one trend row (commit + label + per-variant pass rate) to the log.
  COMMIT="${rec_commit}" LABEL="${LABEL}" \
    python3 "${SCRIPT_DIR}/applescript_capability_scoreboard.py" \
    --history "${SNAPSHOT_DIR}/history.jsonl" "${OUT}/scoreboard.json" || true
  log "Recorded scoreboard → ${SNAPSHOT_DIR}/SNAPSHOT.{md,json} + history.jsonl"
fi

ln -sfn "${OUT}" "${LAB_OUT_ROOT}/latest"
echo ""
log "Done. Artifacts in ${OUT}"
log "  scoreboard: ${OUT}/scoreboard.md"
[[ -n "${BASELINE}" ]] && log "  per-variant diffs: ${OUT}/*.diff.md"
log "  promote to baseline:  BASELINE=${OUT} bash scripts/evals/applescript-capability-lab.sh"
[[ "${RECORD}" != "1" ]] && log "  (set RECORD=1 to refresh the committed ${SNAPSHOT_DIR#${REPO_ROOT}/}/SNAPSHOT + history)"
exit 0
