#!/usr/bin/env bash
set -euo pipefail

: "${DISCORD_WEBHOOK:?DISCORD_WEBHOOK is required}"

RAW_CHANGELOG="${RAW_CHANGELOG:-}"
if [ -z "$RAW_CHANGELOG" ] && [ -f RELEASE_NOTES.md ]; then
  RAW_CHANGELOG=$(cat RELEASE_NOTES.md)
fi

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found; attempting to install..."
  brew install jq >/dev/null 2>&1 || {
    echo "jq is required and could not be installed." >&2
    exit 1
  }
fi

# Truncate to ~1900 chars for Discord embed description
TRUNCATED=$(printf '%s' "$RAW_CHANGELOG" | head -c 1900)

# releases/latest always resolves to Osaurus 1.x, so a Classic post links its
# own DMG.
RELEASE_LANE_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release_lane.py"
if [ "$(python3 "$RELEASE_LANE_PY" field --version "$VERSION" name)" = "classic" ]; then
  CONTENT="🛠️ **New Osaurus Classic maintenance release**"
  DOWNLOAD="[Download Osaurus-${VERSION}.dmg](https://github.com/osaurus-ai/osaurus/releases/download/${VERSION}/Osaurus-${VERSION}.dmg)"
else
  CONTENT="🚀 **New Osaurus Release!**"
  DOWNLOAD="[Download Osaurus.dmg](https://github.com/osaurus-ai/osaurus/releases/latest/download/Osaurus.dmg)"
fi

jq -n \
  --arg content  "$CONTENT" \
  --arg title    "$(python3 "$RELEASE_LANE_PY" field --version "$VERSION" title)" \
  --arg desc     "$TRUNCATED" \
  --arg download "$DOWNLOAD" \
  --arg page     "[View on GitHub](https://github.com/osaurus-ai/osaurus/releases/tag/${VERSION})" \
  '{
    content: $content,
    embeds: [
      {
        title: $title,
        description: $desc,
        color: 5814783,
        fields: [
          { name: "📥 Download",  value: $download, inline: true },
          { name: "📋 Release Page", value: $page,     inline: true }
        ],
        footer:   { text: "Released via GitHub Actions" },
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%S.000Z"))
      }
    ]
  }' > payload.json

curl -f -X POST -H "Content-Type: application/json" --data @payload.json "$DISCORD_WEBHOOK"

echo "✅ Discord notification sent"


