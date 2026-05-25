#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-/tmp/osaurus-pr-dirty-scope-classifier-$(date +%Y%m%d-%H%M%S).md}"
mkdir -p "$(dirname "$OUT")"

all_dirty="$({
  git -C "$ROOT" diff --name-only
  git -C "$ROOT" diff --cached --name-only
  git -C "$ROOT" ls-files --others --exclude-standard
} | sort -u)"

classify() {
  local path="$1"
  case "$path" in
    scripts/live-proof/assert-*.sh|scripts/live-proof/launch-keychain-free-osaurus.sh|scripts/live-proof/classify-osaurus-pr-dirty-scope.sh)
      echo "release-guard" ;;
    Packages/OsaurusCore/Package.swift|Packages/OsaurusCore/Package.resolved|osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved|App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
      echo "dependency-pin" ;;
    .agents/vmlx-osaurus/codex/*)
      echo "coordination-doc" ;;
    Packages/OsaurusCore/Services/ModelRuntime/*|Packages/OsaurusCore/Services/ModelRuntime.swift|Packages/OsaurusCore/Models/Configuration/ServerRuntimeSettingsStore.swift|Packages/OsaurusCore/Models/Configuration/ModelOptions.swift|Packages/OsaurusCore/Views/Settings/ServerSettings/*|Packages/OsaurusCore/Views/Settings/ServerSettingsView.swift)
      echo "runtime-settings-cache" ;;
    Packages/OsaurusCore/Networking/*|Packages/OsaurusCore/Models/API/*)
      echo "api-streaming-responses" ;;
    Packages/OsaurusCore/Services/Chat/*|Packages/OsaurusCore/Views/Chat/*)
      echo "chat-reasoning-tool-ui" ;;
    Packages/OsaurusCore/Services/Keychain/*|Packages/OsaurusCore/Services/MCP/MCPProviderKeychain.swift|Packages/OsaurusCore/Identity/StorageKeyManager.swift|Packages/OsaurusCore/AppDelegate.swift|AGENTS.md)
      echo "keychain-launch-safety" ;;
    Packages/OsaurusCore/Managers/Model/*|Packages/OsaurusCore/Services/HuggingFaceService.swift|Packages/OsaurusCore/Services/Provider/*|Packages/OsaurusCore/Services/Inference/*|Packages/OsaurusCore/Services/LocalGenerationDefaults.swift|Packages/OsaurusCore/Services/LocalReasoningCapability.swift|Packages/OsaurusCore/Services/ModelOptionsStore.swift|Packages/OsaurusCore/Services/Context/*|Packages/OsaurusCore/Utils/OsaurusPaths.swift)
      echo "model-provider-defaults" ;;
    Packages/OsaurusCore/Tests/*)
      echo "tests" ;;
    docs/*)
      echo "docs" ;;
    .spm-cache/*|.claude/*|investigation/*|DerivedData*|*.xcresult|*.log)
      echo "local-artifact" ;;
    *)
      echo "unknown" ;;
  esac
}

{
  echo "# Osaurus PR dirty-scope classification"
  echo
  echo "Repo: $ROOT"
  echo "Branch: $(git -C "$ROOT" branch --show-current)"
  echo "HEAD: $(git -C "$ROOT" rev-parse HEAD)"
  echo
  if [[ -z "$all_dirty" ]]; then
    echo "No dirty paths."
    exit 0
  fi

  printf '%s\t%s\n' "category" "path" >"$OUT.tsv"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    printf '%s\t%s\n' "$(classify "$path")" "$path" >>"$OUT.tsv"
  done <<<"$all_dirty"

  echo "## Counts"
  echo
  awk -F '\t' 'NR>1 { count[$1]++ } END { for (c in count) print "- " c ": " count[c] }' "$OUT.tsv" | sort
  echo
  echo "## PR interpretation"
  echo
  echo "- release-guard and coordination-doc paths are expected readiness support."
  echo "- runtime-settings-cache, api-streaming-responses, chat-reasoning-tool-ui, keychain-launch-safety, and model-provider-defaults are likely PR-scope but require review/proof."
  echo "- tests and docs are PR-scope only if they directly support the changed behavior."
  echo "- local-artifact and unknown paths block publication until removed, ignored, or manually classified."
  echo
  for category in release-guard dependency-pin coordination-doc keychain-launch-safety runtime-settings-cache api-streaming-responses chat-reasoning-tool-ui model-provider-defaults tests docs local-artifact unknown; do
    if awk -F '\t' -v c="$category" 'NR>1 && $1 == c { found=1 } END { exit found ? 0 : 1 }' "$OUT.tsv"; then
      echo "## $category"
      echo
      awk -F '\t' -v c="$category" 'NR>1 && $1 == c { print "- `" $2 "`" }' "$OUT.tsv"
      echo
    fi
  done
} >"$OUT"

echo "$OUT"
