#!/usr/bin/env bash
set -euo pipefail

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

# Target repository for hosting files and releases (match SUFeedURL)
# Keep this in sync with scripts/create_release.sh and the workflow env
PUBLIC_REPO="${PUBLIC_REPO:-$GITHUB_REPOSITORY}"

SPARKLE_CHANNEL="${SPARKLE_CHANNEL:-release}"
echo "Building appcast for channel: ${SPARKLE_CHANNEL}"

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

# Inject <description> (markdown) and <sparkle:hardwareRequirements> into current version's items
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
    print "            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"
    nf = ENVIRON["NOTES_FILE"]
    if (nf != "") {
      print "            <description><![CDATA["
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

# Merge new items into the existing appcast (preserving items from other channels)
EXISTING_ITEMS=""
if [ -f "public-repo/docs/appcast.xml" ]; then
  EXISTING_ITEMS=$(sed -n '/<item>/,/<\/item>/p' public-repo/docs/appcast.xml | \
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
  printf '%s' "$EXISTING_ITEMS"
  echo '  </channel>'
  echo '</rss>'
} > updates/appcast.xml

# Validate XML (fail fast if malformed)
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout updates/appcast.xml || { echo "❌ Malformed appcast.xml"; exit 1; }
fi

cp updates/appcast.xml public-repo/docs/
cd public-repo
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add docs/appcast.xml
git commit -m "Update appcast for ${VERSION} (${SPARKLE_CHANNEL})" || echo "No changes to commit"
git push origin main

echo "✅ Appcast deployed to public repository (channel: ${SPARKLE_CHANNEL})"
