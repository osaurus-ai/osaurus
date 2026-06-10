#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_file() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then
    pass "$label exists"
  else
    fail_msg "missing $label: $file"
  fi
}

require_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -q "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "missing $label in ${file#$ROOT/}"
  fi
}

reject_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -n "$pattern" "$file"; then
    fail_msg "forbidden $label in ${file#$ROOT/}"
  else
    pass "no $label"
  fi
}

MODEL_MANAGER="$ROOT/Packages/OsaurusCore/Managers/Model/ModelManager.swift"
HF_SERVICE="$ROOT/Packages/OsaurusCore/Services/HuggingFaceService.swift"
APP_DELEGATE="$ROOT/Packages/OsaurusCore/AppDelegate.swift"
MODEL_DOWNLOAD_VIEW="$ROOT/Packages/OsaurusCore/Views/Model/ModelDownloadView.swift"
TESTS="$ROOT/Packages/OsaurusCore/Tests/Model/ModelManagerResolveTests.swift"

require_file "$MODEL_MANAGER" "ModelManager"
require_file "$HF_SERVICE" "HuggingFaceService"
require_file "$APP_DELEGATE" "AppDelegate"
require_file "$MODEL_DOWNLOAD_VIEW" "ModelDownloadView"
require_file "$TESTS" "ModelManagerResolveTests"

require_text "$MODEL_MANAGER" 'nonisolated static func nameLooksLikeMLX' \
  "ModelManager has MLX artifact hint helper"
require_text "$MODEL_MANAGER" 'nonisolated static func nameLooksLikeMLX' \
  "ModelManager MLX artifact hint helper is callable from nonisolated tests"
require_text "$MODEL_MANAGER" 'lower\.contains\("-mxfp"\)|lower\.contains\("_mxfp"\)' \
  "ModelManager accepts MXFP artifact-family hints"
require_text "$MODEL_MANAGER" 'lower\.contains\("-jang"\)|lower\.contains\("_jang"\)' \
  "ModelManager accepts JANG artifact-family hints"
require_text "$MODEL_MANAGER" 'lower\.contains\("-jangtq"\)|lower\.contains\("_jangtq"\)' \
  "ModelManager accepts JANGTQ artifact-family hints"
require_text "$MODEL_MANAGER" 'lower\.contains\("turboquant"\)' \
  "ModelManager accepts TurboQuant artifact-family hints"
reject_text "$MODEL_MANAGER" 'guard .*contains\("mlx"\).*else \{ return nil \}' \
  "literal-MLX-only import guard"

require_text "$HF_SERVICE" 'repoIdHasMLXArtifactHint' \
  "HuggingFaceService has artifact-family compatibility helper"
require_text "$HF_SERVICE" 'Self\.repoIdHasMLXArtifactHint\(lower\) && hasRequiredFiles\(meta: meta\)' \
  "HF compatibility uses artifact hint plus required files"
require_text "$HF_SERVICE" 'lowerRepoId\.contains\("-mxfp"\)|lowerRepoId\.contains\("_mxfp"\)' \
  "HF compatibility accepts MXFP hints"
require_text "$HF_SERVICE" 'lowerRepoId\.contains\("-jang"\)|lowerRepoId\.contains\("_jang"\)' \
  "HF compatibility accepts JANG hints"
require_text "$HF_SERVICE" 'lowerRepoId\.contains\("-jangtq"\)|lowerRepoId\.contains\("_jangtq"\)' \
  "HF compatibility accepts JANGTQ hints"
require_text "$HF_SERVICE" 'lowerRepoId\.contains\("turboquant"\)' \
  "HF compatibility accepts TurboQuant hints"
require_text "$HF_SERVICE" 'hasRequiredFiles\(meta: meta\)' \
  "HF compatibility still requires model files"

require_text "$TESTS" 'Qwen3\.6-35B-A3B-MXFP4-CRACK-MTP' \
  "regression covers exact reported Qwen MXFP4 MTP slug"
require_text "$TESTS" 'Qwen3\.6-35B-A3B-JANGTQ4-CRACK' \
  "regression covers JANGTQ family hint"
require_text "$TESTS" 'Gemma-4-31B-JANG_4M' \
  "regression covers JANG family hint"
require_text "$TESTS" 'TurboQuant-4bit' \
  "regression covers TurboQuant family hint"
require_text "$TESTS" 'Plain-Transformers-Checkpoint' \
  "regression rejects plain non-MLX checkpoint"

require_text "$MODEL_DOWNLOAD_VIEW" 'MLX, MXFP, JANG, JANGTQ, or TurboQuant' \
  "Model Download UI names accepted artifact-family hints"
reject_text "$MODEL_DOWNLOAD_VIEW" 'must have .*mlx.*repo name|one with .*-mlx.*in its name' \
  "literal-MLX-only Model Download error copy"
require_text "$APP_DELEGATE" 'MLX, MXFP, JANG, JANGTQ, and TurboQuant' \
  "HF deeplink alert names accepted artifact-family hints"

active="$({ ps -axo pid,ppid,rss,etime,command || true; } \
  | rg -v '/Users/eric/\.codex/computer-use/|SkyComputerUseClient' \
  | rg -i 'xcodebuild|codesign( |$)|notarytool|/usr/bin/security( |$)|/Users/eric/osaurus-staging.*(swift-test|xcrun swift|swift test|swift build|swift-driver|swift-frontend|PackagePlugin|\\.build/.*/Cmlx\\.build|/usr/bin/clang .*osaurus-staging)' \
  | rg -v 'rg -i|assert-hf-import-compatibility' || true)"
if [[ -n "$active" ]]; then
  echo "$active" >&2
  fail_msg "active keychain/build process detected; source assertions above are useful but do not promote live import proof"
else
  pass "no active keychain/build process"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "HF import compatibility guard failed." >&2
  exit 1
fi

echo "HF import compatibility guard passed."
