#!/usr/bin/env bash
set -uo pipefail

# Osaurus optimization loop — one command: prep → run every suite per
# model into a timestamped dir → cross-model matrix (scoreboard) →
# (optional) diff vs a saved baseline. This is the maintainer pipeline:
# run it, read the matrix + diff, fix a root cause, run it again, and
# promote the new dir to baseline when the delta is a win.
#
#   measure ──▶ scoreboard ──▶ diff vs baseline ──▶ triage/promote
#
# It is NOT an agent orchestrator: it's a robust sequential test driver
# (sequential keeps local MLX GPU work from contending across suites).
#
# Env overrides:
#   MODELS         space-separated model ids run through the LLM suites.
#                  Default: "foundation auto" — "auto" resolves to the currently
#                  configured local model (a bare shortcut like "qwen3-4b" does
#                  NOT resolve to a repo tail and would error every case, so the
#                  default stays resolvable). Pass a full repo id to pin a local
#                  model, e.g. MODELS="foundation mlx-community/Qwen3.5-4B-OptiQ-4bit".
#                  Add a remote frontier with e.g.
#                  MODELS="foundation auto xai/grok-4.3" (requires XAI_API_KEY).
#   DET_MODEL      model for the deterministic / model-independent suites
#                  (no LLM call). Default: "auto".
#   LLM_SUITES     space-separated per-model suites to run. Default is the full
#                  set; override to scope a run, e.g.
#                  LLM_SUITES="Subagent ComputerUseLoop SandboxFrontier".
#   DET_SUITES     space-separated model-free suites (override to scope/skip).
#   LOOP_OUT_ROOT  parent dir for timestamped runs. Default build/evals/loop.
#   BASELINE       dir of a previous run to diff against (enables the gate).
#   FILTER         only run cases whose id contains this substring.
#   STRICT         "1" → exit non-zero if BASELINE diff finds blocking
#                  regressions (CI gate). Default off (case failures are
#                  the signal we measure, not a loop failure).
#   RECORD         "1" → also refresh reports/SNAPSHOT.{md,json} (the latest
#                  committed scoreboard) and append one row per model to
#                  reports/history.jsonl (the append-only trend log), so the
#                  run is publishable with a tiny diff. Default off: a bare
#                  run only writes the git-ignored timestamped dir. See
#                  reports/README.md for the commit workflow.
#   LABEL          free-form note recorded in each history row (with RECORD=1),
#                  e.g. LABEL="qwen tool-call fix".
#   SNAPSHOT_DIR   where the committed scoreboard lives. Default <repo>/reports.
#   SKIP_DET       "1" → skip the deterministic (model-independent) suites and
#                  run only the per-model LLM suites. Used by the crowdsourced
#                  contribution flow (scripts/evals/contribute.sh): those suites
#                  validate Osaurus's own parsing and don't vary by the
#                  contributor's model, so they add nothing to a per-model
#                  compatibility report. Default off.
#   OSAURUS_EVALS_SKIP_PREP=1   skip the asset-prep step.
#   SUITE_TIMEOUT_SEC   hard wall-clock cap (seconds) for ONE suite/model
#                  subprocess. Backstop so a wedged process can't stall the
#                  whole sequential matrix (the in-process per-case watchdog,
#                  OSAURUS_EVALS_CASE_TIMEOUT_SEC, is the first line of
#                  defense; this catches a hang the in-process timer can't,
#                  e.g. a CPU-bound spin that never yields). Default 2700
#                  (45m). 0 disables. Requires `timeout`/`gtimeout` on PATH;
#                  if neither is present the cap is skipped with a warning.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EVALS_PKG="${REPO_ROOT}/Packages/OsaurusEvals"

MODELS="${MODELS:-foundation auto}"
DET_MODEL="${DET_MODEL:-auto}"
LOOP_OUT_ROOT="${LOOP_OUT_ROOT:-${REPO_ROOT}/build/evals/loop}"
BASELINE="${BASELINE:-}"
FILTER="${FILTER:-}"
STRICT="${STRICT:-0}"
RECORD="${RECORD:-0}"
LABEL="${LABEL:-}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-${REPO_ROOT}/reports}"
SKIP_DET="${SKIP_DET:-0}"
SUITE_TIMEOUT_SEC="${SUITE_TIMEOUT_SEC:-2700}"

# Resolve a `timeout`-compatible command once (GNU coreutils ships `gtimeout`
# on macOS via Homebrew; Linux/CI has `timeout`). Empty when neither exists,
# in which case the per-suite cap is a documented no-op (the in-process
# per-case watchdog still applies).
TIMEOUT_BIN=""
if command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
fi

# Suites that never call an LLM (pure-data validators + the embedder-only
# capability_search lane) — run ONCE with DET_MODEL.
# Override with a space-separated DET_SUITES env var (e.g. a scoped run).
# `read -ra` is the robust, SC2206-clean way to split the space-separated
# override/default into the array (and is bash 3.2-safe). The `${VAR:-...}`
# default is expanded before `read` reassigns the same name.
read -ra DET_SUITES <<< "${DET_SUITES:-ArgumentCoercion CapabilitySearch ComputerUse PrefixHash RequestValidation SandboxDiagnostics Schema ScreenContext StreamingHint ToolEnvelope}"
# Suites that drive a model (or the sandbox VM) — run PER model.
# `Subagent` runs all subagent flows through the one SubagentSession host:
# its scripted cases are model-independent (identical per model) while the live
# lanes (spawn, computer_use-on-scripted-world, image) vary with
# the run model, so it lands real `subagent` rows in the cross-model matrix.
# Override with a space-separated LLM_SUITES env var to scope a run, e.g.
# LLM_SUITES="Subagent ComputerUseLoop SandboxFrontier" for a subagent-focused matrix.
# `AppleScript` runs all AppleScript flows through the one AppleScriptLoop: its
# scripted cases are model-independent (identical per model) while the live lanes
# (real-model + mock/real executor) vary with the run model, so it lands real
# `apple_script` rows in the cross-model matrix (same rationale as `Subagent`).
# `read -ra` splits the override/default into the array (SC2206-clean, bash 3.2-safe).
read -ra LLM_SUITES <<< "${LLM_SUITES:-AgentLoop AgentLoopFrontier AgentDB AppleScript CapabilityClaims ComputerUseLoop DefaultAgent SandboxFrontier Subagent}"

log() { printf '[opt-loop] %s\n' "$*"; }

# ── 1. Prep + build ──────────────────────────────────────────────────────
if [[ "${OSAURUS_EVALS_SKIP_PREP:-0}" != "1" ]]; then
  log "Preparing eval assets (metallib + embedder)…"
  bash "${SCRIPT_DIR}/prepare-evals-env.sh"
fi

log "Building osaurus-evals…"
swift build --package-path "${EVALS_PKG}" >/dev/null
BIN="$(swift build --package-path "${EVALS_PKG}" --show-bin-path)/osaurus-evals"
if [[ ! -x "${BIN}" ]]; then
  log "ERROR: osaurus-evals binary not found at ${BIN}"
  exit 2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${LOOP_OUT_ROOT}/${STAMP}"
mkdir -p "${OUT}"
log "Run dir: ${OUT}"

filter_args=()
[[ -n "${FILTER}" ]] && filter_args=(--filter "${FILTER}")

# Sanitize a model id into a filename-safe label (xai/grok-4.3 → xai-grok-4.3).
label_for() { printf '%s' "$1" | tr '/' '-'; }

run_suite() {
  # run_suite <model> <label> <suite>
  local model="$1" label="$2" suite="$3"
  local out_path="${OUT}/${label}-${suite}.json"
  local log_path="${OUT}/${label}-${suite}.log"
  log "  ${label} / ${suite} …"
  # NOTE: `${filter_args[@]+"${filter_args[@]}"}` (not a bare
  # `"${filter_args[@]}"`) — under `set -u`, macOS's stock bash 3.2 treats an
  # EMPTY array expansion as an unbound variable and aborts before invoking the
  # binary, which silently zeroes every suite (no `--out` JSON written). The
  # `+`-guarded form expands to nothing when no FILTER is set and to the args
  # otherwise, safe on bash 3.2.
  # Optional hard cap on the suite/model subprocess. `gtimeout --signal=KILL`
  # after a grace TERM so a process wedged in an uninterruptible state is still
  # reaped; rc=124 marks the timeout in the log for triage.
  local timeout_cmd=()
  if [[ -n "${TIMEOUT_BIN}" && "${SUITE_TIMEOUT_SEC}" != "0" ]]; then
    timeout_cmd=("${TIMEOUT_BIN}" --kill-after=30 "${SUITE_TIMEOUT_SEC}")
  fi
  ( cd "${EVALS_PKG}" && "${timeout_cmd[@]+${timeout_cmd[@]}}" "${BIN}" run \
      --suite "Suites/${suite}" \
      --model "${model}" \
      --out "${out_path}" \
      ${filter_args[@]+"${filter_args[@]}"} ) >"${log_path}" 2>&1
  local rc=$?
  if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
    log "    rc=${rc} (SUITE TIMEOUT after ${SUITE_TIMEOUT_SEC}s) → ${label}/${suite} KILLED"
  else
    log "    rc=${rc} → ${out_path##*/}"
  fi
  # A missing report means the run failed BEFORE writing (bad model id, startup
  # crash, or a script-level error) — distinct from case failures, which still
  # produce a JSON. Surface it loudly so a systematic failure can't hide behind
  # the intentional `return 0` below.
  if [[ ! -s "${out_path}" ]]; then
    log "    WARNING: no report written for ${label}/${suite} — see ${log_path##*/}"
  fi
  return 0  # case failures are the measurement, never abort the loop
}

# ── 2. Deterministic suites (once) ───────────────────────────────────────
if [[ "${SKIP_DET}" == "1" ]]; then
  log "Skipping deterministic suites (SKIP_DET=1)."
else
  log "Deterministic suites (model=${DET_MODEL}):"
  for suite in "${DET_SUITES[@]}"; do
    run_suite "${DET_MODEL}" "det" "${suite}"
  done
fi

# ── 3. LLM suites (per model) ────────────────────────────────────────────
for model in ${MODELS}; do
  label="$(label_for "${model}")"
  log "LLM suites for model=${model} (label=${label}):"
  for suite in "${LLM_SUITES[@]}"; do
    run_suite "${model}" "llm-${label}" "${suite}"
  done
done

# ── 4. Scoreboard (cross-model matrix) ───────────────────────────────────
log "Writing cross-model matrix…"
"${BIN}" matrix "${OUT}" \
  --out "${OUT}/matrix.json" \
  --markdown "${OUT}/matrix.md" || log "matrix step failed (non-fatal)"

# ── 4b. Record committed snapshot + history (opt-in: RECORD=1) ───────────
# Refresh the small, committed scoreboard. Raw per-case reports stay in the
# git-ignored run dir; only SNAPSHOT.{md,json} + the append-only history.jsonl
# are version-controlled (see reports/README.md). This rebuilds the snapshot
# from THIS run's reports so the latest committed scoreboard always matches the
# newest recorded run.
if [[ "${RECORD}" == "1" ]]; then
  rec_commit="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || true)"
  log "Recording scoreboard → ${SNAPSHOT_DIR}/SNAPSHOT.{md,json} + history.jsonl"
  "${BIN}" matrix "${OUT}" \
    --out "${SNAPSHOT_DIR}/SNAPSHOT.json" \
    --markdown "${SNAPSHOT_DIR}/SNAPSHOT.md" \
    --history "${SNAPSHOT_DIR}/history.jsonl" \
    --commit "${rec_commit}" \
    --label "${LABEL}" || log "record step failed (non-fatal)"
fi

# ── 5. Diff vs baseline (optional gate) ──────────────────────────────────
gate_rc=0
if [[ -n "${BASELINE}" ]]; then
  if [[ -d "${BASELINE}" ]]; then
    log "Diffing against baseline ${BASELINE}…"
    # Build the optional gate flag as an array (not an unquoted command
    # substitution) so it's both word-split-safe — SC2046 — and bash 3.2-safe
    # via the same `+`-guarded empty-array expansion documented for filter_args.
    strict_args=()
    [[ "${STRICT}" == "1" ]] && strict_args=(--fail-on-regression)
    "${BIN}" diff "${BASELINE}" "${OUT}" \
      --out "${OUT}/diff.json" \
      --markdown "${OUT}/diff.md" \
      ${strict_args[@]+"${strict_args[@]}"}
    gate_rc=$?
  else
    log "WARNING: BASELINE='${BASELINE}' is not a directory; skipping diff."
  fi
fi

# ── 6. latest symlink + summary ──────────────────────────────────────────
ln -sfn "${OUT}" "${LOOP_OUT_ROOT}/latest"
echo ""
log "Done. Artifacts in ${OUT}"
log "  scoreboard: ${OUT}/matrix.md"
[[ -n "${BASELINE}" ]] && log "  diff:       ${OUT}/diff.md"
log "  promote to baseline:  BASELINE=${OUT} bash scripts/evals/optimization-loop.sh"
if [[ "${RECORD}" == "1" ]]; then
  log "  recorded:   ${SNAPSHOT_DIR}/SNAPSHOT.md + history.jsonl"
  log "  publish:    git add reports/SNAPSHOT.md reports/SNAPSHOT.json reports/history.jsonl && git commit"
else
  log "  (set RECORD=1 to refresh the committed reports/SNAPSHOT + history.jsonl)"
fi

if [[ "${STRICT}" == "1" && ${gate_rc} -ne 0 ]]; then
  log "STRICT gate: blocking regression(s) detected (exit 1)."
  exit 1
fi
exit 0
