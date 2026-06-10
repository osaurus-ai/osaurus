#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHAT_ENGINE="$ROOT/Packages/OsaurusCore/Services/Chat/ChatEngine.swift"
CHAT_TESTS="$ROOT/Packages/OsaurusCore/Tests/Chat/ChatEngineTests.swift"
HTTP_HANDLER="$ROOT/Packages/OsaurusCore/Networking/HTTPHandler.swift"
HTTP_STREAM_TESTS="$ROOT/Packages/OsaurusCore/Tests/Networking/HTTPHandlerChatStreamingTests.swift"
OPENAI_API="$ROOT/Packages/OsaurusCore/Models/API/OpenAIAPI.swift"
OPEN_RESPONSES_API="$ROOT/Packages/OsaurusCore/Models/API/OpenResponsesAPI.swift"

fail=0
pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_text() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -q "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "$label"
  fi
}

require_file() {
  local file="$1"
  local label="$2"
  if [[ -f "$file" ]]; then
    pass "$label exists"
  else
    fail_msg "$label missing: $file"
  fi
}

require_order() {
  local file="$1"
  local first="$2"
  local second="$3"
  local label="$4"
  local first_line second_line
  first_line="$(rg -n "$first" "$file" | head -1 | cut -d: -f1 || true)"
  second_line="$(rg -n "$second" "$file" | head -1 | cut -d: -f1 || true)"
  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    pass "$label"
  else
    fail_msg "$label"
  fi
}

require_file "$CHAT_ENGINE" "ChatEngine"
require_file "$CHAT_TESTS" "ChatEngineTests"
require_file "$HTTP_HANDLER" "HTTPHandler"
require_file "$HTTP_STREAM_TESTS" "HTTPHandlerChatStreamingTests"
require_file "$OPENAI_API" "OpenAIAPI"
require_file "$OPEN_RESPONSES_API" "OpenResponsesAPI"

require_text "$CHAT_ENGINE" 'guard let requestOptions else \{' \
  "bare API requests do not synthesize profile defaults from nil options"
require_text "$CHAT_ENGINE" 'return \[:\]' \
  "nil request options remain empty"
require_text "$CHAT_ENGINE" 'if let reasoning = StreamingReasoningHint\.decode\(delta\)' \
  "ChatEngine decodes reasoning sentinel before visible text"
require_text "$CHAT_ENGINE" 'TokenEstimator\.estimate\(reasoning\)' \
  "reasoning token accounting uses decoded reasoning text"
require_text "$CHAT_ENGINE" 'continuation\.yield\(delta\)' \
  "reasoning sentinel is preserved for UI/API endpoint routing"
require_text "$CHAT_TESTS" 'streamChat_preserves_reasoning_sentinel_for_endpoint_routing' \
  "reasoning sentinel regression exists"
require_text "$CHAT_TESTS" 'completeChat_keepsBareAPIRequestsFreeOfHiddenThinkingDefaults' \
  "bare API no-hidden-thinking regression exists"
require_text "$CHAT_TESTS" 'modelOptions\["disableThinking"\] == nil' \
  "regression rejects hidden disableThinking defaults"
require_text "$HTTP_HANDLER" 'writerBound\.value\.writeReasoning\(' \
  "OpenAI-compatible SSE routes reasoning onto reasoning_content"
require_text "$HTTP_HANDLER" 'writerBound\.value\.writeThinkingDelta\(reasoning' \
  "Anthropic SSE routes reasoning onto thinking_delta"
require_text "$HTTP_HANDLER" 'writerBound\.value\.writeReasoningDelta\(' \
  "OpenResponses SSE routes reasoning onto summary text delta"
require_text "$OPENAI_API" 'case reasoning_content' \
  "OpenAI API model preserves reasoning_content coding key"
require_text "$OPENAI_API" 'encodeIfPresent\(reasoning_content, forKey: \.reasoning_content\)' \
  "OpenAI API model encodes reasoning_content when present"
require_text "$OPEN_RESPONSES_API" 'response\.reasoning_summary_text\.delta' \
  "OpenResponses API declares reasoning summary delta event"
require_text "$OPEN_RESPONSES_API" 'response\.reasoning_summary_text\.done' \
  "OpenResponses API declares reasoning summary done event"
require_text "$HTTP_STREAM_TESTS" 'sse_path_emits_reasoning_content_field' \
  "OpenAI SSE reasoning_content regression exists"
require_text "$HTTP_STREAM_TESTS" '\\"reasoning_content\\":\\"thinking\.\.\.\\"' \
  "OpenAI SSE regression asserts reasoning_content payload"
require_text "$HTTP_STREAM_TESTS" '!body\.contains\("\\u\{FFFE\}"\)' \
  "OpenAI SSE regression rejects leaking reasoning sentinel"
require_text "$HTTP_STREAM_TESTS" 'anthropic_sse_emits_thinking_delta_for_reasoning_sentinel' \
  "Anthropic SSE thinking_delta regression exists"
require_text "$HTTP_STREAM_TESTS" 'openresponses_sse_emits_reasoning_summary_text_events' \
  "OpenResponses reasoning summary event regression exists"
require_text "$HTTP_STREAM_TESTS" '\\"type\\":\\"response\.reasoning_summary_text\.delta\\"' \
  "OpenResponses regression asserts reasoning summary delta event"
require_text "$HTTP_STREAM_TESTS" '\\"type\\":\\"response\.reasoning_summary_text\.done\\"' \
  "OpenResponses regression asserts reasoning summary done event"
require_text "$HTTP_STREAM_TESTS" 'openresponses_sse_does_not_open_message_item_when_only_reasoning' \
  "OpenResponses reasoning-only regression exists"
require_text "$HTTP_STREAM_TESTS" '!body\.contains\("\\"type\\":\\"response\.output_text\.delta\\""\)' \
  "OpenResponses reasoning-only regression rejects visible text delta"

require_order "$CHAT_ENGINE" 'StreamingReasoningHint\.decode\(delta\)' \
  'StreamingToolHint\.isSentinel\(delta\)' \
  "reasoning sentinel handled before tool sentinel branch"
require_order "$CHAT_ENGINE" 'StreamingReasoningHint\.decode\(delta\)' \
  'responseAccumulator\.append\(delta\)' \
  "reasoning sentinel handled before visible response accumulation"
require_order "$CHAT_ENGINE" 'StreamingReasoningHint\.decode\(delta\)' \
  'TokenEstimator\.estimate\(delta\)' \
  "reasoning sentinel handled before visible delta token estimate"
require_order "$HTTP_HANDLER" 'StreamingReasoningHint\.decode\(delta\)' \
  'responseContent \+= delta' \
  "HTTP SSE handles reasoning before visible response accumulation"
require_order "$HTTP_HANDLER" 'StreamingReasoningHint\.decode\(delta\)' \
  'writerBound\.value\.writeToolCall' \
  "HTTP SSE handles reasoning before tool-call routing"

active="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -v '/Users/eric/\.codex/computer-use/|SkyComputerUseClient' \
  | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-chat-reasoning-delta-routing' || true)"
if [[ -n "$active" ]]; then
  echo "$active" >&2
  fail_msg "active keychain/build process detected; source assertions above are still useful but do not promote live readiness"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Chat reasoning delta routing guard failed." >&2
  exit 1
fi

echo "Chat reasoning delta routing guard passed."
