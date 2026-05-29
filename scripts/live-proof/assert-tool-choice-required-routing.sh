#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_text() {
  local file="$1"
  local text="$2"
  local label="$3"
  if rg -q --fixed-strings "$text" "$file"; then
    pass "$label"
  else
    fail_msg "$label"
  fi
}

OPENAI="$ROOT/Packages/OsaurusCore/Models/API/OpenAIAPI.swift"
RESPONSES="$ROOT/Packages/OsaurusCore/Models/API/OpenResponsesAPI.swift"
ANTHROPIC="$ROOT/Packages/OsaurusCore/Models/API/AnthropicAPI.swift"
REMOTE="$ROOT/Packages/OsaurusCore/Services/Provider/RemoteProviderService.swift"
RUNTIME="$ROOT/Packages/OsaurusCore/Services/ModelRuntime.swift"
TESTS="$ROOT/Packages/OsaurusCore/Tests/Networking/ToolChoiceDecodingTests.swift"
TOKENIZER_TESTS="$ROOT/Packages/OsaurusCore/Tests/Service/SwiftTransformersTokenizerLoaderTests.swift"

for file in "$OPENAI" "$RESPONSES" "$ANTHROPIC" "$REMOTE" "$RUNTIME" "$TESTS" "$TOKENIZER_TESTS"; do
  [[ -f "$file" ]] || { fail_msg "missing ${file#$ROOT/}"; continue; }
done

require_text "$OPENAI" "case required" "OpenAI tool_choice has required case"
require_text "$OPENAI" 'case "required": self = .required' "OpenAI decodes required string"
require_text "$OPENAI" 'try container.encode("required")' "OpenAI encodes required string"
require_text "$OPENAI" "'auto', 'none', 'required'" "OpenAI unsupported-tool-choice error names required"

require_text "$RESPONSES" "case .required:" "OpenResponses required branch exists"
require_text "$RESPONSES" "openAIToolChoice = .required" "OpenResponses required maps to local required"
require_text "$ANTHROPIC" "openAIToolChoice = .required" "Anthropic any maps to local required"

require_text "$REMOTE" "anthropicToolChoice = .any" "remote Anthropic required maps to any"
require_text "$REMOTE" "case .required, .function:" "remote Gemini required maps to ANY"
require_text "$REMOTE" "openResponsesToolChoice = .required" "remote OpenResponses required preserved"

require_text "$RUNTIME" "case .auto, .required:" "local tokenizer tools preserved for required"
require_text "$RUNTIME" 'Named `tool_choice` is enforced by `makeTokenizerTools`' \
  "local named tool_choice uses schema filtering instead of prompt directive"

require_text "$TESTS" "func decodesRequired" "tool_choice required decode regression exists"
require_text "$TESTS" 'decode("\"required\"")' "required decode regression uses OpenAI string"
require_text "$TESTS" 'decode("\"any\"")' "Anthropic any is not accepted as OpenAI tool_choice string"
require_text "$ROOT/Packages/OsaurusCore/Tests/Service/MLXBatchAdapterTests.swift" \
  "forcedToolChoiceUsesSchemaFilteringWithoutPromptDirective" \
  "named tool_choice no-prompt-directive regression exists"
require_text "$TOKENIZER_TESTS" "zayaTextLocalTokenizerRendersZyphraToolsNotGemmaFallback" \
  "ZAYA text required tool-choice tokenizer regression exists"
require_text "$TOKENIZER_TESTS" "zayaVLLocalTokenizerKeepsRequiredToolReminderInCurrentUserTurn" \
  "ZAYA multi-turn required tool-choice reminder regression exists"
require_text "$TOKENIZER_TESTS" 'Use the `line_count` function.' \
  "ZAYA named required tool-choice instruction regression exists"

exit "$fail"
