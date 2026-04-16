#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/validate_pr_branch.sh [options]

Run the practical validation lane for an Osaurus PR branch:
  - git whitespace check
  - swift-format lint
  - focused Swift package tests
  - workspace app build
  - optional app launch smoke check

Options:
  --repo-root PATH          Validate a different worktree or checkout
  --test-filter FILTER      Swift test filter; repeatable, combined with |
  --scratch-path PATH       SwiftPM scratch path
  --derived-data-path PATH  Xcode DerivedData path
  --scheme NAME             Xcode scheme to build (default: osaurus)
  --skip-lint               Skip swift-format lint
  --skip-tests              Skip Swift package tests
  --skip-build              Skip workspace app build
  --launch-check            Launch the built app and verify the process starts
  --clean                   Remove the derived-data and scratch paths first
  --help                    Show this help

Examples:
  scripts/validate_pr_branch.sh \
    --test-filter 'AttachedDocumentToolsTests|ChatViewSandboxTests' \
    --launch-check

  scripts/validate_pr_branch.sh \
    --repo-root ../other-worktree \
    --test-filter 'FileImportRegistryTests|PluginManifestDecodingTests'
EOF
}

log_step() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

resolve_base_ref() {
  local candidate
  for candidate in upstream/main origin/main upstream/master origin/master; do
    if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

collect_swift_lint_targets() {
  local base_ref merge_base path

  if ! base_ref="$(resolve_base_ref)"; then
    return 1
  fi

  merge_base="$(git merge-base HEAD "$base_ref")"
  git diff --name-only --diff-filter=ACMR "$merge_base"...HEAD -- . \
    | while IFS= read -r path; do
      case "$path" in
        *.swift)
          printf '%s\n' "$path"
          ;;
      esac
    done
}

require_clean_worktree() {
  local status
  status="$(git status --short --untracked-files=all)"
  if [[ -n "$status" ]]; then
    echo "Working tree must be clean before validation:" >&2
    echo "$status" >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scheme="osaurus"
scratch_path=""
derived_data_path=""
skip_lint=0
skip_tests=0
skip_build=0
launch_check=0
clean_paths=0
declare -a test_filters=()

while (($# > 0)); do
  case "$1" in
    --repo-root)
      repo_root="$2"
      shift 2
      ;;
    --test-filter)
      test_filters+=("$2")
      shift 2
      ;;
    --scratch-path)
      scratch_path="$2"
      shift 2
      ;;
    --derived-data-path)
      derived_data_path="$2"
      shift 2
      ;;
    --scheme)
      scheme="$2"
      shift 2
      ;;
    --skip-lint)
      skip_lint=1
      shift
      ;;
    --skip-tests)
      skip_tests=1
      shift
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --launch-check)
      launch_check=1
      shift
      ;;
    --clean)
      clean_paths=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$repo_root" && pwd)"
workspace_path="$repo_root/osaurus.xcworkspace"
package_path="$repo_root/Packages/OsaurusCore"
scratch_path="${scratch_path:-/tmp/osaurus-pr-validation-$(basename "$repo_root")-tests}"
derived_data_path="${derived_data_path:-$repo_root/build/DerivedData-pr-validation}"
app_path="$derived_data_path/Build/Products/Debug/osaurus.app"
app_binary="$app_path/Contents/MacOS/osaurus"

if (( skip_tests == 0 )) && ((${#test_filters[@]} == 0)); then
  echo "At least one --test-filter is required unless --skip-tests is used." >&2
  exit 2
fi

require_command git
require_command swift
require_command xcodebuild

if (( skip_lint == 0 )); then
  require_command swift-format
fi

if (( launch_check == 1 )); then
  require_command open
  require_command pgrep
fi

if [[ ! -d "$workspace_path" ]]; then
  echo "Workspace not found: $workspace_path" >&2
  exit 1
fi

if [[ ! -f "$package_path/Package.swift" ]]; then
  echo "Swift package not found: $package_path" >&2
  exit 1
fi

if (( clean_paths == 1 )); then
  log_step "Cleaning prior build state"
  rm -rf "$scratch_path" "$derived_data_path"
fi

cd "$repo_root"

log_step "Checking worktree cleanliness"
require_clean_worktree

log_step "Checking git diff formatting"
git diff --check

if (( skip_lint == 0 )); then
  log_step "Running swift-format lint"
  lint_targets=()
  while IFS= read -r lint_target; do
    [[ -n "$lint_target" ]] || continue
    lint_targets+=("$lint_target")
  done < <(collect_swift_lint_targets || true)

  if ((${#lint_targets[@]} > 0)); then
    swift-format lint --strict "${lint_targets[@]}"
  else
    if resolve_base_ref >/dev/null 2>&1; then
      echo "No PR-local Swift files changed; skipping swift-format lint."
    else
      echo "Could not resolve a base ref for diff-aware linting; falling back to full tree."
      swift-format lint --strict --recursive Packages App
    fi
  fi
fi

if (( skip_tests == 0 )); then
  test_filter_regex="${test_filters[0]}"
  if ((${#test_filters[@]} > 1)); then
    for filter in "${test_filters[@]:1}"; do
      test_filter_regex="${test_filter_regex}|${filter}"
    done
  fi

  log_step "Running focused Swift package tests"
  swift test \
    --package-path "$package_path" \
    --scratch-path "$scratch_path" \
    --filter "$test_filter_regex"
fi

if (( skip_build == 0 )); then
  log_step "Building app from workspace"
  xcodebuild \
    -workspace "$workspace_path" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
fi

if (( launch_check == 1 )); then
  log_step "Launching built app for smoke check"
  if [[ ! -d "$app_path" ]]; then
    echo "Built app not found at $app_path" >&2
    exit 1
  fi

  existing_pids="$(pgrep -f "$app_binary" || true)"
  if [[ -n "$existing_pids" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      kill "$pid" || true
    done <<<"$existing_pids"
    sleep 2
  fi

  /usr/bin/open -n "$app_path"
  sleep 5
  launched_pid="$(pgrep -f "$app_binary" | head -n 1 || true)"
  if [[ -z "$launched_pid" ]]; then
    echo "Launch check failed for $app_binary" >&2
    exit 1
  fi
  echo "Launch check passed with PID $launched_pid"
  kill "$launched_pid" || true
fi

log_step "Re-checking worktree cleanliness"
require_clean_worktree

log_step "Validation complete"
