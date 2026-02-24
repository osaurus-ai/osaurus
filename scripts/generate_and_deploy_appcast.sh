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
  "https://github.com/osaurus-ai/osaurus/releases/download/0.0.9/Osaurus-0.0.9.dmg"


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
  :root {{ color-scheme: light dark; }}
  body {{ font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif; margin: 0 auto; padding: 24px 24px 16px; line-height: 1.6; color: #24292e; background-color: #ffffff; max-width: 680px; }}
  h1 {{ font-size: 24px; font-weight: 600; margin: 0 0 20px 0; padding-bottom: 12px; border-bottom: 1px solid #e1e4e8; color: #24292e; }}
  h2 {{ font-size: 15px; font-weight: 600; margin: 20px 0 10px 0; color: #24292e; padding: 4px 10px; background: #f6f8fa; border-radius: 6px; display: inline-block; }}
  h3 {{ font-size: 14px; font-weight: 600; margin: 16px 0 8px 0; color: #24292e; }}
  ul {{ margin: 8px 0 16px 0; padding-left: 0; list-style: none; }}
  li {{ margin: 6px 0; padding: 4px 0 4px 14px; color: #57606a; border-left: 2px solid #d0d7de; font-size: 14px; }}
  pre, code {{ font-family: 'SF Mono', Monaco, 'Cascadia Code', 'Roboto Mono', Consolas, 'Courier New', monospace; font-size: 13px; }}
  code {{ padding: 2px 4px; border-radius: 4px; background-color: #f6f8fa; }}
  pre {{ padding: 16px; border-radius: 6px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; line-height: 1.5; background: #f6f8fa; border: 1px solid #e1e4e8; font-size: 13px; color: #57606a; }}
  a {{ color: #0969da; text-decoration: none; }}
  a:hover {{ text-decoration: underline; }}
  .version {{ display: inline-block; font-size: 14px; color: #6e7781; font-weight: normal; margin-left: 8px; }}
  .footer {{ margin-top: 24px; padding-top: 14px; border-top: 1px solid #e1e4e8; text-align: center; }}
  .footer a {{ font-size: 13px; color: #6e7781; }}
  .footer a:hover {{ color: #0969da; }}
  @media (prefers-color-scheme: dark) {{
    body {{ background-color: #0b0f14; color: #e6edf3; }}
    h1, h3 {{ color: #e6edf3; }}
    h1 {{ border-bottom-color: #30363d; }}
    h2 {{ color: #e6edf3; background: #161b22; }}
    li {{ color: #9aa6b2; border-left-color: #30363d; }}
    a {{ color: #79c0ff; }}
    code {{ background-color: #161b22; color: #e6edf3; }}
    pre {{ background: #161b22; border: 1px solid #30363d; color: #9aa6b2; }}
    .footer {{ border-top-color: #30363d; }}
    .footer a {{ color: #9aa6b2; }}
    .footer a:hover {{ color: #79c0ff; }}
  }}
</style></head><body>
<h1>Osaurus <span class="version">{version}</span></h1>
{body_html}
<div class="footer">
  <a href="https://github.com/osaurus-ai/osaurus/releases" target="_blank">View all releases on GitHub &#8594;</a>
</div>
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


