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

jq -n \
  --arg content  "🚀 **New Osaurus Release!**" \
  --arg version  "${VERSION}" \
  --arg desc     "$TRUNCATED" \
  --arg download "[Download Osaurus.dmg](https://github.com/dinoki-ai/osaurus/releases/latest/download/Osaurus.dmg)" \
  --arg page     "[View on GitHub](https://github.com/dinoki-ai/osaurus/releases/tag/${VERSION})" \
  '{
    content: $content,
    embeds: [
      {
        title: ("Osaurus " + $version),
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


