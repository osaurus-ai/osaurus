#!/usr/bin/env bash
set -euo pipefail

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

# Target repository for hosting files and releases (match SUFeedURL)
# Keep this in sync with scripts/create_release.sh and the workflow env
PUBLIC_REPO="${PUBLIC_REPO:-$GITHUB_REPOSITORY}"

# Derive owner and repo for building URLs (used for GitHub Pages base)
PUBLIC_OWNER="${PUBLIC_REPO%%/*}"
PUBLIC_NAME="${PUBLIC_REPO#*/}"

mkdir -p sparkle_tools updates
cd sparkle_tools
curl -L -o sparkle.tar.xz "https://github.com/sparkle-project/Sparkle/releases/download/2.7.0/Sparkle-2.7.0.tar.xz"
tar -xf sparkle.tar.xz
chmod +x bin/generate_appcast
chmod +x bin/sign_update
cd ..

sleep 30

mkdir -p updates/arm64

echo "Downloading released DMG..."
curl -L -f -o "updates/arm64/Osaurus-${VERSION}.dmg" \
  "https://github.com/${PUBLIC_REPO}/releases/download/${VERSION}/Osaurus-${VERSION}.dmg"

curl -L -f -o "updates/arm64/Osaurus-0.0.9.dmg" \
  "https://github.com/dinoki-ai/osaurus/releases/download/0.0.9/Osaurus-0.0.9.dmg"


if [ ! -f "updates/arm64/Osaurus-${VERSION}.html" ]; then
  echo "Reconstructing release notes HTML files..."
  : "${CHANGELOG:?CHANGELOG is required to reconstruct release notes}"
  printf '%s\n' "$CHANGELOG" > RELEASE_NOTES.md
  python3 -m pip install --user markdown >/dev/null 2>&1 || true
  python3 - << 'PY'
import os, pathlib
try:
    import markdown
except Exception:
    markdown = None
version = os.environ.get('VERSION', '')
md_text = pathlib.Path('RELEASE_NOTES.md').read_text(encoding='utf-8')
if markdown is not None:
    body_html = markdown.markdown(md_text, extensions=['extra'])
else:
    import html
    body_html = '<pre style="white-space: pre-wrap">' + html.escape(md_text) + '</pre>'
template = f"""<!doctype html><html><head><meta charset=\"utf-8\"><title>Osaurus {version} Release Notes</title>
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<style>
  body { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif; padding: 16px; line-height: 1.5; }
  h1, h2, h3 { margin-top: 1.2em; }
  pre, code { font-family: ui-monospace, Menlo, Monaco, Consolas, monospace; }
  ul { padding-left: 1.2em; }
  a { color: #0b69ff; text-decoration: none; }
  a:hover { text-decoration: underline; }
</style></head><body>
<h1>Osaurus {version}</h1>
{body_html}
</body></html>"""
pathlib.Path(f'updates/arm64/Osaurus-{version}.html').write_text(template, encoding='utf-8')
PY
fi

echo "$SPARKLE_PRIVATE_KEY" > private_key.txt
chmod 600 private_key.txt

./sparkle_tools/bin/generate_appcast \
  --ed-key-file private_key.txt \
  --download-url-prefix "https://github.com/${PUBLIC_REPO}/releases/download/${VERSION}/" \
  --channel "release" \
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
      sub(/\/>$/, " sparkle:edSignature=\"" ed "\"/>", line)
      if (line !~ /sparkle:edSignature=/) {
        sub(/\s*>$/, " sparkle:edSignature=\"" ed "\"/>", line)
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
    sed -E "s#(<enclosure[^>]*Osaurus-${VERSION}\.dmg\"[^>]*)/>#\\1 sparkle:edSignature=\"${EDSIG}\"/>#g" updates/appcast-arm64.xml > "$tmpfile"
    mv "$tmpfile" updates/appcast-arm64.xml
  fi

  # Verify we successfully inserted signature
  if ! grep -q 'edSignature' updates/appcast-arm64.xml; then
    echo "❌ Failed to inject edSignature into appcast." >&2
    exit 1
  fi
  echo "✅ Injected edSignature via sign_update."
fi

{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">'
  echo '  <channel>'
  echo '    <title>Osaurus</title>'
  sed -n '/<item>/,/<\/item>/p' updates/appcast-arm64.xml
  echo '  </channel>'
  echo '</rss>'
} > updates/appcast.xml

# Rewrite release notes URLs to use stable "latest" aliases
tmpfile=$(mktemp)
sed "s/Osaurus-${VERSION}\.html/Osaurus-latest.html/g" updates/appcast.xml > "$tmpfile"
mv "$tmpfile" updates/appcast.xml

# Convert relative release notes links to absolute URLs
# Default to GitHub Pages for the configured public repo (docs/ folder)
# e.g. https://<owner>.github.io/<repo>/
PAGES_BASE="${RELEASE_NOTES_BASE_URL:-https://${PUBLIC_OWNER}.github.io/${PUBLIC_NAME}/}"
tmpfile=$(mktemp)
sed -E "s#<sparkle:releaseNotesLink>[^<]*Osaurus-latest\.html</sparkle:releaseNotesLink>#<sparkle:releaseNotesLink>${PAGES_BASE}Osaurus-latest.html</sparkle:releaseNotesLink>#g" updates/appcast.xml > "$tmpfile"
mv "$tmpfile" updates/appcast.xml

# Validate XML (fail fast if malformed)
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout updates/appcast.xml || { echo "❌ Malformed appcast.xml"; exit 1; }
fi



git clone https://x-access-token:${GH_TOKEN}@github.com/${PUBLIC_REPO}.git public-repo
mkdir -p public-repo/docs
cp updates/appcast.xml public-repo/docs/
# Also publish HTML release notes to the repo for stable raw URLs (served via Pages)
cp "updates/arm64/Osaurus-${VERSION}.html" "public-repo/docs/Osaurus-latest.html"
cd public-repo
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add docs/appcast.xml \
  docs/Osaurus-latest.html
git commit -m "Update appcast and notes for ${VERSION}" || echo "No changes to commit"
git push origin main

echo "✅ Appcast deployed to public repository"


