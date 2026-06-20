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
#                  Default: "foundation qwen3-4b". Add a remote frontier
#                  with e.g. MODELS="foundation qwen3-4b xai/grok-4.3"
#                  (requires XAI_API_KEY in the environment).
#   DET_MODEL      model for the deterministic / model-independent suites
#                  (no LLM call). Default: "auto".
#   LOOP_OUT_ROOT  parent dir for timestamped runs. Default build/evals/loop.
#   BASELINE       dir of a previous run to diff against (enables the gate).
#   FILTER         only run cases whose id contains this substring.
#   STRICT         "1" → exit non-zero if BASELINE diff finds blocking
#                  regressions (CI gate). Default off (case failures are
#                  the signal we measure, not a loop failure).
#   OSAURUS_EVALS_SKIP_PREP=1   skip the asset-prep step.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EVALS_PKG="${REPO_ROOT}/Packages/OsaurusEvals"

MODELS="${MODELS:-foundation qwen3-4b}"
DET_MODEL="${DET_MODEL:-auto}"
LOOP_OUT_ROOT="${LOOP_OUT_ROOT:-${REPO_ROOT}/build/evals/loop}"
BASELINE="${BASELINE:-}"
FILTER="${FILTER:-}"
STRICT="${STRICT:-0}"

# Suites that never call an LLM (pure-data validators + the embedder-only
# capability_search lane) — run ONCE with DET_MODEL.
DET_SUITES=(
  ArgumentCoercion CapabilitySearch ComputerUse PrefixHash
  RequestValidation SandboxDiagnostics Schema StreamingHint ToolEnvelope
)
# Suites that drive a model (or the sandbox VM) — run PER model.
LLM_SUITES=(
  AgentLoop AgentLoopFrontier CapabilityClaims ComputerUseLoop SandboxFrontier
)

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
  ( cd "${EVALS_PKG}" && "${BIN}" run \
      --suite "Suites/${suite}" \
      --model "${model}" \
      --out "${out_path}" \
      ${filter_args[@]+"${filter_args[@]}"} ) >"${log_path}" 2>&1
  local rc=$?
  log "    rc=${rc} → ${out_path##*/}"
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
log "Deterministic suites (model=${DET_MODEL}):"
for suite in "${DET_SUITES[@]}"; do
  run_suite "${DET_MODEL}" "det" "${suite}"
done

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

# ── 5. Diff vs baseline (optional gate) ──────────────────────────────────
gate_rc=0
if [[ -n "${BASELINE}" ]]; then
  if [[ -d "${BASELINE}" ]]; then
    log "Diffing against baseline ${BASELINE}…"
    "${BIN}" diff "${BASELINE}" "${OUT}" \
      --out "${OUT}/diff.json" \
      --markdown "${OUT}/diff.md" \
      $( [[ "${STRICT}" == "1" ]] && printf -- '--fail-on-regression' )
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

if [[ "${STRICT}" == "1" && ${gate_rc} -ne 0 ]]; then
  log "STRICT gate: blocking regression(s) detected (exit 1)."
  exit 1
fi
exit 0
