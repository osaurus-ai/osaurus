#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/evals/eval-watcher-report.sh [options]

Generate a stored local+frontier eval report bundle for a watcher lane, then
refresh the lane scoreboard from all stored bundles.

Options:
  --channel <name>          Watcher lane name. Default: main.
  --out-root <dir>          Stored artifact root. Default: build/evals/watcher.
  --artifact-id <id>        Stable artifact ID. Default: <channel>-<timestamp>.
  --preset <name>           Model lane preset: local-frontier, local-only,
                            frontier-only. Default: local-frontier.
  --local-model <id>        Local/default evidence model. Default: foundation.
  --frontier-model <id>     Frontier evidence model. Default: openai/gpt-4o-mini.
  --baseline <dir>          Optional baseline report bundle/report directory.
  --max-regressions <n>     No-regression threshold for scoreboard. Default: 0.
  --suite <dir>             Suite directory. May be repeated.
  --filter <substr>         Only run matching case ids.
  --judge-model <id>        Judge model passed through to osaurus-evals report.
  --include-sandbox-frontier
                            Add SandboxFrontier to the default report suites.
  --from-reports <dir>      Build report bundle from existing EvalReport JSON.
                            Useful for fixture smoke tests; makes no model calls.
  --startup-timeout <s>     Startup watchdog for live report runs. Use 0 to disable.
  --plan-only               Print the commands without running them.
  -h, --help                Show this help.

Artifacts:
  <out-root>/<channel>/<timestamp>/report/
  <out-root>/<channel>/scoreboard/latest/
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
channel="${EVALS_WATCHER_CHANNEL:-main}"
out_root="${EVALS_WATCHER_OUT:-build/evals/watcher}"
local_model="${LOCAL_MODEL:-foundation}"
frontier_model="${FRONTIER_MODEL:-openai/gpt-4o-mini}"
preset="${EVALS_REPORT_PRESET:-local-frontier}"
artifact_id="${EVALS_WATCHER_ARTIFACT_ID:-}"
max_regressions="${EVALS_MAX_REGRESSIONS:-0}"
baseline="${BASELINE_DIR:-}"
filter="${FILTER:-}"
judge_model="${JUDGE_MODEL:-}"
include_sandbox_frontier="${INCLUDE_SANDBOX_FRONTIER:-}"
from_reports="${EVALS_FROM_REPORTS:-}"
startup_timeout="${OSAURUS_EVALS_STARTUP_TIMEOUT_SECONDS:-}"
plan_only=0
suites=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      channel="${2:?missing value for --channel}"
      shift 2
      ;;
    --out-root)
      out_root="${2:?missing value for --out-root}"
      shift 2
      ;;
    --local-model)
      local_model="${2:?missing value for --local-model}"
      shift 2
      ;;
    --frontier-model)
      frontier_model="${2:?missing value for --frontier-model}"
      shift 2
      ;;
    --preset)
      preset="${2:?missing value for --preset}"
      shift 2
      ;;
    --artifact-id)
      artifact_id="${2:?missing value for --artifact-id}"
      shift 2
      ;;
    --baseline)
      baseline="${2:?missing value for --baseline}"
      shift 2
      ;;
    --max-regressions)
      max_regressions="${2:?missing value for --max-regressions}"
      shift 2
      ;;
    --suite)
      suites+=("${2:?missing value for --suite}")
      shift 2
      ;;
    --filter)
      filter="${2:?missing value for --filter}"
      shift 2
      ;;
    --judge-model)
      judge_model="${2:?missing value for --judge-model}"
      shift 2
      ;;
    --include-sandbox-frontier)
      include_sandbox_frontier=1
      shift
      ;;
    --from-reports)
      from_reports="${2:?missing value for --from-reports}"
      shift 2
      ;;
    --startup-timeout)
      startup_timeout="${2:?missing value for --startup-timeout}"
      shift 2
      ;;
    --plan-only)
      plan_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
lane_root="${out_root%/}/${channel}"
run_root="${lane_root}/${stamp}"
report_dir="${run_root}/report"
scoreboard_dir="${lane_root}/scoreboard/latest"
if [[ -z "$artifact_id" ]]; then
  artifact_id="${channel}-${stamp}"
fi

child_pid=""

write_status() {
  local status="$1"
  local rc="$2"
  mkdir -p "$run_root"
  cat >"${run_root}/watcher-status.json" <<STATUS
{
  "artifactId": "${artifact_id}",
  "channel": "${channel}",
  "reportDir": "${report_dir}",
  "scoreboardDir": "${scoreboard_dir}",
  "status": "${status}",
  "exitCode": ${rc}
}
STATUS
}

cancel_watcher() {
  local rc=130
  if [[ -n "$child_pid" ]]; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  write_status "canceled" "$rc"
  echo "eval watcher canceled; active child stopped before scoreboard refresh" >&2
  exit "$rc"
}

run_child() {
  "$@" &
  child_pid=$!
  wait "$child_pid"
  local rc=$?
  child_pid=""
  return "$rc"
}

trap cancel_watcher INT TERM

report_cmd=(
  swift run --package-path Packages/OsaurusEvals osaurus-evals report
  --preset "$preset"
  --local-model "$local_model"
  --frontier-model "$frontier_model"
  --artifact-id "$artifact_id"
  --out-dir "$report_dir"
)

if [[ -n "$from_reports" ]]; then
  report_cmd+=(--from-reports "$from_reports")
fi
if [[ -n "$baseline" ]]; then
  report_cmd+=(--baseline "$baseline")
fi
if [[ -n "$filter" ]]; then
  report_cmd+=(--filter "$filter")
fi
if [[ -n "$judge_model" ]]; then
  report_cmd+=(--judge-model "$judge_model")
fi
if [[ -n "$include_sandbox_frontier" ]]; then
  report_cmd+=(--include-sandbox-frontier)
fi
if [[ -n "$startup_timeout" ]]; then
  report_cmd+=(--startup-timeout "$startup_timeout")
fi
if [[ "${#suites[@]}" -gt 0 ]]; then
  for suite in "${suites[@]}"; do
    report_cmd+=(--suite "$suite")
  done
fi

scoreboard_cmd=(
  swift run --package-path Packages/OsaurusEvals osaurus-evals scoreboard
  --reports-root "$lane_root"
  --out-dir "$scoreboard_dir"
  --max-regressions "$max_regressions"
)

if [[ "$plan_only" == "1" ]]; then
  printf 'cd %q\n' "$repo_root"
  printf '%q ' "${report_cmd[@]}"
  printf '\n'
  printf '%q ' "${scoreboard_cmd[@]}"
  printf '\n'
  exit 0
fi

cd "$repo_root" || exit
mkdir -p "$report_dir" "$scoreboard_dir"

run_child "${report_cmd[@]}"
report_rc=$?

if [[ "$report_rc" -ne 0 && ! -f "${report_dir}/summary.json" ]]; then
  write_status "report_failed" "$report_rc"
  exit "$report_rc"
fi

run_child "${scoreboard_cmd[@]}"
scoreboard_rc=$?

echo ""
echo "eval watcher report: ${report_dir}"
echo "eval watcher scoreboard: ${scoreboard_dir}"

if [[ "$scoreboard_rc" -ne 0 ]]; then
  write_status "scoreboard_failed" "$scoreboard_rc"
  exit "$scoreboard_rc"
fi
write_status "completed" "$scoreboard_rc"
exit "$scoreboard_rc"
