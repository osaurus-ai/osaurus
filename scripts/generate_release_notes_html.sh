#!/usr/bin/env bash
set -euo pipefail

: "${VERSION:?VERSION is required}"

mkdir -p updates/arm64

# If RELEASE_NOTES.md does not exist or is empty, optionally write from env CHANGELOG
if [ ! -s RELEASE_NOTES.md ]; then
  printf '%s\n' "${CHANGELOG:-}" > RELEASE_NOTES.md
fi

# Install markdown converter quietly (best effort)
python3 -m pip install --user markdown >/dev/null 2>&1 || true

python3 - "$VERSION" << 'PY'
import os, pathlib, sys
version = sys.argv[1]
try:
    import markdown
except Exception:
    markdown = None

md_path = pathlib.Path('RELEASE_NOTES.md')
md_text = md_path.read_text(encoding='utf-8') if md_path.exists() else ''

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


