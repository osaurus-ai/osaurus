#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG="$ROOT/Packages/OsaurusCore/Package.swift"
RESOLVED="$ROOT/Packages/OsaurusCore/Package.resolved"
CHECKOUT="$ROOT/Packages/OsaurusCore/.build/checkouts/vmlx-swift"
PARSER="$CHECKOUT/Libraries/MLXLMCommon/ReasoningParser.swift"
TOOL_PARSER="$CHECKOUT/Libraries/MLXLMCommon/Tool/Parsers/GemmaFunctionParser.swift"
TESTS="$CHECKOUT/Tests/MLXLMCommonFocusedTests/Gemma4ThoughtChannelParserFocusedTests.swift"
TOOL_TESTS="$CHECKOUT/Tests/MLXLMTests/ToolCallEdgeCasesTests.swift"
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
else
  warn "SwiftPM vmlx tool parser missing; cannot inspect Gemma tool whitespace fix"
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
else
  warn "SwiftPM vmlx tool tests missing; cannot inspect Gemma tool whitespace regression"
  fail=1
fi

active="$({ ps -axo pid,ppid,rss,etime,command || true; } | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|swift-build --package-path Packages/OsaurusCore|swift-test --package-path Packages/OsaurusCore|/Users/eric/osaurus-staging/Packages/OsaurusCore/.build' | rg -v 'rg -i|assert-vmlx-gemma4-parser-fix-wired' || true)"
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
