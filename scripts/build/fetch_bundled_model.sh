#!/usr/bin/env bash
set -euo pipefail

# Stage the bundled onboarding model for the "full" distribution DMG.
#
# Downloads OsaurusAI/Raptor-0.6-4B-JANG_6M at a pinned Hugging Face commit,
# keeps exactly the file set `ModelDownloadService` would download (so the
# seeded bundle is byte-identical to an in-app download), verifies the
# weights against a pinned SHA-256, and writes `manifest.json` for
# `BundledModelSeeder` (Packages/OsaurusCore/Services/BundledModelSeeder.swift).
#
# The MODEL_ID / REVISION / WEIGHTS_SHA256 pins below must move together.
# The revision is a commit hash, so every `resolve/<REVISION>/<file>` URL is
# immutable; the weights digest is the fail-closed check on the one file
# that matters.
#
# Usage: fetch_bundled_model.sh <output-dir>
#   <output-dir> receives `manifest.json` and `<org>/<repo>/<files>`
#   (typically <App>.app/Contents/Resources/BundledModels).
#
# Environment:
#   HF_TOKEN                  optional; avoids anonymous CDN throttling.
#   BUNDLED_MODEL_CACHE_DIR   download cache (default ~/.cache/osaurus-bundled-model).
#   BUNDLED_MODEL_SOURCE_DIR  stage from an existing local bundle instead of
#                             downloading (still digest-verified). Local dev only.

MODEL_ID="OsaurusAI/Raptor-0.6-4B-JANG_6M"
REVISION="41328ca5650100fa2e1913b1be7124ef33cc51c8"
WEIGHTS_FILE="model-00001-of-00001.safetensors"
WEIGHTS_SHA256="4b99612854c5f0a4c6c7e0098a0c1dfda98e90880f983bd8254feae09cabf43d"

# Mirror of ModelDownloadService.downloadFilePatterns / downloadExcludedFiles.
INCLUDE_GLOBS=("*.json" "*.jinja" "*.txt" "*.model" "*.safetensors")
EXCLUDE_FILES=("README.md" ".gitattributes")

OUT_DIR="${1:?output directory required (e.g. Osaurus.app/Contents/Resources/BundledModels)}"
CACHE_DIR="${BUNDLED_MODEL_CACHE_DIR:-${HOME}/.cache/osaurus-bundled-model}"
SOURCE_DIR="${BUNDLED_MODEL_SOURCE_DIR:-}"

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

size_of() {
  stat -f %z "$1"
}

wanted() {
  local name="$1" glob
  for excluded in "${EXCLUDE_FILES[@]}"; do
    [[ "$name" == "$excluded" ]] && return 1
  done
  for glob in "${INCLUDE_GLOBS[@]}"; do
    # shellcheck disable=SC2254
    case "$name" in
      $glob) return 0 ;;
    esac
  done
  return 1
}

AUTH_ARGS=()
if [[ -n "${HF_TOKEN:-}" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer ${HF_TOKEN}")
fi

# 1. Resolve the file list at the pinned revision.
FILES=()
if [[ -n "$SOURCE_DIR" ]]; then
  echo "Staging bundled model from local source ${SOURCE_DIR}"
  while IFS= read -r name; do
    wanted "$name" && FILES+=("$name")
  done < <(ls -1 "$SOURCE_DIR")
else
  echo "Resolving ${MODEL_ID}@${REVISION} file list..."
  LISTING="$(curl -fsSL --retry 3 "${AUTH_ARGS[@]}" \
    "https://huggingface.co/api/models/${MODEL_ID}/revision/${REVISION}")"
  while IFS= read -r name; do
    wanted "$name" && FILES+=("$name")
  done < <(printf '%s' "$LISTING" | python3 -c 'import json,sys
for s in json.load(sys.stdin)["siblings"]:
    print(s["rfilename"])')
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERROR: no files matched the download patterns for ${MODEL_ID}" >&2
  exit 1
fi
HAS_WEIGHTS=0
for f in "${FILES[@]}"; do
  [[ "$f" == "$WEIGHTS_FILE" ]] && HAS_WEIGHTS=1
done
if [[ $HAS_WEIGHTS -ne 1 ]]; then
  echo "ERROR: ${WEIGHTS_FILE} missing from ${MODEL_ID}@${REVISION}" >&2
  exit 1
fi

# 2. Fetch into the revision-keyed cache (resumable).
REV_CACHE="${CACHE_DIR}/${MODEL_ID}/${REVISION}"
mkdir -p "$REV_CACHE"
for name in "${FILES[@]}"; do
  target="${REV_CACHE}/${name}"
  if [[ -n "$SOURCE_DIR" ]]; then
    cp -c "${SOURCE_DIR}/${name}" "$target" 2>/dev/null || cp "${SOURCE_DIR}/${name}" "$target"
    continue
  fi
  if [[ -f "$target" && "$name" == "$WEIGHTS_FILE" && "$(sha256_of "$target")" == "$WEIGHTS_SHA256" ]]; then
    echo "  cached  ${name}"
    continue
  fi
  echo "  fetch   ${name}"
  curl -fL --retry 5 --retry-delay 5 -C - "${AUTH_ARGS[@]}" \
    -o "$target" \
    "https://huggingface.co/${MODEL_ID}/resolve/${REVISION}/${name}"
done

# 3. Fail closed on the weights digest.
ACTUAL_WEIGHTS_SHA="$(sha256_of "${REV_CACHE}/${WEIGHTS_FILE}")"
if [[ "$ACTUAL_WEIGHTS_SHA" != "$WEIGHTS_SHA256" ]]; then
  echo "ERROR: ${WEIGHTS_FILE} SHA-256 mismatch (expected ${WEIGHTS_SHA256}, got ${ACTUAL_WEIGHTS_SHA})" >&2
  rm -f "${REV_CACHE}/${WEIGHTS_FILE}"
  exit 1
fi

# 4. Stage into the output directory and write the manifest.
MODEL_OUT="${OUT_DIR}/${MODEL_ID}"
rm -rf "$MODEL_OUT"
mkdir -p "$MODEL_OUT"
ENTRIES_FILE="$(mktemp)"
trap 'rm -f "$ENTRIES_FILE"' EXIT
TOTAL_BYTES=0
for name in "${FILES[@]}"; do
  src="${REV_CACHE}/${name}"
  cp -c "$src" "${MODEL_OUT}/${name}" 2>/dev/null || cp "$src" "${MODEL_OUT}/${name}"
  bytes="$(size_of "$src")"
  TOTAL_BYTES=$((TOTAL_BYTES + bytes))
  printf '%s\t%s\t%s\n' "$name" "$bytes" "$(sha256_of "$src")" >> "$ENTRIES_FILE"
done

python3 - "$OUT_DIR/manifest.json" "$MODEL_ID" "$REVISION" "$TOTAL_BYTES" "$ENTRIES_FILE" <<'PY'
import json, sys
out, model_id, revision, total, entries_path = sys.argv[1:6]
files = []
with open(entries_path) as fh:
    for line in fh:
        name, size, digest = line.rstrip("\n").split("\t")
        files.append({"path": name, "bytes": int(size), "sha256": digest})
files.sort(key=lambda f: f["path"])
manifest = {
    "models": [
        {
            "id": model_id,
            "revision": revision,
            "source": f"https://huggingface.co/{model_id}/tree/{revision}",
            "totalBytes": int(total),
            "files": files,
        }
    ]
}
with open(out, "w") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

echo "Bundled model ${MODEL_ID}@${REVISION} staged at ${MODEL_OUT} (${TOTAL_BYTES} bytes, ${#FILES[@]} files)"
