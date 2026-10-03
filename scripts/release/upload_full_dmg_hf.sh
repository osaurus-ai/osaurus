#!/usr/bin/env bash
set -euo pipefail

# Publish the full (model-bundled) DMG.
#
# GitHub Releases reject assets over 2 GiB, so the ~4 GB full DMG is hosted
# on the Hugging Face Hub under the OsaurusAI org instead:
#
#   datasets/OsaurusAI/osaurus-releases/<VERSION>/Osaurus-<VERSION>-full.dmg
#   datasets/OsaurusAI/osaurus-releases/<VERSION>/SHA256SUMS
#   datasets/OsaurusAI/osaurus-releases/latest.json      (non-beta only)
#
# Afterwards the GitHub release body gains a "Downloads" section pointing at
# it, so the release page stays the single place users look.
#
# Environment:
#   HF_TOKEN       write token for the OsaurusAI org (required)
#   GH_TOKEN       for `gh release edit` (optional; skipped when unset or
#                  when no release exists for VERSION, e.g. workflow_dispatch)
#   VERSION        release version (required)
#   IS_BETA        "true" for pre-releases (no latest.json update)
#   PUBLIC_REPO    GitHub repo for the release page (default $GITHUB_REPOSITORY)
#   HF_RELEASES_REPO  override the HF dataset repo id (default OsaurusAI/osaurus-releases)

: "${HF_TOKEN:?HF_TOKEN is required}"
: "${VERSION:?VERSION is required}"

IS_BETA="${IS_BETA:-false}"
PUBLIC_REPO="${PUBLIC_REPO:-${GITHUB_REPOSITORY:-osaurus-ai/osaurus}}"
HF_RELEASES_REPO="${HF_RELEASES_REPO:-OsaurusAI/osaurus-releases}"
DMG_NAME="Osaurus-${VERSION}-full.dmg"
DMG_PATH="build_output/${DMG_NAME}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: full DMG not found at ${DMG_PATH}" >&2
  exit 1
fi

DMG_BYTES="$(stat -f %z "$DMG_PATH")"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
DMG_GB="$(python3 -c "print(f'{${DMG_BYTES}/1e9:.1f}')")"

# 1. Stage the version folder exactly as it will appear on the Hub.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "${STAGE}/${VERSION}"
# APFS clone when possible (instant, no extra disk); plain copy otherwise.
cp -c "$DMG_PATH" "${STAGE}/${VERSION}/${DMG_NAME}" 2>/dev/null || cp "$DMG_PATH" "${STAGE}/${VERSION}/${DMG_NAME}"
printf '%s  %s\n' "$DMG_SHA256" "$DMG_NAME" > "${STAGE}/${VERSION}/SHA256SUMS"
cp "${STAGE}/${VERSION}/SHA256SUMS" "build_output/${DMG_NAME}.SHA256SUMS"

DOWNLOAD_URL="https://huggingface.co/datasets/${HF_RELEASES_REPO}/resolve/main/${VERSION}/${DMG_NAME}"

if [[ "$IS_BETA" != "true" ]]; then
  python3 - "${STAGE}/latest.json" "$VERSION" "$DMG_NAME" "$DOWNLOAD_URL" "$DMG_BYTES" "$DMG_SHA256" <<'PY'
import datetime, json, sys
out, version, name, url, size, digest = sys.argv[1:7]
payload = {
    "version": version,
    "asset": name,
    "url": url,
    "bytes": int(size),
    "sha256": digest,
    "bundledModels": ["OsaurusAI/Raptor-0.6-4B-JANG_6M"],
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(out, "w") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
fi

# 2. Upload with huggingface_hub (handles the multipart LFS transfer of the
#    4 GB payload). Installed into a throwaway venv so the runner's system
#    Python is untouched.
VENV="$(mktemp -d)/hf-venv"
python3 -m venv "$VENV"
"${VENV}/bin/pip" install --quiet --upgrade pip
"${VENV}/bin/pip" install --quiet "huggingface_hub>=0.34"

echo "Uploading ${DMG_NAME} (${DMG_BYTES} bytes) to ${HF_RELEASES_REPO}..."
HF_TOKEN="$HF_TOKEN" "${VENV}/bin/python" - "$HF_RELEASES_REPO" "$STAGE" "$VERSION" <<'PY'
import os, sys
from huggingface_hub import HfApi

repo_id, stage, version = sys.argv[1:4]
api = HfApi(token=os.environ["HF_TOKEN"])
api.create_repo(repo_id, repo_type="dataset", exist_ok=True)
api.upload_folder(
    repo_id=repo_id,
    repo_type="dataset",
    folder_path=stage,
    commit_message=f"Osaurus {version} full DMG",
)
print(f"Uploaded {version} to {repo_id}")
PY

# 3. Confirm the asset resolves before advertising it.
for attempt in 1 2 3 4 5 6; do
  if curl -fsIL -o /dev/null "$DOWNLOAD_URL"; then
    break
  fi
  if [[ $attempt -eq 6 ]]; then
    echo "ERROR: ${DOWNLOAD_URL} does not resolve after upload" >&2
    exit 1
  fi
  sleep 10
done

echo "FULL_DMG_URL=${DOWNLOAD_URL}" >> "${GITHUB_ENV:-/dev/null}"
echo "Full DMG published: ${DOWNLOAD_URL} (${DMG_GB} GB, sha256 ${DMG_SHA256})"

# 4. Append the download to the GitHub release notes (idempotent).
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN not set; skipping release-notes update."
  exit 0
fi
if ! gh release view "$VERSION" --repo "$PUBLIC_REPO" >/dev/null 2>&1; then
  echo "No GitHub release ${VERSION} in ${PUBLIC_REPO}; skipping release-notes update."
  exit 0
fi

BODY_FILE="$(mktemp)"
gh release view "$VERSION" --repo "$PUBLIC_REPO" --json body -q .body > "$BODY_FILE"
if grep -q "<!-- full-dmg -->" "$BODY_FILE"; then
  # Replace a previous section (re-run) rather than appending twice.
  python3 - "$BODY_FILE" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r"\n*<!-- full-dmg -->.*?<!-- /full-dmg -->\n*", "\n", text, flags=re.S)
open(path, "w").write(text.rstrip("\n") + "\n")
PY
fi
cat >> "$BODY_FILE" <<EOF

<!-- full-dmg -->
## Downloads

- [Osaurus-${VERSION}.dmg](https://github.com/${PUBLIC_REPO}/releases/download/${VERSION}/Osaurus-${VERSION}.dmg) — standard build. Pick a model during onboarding.
- [${DMG_NAME}](${DOWNLOAD_URL}) — ${DMG_GB} GB, Raptor 0.6 bundled. Chat offline right after install; no model download. \`sha256 ${DMG_SHA256}\`
<!-- /full-dmg -->
EOF

gh release edit "$VERSION" --repo "$PUBLIC_REPO" --notes-file "$BODY_FILE"
rm -f "$BODY_FILE"
echo "Release notes for ${VERSION} now link the full DMG."
