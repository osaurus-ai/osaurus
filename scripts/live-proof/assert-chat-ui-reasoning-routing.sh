#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHAT_VIEW="$ROOT/Packages/OsaurusCore/Views/Chat/ChatView.swift"
PROCESSOR="$ROOT/Packages/OsaurusCore/Utils/StreamingDeltaProcessor.swift"
TESTS="$ROOT/Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_file() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then
    pass "$label exists"
  else
    fail_msg "$label missing: $file"
  fi
}

require_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -q "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "$label"
  fi
}

reject_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -q "$pattern" "$file"; then
    fail_msg "$label"
  else
    pass "$label"
  fi
}

require_order() {
  local file="$1" first="$2" second="$3" label="$4"
  local first_line second_line
  first_line="$(rg -n "$first" "$file" | head -1 | cut -d: -f1 || true)"
  second_line="$(rg -n "$second" "$file" | head -1 | cut -d: -f1 || true)"
  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    pass "$label"
  else
    fail_msg "$label"
  fi
}

require_file "$CHAT_VIEW" "ChatView"
require_file "$PROCESSOR" "StreamingDeltaProcessor"
require_file "$TESTS" "RuntimePolicySourceTests"

require_text "$CHAT_VIEW" 'StreamingReasoningHint\.decode\(delta\)' \
  "ChatView decodes reasoning sentinel"
require_text "$CHAT_VIEW" 'processor\.receiveReasoning\(reasoning\)' \
  "ChatView routes reasoning to processor reasoning path"
require_text "$CHAT_VIEW" 'processor\.receiveDelta\(delta\)' \
  "ChatView routes visible deltas through visible path"
require_order "$CHAT_VIEW" 'StreamingReasoningHint\.decode\(delta\)' 'processor\.receiveReasoning\(reasoning\)' \
  "ChatView decodes reasoning before forwarding reasoning"
require_order "$CHAT_VIEW" 'processor\.receiveReasoning\(reasoning\)' 'processor\.receiveDelta\(delta\)' \
  "ChatView handles reasoning before visible delta fallback"
reject_text "$CHAT_VIEW" 'processor\.receiveDelta\(reasoning\)' \
  "ChatView does not append reasoning to visible text"
reject_text "$CHAT_VIEW" 'reasoning\.contains\("thought"\)|reasoning\.contains\("<\\|channel>"\)|reasoning\.contains\("<think"\)' \
  "ChatView does not scan/repair reasoning protocol text"

require_text "$PROCESSOR" 'func receiveReasoning\(_ text: String\)' \
  "processor has dedicated reasoning entrypoint"
require_text "$PROCESSOR" 'appendThinking\(text\)' \
  "processor appends reasoning to Think panel storage"
require_text "$PROCESSOR" "turn's thinking channel, which the Think panel renders" \
  "processor documents Think panel routing"
reject_text "$PROCESSOR" 'func receiveReasoning\(_ text: String\)[[:space:][:print:]]*appendContent' \
  "processor reasoning path does not call appendContent"
reject_text "$PROCESSOR" 'contains\("<think"|contains\("<\\|channel"|contains\("thought' \
  "processor does not scan reasoning protocol repair markers"

require_text "$CHAT_VIEW" 'req\.samplingParametersAreImplicit = true' \
  "normal ChatView sends preserve implicit sampling marker"
require_text "$CHAT_VIEW" 'finalReq\.samplingParametersAreImplicit = true' \
  "tool-budget wrap-up sends preserve implicit sampling marker"
require_text "$TESTS" 'Chat UI routes parsed reasoning only through the reasoning sentinel' \
  "source regression covers Chat UI reasoning routing"
require_text "$TESTS" 'Chat UI sends accumulated history and marks implicit sampling without forcing native MTP' \
  "source regression covers Chat UI implicit sampling contract"

active="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -v '/Users/eric/\.codex/computer-use/|SkyComputerUseClient' \
  | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-chat-ui-reasoning-routing' || true)"
if [[ -n "$active" ]]; then
  echo "$active" >&2
  fail_msg "active keychain/build process detected; source assertions above are still useful but do not promote live UI readiness"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Chat UI reasoning routing guard failed." >&2
  exit 1
fi

echo "Chat UI reasoning routing guard passed."
