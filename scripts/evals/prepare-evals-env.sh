#!/usr/bin/env bash
set -euo pipefail

# Prepare the local environment so `make evals` can run the full matrix
# (local MLX models + capability_search) on a clean checkout, without the
# manual one-off setup that used to be required.
#
# Idempotent asset prep — NOT an orchestrator. It does the two things the
# SwiftPM eval CLI cannot do for itself:
#
#   1. Colocate MLX's `default.metallib` next to the `osaurus-evals`
#      binary. SwiftPM CLI builds (unlike `make app`) don't bundle the
#      Cmlx Metal shader library, so a local MLX model load otherwise
#      fails with "Failed to load the default metallib".
#   2. Ensure the `minishlab/potion-base-4M` embedder is in the Hugging
#      Face cache so the capability_search semantic index isn't empty.
#
# Safe to run repeatedly; skips work that is already done.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EVALS_PKG="${REPO_ROOT}/Packages/OsaurusEvals"
EMBED_MODEL="minishlab/potion-base-4M"

shopt -s nullglob

log() { printf '[evals-prep] %s\n' "$*"; }
warn() { printf '[evals-prep] WARNING: %s\n' "$*" >&2; }

# ── 1. Build the eval binary so its .build dir exists for the copy ───────
# `make evals` would build via `swift run` anyway; building here first
# (same build cache, no double compile) guarantees the destination dir
# exists before we drop the metallib in.
if [[ "${OSAURUS_EVALS_SKIP_BUILD:-0}" != "1" ]]; then
  log "Building osaurus-evals (swift build)…"
  swift build --package-path "${EVALS_PKG}" >/dev/null
fi

bin_dirs=()
for d in "${EVALS_PKG}"/.build/debug "${EVALS_PKG}"/.build/*/debug; do
  [[ -d "${d}" ]] && bin_dirs+=("${d}")
done

# ── 2. Colocate the MLX metallib ─────────────────────────────────────────
find_metallib_source() {
  if [[ -n "${OSAURUS_MLX_METALLIB:-}" && -f "${OSAURUS_MLX_METALLIB}" ]]; then
    printf '%s' "${OSAURUS_MLX_METALLIB}"
    return 0
  fi
  # Already colocated from a previous run?
  local d
  for d in "${bin_dirs[@]}"; do
    [[ -f "${d}/default.metallib" ]] && { printf '%s' "${d}/default.metallib"; return 0; }
    [[ -f "${d}/mlx.metallib" ]] && { printf '%s' "${d}/mlx.metallib"; return 0; }
  done
  # Xcode DerivedData build products (`make app` / xcodebuild).
  local cands=(
    "${HOME}"/Library/Developer/Xcode/DerivedData/osaurus-*/Build/Products/*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib
    "${HOME}"/Library/Developer/Xcode/DerivedData/osaurus-*/Build/Products/*/osaurus.app/Contents/Resources/default.metallib
  )
  local c
  for c in "${cands[@]}"; do
    [[ -f "${c}" ]] && { printf '%s' "${c}"; return 0; }
  done
  return 1
}

if [[ ${#bin_dirs[@]} -eq 0 ]]; then
  warn "no osaurus-evals .build/debug dir found; skipping metallib colocation."
else
  if metallib_src="$(find_metallib_source)"; then
    for d in "${bin_dirs[@]}"; do
      for name in default.metallib mlx.metallib; do
        if [[ ! -f "${d}/${name}" ]]; then
          cp "${metallib_src}" "${d}/${name}"
          log "Colocated metallib → ${d#"${REPO_ROOT}/"}/${name}"
        fi
      done
    done
  else
    warn "no source default.metallib found. Build the app once (\`make app\`) or set OSAURUS_MLX_METALLIB."
    warn "local MLX model evals will fail to load the Metal library until then."
  fi
fi

# ── 3. Ensure the capability_search embedder ─────────────────────────────
embedder_present() {
  local snap base="${HOME}/.cache/huggingface/hub/models--minishlab--potion-base-4M/snapshots"
  if [[ -d "${base}" ]]; then
    for snap in "${base}"/*; do
      if [[ -f "${snap}/config.json" && -f "${snap}/model.safetensors" && -f "${snap}/tokenizer.json" ]]; then
        return 0
      fi
    done
  fi
  local d
  for d in "${HOME}/models/minishlab--potion-base-4M" "${HOME}/models/potion-base-4M" "${OSAURUS_EMBEDDING_MODEL_DIR:-}"; do
    [[ -n "${d}" ]] || continue
    if [[ -f "${d}/config.json" && -f "${d}/model.safetensors" && -f "${d}/tokenizer.json" ]]; then
      return 0
    fi
  done
  return 1
}

if embedder_present; then
  log "Embedder ${EMBED_MODEL} already present."
else
  log "Embedder ${EMBED_MODEL} missing; downloading into the Hugging Face cache…"
  if command -v hf >/dev/null 2>&1; then
    hf download "${EMBED_MODEL}"
  elif command -v uvx >/dev/null 2>&1; then
    uvx --from "huggingface_hub[cli]" hf download "${EMBED_MODEL}"
  else
    warn "neither 'hf' nor 'uvx' found; cannot download ${EMBED_MODEL}."
    warn "capability_search will run with an EMPTY semantic index."
    warn "install it manually or set OSAURUS_EMBEDDING_MODEL_DIR to a local copy."
  fi
fi

# ── 4. (opt-in) install the osaurus.browser plugin ───────────────────────
# The capability_claims browser cases require the `osaurus.browser` native
# plugin installed on disk. Installing it mutates ~/.osaurus, so it's
# opt-in (most suites don't need it): export OSAURUS_EVALS_INSTALL_BROWSER=1
# (the CapabilityClaims re-run does). Best-effort; never fails the prep.
if [[ "${OSAURUS_EVALS_INSTALL_BROWSER:-0}" == "1" ]]; then
  if command -v osaurus >/dev/null 2>&1; then
    log "Installing osaurus.browser plugin (OSAURUS_EVALS_INSTALL_BROWSER=1)…"
    osaurus tools install osaurus.browser || warn "osaurus.browser install failed; capability_claims browser cases will skip."
  else
    warn "OSAURUS_EVALS_INSTALL_BROWSER=1 but 'osaurus' CLI not found; skipping browser plugin install."
  fi
fi

log "Done."
