#!/usr/bin/env bash
set -euo pipefail

# Wrapper for scripts/benchmark_models.py with sensible defaults.
# Override via env vars:
#   OSA_BASE (default http://127.0.0.1:8080)
#   OSA_MODEL (default llama-3.2-3b-instruct-4bit)
#   OLLAMA_BASE (default http://127.0.0.1:11434)
#   OLLAMA_MODEL (default llama3.2)
#   ITER (default 10)
#   CONC (default 1)
#   MAXTOK (default 512)
#   OUT_PREFIX (default ./results/osaurus-vs-ollama-batch)
#   PROMPTS_FILE (optional) or PROMPTS (comma-separated)
#   NOSTREAM (set to 1 to disable streaming)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PY="${ROOT_DIR}/.bench-venv/bin/python"
BENCH="${ROOT_DIR}/scripts/benchmark_models.py"

OSA_BASE=${OSA_BASE:-"http://127.0.0.1:8080"}
OSA_MODEL=${OSA_MODEL:-"llama-3.2-3b-instruct-4bit"}
OLLAMA_BASE=${OLLAMA_BASE:-"http://127.0.0.1:11434"}
OLLAMA_MODEL=${OLLAMA_MODEL:-"llama3.2"}
ITER=${ITER:-10}
CONC=${CONC:-1}
MAXTOK=${MAXTOK:-512}
OUT_PREFIX=${OUT_PREFIX:-"${ROOT_DIR}/results/osaurus-vs-ollama-batch"}
PROMPTS_FILE=${PROMPTS_FILE:-""}
PROMPTS=${PROMPTS:-"Write a one-sentence summary of the theory of evolution.,List three uses of fossil records in paleontology."}
NOSTREAM=${NOSTREAM:-0}

ARGS=(
  --server "osaurus|${OSA_BASE}|${OSA_MODEL}"
  --server "ollama|${OLLAMA_BASE}|${OLLAMA_MODEL}"
  --iterations "${ITER}"
  --concurrency "${CONC}"
  --max-tokens "${MAXTOK}"
  --output-prefix "${OUT_PREFIX}"
  --export json csv
)

if [[ "${NOSTREAM}" == "1" ]]; then
  ARGS+=(--no-stream)
fi

if [[ -n "${PROMPTS_FILE}" ]]; then
  ARGS+=(--prompts-file "${PROMPTS_FILE}")
else
  IFS=',' read -ra P_ARR <<< "${PROMPTS}"
  for p in "${P_ARR[@]}"; do
    ARGS+=(--prompt "$p")
  done
fi

exec "${PY}" "${BENCH}" "${ARGS[@]}"


