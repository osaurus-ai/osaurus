#!/usr/bin/env bash
set -euo pipefail

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

# Target repository for hosting files and releases (match SUFeedURL)
# Keep this in sync with scripts/create_release.sh and the workflow env
PUBLIC_REPO="${PUBLIC_REPO:-$GITHUB_REPOSITORY}"

SPARKLE_CHANNEL="${SPARKLE_CHANNEL:-release}"
echo "Building appcast for channel: ${SPARKLE_CHANNEL}"

# The version picks the feed: 0.x (Classic) writes appcast.xml, 1.x and later
# write appcast-next.xml. Neither lane may touch the other's feed.
RELEASE_LANE_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release_lane.py"
APPCAST_FILE="$(python3 "$RELEASE_LANE_PY" field --version "$VERSION" appcast_file)"
echo "Release lane feed: ${APPCAST_FILE}"

mkdir -p sparkle_tools updates
cd sparkle_tools
curl -L -o sparkle.tar.xz "https://github.com/sparkle-project/Sparkle/releases/download/2.9.0/Sparkle-2.9.0.tar.xz"
tar -xf sparkle.tar.xz
chmod +x bin/generate_appcast
chmod +x bin/sign_update
cd ..

sleep 30

mkdir -p updates/arm64

echo "Downloading released DMG..."
curl -L -f -o "updates/arm64/Osaurus-${VERSION}.dmg" \
  "https://github.com/${PUBLIC_REPO}/releases/download/${VERSION}/Osaurus-${VERSION}.dmg"

echo "$SPARKLE_PRIVATE_KEY" > private_key.txt
chmod 600 private_key.txt

./sparkle_tools/bin/generate_appcast \
  --ed-key-file private_key.txt \
  --download-url-prefix "https://github.com/${PUBLIC_REPO}/releases/download/${VERSION}/" \
  --channel "${SPARKLE_CHANNEL}" \
  -o updates/appcast-arm64.xml \
  updates/arm64/

# Ensure signatures were generated; if missing, generate with sign_update and patch
if ! grep -q 'edSignature' updates/appcast-arm64.xml; then
  echo "⚠️ No edSignature found from generate_appcast; attempting manual signing..."
  SIG_OUTPUT=$(./sparkle_tools/bin/sign_update --ed-key-file private_key.txt "updates/arm64/Osaurus-${VERSION}.dmg" | tr -d '\n') || true
  EDSIG=$(printf "%s" "$SIG_OUTPUT" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')
  FILELEN=$(printf "%s" "$SIG_OUTPUT" | sed -n 's/.* length="\([^"]*\)".*/\1/p')
  if [ -z "${EDSIG}" ] || [ -z "${FILELEN}" ]; then
    echo "❌ Failed to derive signature with sign_update; check SPARKLE_PRIVATE_KEY format (base64 32-byte seed)." >&2
    exit 1
  fi
  tmpfile=$(mktemp)
  awk -v ver="${VERSION}" -v ed="${EDSIG}" -v len="${FILELEN}" '
    /<enclosure/ && $0 ~ ("Osaurus-" ver ".dmg") {
      line=$0
      gsub(/length="[^"]*"/, "length=\"" len "\"", line)
      if (line ~ /sparkle:edSignature=/) {
        sub(/sparkle:edSignature="[^"]*"/, "sparkle:edSignature=\"" ed "\"", line)
      } else {
        sub(/[[:space:]]*\/>[[:space:]]*$/, " sparkle:edSignature=\"" ed "\"/>", line)
      }
      print line
      next
    }
    { print }
  ' updates/appcast-arm64.xml > "$tmpfile"
  mv "$tmpfile" updates/appcast-arm64.xml

  # Fallback: if still missing, inject signature attribute with sed
  if ! grep -q 'edSignature' updates/appcast-arm64.xml; then
    tmpfile=$(mktemp)
    sed -E "s#(<enclosure[^>]*Osaurus-${VERSION}\.dmg\"[^>]*)[[:space:]]*/>#\\1 sparkle:edSignature=\"${EDSIG}\"/>#g" updates/appcast-arm64.xml > "$tmpfile"
    mv "$tmpfile" updates/appcast-arm64.xml
  fi

  # Verify we successfully inserted signature
  if ! grep -q 'edSignature' updates/appcast-arm64.xml; then
    echo "❌ Failed to inject edSignature into appcast." >&2
    exit 1
  fi
  echo "✅ Injected edSignature via sign_update."
fi

# If RELEASE_NOTES.md doesn't exist, fetch release notes from the GitHub Release
if [ ! -f "RELEASE_NOTES.md" ]; then
  echo "No local RELEASE_NOTES.md found; fetching from GitHub Release..."
  BODY=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${PUBLIC_REPO}/releases/tags/${VERSION}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('body',''))" 2>/dev/null || true)
  if [ -n "$BODY" ]; then
    printf '%s\n' "$BODY" > RELEASE_NOTES.md
  fi
fi

# Inject <description> (markdown) into current version's item
# Remove any releaseNotesLink since we use inline description instead
# Notes are read via ENVIRON to avoid awk -v interpreting backslash escape sequences
tmpfile=$(mktemp)
RELEASE_NOTES_FILE=""
if [ -f "RELEASE_NOTES.md" ]; then
  RELEASE_NOTES_FILE="RELEASE_NOTES.md"
fi
NOTES_FILE="$RELEASE_NOTES_FILE" awk -v ver="${VERSION}" '
  BEGIN { vtag = "<sparkle:version>" ver "</sparkle:version>" }
  $0 ~ vtag { is_current=1 }
  /<sparkle:releaseNotesLink>/ && is_current { next }
  /<\/item>/ && is_current {
    nf = ENVIRON["NOTES_FILE"]
    if (nf != "") {
      print "            <description sparkle:format=\"markdown\"><![CDATA["
      while ((getline line < nf) > 0) {
        gsub(/\]\]>/, "]]]]><![CDATA[>", line)
        print line
      }
      close(nf)
      print "]]></description>"
    }
    is_current=0
  }
  { print }
' updates/appcast-arm64.xml > "$tmpfile"
mv "$tmpfile" updates/appcast-arm64.xml

# Extract new items from the generated appcast
NEW_ITEMS=$(sed -n '/<item>/,/<\/item>/p' updates/appcast-arm64.xml)

# Clone the public repo to merge with the existing appcast
git clone "https://x-access-token:${GH_TOKEN}@github.com/${PUBLIC_REPO}.git" public-repo
mkdir -p public-repo/docs

# Merge new items into this lane's existing appcast (preserving items from other channels)
EXISTING_ITEMS=""
if [ -f "public-repo/docs/${APPCAST_FILE}" ]; then
  python3 "$RELEASE_LANE_PY" check-feed --version "$VERSION" --feed-file "$APPCAST_FILE" \
    --appcast "public-repo/docs/${APPCAST_FILE}"
  EXISTING_ITEMS=$(sed -n '/<item>/,/<\/item>/p' "public-repo/docs/${APPCAST_FILE}" | \
    sed 's/<\/channel>//g; s/<\/rss>//g' | \
    awk -v ver="${VERSION}" '
      /<item>/    { buf=""; inside=1 }
      inside      { buf = buf $0 "\n" }
      /<\/item>/  {
        inside=0
        if (buf !~ ("<sparkle:version>" ver "</sparkle:version>"))
          printf "%s", buf
      }
    ')
fi

{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">'
  echo '  <channel>'
  echo '    <title>Osaurus</title>'
  printf '%s\n' "$NEW_ITEMS"
  [ -n "$EXISTING_ITEMS" ] && printf '%s\n' "$EXISTING_ITEMS"
  echo '  </channel>'
  echo '</rss>'
} > "updates/${APPCAST_FILE}"

# Validate XML (fail fast if malformed)
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "updates/${APPCAST_FILE}" || { echo "❌ Malformed ${APPCAST_FILE}"; exit 1; }
fi
python3 "$RELEASE_LANE_PY" check-feed --version "$VERSION" --feed-file "$APPCAST_FILE" \
  --appcast "updates/${APPCAST_FILE}"

cp "updates/${APPCAST_FILE}" public-repo/docs/
cd public-repo
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add "docs/${APPCAST_FILE}"
git commit -m "Update ${APPCAST_FILE} for ${VERSION} (${SPARKLE_CHANNEL})" || echo "No changes to commit"
git push origin main

echo "✅ ${APPCAST_FILE} deployed to public repository (channel: ${SPARKLE_CHANNEL})"
