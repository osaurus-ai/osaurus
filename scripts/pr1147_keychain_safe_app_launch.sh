#!/usr/bin/env bash
set -euo pipefail

APP_PATH="build/XcodeDerivedData-codex-live-pr1147/Build/Products/Debug/osaurus.app"
MODELS_DIR="/Users/eric/models"
DRY_RUN=0
HOLD_SECONDS=8
declare -a EXTRA_ENVS=()

usage() {
  cat <<'EOF'
Usage:
  scripts/pr1147_keychain_safe_app_launch.sh [options]

Launch the PR 1147 debug app through macOS LaunchServices so live gates use the
real user Keychain context. This helper intentionally refuses fake-HOME direct
binary launch patterns.

Options:
  --app PATH             App bundle to launch. Default: PR debug app path.
  --models-dir PATH      OSU_MODELS_DIR to expose through launchctl.
                         Default: /Users/eric/models.
  --env KEY=VALUE        Extra launchctl environment variable. Repeatable.
                         HOME is not allowed.
  --hold-seconds N       Seconds to keep launchctl env before restoring.
                         Default: 8.
  --dry-run              Print the launch plan without changing launchctl env.
  -h, --help             Show this help.

After launch, pair this with scripts/pr1147_http_route_probe.py and the live
artifact contract in docs/internal/live-gates/20260518T_pr1147_live_user_api_execution_manifest.md.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:?missing --app value}"
      shift 2
      ;;
    --models-dir)
      MODELS_DIR="${2:?missing --models-dir value}"
      shift 2
      ;;
    --env)
      EXTRA_ENVS+=("${2:?missing --env KEY=VALUE value}")
      shift 2
      ;;
    --hold-seconds)
      HOLD_SECONDS="${2:?missing --hold-seconds value}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
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

case "${HOME:-}" in
  /Users/*) ;;
  *)
    echo "Refusing to launch: HOME must be the real user home, not '${HOME:-<unset>}'." >&2
    echo "Do not use fake HOME for Osaurus app gates; Keychain stores the database encryption key." >&2
    exit 64
    ;;
esac

if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
  echo "App bundle not found or not a .app directory: $APP_PATH" >&2
  exit 66
fi

if [[ ! -d "$MODELS_DIR" ]]; then
  echo "Models directory not found: $MODELS_DIR" >&2
  exit 66
fi

if ! [[ "$HOLD_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "--hold-seconds must be a non-negative integer" >&2
  exit 64
fi

declare -a ENV_KEYS=("OSU_MODELS_DIR")
declare -a ENV_VALUES=("$MODELS_DIR")

if [[ "${#EXTRA_ENVS[@]}" -gt 0 ]]; then
  for item in "${EXTRA_ENVS[@]}"; do
    if [[ "$item" != *=* ]]; then
      echo "--env must be KEY=VALUE: $item" >&2
      exit 64
    fi
    key="${item%%=*}"
    value="${item#*=}"
    if [[ -z "$key" || "$key" == "HOME" ]]; then
      echo "--env may not set HOME; use LaunchServices with the real user home." >&2
      exit 64
    fi
    ENV_KEYS+=("$key")
    ENV_VALUES+=("$value")
  done
fi

echo "Launching with LaunchServices:"
echo "  app: $APP_PATH"
echo "  HOME: $HOME"
for idx in "${!ENV_KEYS[@]}"; do
  echo "  ${ENV_KEYS[$idx]}=${ENV_VALUES[$idx]}"
done
echo "  hold_seconds: $HOLD_SECONDS"

if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

declare -a PREVIOUS_VALUES=()

cleanup() {
  for idx in "${!ENV_KEYS[@]}"; do
    key="${ENV_KEYS[$idx]}"
    previous="${PREVIOUS_VALUES[$idx]:-}"
    if [[ -n "$previous" ]]; then
      launchctl setenv "$key" "$previous" >/dev/null
    else
      launchctl unsetenv "$key" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT

for idx in "${!ENV_KEYS[@]}"; do
  key="${ENV_KEYS[$idx]}"
  value="${ENV_VALUES[$idx]}"
  PREVIOUS_VALUES+=("$(launchctl getenv "$key" || true)")
  launchctl setenv "$key" "$value"
done

open -n "$APP_PATH"

if [[ "$HOLD_SECONDS" != "0" ]]; then
  sleep "$HOLD_SECONDS"
fi

echo "LaunchServices request sent; launchctl environment restored."
