---
title: Privacy, Storage, and Encryption
summary: Where your data lives, at-rest encryption, backups, and what (if anything) leaves your Mac.
order: 170
---

# Privacy, Storage, and Encryption

Osaurus is local-first: chats, memory, agents, and config all live under `~/.osaurus/` on your Mac.

## What leaves your Mac

- Nothing conversation-related, unless you connect a cloud provider (then your prompts go to that provider) or enable server network exposure.
- Anonymous usage analytics (Aptabase — no chats, prompts, or keys) and crash reports (Sentry) are consent-gated: Settings → Privacy & Security → Send Crash Reports.
- The Privacy tab also offers an experimental Privacy Filter that scrubs sensitive text before cloud sends. Its Detection Rules ship international presets — national ID, tax, health and bank number formats for 100+ countries plus global finance, network and secret patterns. Presets for your Mac's locale region are on from the first launch; pick more countries under Privacy & Security → Detection Rules → My Regions.
- To see exactly what did leave, open Settings → Insights: every model request, web search, URL fetch, MCP call, channel delivery and Router call is logged with a Local/Cloud badge, destination, bytes, and (for model requests) whether the Privacy Filter redacted anything. Retention and whether prompt/response bodies are stored: Settings → Privacy & Security → Activity Log. See the Insights topic.

## Storage layout

- `~/.osaurus/sync/` (chats, see the Sync topic), `chat-history/history.sqlite` (the pre-sync chat history, kept read-only as a backup), `memory/memory.sqlite`, `agents/<uuid>/db.sqlite`, `activity/activity.sqlite` (the Insights activity log), `skills/`, `config/*.json`, attachments as content-addressed blobs.
- Local models are separate, in `~/MLXModels/`.

## Spaces

A Space is a separate Osaurus environment with its own chats, agents, settings, setup state, and saved keys. Use one to try a fresh setup or keep a test configuration apart from your everyday one.

- Manage Spaces from the Dock: right-click the Osaurus icon → **Space:** followed by the current Space's name. From there you can switch Spaces, choose **New Space…**, **Rename This Space…**, **Reset This Space…** (wipes only that Space and reopens setup), **Delete Space**, or **Show Space in Finder**.
- Switching, creating, resetting, or deleting the current Space restarts Osaurus. Only one Space runs at a time.
- The **Default Space** is `~/.osaurus/` and can't be renamed or deleted. Other Spaces live in `~/.osaurus-spaces/<id>/data/`, with their saved preferences beside it.
- Each Space gets its own Keychain entries (identity, sign-in, Sync, and API keys). Keys in a non-Default Space stay on this Mac and never sync through iCloud Keychain.
- Shared across Spaces: local models in `~/MLXModels/`, the Hugging Face download cache, macOS permissions (Accessibility, Notifications, and so on), update settings, and the app language.
- A Factory Reset run inside a non-Default Space resets only that Space.

## Encryption

- Default: plaintext SQLite protected by macOS FileVault. If you don't use FileVault, backups of `~/.osaurus` are readable.
- Opt-in at-rest encryption: Settings… (⌘,) → Privacy & Security → Data & Storage → **Encrypt Local Data at Rest (SQLCipher)**. Migration runs both ways.
- The encryption key lives in this device's Keychain only (not iCloud-synced). Losing the key means losing the data — export a plaintext backup first.
- **Rotate Storage Key** is available while encryption is on.

## Backup and recovery

- Privacy & Security → Data & Storage → **Export Plaintext Backup** copies databases, attachments, and config to a folder you choose (decrypting if needed). Do this before a macOS reinstall or Mac migration.
- "Stores needing attention" lists degraded stores with Retry / Reset; Reset quarantines the file to `~/.osaurus/quarantine/` — nothing is deleted.

## Secrets

API keys and tokens are always stored in the macOS Keychain, never in JSON config, and never pass through chat text.
