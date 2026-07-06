#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${OSAURUS_CHANNEL_SMOKE_MODE:-fixture}"
PROVIDERS="${OSAURUS_CHANNEL_SMOKE_PROVIDERS:-slack,telegram}"
RUN_CORE_FIXTURES="${OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES:-0}"
APPROVE_SEND="${OSAURUS_CHANNEL_SMOKE_APPROVE_SEND:-0}"
CONFIRM_SEND="${OSAURUS_CHANNEL_SMOKE_CONFIRM_SEND:-false}"
TEST_MESSAGE="${OSAURUS_CHANNEL_SMOKE_TEST_MESSAGE:-Osaurus Slack/Telegram disposable channel smoke}"
ARTIFACT_DIR="${OSAURUS_CHANNEL_SMOKE_ARTIFACT_DIR:-$ROOT/build/live-proof/channel-smoke/$(date -u +%Y%m%dT%H%M%SZ)}"
JSON_ARTIFACT="$ARTIFACT_DIR/channel-smoke-proof.json"
MD_ARTIFACT="$ARTIFACT_DIR/channel-smoke-proof.md"
LOG_ARTIFACT="$ARTIFACT_DIR/channel-smoke-proof.log"

fail=0
events=()
md_rows=()

usage() {
  cat <<'EOF'
Run Slack/Telegram Agent Channel smoke proof.

Modes:
  fixture (default)  No secrets or provider network calls. Runs source/fixture proof.
  live               Uses disposable provider credentials from environment.

Row status legend (only some statuses are execution proof):
  pass           Executed proof (focused Swift fixture tests actually ran).
  source         rg source-string assertion only; code exists, not executed.
  documented     Documentation-only claim; nothing was executed.
  provider_curl  Raw provider API curl succeeded; does NOT exercise Osaurus
                 runtimes or agent_channel_* tools.
  warn/skipped   Missing optional evidence or intentionally skipped.
  fail           Required evidence missing or a check errored.

Per AGENTS.md, source-only assertions are not production proof. App-surface
Osaurus runtime proof is a separate lane: follow
docs/CHANNEL_RELEASE_RUNBOOK_SLACK_TELEGRAM.md through the app surface
(scripts/live-proof/launch-keychain-free-osaurus.sh).

Common env:
  OSAURUS_CHANNEL_SMOKE_MODE=fixture|live
  OSAURUS_CHANNEL_SMOKE_PROVIDERS=slack,telegram
  OSAURUS_CHANNEL_SMOKE_ARTIFACT_DIR=build/live-proof/channel-smoke/<run>
  OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1
  OSAURUS_CHANNEL_SMOKE_APPROVE_SEND=1
  OSAURUS_CHANNEL_SMOKE_CONFIRM_SEND=true
  OSAURUS_CHANNEL_SMOKE_TEST_MESSAGE="disposable proof message"

Slack live env:
  OSAURUS_SLACK_BOT_TOKEN=xoxb-...
  OSAURUS_SLACK_APP_TOKEN=xapp-...          # Socket Mode setup evidence, optional here
  OSAURUS_SLACK_SIGNING_SECRET=...          # webhook setup evidence, optional here
  OSAURUS_SLACK_TEAM_ID=T...
  OSAURUS_SLACK_READ_CHANNEL_ID=C...
  OSAURUS_SLACK_WRITE_CHANNEL_ID=C...
  OSAURUS_SLACK_DENIED_CHANNEL_ID=C...

Telegram live env:
  OSAURUS_TELEGRAM_BOT_TOKEN=123456:...
  OSAURUS_TELEGRAM_READ_CHAT_ID=-100...
  OSAURUS_TELEGRAM_WRITE_CHAT_ID=-100...
  OSAURUS_TELEGRAM_DENIED_CHAT_ID=-100...
  OSAURUS_TELEGRAM_ALLOWED_SENDER_ID=123
  OSAURUS_TELEGRAM_DENIED_SENDER_ID=456
  OSAURUS_TELEGRAM_POLL_UPDATES=1           # optional long-poll read evidence
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

mkdir -p "$ARTIFACT_DIR"
: > "$LOG_ARTIFACT"

json_escape() {
  local s="$1"
  s="${s//$'\r'/}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

redact() {
  local text="$*"
  local name value
  for name in \
    OSAURUS_SLACK_BOT_TOKEN \
    OSAURUS_SLACK_APP_TOKEN \
    OSAURUS_SLACK_SIGNING_SECRET \
    OSAURUS_TELEGRAM_BOT_TOKEN \
    OSAURUS_TELEGRAM_WEBHOOK_SECRET; do
    value="${!name:-}"
    if [[ -n "$value" && "${#value}" -ge 6 ]]; then
      text="${text//$value/[REDACTED:$name]}"
    fi
  done
  printf '%s' "$text" | sed -E \
    -e 's/xox[baprs]-[A-Za-z0-9._:-]+/[REDACTED:SLACK_TOKEN]/g' \
    -e 's/xapp-[A-Za-z0-9._:-]+/[REDACTED:SLACK_APP_TOKEN]/g' \
    -e 's/[0-9]{5,}:[A-Za-z0-9_-]{20,}/[REDACTED:TELEGRAM_BOT_TOKEN]/g'
}

md_escape() {
  local s
  s="$(redact "$1")"
  s="${s//|/\\|}"
  s="${s//$'\n'/<br>}"
  printf '%s' "$s"
}

record() {
  local id="$1"
  local status="$2"
  shift 2
  local summary
  summary="$(redact "$*")"
  events+=("{\"id\":\"$(json_escape "$id")\",\"status\":\"$(json_escape "$status")\",\"summary\":\"$(json_escape "$summary")\"}")
  md_rows+=("| \`$(md_escape "$id")\` | $(md_escape "$status") | $(md_escape "$summary") |")
  printf '%s %-56s %s\n' "$status" "$id" "$summary" | tee -a "$LOG_ARTIFACT"
  if [[ "$status" == "fail" ]]; then
    fail=1
  fi
}

require_text() {
  local file="$1"
  local pattern="$2"
  local id="$3"
  if rg -q --fixed-strings "$pattern" "$ROOT/$file"; then
    record "$id" source "source assertion only: $file contains $pattern (not execution proof)"
  else
    record "$id" fail "$file is missing $pattern"
  fi
}

json_ok() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print("true" if json.load(sys.stdin).get("ok") is True else "false")' 2>/dev/null || true
  else
    if grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
      printf 'true\n'
    fi
  fi
}

curl_capture() {
  local id="$1"
  shift
  local output status
  set +e
  output="$(curl -sS "$@" 2>&1)"
  status=$?
  set -e
  printf '\n--- %s ---\n%s\n' "$id" "$(redact "$output")" >> "$LOG_ARTIFACT"
  if [[ "$status" -ne 0 ]]; then
    record "$id" fail "curl failed with exit $status"
    return 1
  fi
  printf '%s' "$output"
}

require_env() {
  local name="$1"
  local id="$2"
  if [[ -z "${!name:-}" ]]; then
    record "$id" fail "missing required env $name"
    return 1
  fi
  return 0
}

run_source_assertions() {
  require_text "Packages/OsaurusCore/Tools/ToolRegistry.swift" "externallyDeniedToolNames" \
    "source.external_denial_set_exists"
  require_text "Packages/OsaurusCore/Tools/ToolRegistry.swift" "agent_channel_send_message" \
    "source.agent_channel_send_externally_denied"
  require_text "Packages/OsaurusCore/Tests/Slack/SlackConnectionTests.swift" \
    "agentChannelReadToolRejectsRoomsOutsideSlackReadAllowlist" \
    "source.slack_room_denial_fixture"
  require_text "Packages/OsaurusCore/Tests/Slack/SlackConnectionTests.swift" \
    "agentChannelSendToolRequiresConfirmSendForSlack" \
    "source.slack_unapproved_send_fixture"
  require_text "Packages/OsaurusCore/Tests/Slack/SlackConnectionTests.swift" \
    "agentChannelSendToolPostsOnlyWhenSlackWriteEnabledAllowlistedAndConfirmed" \
    "source.slack_confirmed_send_fixture"
  require_text "Packages/OsaurusCore/Tests/Slack/SlackConnectionTests.swift" \
    "slackInboundEventRequiresSenderAllowlistBeforeStorage" \
    "source.slack_sender_denial_fixture"
  require_text "Packages/OsaurusCore/Services/Slack/SlackSocketModeTransportRuntime.swift" \
    "SlackSocketModeTransportRuntime" \
    "source.slack_socket_mode_runtime"
  require_text "Packages/OsaurusCore/Tests/Slack/SlackConnectionTests.swift" \
    "socketModeRuntimeAcksAuthorizedEnvelopeAndStoresMessage" \
    "source.slack_socket_mode_fixture"
  require_text "Packages/OsaurusCore/Tests/Telegram/TelegramConnectionTests.swift" \
    "normalizationSkipsUnauthorizedSelfAndBotMessages" \
    "source.telegram_room_bot_denial_fixture"
  require_text "Packages/OsaurusCore/Tests/Telegram/TelegramConnectionTests.swift" \
    "inboundReceiveRequiresSenderAllowlistBeforeStorage" \
    "source.telegram_sender_denial_fixture"
  require_text "Packages/OsaurusCore/Tests/Networking/MCPHTTPHandlerTests.swift" \
    "mcp_call_refuses_externally_denied_tools" \
    "source.mcp_call_denial_fixture"
  require_text "Packages/OsaurusCore/Tests/Networking/MCPHTTPHandlerTests.swift" \
    "remote_dispatch_surface_binding_denies_agent_channel_tools" \
    "source.remote_dispatch_denial_fixture"

  if rg -q --fixed-strings "senderAllowlist" "$ROOT/Packages/OsaurusCore/Models/Slack/SlackConnectionConfiguration.swift"; then
    record "source.slack_sender_allowlist" source "source assertion only: Slack configuration exposes sender allowlist"
  else
    record "source.slack_sender_allowlist" fail "Slack native config must expose sender allowlist before channel receive proof"
  fi
}

run_core_fixture_tests() {
  if [[ "$RUN_CORE_FIXTURES" != "1" ]]; then
    record "fixture.core_tests" skipped "set OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1 to run focused Swift fixture tests"
    return
  fi

  local test_root="$ARTIFACT_DIR/test-root"
  local models_dir="$ARTIFACT_DIR/models"
  mkdir -p "$test_root" "$models_dir"
  local log="$ARTIFACT_DIR/core-fixtures.log"
  set +e
  (
    cd "$ROOT"
    OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
    OSAURUS_TEST_ROOT="$test_root" \
    OSU_MODELS_DIR="$models_dir" \
    swift test --package-path Packages/OsaurusCore \
      --filter 'SlackConnectionTests|TelegramConnectionTests|MCPHTTPHandlerTests/mcp_call_refuses_externally_denied_tools|MCPHTTPHandlerTests/remote_dispatch_surface_binding_denies_agent_channel_tools'
  ) > "$log" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    record "fixture.core_tests" pass "focused Swift fixture tests passed; log: $log"
  else
    record "fixture.core_tests" fail "focused Swift fixture tests failed; redacted tail is in proof log"
    tail -n 80 "$log" | while IFS= read -r line; do redact "$line"; printf '\n'; done >> "$LOG_ARTIFACT"
  fi
}

run_fixture_smoke() {
  record "fixture.list_rooms_chats" documented "covered by focused Swift fixtures when OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1"
  record "fixture.read_store" documented "covered by focused Swift fixtures when OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1"
  record "fixture.draft_no_send" documented "covered by focused Swift fixtures when OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1"
  record "fixture.unapproved_send_denied" documented "covered by focused Swift fixtures when OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1"
  record "fixture.confirmed_send_gate" documented "confirmed sends still require OSAURUS_CHANNEL_SMOKE_APPROVE_SEND=1 plus OSAURUS_CHANNEL_SMOKE_CONFIRM_SEND=true"
  record "fixture.unauthorized_room_denial" documented "covered by focused Swift fixtures when OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1"
  record "fixture.unauthorized_sender_denial" documented "covered by focused Swift fixtures when OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1"
  record "fixture.external_mcp_denial" documented "covered by focused Swift fixtures when OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1"
}

run_live_slack() {
  require_env OSAURUS_SLACK_BOT_TOKEN "slack.env.bot_token" || return
  require_env OSAURUS_SLACK_TEAM_ID "slack.env.team_id" || return
  require_env OSAURUS_SLACK_READ_CHANNEL_ID "slack.env.read_channel" || return
  require_env OSAURUS_SLACK_WRITE_CHANNEL_ID "slack.env.write_channel" || return

  local response ok
  response="$(curl_capture "slack.auth_test" \
    -X POST https://slack.com/api/auth.test \
    -H "Authorization: Bearer ${OSAURUS_SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "")" || return
  ok="$(printf '%s' "$response" | json_ok)"
  if [[ "$ok" == "true" ]]; then
    record "slack.auth_test" provider_curl "raw curl: Slack bot token authenticated (does not exercise Osaurus runtimes)"
  else
    record "slack.auth_test" fail "Slack auth.test returned ok=false"
    return
  fi

  response="$(curl_capture "slack.list_rooms" \
    -X POST https://slack.com/api/conversations.list \
    -H "Authorization: Bearer ${OSAURUS_SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "types=public_channel,private_channel,mpim,im" \
    --data "exclude_archived=true" \
    --data "limit=100")" || return
  ok="$(printf '%s' "$response" | json_ok)"
  [[ "$ok" == "true" ]] \
    && record "slack.list_rooms" provider_curl "raw curl: Slack conversations.list succeeded (does not exercise agent_channel_list_rooms)" \
    || record "slack.list_rooms" fail "Slack conversations.list returned ok=false"

  response="$(curl_capture "slack.read_store" \
    -X POST https://slack.com/api/conversations.history \
    -H "Authorization: Bearer ${OSAURUS_SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "channel=${OSAURUS_SLACK_READ_CHANNEL_ID}" \
    --data "limit=3")" || return
  ok="$(printf '%s' "$response" | json_ok)"
  [[ "$ok" == "true" ]] \
    && record "slack.read_store" provider_curl "raw curl: Slack disposable read succeeded (does not exercise agent_channel_read_messages or the local store)" \
    || record "slack.read_store" fail "Slack conversations.history returned ok=false"

  record "slack.draft_no_send" documented "documentation only: draft check is local; no Slack chat.postMessage call attempted"

  if [[ "$APPROVE_SEND" == "1" && "$CONFIRM_SEND" == "true" ]]; then
    local body
    body="{\"channel\":\"$(json_escape "$OSAURUS_SLACK_WRITE_CHANNEL_ID")\",\"text\":\"$(json_escape "$TEST_MESSAGE")\",\"parse\":\"none\",\"link_names\":false,\"unfurl_links\":false,\"unfurl_media\":false}"
    response="$(curl_capture "slack.confirmed_send" \
      -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer ${OSAURUS_SLACK_BOT_TOKEN}" \
      -H "Content-Type: application/json; charset=utf-8" \
      --data "$body")" || return
    ok="$(printf '%s' "$response" | json_ok)"
    [[ "$ok" == "true" ]] \
      && record "slack.confirmed_send" provider_curl "raw curl: Slack disposable send executed after approval flags (does not exercise agent_channel_send_message)" \
      || record "slack.confirmed_send" fail "Slack chat.postMessage returned ok=false"
  else
    record "slack.unapproved_send_denied" documented "documentation only: this script skipped the send; Osaurus confirm_send denial is proven by fixtures and the app-surface lane"
  fi

  if [[ -n "${OSAURUS_SLACK_DENIED_CHANNEL_ID:-}" ]]; then
    record "slack.unauthorized_room_denial" documented "documentation only: denied Slack channel ${OSAURUS_SLACK_DENIED_CHANNEL_ID} named for the app-surface denial proof; nothing executed here"
  else
    record "slack.unauthorized_room_denial" warn "set OSAURUS_SLACK_DENIED_CHANNEL_ID to name a disposable denied channel"
  fi
  record "slack.unauthorized_sender_denial" documented "documentation only: Slack sender allowlist denial is fixture-covered; live Socket Mode sender denial belongs to the app-surface lane"
}

run_live_telegram() {
  require_env OSAURUS_TELEGRAM_BOT_TOKEN "telegram.env.bot_token" || return
  require_env OSAURUS_TELEGRAM_READ_CHAT_ID "telegram.env.read_chat" || return
  require_env OSAURUS_TELEGRAM_WRITE_CHAT_ID "telegram.env.write_chat" || return

  local base="https://api.telegram.org/bot${OSAURUS_TELEGRAM_BOT_TOKEN}"
  local response ok
  response="$(curl_capture "telegram.get_me" "$base/getMe")" || return
  ok="$(printf '%s' "$response" | json_ok)"
  [[ "$ok" == "true" ]] \
    && record "telegram.get_me" provider_curl "raw curl: Telegram bot token authenticated (does not exercise Osaurus runtimes)" \
    || { record "telegram.get_me" fail "Telegram getMe returned ok=false"; return; }

  response="$(curl_capture "telegram.list_chats.read" \
    "$base/getChat?chat_id=${OSAURUS_TELEGRAM_READ_CHAT_ID}")" || return
  ok="$(printf '%s' "$response" | json_ok)"
  [[ "$ok" == "true" ]] \
    && record "telegram.list_chats.read" provider_curl "raw curl: Telegram read chat resolved (does not exercise agent_channel_list_rooms)" \
    || record "telegram.list_chats.read" fail "Telegram getChat for read chat returned ok=false"

  response="$(curl_capture "telegram.list_chats.write" \
    "$base/getChat?chat_id=${OSAURUS_TELEGRAM_WRITE_CHAT_ID}")" || return
  ok="$(printf '%s' "$response" | json_ok)"
  [[ "$ok" == "true" ]] \
    && record "telegram.list_chats.write" provider_curl "raw curl: Telegram write chat resolved (does not exercise agent_channel_list_rooms)" \
    || record "telegram.list_chats.write" fail "Telegram getChat for write chat returned ok=false"

  if [[ "${OSAURUS_TELEGRAM_POLL_UPDATES:-0}" == "1" ]]; then
    response="$(curl_capture "telegram.read_store" "$base/getUpdates?limit=5&timeout=0")" || return
    ok="$(printf '%s' "$response" | json_ok)"
    [[ "$ok" == "true" ]] \
      && record "telegram.read_store" provider_curl "raw curl: Telegram long-poll returned (does not exercise the Osaurus long-poll runtime or store)" \
      || record "telegram.read_store" fail "Telegram getUpdates returned ok=false"
  else
    record "telegram.read_store" warn "set OSAURUS_TELEGRAM_POLL_UPDATES=1 for provider long-poll read evidence; Osaurus store proof belongs to the app-surface lane"
  fi

  record "telegram.draft_no_send" documented "documentation only: draft check is local; no Telegram sendMessage call attempted"

  if [[ "$APPROVE_SEND" == "1" && "$CONFIRM_SEND" == "true" ]]; then
    response="$(curl_capture "telegram.confirmed_send" \
      -X POST "$base/sendMessage" \
      --data-urlencode "chat_id=${OSAURUS_TELEGRAM_WRITE_CHAT_ID}" \
      --data-urlencode "text=${TEST_MESSAGE}")" || return
    ok="$(printf '%s' "$response" | json_ok)"
    [[ "$ok" == "true" ]] \
      && record "telegram.confirmed_send" provider_curl "raw curl: Telegram disposable send executed after approval flags (does not exercise agent_channel_send_message)" \
      || record "telegram.confirmed_send" fail "Telegram sendMessage returned ok=false"
  else
    record "telegram.unapproved_send_denied" documented "documentation only: this script skipped the send; Osaurus confirm_send denial is proven by fixtures and the app-surface lane"
  fi

  if [[ -n "${OSAURUS_TELEGRAM_DENIED_CHAT_ID:-}" ]]; then
    record "telegram.unauthorized_room_denial" documented "documentation only: denied Telegram chat ${OSAURUS_TELEGRAM_DENIED_CHAT_ID} named for the app-surface denial proof; nothing executed here"
  else
    record "telegram.unauthorized_room_denial" warn "set OSAURUS_TELEGRAM_DENIED_CHAT_ID to name a disposable denied chat"
  fi

  if [[ -n "${OSAURUS_TELEGRAM_ALLOWED_SENDER_ID:-}" && -n "${OSAURUS_TELEGRAM_DENIED_SENDER_ID:-}" \
        && "${OSAURUS_TELEGRAM_ALLOWED_SENDER_ID}" != "${OSAURUS_TELEGRAM_DENIED_SENDER_ID}" ]]; then
    record "telegram.unauthorized_sender_denial" documented "documentation only: distinct denied sender named for the app-surface denial proof; fixture tests cover the gate"
  else
    record "telegram.unauthorized_sender_denial" warn "set distinct OSAURUS_TELEGRAM_ALLOWED_SENDER_ID and OSAURUS_TELEGRAM_DENIED_SENDER_ID"
  fi
}

write_artifacts() {
  {
    printf '{\n'
    printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "mode": "%s",\n' "$(json_escape "$MODE")"
    printf '  "providers": "%s",\n' "$(json_escape "$PROVIDERS")"
    printf '  "approval": {"approve_send": "%s", "confirm_send": "%s"},\n' \
      "$(json_escape "$APPROVE_SEND")" "$(json_escape "$CONFIRM_SEND")"
    printf '  "redaction": "known Slack and Telegram token env values plus token-shaped strings are redacted",\n'
    printf '  "status_legend": {"pass": "executed proof", "source": "source-string assertion only", "documented": "documentation-only claim", "provider_curl": "raw provider curl; not Osaurus runtime proof", "warn": "missing optional evidence", "skipped": "intentionally skipped", "fail": "required evidence missing"},\n'
    printf '  "events": [\n'
    local i
    for i in "${!events[@]}"; do
      if [[ "$i" -gt 0 ]]; then printf ',\n'; fi
      printf '    %s' "${events[$i]}"
    done
    printf '\n  ]\n'
    printf '}\n'
  } > "$JSON_ARTIFACT"

  {
    printf '# Slack/Telegram Agent Channel Smoke Proof\n\n'
    printf '%s\n' "- Generated: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`"
    printf '%s\n' "- Mode: \`$MODE\`"
    printf '%s\n' "- Providers: \`$PROVIDERS\`"
    printf '%s\n' "- Approval flags: \`OSAURUS_CHANNEL_SMOKE_APPROVE_SEND=$APPROVE_SEND\`, \`OSAURUS_CHANNEL_SMOKE_CONFIRM_SEND=$CONFIRM_SEND\`"
    printf '%s\n' "- JSON artifact: \`$JSON_ARTIFACT\`"
    printf '%s\n\n' "- Log artifact: \`$LOG_ARTIFACT\`"
    printf '%s\n' "Status legend: \`pass\` = executed proof; \`source\` = source-string assertion only;"
    printf '%s\n' "\`documented\` = documentation-only claim; \`provider_curl\` = raw provider curl (not"
    printf '%s\n\n' "Osaurus runtime proof); \`warn\`/\`skipped\` = missing or skipped optional evidence."
    printf '| Check | Status | Summary |\n'
    printf '| --- | --- | --- |\n'
    local row
    for row in "${md_rows[@]}"; do
      printf '%s\n' "$row"
    done
  } > "$MD_ARTIFACT"
}

case "$MODE" in
  fixture|live) ;;
  *)
    record "mode" fail "unsupported OSAURUS_CHANNEL_SMOKE_MODE=$MODE"
    write_artifacts
    exit 1
    ;;
esac

record "start" info "mode=$MODE providers=$PROVIDERS artifact_dir=$ARTIFACT_DIR"
run_source_assertions
run_core_fixture_tests

if [[ "$MODE" == "fixture" ]]; then
  run_fixture_smoke
else
  for provider in ${PROVIDERS//,/ }; do
    case "$provider" in
      slack) run_live_slack ;;
      telegram) run_live_telegram ;;
      "") ;;
      *) record "provider.$provider" fail "unknown provider '$provider'" ;;
    esac
  done
fi

record "external_mcp_denial" documented "documentation only: MCP/remote dispatch denial is source-asserted here; run focused core fixtures and the app-surface /mcp/call check for executed proof"
record "live.app_surface_lane" info "Osaurus runtime proof (agent_channel_* tools, Socket Mode/long-poll receive, kill switch) is a separate lane: docs/CHANNEL_RELEASE_RUNBOOK_SLACK_TELEGRAM.md via scripts/live-proof/launch-keychain-free-osaurus.sh"
write_artifacts

echo "Artifacts:"
echo "  $MD_ARTIFACT"
echo "  $JSON_ARTIFACT"
echo "  $LOG_ARTIFACT"

exit "$fail"
