#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

usage() {
  cat <<'EOF'
Run the Osaurus agent-loop eval regression lab.

Usage:
  scripts/evals/agent-loop-regression-lab.sh --baseline <path> [--suite <dir> ...] [--model <id>]
  scripts/evals/agent-loop-regression-lab.sh --baseline <path> --current <path> [--out-dir <dir>]

By default the CLI runs Packages/OsaurusEvals/Suites/AgentLoop and
Packages/OsaurusEvals/Suites/AgentLoopFrontier, writes per-suite JSON reports,
and emits regression-summary.json plus regression-summary.md under
build/evals/agent-loop-regression-lab/<timestamp>.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -eq 0 ]]; then
  usage
  exit 0
fi

cd "${REPO_ROOT}"
exec swift run --package-path Packages/OsaurusEvals osaurus-evals agent-loop-lab "$@"
