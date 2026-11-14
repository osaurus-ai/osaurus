#!/usr/bin/env bash
set -euo pipefail

# Prepare the local environment so `make evals` can run the full matrix
# (local MLX models + capability_search) on a clean checkout, without the
# manual one-off setup that used to be required.
#
# Idempotent asset prep — NOT an orchestrator. It does the one thing the
# SwiftPM eval CLI cannot do for itself: colocate MLX's `default.metallib`
# next to the `osaurus-evals` binary. SwiftPM CLI builds (unlike
# `make app`) don't bundle the Cmlx Metal shader library, so a local MLX
# model load otherwise fails with "Failed to load the default metallib".
#
# The capability_search embedder (`minishlab/potion-base-4M`) ships in
# OsaurusCore's resource bundle, so it needs no download here.
#
# Safe to run repeatedly; skips work that is already done.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EVALS_PKG="${REPO_ROOT}/Packages/OsaurusEvals"
BUNDLED_EMBEDDER="${REPO_ROOT}/Packages/OsaurusCore/EmbeddingModels/potion-base-4M"
EVALS_BUILD_CONFIGURATION="${EVALS_BUILD_CONFIGURATION:-debug}"

shopt -s nullglob

log() { printf '[evals-prep] %s\n' "$*"; }
warn() { printf '[evals-prep] WARNING: %s\n' "$*" >&2; }

# ── 1. Build the eval binary so its .build dir exists for the copy ───────
# `make evals` would build via `swift run` anyway; building here first
# (same build cache, no double compile) guarantees the destination dir
# exists before we drop the metallib in.
if [[ "${OSAURUS_EVALS_SKIP_BUILD:-0}" != "1" ]]; then
  log "Building osaurus-evals (swift build)…"
  swift build --package-path "${EVALS_PKG}" -c "${EVALS_BUILD_CONFIGURATION}" >/dev/null
fi

bin_dirs=()
for d in "${EVALS_PKG}"/.build/"${EVALS_BUILD_CONFIGURATION}" \
         "${EVALS_PKG}"/.build/*/"${EVALS_BUILD_CONFIGURATION}"; do
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
  # Build products. The `mlx-swift_Cmlx.bundle` copy is the MLX KERNEL
  # library (~3.6 MB); the one inside `osaurus.app/Contents/Resources` is the
  # app's own small metallib and does NOT contain the MLX kernels — a local
  # MLX eval colocated with it dies at first decode with
  # "[metal::Device] Unable to load kernel rmsbfloat16". Always prefer the
  # Cmlx bundle, and search repo-local derived-data paths too: the Makefile
  # and every `-derivedDataPath build/...` invocation put products there,
  # not under ~/Library/Developer/Xcode/DerivedData.
  local cands=(
    "${REPO_ROOT}"/build/*/Build/Products/*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib
    "${HOME}"/Library/Developer/Xcode/DerivedData/osaurus-*/Build/Products/*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib
    "${REPO_ROOT}"/build/*/Build/Products/*/osaurus.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib
    "${HOME}"/Library/Developer/Xcode/DerivedData/osaurus-*/Build/Products/*/osaurus.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib
  )
  local c
  for c in "${cands[@]-}"; do
    [[ -f "${c}" ]] && { printf '%s' "${c}"; return 0; }
  done
  return 1
}

# The MLX kernel library is multi-megabyte. Anything much smaller is the
# app's own metallib (or a truncated copy) and will fail at first decode
# rather than at colocation time, which is far harder to diagnose.
metallib_looks_like_mlx() {
  local f="$1" bytes
  bytes="$(stat -f%z "${f}" 2>/dev/null || echo 0)"
  [[ "${bytes}" -ge 1048576 ]]
}

if [[ ${#bin_dirs[@]} -eq 0 ]]; then
  warn "no osaurus-evals .build/${EVALS_BUILD_CONFIGURATION} dir found; skipping metallib colocation."
else
  if metallib_src="$(find_metallib_source)"; then
    if ! metallib_looks_like_mlx "${metallib_src}"; then
      warn "chosen metallib is suspiciously small: ${metallib_src}"
      warn "that is almost certainly the app's own metallib, not MLX's kernel library."
      warn "local MLX evals would abort at first decode with 'Unable to load kernel rmsbfloat16'."
      warn "point OSAURUS_MLX_METALLIB at .../mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
    fi
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

# ── 3. Check the bundled capability_search embedder ──────────────────────
if [[ -n "${OSAURUS_EMBEDDING_MODEL_DIR:-}" ]]; then
  log "Embedder override: OSAURUS_EMBEDDING_MODEL_DIR=${OSAURUS_EMBEDDING_MODEL_DIR}"
elif [[ -f "${BUNDLED_EMBEDDER}/config.json" && -f "${BUNDLED_EMBEDDER}/model.safetensors" && -f "${BUNDLED_EMBEDDER}/tokenizer.json" ]]; then
  log "Embedder potion-base-4M ships with OsaurusCore."
else
  warn "bundled embedder missing at ${BUNDLED_EMBEDDER#"${REPO_ROOT}/"}; capability_search will run with an EMPTY semantic index."
fi

# Note: the capability_claims browser cases used to require the
# `osaurus.browser` plugin (OSAURUS_EVALS_INSTALL_BROWSER=1). The browser is
# now a NATIVE Osaurus capability (`browser_use`), so no plugin install is
# needed and those cases run everywhere.

log "Done."
