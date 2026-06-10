#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HANDLER="$ROOT/Packages/OsaurusCore/Networking/HTTPHandler.swift"
HELPER="$ROOT/Packages/OsaurusCore/Networking/HTTPLoopHelpers.swift"
RUNTIME="$ROOT/Packages/OsaurusCore/Services/ModelRuntime.swift"
RUNTIME_TESTS="$ROOT/Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift"
CHAT_STOP_TESTS="$ROOT/Packages/OsaurusCore/Tests/Chat/ChatSessionStopTests.swift"
HTTP_TESTS="$ROOT/Packages/OsaurusCore/Tests/Networking/HTTPHandlerChatStreamingTests.swift"

fail=0
pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_file() {
  local file="$1"
  local label="$2"
  if [[ -f "$file" ]]; then
    pass "$label exists"
  else
    fail_msg "$label missing: $file"
  fi
}

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

reject_text() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -q "$pattern" "$file"; then
    fail_msg "$label"
  else
    pass "$label"
  fi
}

require_count_at_least() {
  local file="$1"
  local pattern="$2"
  local min_count="$3"
  local label="$4"
  local count
  count="$(rg -c "$pattern" "$file" || true)"
  if [[ "$count" -ge "$min_count" ]]; then
    pass "$label ($count >= $min_count)"
  else
    fail_msg "$label ($count < $min_count)"
  fi
}

require_file "$HANDLER" "HTTPHandler"
require_file "$HELPER" "HTTPLoopHelpers"
require_file "$RUNTIME" "ModelRuntime"
require_file "$RUNTIME_TESTS" "RuntimePolicySourceTests"
require_file "$CHAT_STOP_TESTS" "ChatSessionStopTests"
require_file "$HTTP_TESTS" "HTTPHandlerChatStreamingTests"

require_text "$HELPER" 'final class HTTPRequestTaskRegistry' \
  "request task registry exists"
require_text "$HELPER" 'func cancelAll\(\)' \
  "request task registry can cancel all tasks"
require_text "$HELPER" 'if cancelled \{ return true \}' \
  "late-inserted tasks are cancelled after channel cancellation"
require_text "$HELPER" 'task\.cancel\(\)' \
  "request task registry cancels task handles"
require_text "$HANDLER" 'private let requestTasks = HTTPRequestTaskRegistry\(\)' \
  "HTTPHandler owns request task registry"
require_text "$HANDLER" 'private let channelCloseFuture = ChannelCloseFutureBox\(\)' \
  "HTTPHandler captures channel close future"
require_text "$HANDLER" 'requestTasks\.cancelAll\(\)' \
  "HTTPHandler cancels request tasks on close paths"
require_text "$HANDLER" 'if case ChannelEvent\.inputClosed = event' \
  "inputClosed event cancels request tasks"
require_text "$HANDLER" 'private func runRequestTask' \
  "HTTPHandler funnels async request work through runRequestTask"
require_text "$HANDLER" 'channelCloseFuture\.snapshot\(\)\?\.whenComplete \{ _ in' \
  "channel close future cancels request task"
require_text "$HANDLER" 'task\.cancel\(\)' \
  "runRequestTask cancels task on close"
require_count_at_least "$HANDLER" 'runRequestTask\(priority: \.userInitiated\)' 8 \
  "HTTP request entrypoints use cancellable task wrapper"
reject_text "$HANDLER" '^[[:space:]]{8}Task\(priority: \.userInitiated\)' \
  "no top-level unregistered userInitiated request tasks remain"

require_text "$HANDLER" 'let wasResidentBeforeStream = await ModelRuntime\.shared\.isResident\(name: model\)' \
  "streaming path records pre-stream residency"
require_text "$HANDLER" 'var emittedSemanticDelta = false' \
  "streaming path tracks semantic output before cleanup"
require_text "$HANDLER" '!wasResidentBeforeStream && !emittedSemanticDelta' \
  "cleanup is limited to cold loads with no semantic output"
require_text "$HANDLER" 'await ModelRuntime\.shared\.unload\(name: model\)' \
  "cancelled cold load unloads model"
require_text "$HANDLER" 'try Task\.checkCancellation\(\)' \
  "streaming paths check cancellation before/inside generation"
require_text "$HANDLER" 'if disconnected\.value \{ throw CancellationError\(\) \}' \
  "chat completions streaming aborts on client disconnect"
require_text "$HANDLER" 'disconnected\?\.value = true' \
  "SSE keepalive marks disconnect on failed write"
require_text "$HANDLER" 'temperature: request\.temperature,' \
  "Ollama logging preserves nil temperature"
require_text "$HANDLER" 'let logTemperature = req\.temperature' \
  "OpenAI logging preserves nil temperature"
reject_text "$HANDLER" 'temperature \?\? 0\.7' \
  "no hidden temperature fallback remains in HTTPHandler"

echo "--- model cold-load cancellation/drain ---"
require_text "$RUNTIME" 'private struct LoadingTaskRecord' \
  "ModelRuntime tracks cold-load task records"
require_text "$RUNTIME" 'private var loadingTasks: \[String: LoadingTaskRecord\]' \
  "ModelRuntime owns per-model loading task registry"
require_text "$RUNTIME" 'private func cancelAndDrainLoadingTasks' \
  "ModelRuntime has cold-load cancel-and-drain helper"
require_text "$RUNTIME" 'record\.task\.cancel\(\)' \
  "cold-load drain cancels loader task"
require_text "$RUNTIME" 'try\? await record\.task\.value' \
  "cold-load drain awaits cancelled loader task"
require_text "$RUNTIME" 'holder\.container\.disableCaching\(\)' \
  "cancelled/superseded load disables cache state"
require_text "$RUNTIME" 'Stream\.gpu\.synchronize\(\)' \
  "cold-load drain synchronizes GPU before returning"
require_text "$RUNTIME" 'Memory\.clearCache\(\)' \
  "cold-load drain clears MLX memory cache"
require_text "$RUNTIME" 'private func cancelLoadingTask\(name: String, loadID: UInt64\) async' \
  "ModelRuntime exposes loadID-scoped cancellation helper"
require_text "$RUNTIME" 'withTaskCancellationHandler' \
  "loadContainer forwards caller cancellation"
require_text "$RUNTIME" 'onCancel:' \
  "loadContainer installs cancellation handler"
require_text "$RUNTIME" 'cancelLoadingTask\(name: name, loadID: loadID\)' \
  "cancellation handler targets the matching cold-load task"
require_text "$RUNTIME" 'Task\.isCancelled' \
  "load task checks Swift cancellation during setup"
require_text "$RUNTIME" 'await cancelAndDrainLoadingTasks\(\[\(otherName, otherRecord\)\]\)' \
  "strict replacement loads drain the previous cold load"
require_text "$RUNTIME_TESTS" 'new model loads forward caller cancellation into loader task' \
  "source test covers forwarding caller cancellation into loader task"
require_text "$RUNTIME_TESTS" 'cancelled cold load is unloaded before stream setup' \
  "source test covers cancelled cold-load unload before streaming"
require_text "$RUNTIME_TESTS" 'ModelRuntime drains superseded cold loads before starting replacements' \
  "source test covers draining superseded cold loads"

require_text "$CHAT_STOP_TESTS" 'stop_cancelsEngineSetupBeforeStreamIsReturned' \
  "ChatSession stop-before-stream cancellation regression exists"
require_text "$HTTP_TESTS" 'requestTaskRegistryCancelsTaskInsertedAfterChannelCancellation' \
  "late task insertion cancellation regression exists"

active="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -v '/Users/eric/\.codex/computer-use/|SkyComputerUseClient' \
  | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-http-channel-load-cancellation' || true)"
if [[ -n "$active" ]]; then
  echo "$active" >&2
  fail_msg "active keychain/build process detected; source assertions above are still useful but do not promote live readiness"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "HTTP channel/load cancellation guard failed." >&2
  exit 1
fi

echo "HTTP channel/load cancellation guard passed."
