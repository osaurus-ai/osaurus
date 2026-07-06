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
# It is NOT an agent orchestrator: it's a robust test driver. Local-model
# work stays sequential (one MLX process at a time keeps GPU work from
# contending); each model's suites run in ONE process so the model loads
# and warms once (multi-suite mode); remote-provider models — network-bound,
# no GPU contention — run in a parallel lane when PARALLEL_REMOTE=1.
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
#   SUITE_TIMEOUT_SEC   hard wall-clock cap (seconds) PER SUITE. Multi-suite
#                  batches get cap × suite-count for the whole subprocess.
#                  Backstop so a wedged process can't stall the
#                  whole sequential matrix (the in-process per-case watchdog,
#                  OSAURUS_EVALS_CASE_TIMEOUT_SEC, is the first line of
#                  defense; this catches a hang the in-process timer can't,
#                  e.g. a CPU-bound spin that never yields). Default 2700
#                  (45m). 0 disables. Requires `timeout`/`gtimeout` on PATH;
#                  if neither is present the cap is skipped with a warning.
#   EVALS_REPEAT   run every case N times per suite (one process, model stays
#                  warm) and report merged majority outcomes + passRate; flaky
#                  rows are marked and the diff treats their flips as
#                  non-blocking. Default 1 (single execution).
#   EVALS_TRANSCRIPTS "1" (default) → pass --transcripts so every failed or
#                  errored LLM case keeps its FULL transcript (system prompt,
#                  tool calls + result previews, final text) in a
#                  <report>.transcripts/ sidecar inside the run dir. The run
#                  dir is git-ignored, so nothing sensitive can land in a
#                  commit; RECORD=1 snapshots never copy sidecars. "0" turns
#                  it off.
#   PARALLEL_REMOTE "1" (default) → when MODELS mixes local and remote-provider
#                  ids, run the remote models' LLM pass in a background lane
#                  concurrent with the local lane (remote decode is
#                  network-bound — no GPU contention). The remote lane runs
#                  with config storage force-isolated so it can never race the
#                  local lane on the real ~/.osaurus chat config. The
#                  sandbox-VM suite is the one exception: it is serialized
#                  across lanes with a lock (Apple Containerization is
#                  host-global) and runs WITHOUT forced isolation — the host's
#                  provisioned sandbox.json lives in the real root, and an
#                  isolated root would read setupComplete=false and skip every
#                  case. "0" restores the fully sequential order.

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
read -ra LLM_SUITES <<< "${LLM_SUITES:-AgentLoop AgentLoopFrontier AgentDB AppleScript CapabilityClaims ComputerUseLoop DefaultAgent MicroPerf PromptInjection SandboxFrontier Subagent}"

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

# Re-sign with the eval entitlements (com.apple.security.virtualization et
# al). SwiftPM's ad-hoc signature carries no entitlements, so without this
# every SandboxFrontier case skips with a vmnet "Container networking
# failed" — the VM can't attach its NAT interface. Idempotent: skipped when
# the current signature already carries the virtualization key (signing
# changes the binary's code-directory hash, which would re-trigger the
# macOS Keychain consent prompt for no reason).
ENTITLEMENTS="${EVALS_PKG}/osaurus-evals.entitlements"
if [[ -f "${ENTITLEMENTS}" ]] \
  && ! codesign -d --entitlements - "${BIN}" 2>/dev/null \
       | grep -q 'com.apple.security.virtualization'; then
  log "Signing osaurus-evals with eval entitlements (sandbox VM support)…"
  codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${BIN}" \
    || log "WARNING: codesign failed — SandboxFrontier cases will skip"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${LOOP_OUT_ROOT}/${STAMP}"
mkdir -p "${OUT}"
log "Run dir: ${OUT}"

filter_args=()
[[ -n "${FILTER}" ]] && filter_args=(--filter "${FILTER}")

# Optional per-case repeat trials (EVALS_REPEAT=N → merged majority outcome +
# passRate per case; the kit marks inconsistent rows flaky).
repeat_args=()
[[ "${EVALS_REPEAT:-1}" != "1" ]] && repeat_args=(--repeat "${EVALS_REPEAT}")

# Failed-case transcript sidecars (on by default: the run dir is git-ignored,
# and a failed row without its transcript usually means a re-run).
transcript_args=()
[[ "${EVALS_TRANSCRIPTS:-1}" == "1" ]] && transcript_args=(--transcripts)

# Sanitize a model id into a filename-safe label (xai/grok-4.3 → xai-grok-4.3).
label_for() { printf '%s' "$1" | tr '/' '-'; }

# Remote-provider routing prefixes the CLI can bootstrap ephemerally — must
# mirror `EvalRemoteProviderBootstrap.presets`. A slash alone doesn't mean
# remote (local HF repo ids like mlx-community/Qwen3-4B also have one); only
# a known provider prefix routes off-device.
REMOTE_PREFIXES="xai openai groq openrouter anthropic google deepseek"
is_remote_model() {
  local model="$1"
  case "${model}" in */*) ;; *) return 1 ;; esac
  local prefix
  prefix="$(printf '%s' "${model%%/*}" | tr '[:upper:]' '[:lower:]')"
  local p
  for p in ${REMOTE_PREFIXES}; do
    [[ "${prefix}" == "${p}" ]] && return 0
  done
  return 1
}

# Serialize sandbox-VM suites across parallel lanes: Apple Containerization
# state (rootfs, container name) is host-global, and two concurrent boots can
# corrupt the guest. mkdir is the atomic test-and-set; the lock lives inside
# this run's OUT dir so a crashed previous run can never wedge a new one.
SANDBOX_LOCK_DIR="${OUT}/.sandbox-vm.lock"
with_sandbox_lock() {
  local waited=0
  while ! mkdir "${SANDBOX_LOCK_DIR}" 2>/dev/null; do
    sleep 5
    waited=$((waited + 5))
    if (( waited % 300 == 0 )); then
      log "  (waited ${waited}s for the sandbox-VM lock…)"
    fi
  done
  "$@"
  local rc=$?
  rmdir "${SANDBOX_LOCK_DIR}" 2>/dev/null || true
  return ${rc}
}

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
      ${repeat_args[@]+"${repeat_args[@]}"} \
      ${transcript_args[@]+"${transcript_args[@]}"} \
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

run_suites_batch() {
  # run_suites_batch <model> <label> <batch-name> <suite...>
  # ONE CLI process for all the suites: the model loads + warms once and stays
  # resident across them (the CLI's repeatable --suite mode) — the biggest
  # wall-clock lever for a local-model pass vs. the old process-per-suite
  # order. Report names match run_suite's exactly (--out-dir + --out-prefix
  # resolve to ${OUT}/${label}-<Suite>.json), so matrix/diff see no change.
  local model="$1" label="$2" batch="$3"
  shift 3
  local suites=("$@")
  [[ ${#suites[@]} -eq 0 ]] && return 0
  if [[ ${#suites[@]} -eq 1 ]]; then
    run_suite "${model}" "${label}" "${suites[0]}"
    return 0
  fi
  local log_path="${OUT}/${label}-${batch}.log"
  local suite_args=()
  local s
  for s in "${suites[@]}"; do
    suite_args+=(--suite "Suites/${s}")
  done
  log "  ${label} / ${#suites[@]} suites in one process: ${suites[*]}"
  # SUITE_TIMEOUT_SEC is a per-suite cap; the batch process gets cap × count.
  local batch_timeout=$((SUITE_TIMEOUT_SEC * ${#suites[@]}))
  local timeout_cmd=()
  if [[ -n "${TIMEOUT_BIN}" && "${SUITE_TIMEOUT_SEC}" != "0" ]]; then
    timeout_cmd=("${TIMEOUT_BIN}" --kill-after=30 "${batch_timeout}")
  fi
  ( cd "${EVALS_PKG}" && "${timeout_cmd[@]+${timeout_cmd[@]}}" "${BIN}" run \
      "${suite_args[@]}" \
      --model "${model}" \
      --out-dir "${OUT}" \
      --out-prefix "${label}-" \
      ${repeat_args[@]+"${repeat_args[@]}"} \
      ${transcript_args[@]+"${transcript_args[@]}"} \
      ${filter_args[@]+"${filter_args[@]}"} ) >"${log_path}" 2>&1
  local rc=$?
  if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
    log "    rc=${rc} (BATCH TIMEOUT after ${batch_timeout}s) → ${label} batch KILLED"
  else
    log "    rc=${rc} → ${label}-*.json"
  fi
  # Self-heal: a timeout/watchdog kill mid-batch leaves LATER suites
  # reportless — a robustness gap process-per-suite never had. Re-run just the
  # missing suites individually so one wedged suite can't zero its siblings.
  # If EVERY suite is missing the failure is systematic (bad model id, startup
  # crash); re-running each would fail identically, so only warn loudly.
  local missing=()
  for s in "${suites[@]}"; do
    [[ -s "${OUT}/${label}-${s}.json" ]] || missing+=("${s}")
  done
  if [[ ${#missing[@]} -eq ${#suites[@]} ]]; then
    log "    WARNING: batch wrote no reports at all for ${label} — see ${log_path##*/}"
  elif [[ ${#missing[@]} -gt 0 ]]; then
    log "    batch left ${#missing[@]} suite(s) without a report; re-running individually…"
    for s in "${missing[@]}"; do
      run_suite "${model}" "${label}" "${s}"
    done
  fi
  return 0  # case failures are the measurement, never abort the loop
}

# LLM suites that boot the Apple Containerization VM — split out of the batch
# so with_sandbox_lock can serialize them across the parallel lanes. The VM is
# the only host-global resource worth a lock: ComputerUseLoop drives an
# in-process scripted world, and AppleScript's single real-executor case
# writes a fixed-content scratch note (identical across lanes — a concurrent
# write is benign), so serializing those suites would only cost the local
# lane an extra model load for no safety gain.
SANDBOX_VM_SUITES="SandboxFrontier"

run_model_lane() {
  # run_model_lane <model> <label> — the full LLM pass for one model: every
  # non-VM suite in one warm process, then the VM suites under the lock.
  local model="$1" label="$2"
  local batch_suites=() vm_suites=()
  local s
  for s in "${LLM_SUITES[@]}"; do
    if [[ " ${SANDBOX_VM_SUITES} " == *" ${s} "* ]]; then
      vm_suites+=("${s}")
    else
      batch_suites+=("${s}")
    fi
  done
  run_suites_batch "${model}" "llm-${label}" "batch" ${batch_suites[@]+"${batch_suites[@]}"}
  for s in ${vm_suites[@]+"${vm_suites[@]}"}; do
    # VM suites must NOT inherit forced config isolation (the remote lane
    # sets OSAURUS_EVALS_ISOLATE_CONFIG=1 for its whole model pass): an
    # isolated root hides the host's provisioned sandbox.json, so
    # setupComplete reads false and every case silently skips with
    # "sandbox setup incomplete on this host". The sandbox VM and its
    # provisioning config are host-global by design, and cross-lane
    # contention is already serialized by with_sandbox_lock — the same
    # real-root regime the local lane always used for this suite.
    OSAURUS_EVALS_ISOLATE_CONFIG=0 with_sandbox_lock \
      run_suite "${model}" "llm-${label}" "${s}"
  done
}

# ── 2. Deterministic suites (once) ───────────────────────────────────────
if [[ "${SKIP_DET}" == "1" ]]; then
  log "Skipping deterministic suites (SKIP_DET=1)."
else
  log "Deterministic suites (model=${DET_MODEL}):"
  run_suites_batch "${DET_MODEL}" "det" "batch" ${DET_SUITES[@]+"${DET_SUITES[@]}"}
fi

# ── 2b. Judge calibration (once) ─────────────────────────────────────────
# Grades the RESOLVED judge (JUDGE_MODEL / strong *_API_KEY / self-judge
# fallback) against fixtures with KNOWN verdicts — the judge doesn't vary by
# run model, so this runs once per loop, not once per MODELS entry. Burns a
# handful of judge calls (~1 per case). Skipped alongside SKIP_DET so the
# crowdsourced contribute flow (per-model compat only) is unchanged; skip
# individually with JUDGE_CAL=0.
JUDGE_CAL="${JUDGE_CAL:-1}"
if [[ "${SKIP_DET}" == "1" || "${JUDGE_CAL}" != "1" ]]; then
  log "Skipping judge calibration (SKIP_DET=${SKIP_DET}, JUDGE_CAL=${JUDGE_CAL})."
else
  log "Judge calibration (measures the judge itself):"
  run_suite "${DET_MODEL}" "judge" "JudgeCalibration"
fi

# ── 3. LLM suites (per model) ────────────────────────────────────────────
# Split MODELS into the local lane (sequential — MLX GPU work must not
# contend) and the remote lane (network-bound provider APIs). With
# PARALLEL_REMOTE=1 and both lanes non-empty, the remote lane runs in the
# background while the local lane keeps the GPU busy.
LOCAL_MODELS=()
REMOTE_MODELS=()
for model in ${MODELS}; do
  if is_remote_model "${model}"; then
    REMOTE_MODELS+=("${model}")
  else
    LOCAL_MODELS+=("${model}")
  fi
done

remote_lane() {
  # Remote models never need the real ~/.osaurus chat config (the model id is
  # explicit and the provider is bootstrapped from env keys), so force config
  # isolation: the lane cannot race the local lane — or the developer's live
  # app — on shared config state.
  local model label
  for model in ${REMOTE_MODELS[@]+"${REMOTE_MODELS[@]}"}; do
    label="$(label_for "${model}")"
    log "LLM suites for model=${model} (label=${label}) [remote lane]:"
    OSAURUS_EVALS_ISOLATE_CONFIG=1 run_model_lane "${model}" "${label}"
  done
}

PARALLEL_REMOTE="${PARALLEL_REMOTE:-1}"
if [[ "${PARALLEL_REMOTE}" == "1" && ${#REMOTE_MODELS[@]} -gt 0 && ${#LOCAL_MODELS[@]} -gt 0 ]]; then
  log "Parallel lanes: ${#LOCAL_MODELS[@]} local + ${#REMOTE_MODELS[@]} remote model(s) (PARALLEL_REMOTE=0 to serialize)."
  remote_lane &
  remote_lane_pid=$!
  for model in "${LOCAL_MODELS[@]}"; do
    label="$(label_for "${model}")"
    log "LLM suites for model=${model} (label=${label}) [local lane]:"
    run_model_lane "${model}" "${label}"
  done
  wait "${remote_lane_pid}" || true
  log "Remote lane finished."
else
  for model in ${MODELS}; do
    label="$(label_for "${model}")"
    log "LLM suites for model=${model} (label=${label}):"
    run_model_lane "${model}" "${label}"
  done
fi

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
