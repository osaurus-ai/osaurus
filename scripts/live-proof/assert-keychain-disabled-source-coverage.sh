#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $1"; }
fail_msg() {
  echo "FAIL $1" >&2
  fail=1
}

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

require_text "$ROOT/Packages/OsaurusCore/Services/Keychain/KeychainQueryHelpers.swift" \
  "static var disablesKeychainForProcess" \
  "shared disabled-process flag"

require_text "$ROOT/Packages/OsaurusCore/Services/Keychain/AgentSecretsKeychain.swift" \
  "if KeychainQueryHelpers.disablesKeychainForProcess { return nil }" \
  "agent secret reads bypass Keychain"
require_text "$ROOT/Packages/OsaurusCore/Services/Keychain/AgentSecretsKeychain.swift" \
  "if KeychainQueryHelpers.disablesKeychainForProcess { return false }" \
  "agent secret writes bypass Keychain"
require_text "$ROOT/Packages/OsaurusCore/Services/Keychain/AgentSecretsKeychain.swift" \
  "if KeychainQueryHelpers.disablesKeychainForProcess { return true }" \
  "agent secret deletes bypass Keychain"

require_text "$ROOT/Packages/OsaurusCore/Services/Keychain/ToolSecretsKeychain.swift" \
  "if KeychainQueryHelpers.disablesKeychainForProcess { return nil }" \
  "tool secret reads bypass Keychain"
require_text "$ROOT/Packages/OsaurusCore/Services/Keychain/ToolSecretsKeychain.swift" \
  "if KeychainQueryHelpers.disablesKeychainForProcess { return [] }" \
  "tool secret enumeration bypasses Keychain"

require_text "$ROOT/Packages/OsaurusCore/Services/Provider/RemoteProviderKeychain.swift" \
  "if KeychainQueryHelpers.disablesKeychainForProcess { return nil }" \
  "remote provider reads bypass Keychain"
require_text "$ROOT/Packages/OsaurusCore/Services/Provider/RemoteProviderKeychain.swift" \
  "if KeychainQueryHelpers.disablesKeychainForProcess { return false }" \
  "remote provider writes bypass Keychain"

require_text "$ROOT/Packages/OsaurusCore/Services/MCP/MCPProviderKeychain.swift" \
  "if KeychainQueryHelpers.disablesKeychainForProcess { return nil }" \
  "MCP provider reads bypass Keychain"
require_text "$ROOT/Packages/OsaurusCore/Services/MCP/MCPProviderKeychain.swift" \
  "if KeychainQueryHelpers.disablesKeychainForProcess { return false }" \
  "MCP provider writes bypass Keychain"

require_text "$ROOT/Packages/OsaurusCore/Identity/StorageKeyManager.swift" \
  "if Self.disablesKeychainForProcess { return nil }" \
  "storage key reads bypass Keychain"
require_text "$ROOT/Packages/OsaurusCore/Identity/StorageKeyManager.swift" \
  "if Self.disablesKeychainForProcess { return }" \
  "storage key writes bypass Keychain"
require_text "$ROOT/Packages/OsaurusCore/Identity/StorageKeyManager.swift" \
  "generateInMemoryKey()" \
  "storage key uses in-memory disabled-mode key"

require_text "$ROOT/scripts/live-proof/assert-keychain-disabled-source-coverage.sh" \
  "agent secret reads bypass Keychain" \
  "shell guard pins wrapper disabled-mode bypasses"

if rg -n 'xcodebuild\|codesign\( \|\$\)\|notarytool\|/usr/bin/security\( \|\$\)' \
  "$ROOT/scripts/live-proof/assert-keychain-free-proof-path.sh" >/dev/null; then
  pass "process-sensitive guard still blocks signing/keychain lanes"
else
  fail_msg "process-sensitive guard still blocks signing/keychain lanes"
fi

exit "$fail"
