#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG="$ROOT/Packages/OsaurusCore/Package.swift"
RESOLVED="$ROOT/Packages/OsaurusCore/Package.resolved"
CHECKOUT="$ROOT/Packages/OsaurusCore/.build/checkouts/vmlx-swift"
PARSER="$CHECKOUT/Libraries/MLXLMCommon/ReasoningParser.swift"
TOOL_PARSER="$CHECKOUT/Libraries/MLXLMCommon/Tool/Parsers/GemmaFunctionParser.swift"
TOKENIZER_MACROS="$CHECKOUT/Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift"
FALLBACKS="$CHECKOUT/Libraries/MLXLMCommon/ChatTemplates/ChatTemplateFallbacks.swift"
VLM="$CHECKOUT/Libraries/MLXVLM/Models/Gemma4.swift"
VLM_FACTORY="$CHECKOUT/Libraries/MLXVLM/VLMModelFactory.swift"
LLM_FACTORY="$CHECKOUT/Libraries/MLXLLM/LLMModelFactory.swift"
TESTS="$CHECKOUT/Tests/MLXLMCommonFocusedTests/Gemma4ThoughtChannelParserFocusedTests.swift"
TOOL_TESTS="$CHECKOUT/Tests/MLXLMTests/ToolCallEdgeCasesTests.swift"
VLM_TESTS="$CHECKOUT/Tests/MLXLMTests/Gemma4VLMTests.swift"
SOURCE_TESTS="$CHECKOUT/Tests/MLXLMCommonFocusedTests/NoHiddenReasoningCloseBiasFocusedTests.swift"
EXPECTED_VMLX_REVISION="$(sed -nE 's/.*revision: "([0-9a-f]{40})".*/\1/p' "$PKG" | head -1 || true)"
fail=0

fail_msg() { echo "FAIL $*" >&2; fail=1; }
pass() { echo "PASS $*"; }
warn() { echo "WARN $*" >&2; }

if [[ ! -f "$PKG" ]]; then
  fail_msg "missing Package.swift: $PKG"
else
  pass "Package.swift exists"
fi

if [[ -f "$PKG" ]]; then
  if rg -q 'url: "https://github.com/osaurus-ai/vmlx-swift"' "$PKG"; then
    pass "Package.swift uses consolidated osaurus-ai/vmlx-swift dependency"
  else
    fail_msg "Package.swift does not reference osaurus-ai/vmlx-swift"
  fi
  if rg -q 'revision: "57e346b58e1286ab2f7bc458014d125c9bded095"' "$PKG"; then
    warn "Package.swift is still pinned to pre-fix vmlx revision 57e346b58e1286ab2f7bc458014d125c9bded095"
    fail=1
  fi
  if [[ -z "$EXPECTED_VMLX_REVISION" ]]; then
    fail_msg "Package.swift does not expose a 40-hex vMLX revision"
  fi
  if rg -q "revision: \"$EXPECTED_VMLX_REVISION\"" "$PKG"; then
    pass "Package.swift pins vMLX revision $EXPECTED_VMLX_REVISION"
  else
    fail_msg "Package.swift does not pin expected vMLX revision $EXPECTED_VMLX_REVISION"
  fi
fi

if [[ -f "$RESOLVED" ]]; then
  if rg -q '"identity" : "vmlx-swift"' "$RESOLVED"; then
    pass "Package.resolved contains vmlx-swift pin"
  else
    fail_msg "Package.resolved missing vmlx-swift pin"
  fi
  if rg -q "\"revision\" : \"$EXPECTED_VMLX_REVISION\"" "$RESOLVED"; then
    pass "Package.resolved pins vMLX revision $EXPECTED_VMLX_REVISION"
  else
    fail_msg "Package.resolved does not pin expected vMLX revision $EXPECTED_VMLX_REVISION"
  fi
else
  warn "Package.resolved missing; cannot prove resolved vmlx revision"
  fail=1
fi

if [[ -f "$PARSER" ]]; then
  pass "SwiftPM checkout ReasoningParser.swift exists"
  if checkout_head="$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null)" && [[ "$checkout_head" == "$EXPECTED_VMLX_REVISION" ]]; then
    pass "SwiftPM checkout HEAD matches expected vMLX revision"
  else
    fail_msg "SwiftPM checkout HEAD does not match expected vMLX revision $EXPECTED_VMLX_REVISION"
  fi
  if rg -Fq 'channelName == "thought" || channelName == "thinking"' "$PARSER" \
    && rg -Fq 'harmonyChannelShouldStripName = false' "$PARSER"; then
    pass "SwiftPM checkout contains Gemma4 empty thought-channel fix"
  else
    fail_msg "SwiftPM checkout lacks Gemma4 empty thought-channel fix; Osaurus will still surface bare thought in this edge case"
  fi
else
  warn "SwiftPM vmlx checkout missing; cannot inspect wired parser source"
  fail=1
fi

if [[ -f "$TOOL_PARSER" ]]; then
  pass "SwiftPM checkout GemmaFunctionParser.swift exists"
  if rg -q 'trimmingCharacters\(in: \.whitespacesAndNewlines\)' "$TOOL_PARSER"; then
    pass "SwiftPM checkout contains Gemma tool whitespace parser fix"
  else
    fail_msg "SwiftPM checkout lacks Gemma tool whitespace parser fix"
  fi
  if rg -Fq 'JSONDecoder().decode(String.self' "$TOOL_PARSER"; then
    pass "SwiftPM checkout contains Gemma4 quoted native string argument parser fix"
  else
    fail_msg "SwiftPM checkout lacks Gemma4 quoted native string argument parser fix"
  fi
  if rg -Fq 'Gemma-4 parser unwraps redundant quotes around literal-newline escaped values' "$TOOL_TESTS" \
    && rg -Fq 'String(value.dropFirst().dropLast())' "$TOOL_PARSER"; then
    pass "SwiftPM checkout contains Gemma4 literal-newline quoted argument parser fix"
  else
    fail_msg "SwiftPM checkout lacks Gemma4 literal-newline quoted argument parser fix"
  fi
  if rg -Fq 'decodeQuotedStringLiteral' "$TOOL_PARSER" \
    && rg -Fq 'Gemma-4 parser unwraps redundant quotes around raw literal-newline values' "$TOOL_TESTS"; then
    pass "SwiftPM checkout contains Gemma4 raw literal-newline quoted argument parser fix"
  else
    fail_msg "SwiftPM checkout lacks Gemma4 raw literal-newline quoted argument parser fix"
  fi
else
  warn "SwiftPM vmlx tool parser missing; cannot inspect Gemma tool whitespace fix"
  fail=1
fi

if [[ -f "$FALLBACKS" ]]; then
  pass "SwiftPM checkout ChatTemplateFallbacks.swift exists"
  if rg -Fq 'For string parameters, write the raw string value only' "$FALLBACKS" \
    && rg -Fq 'Do not wrap the parameter value in JSON quotes unless the requested value itself includes quote characters' "$FALLBACKS" \
    && rg -Fq 'Do not add a blank line, leading space, trailing newline, or any other character' "$FALLBACKS"; then
    pass "Gemma4 required fallback warns against quoted/space-mutated argument values"
  else
    fail_msg "Gemma4 required fallback lacks quoted/space-mutated argument warning"
  fi
else
  warn "SwiftPM vmlx fallbacks missing; cannot inspect Gemma4 required fallback"
  fail=1
fi

if [[ -f "$TOKENIZER_MACROS" ]]; then
  pass "SwiftPM checkout HuggingFaceIntegrationMacros.swift exists"
  if rg -Fq 'let gemmaToolSchemasPresent' "$TOKENIZER_MACROS" \
    && rg -Fq 'chat-template tools -> Gemma4WithTools fallback engaged' "$TOKENIZER_MACROS" \
    && rg -Fq 'MLXLMCommon.ChatTemplateFallbacks.gemma4WithTools' "$TOKENIZER_MACROS"; then
    pass "Gemma4 tool schemas route through explicit Gemma fallback"
  else
    fail_msg "Gemma4 tool schemas do not route through explicit Gemma fallback"
  fi
else
  warn "SwiftPM vmlx tokenizer macro source missing; cannot inspect Gemma4 required-tool template routing"
  fail=1
fi

if [[ -f "$FALLBACKS" ]] && [[ -f "$TOKENIZER_MACROS" ]]; then
  if rg -Fq "additionalContext['tool_choice'] == 'required'" "$FALLBACKS" \
    && rg -Fq 'render_required_tool_choice_instruction' "$FALLBACKS" \
    && rg -Fq 'Required tool_choice must not inject a synthetic prompt directive' "$CHECKOUT/Tests/MLXLMTests/Gemma4ChatTemplateProbeTests.swift"; then
    pass "Gemma4 required tool_choice is handled inside fallback without synthetic prompt directive"
  else
    fail_msg "Gemma4 required tool_choice fallback contract is missing or untested"
  fi
fi

if [[ -f "$VLM" ]]; then
  pass "SwiftPM checkout Gemma4.swift exists"
  if rg -Fq 'toolSchemas: input.tools' "$VLM"; then
    pass "Gemma4 processor preserves tool schemas into LMInput"
  else
    fail_msg "Gemma4 processor does not preserve tool schemas into LMInput"
  fi
  if rg -Fq 'Gemma4 VLM does not implement video inputs; LMInput.video must be nil' "$VLM" \
    && rg -Fq 'featuresList.append(embedVision(unifiedVisionEmbedder(singleImage)))' "$VLM" \
    && rg -Fq '@ModuleInfo(key: "embed_audio") private var embedAudio: MultimodalEmbedder' "$VLM" \
    && rg -Fq 'Gemma4 audio requires pre-encoded features matching this bundle' "$VLM" \
    && rg -Fq 'audioFeatures.dim(-1) == config.audioEmbedDim' "$VLM" \
    && rg -Fq 'let projectedAudio = embedAudio(audioFeatures).asType(emb.dtype)' "$VLM" \
    && rg -Fq 'Raw waveform feature extraction is not implemented for Gemma4 yet' "$VLM" \
    && rg -Fq 'var softTokenCounts: [Int] = []' "$VLM" \
    && rg -Fq 'softTokenCounts.append(patchCount / (config.poolingKernelSize * config.poolingKernelSize))' "$VLM" \
    && rg -Fq 'tokenizer.convertTokenToId("<|image>")' "$VLM" \
    && rg -Fq 'tokenizer.convertTokenToId("<image|>")' "$VLM" \
    && rg -Fq 'tokenizer.convertTokenToId("<|audio>")' "$VLM" \
    && rg -Fq 'tokenizer.convertTokenToId("<audio|>")' "$VLM"; then
    pass "Gemma4 unified image/pre-encoded-audio path and video/raw-audio boundary are wired"
  else
    fail_msg "Gemma4 unified image/pre-encoded-audio boundary or embedder wiring is incomplete"
  fi
  if rg -Fq 'Gemma4 unified image inputs are not production-supported yet' "$VLM"; then
    fail_msg "Gemma4 unified image path is still guarded as unsupported in the pinned checkout"
  fi
else
  warn "SwiftPM vmlx Gemma4.swift missing; cannot inspect Gemma4 VLM wiring"
  fail=1
fi

if [[ -f "$VLM_FACTORY" ]] && [[ -f "$LLM_FACTORY" ]]; then
  if rg -Fq '"gemma4_unified": create(Gemma4Configuration.self, Gemma4.init)' "$VLM_FACTORY" \
    && rg -Fq '"Gemma4UnifiedProcessor": create(' "$VLM_FACTORY" \
    && rg -Fq 'Gemma4ProcessorConfiguration.self, Gemma4Processor.init)' "$VLM_FACTORY" \
    && rg -Fq '"gemma4_unified_text": create(Gemma4TextConfiguration.self, Gemma4TextModel.init)' "$LLM_FACTORY"; then
    pass "Gemma4 unified model, processor, and text aliases are registered"
  else
    fail_msg "Gemma4 unified registry aliases are incomplete"
  fi
else
  warn "SwiftPM vmlx factory files missing; cannot inspect Gemma4 unified registry"
  fail=1
fi

if [[ -f "$TESTS" ]]; then
  if rg -q 'empty thought channel without newline does not surface thought' "$TESTS"; then
    pass "SwiftPM checkout contains focused Gemma4 no-thought regression"
  else
    fail_msg "SwiftPM checkout lacks focused Gemma4 no-thought regression"
  fi
else
  warn "SwiftPM vmlx tests missing; cannot inspect focused regression"
  fail=1
fi

if [[ -f "$TOOL_TESTS" ]]; then
  if rg -q 'Gemma-4 tool-call parser trims whitespace around function names and keys' "$TOOL_TESTS"; then
    pass "SwiftPM checkout contains Gemma tool whitespace regression"
  else
    fail_msg "SwiftPM checkout lacks Gemma tool whitespace regression"
  fi
  if rg -q 'Gemma-4 parser accepts live 12B quoted native string argument' "$TOOL_TESTS" \
    && rg -q 'Gemma-4 processor routes live 12B quoted native tool-call without visible leak' "$TOOL_TESTS" \
    && rg -q 'Gemma-4 parser unwraps redundant quotes around raw literal-newline values' "$TOOL_TESTS"; then
    pass "SwiftPM checkout contains Gemma4 12B native quoted tool-call regressions"
  else
    fail_msg "SwiftPM checkout lacks Gemma4 12B native quoted tool-call regressions"
  fi
else
  warn "SwiftPM vmlx tool tests missing; cannot inspect Gemma tool whitespace regression"
  fail=1
fi

if [[ -f "$VLM_TESTS" ]] && [[ -f "$SOURCE_TESTS" ]]; then
  if rg -q 'gemma4Unified12BConfigDecode' "$VLM_TESTS" \
    && rg -q 'gemma4UnifiedProcessorConfigDecode' "$VLM_TESTS" \
    && rg -q 'gemma4VLMProcessorPreservesToolsIntoLMInputSchemas' "$SOURCE_TESTS"; then
    pass "SwiftPM checkout contains Gemma4 unified config and schema-preservation regressions"
  else
    fail_msg "SwiftPM checkout lacks Gemma4 unified config/schema-preservation regressions"
  fi
else
  warn "SwiftPM vmlx Gemma4 unified tests missing; cannot inspect config/schema regressions"
  fail=1
fi

active="$({ ps -axo pid,ppid,rss,etime,command || true; } | rg -v '/Users/eric/\.codex/computer-use/|SkyComputerUseClient' | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|swift-build --package-path Packages/OsaurusCore|swift-test --package-path Packages/OsaurusCore|/Users/eric/osaurus-staging/Packages/OsaurusCore/.build' | rg -v 'rg -i|assert-vmlx-gemma4-parser-fix-wired' || true)"
if [[ -n "$active" ]]; then
  fail_msg "active Osaurus build/keychain-sensitive process detected"
  echo "$active" >&2
else
  pass "no active Osaurus build/keychain-sensitive process"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Osaurus vmlx-swift parser wiring guard failed or is process-blocked." >&2
  echo "If source assertions above pass and only the process gate fails, do not classify this as a pin/checkout mismatch." >&2
  exit 1
fi

echo "Osaurus vmlx-swift dependency is wired to the Gemma4 parser fix."
