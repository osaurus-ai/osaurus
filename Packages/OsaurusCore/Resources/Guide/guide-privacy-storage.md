---
title: Privacy, Storage, and Encryption
summary: Where your data lives, at-rest encryption, backups, and what (if anything) leaves your Mac.
order: 170
---

# Privacy, Storage, and Encryption

Osaurus is local-first: chats, memory, agents, and config all live under `~/.osaurus/` on your Mac.

## What leaves your Mac

- Nothing conversation-related, unless you connect a cloud provider (then your prompts go to that provider) or enable server network exposure.
- Anonymous usage analytics (Aptabase — no chats, prompts, or keys) and crash reports (Sentry) are consent-gated: Settings → Privacy → Filter → Send Crash Reports.
- The Privacy tab also offers an experimental Privacy Filter that scrubs sensitive text before cloud sends.
- To see exactly what did leave, open Settings → Insights: every model request, web search, URL fetch, MCP call, channel delivery and Router call is logged with a Local/Cloud badge, destination, bytes, and (for model requests) whether the Privacy Filter redacted anything. Retention and whether prompt/response bodies are stored: Settings → Privacy → Activity Log. See the Insights topic.

## Storage layout

- `~/.osaurus/chat-history/history.sqlite` (chats), `memory/memory.sqlite`, `agents/<uuid>/db.sqlite`, `activity/activity.sqlite` (the Insights activity log), `skills/`, `themes/`, `config/*.json`, attachments as content-addressed blobs.
- Local models are separate, in `~/MLXModels/`.

## Encryption

- Default: plaintext SQLite protected by macOS FileVault. If you don't use FileVault, backups of `~/.osaurus` are readable.
- Opt-in at-rest encryption: Settings… (⌘,) → General → Advanced → Data & Storage → "Encrypt local data at rest (SQLCipher)". Migration runs both ways.
- The encryption key lives in this device's Keychain only (not iCloud-synced). Losing the key means losing the data — export a plaintext backup first.
- Rotate storage key is available while encryption is on.

## Backup and recovery

- General → Advanced → Data & Storage → "Export plaintext backup…" copies databases, attachments, and config to a folder you choose (decrypting if needed). Do this before a macOS reinstall or Mac migration.
- "Stores needing attention" lists degraded stores with Retry / Reset; Reset quarantines the file to `~/.osaurus/quarantine/` — nothing is deleted.

## Secrets

API keys and tokens are always stored in the macOS Keychain, never in JSON config, and never pass through chat text.
