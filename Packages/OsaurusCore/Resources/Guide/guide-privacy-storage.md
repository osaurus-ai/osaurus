---
title: Privacy, Storage, and Encryption
summary: Where your data lives, at-rest encryption, backups, and what (if anything) leaves your Mac.
order: 170
---

# Privacy, Storage, and Encryption

Osaurus is local-first: chats, memory, agents, and config all live under `~/.osaurus/` on your Mac.

## What leaves your Mac

- Nothing conversation-related, unless you connect a cloud provider (then your prompts go to that provider) or enable server network exposure.
- Anonymous usage analytics (Aptabase — no chats, prompts, or keys) and crash reports (Sentry) are consent-gated: Settings → Privacy → Send Crash Reports.
- The Privacy tab also offers an experimental Privacy Filter that scrubs sensitive text before cloud sends.

## Storage layout

- `~/.osaurus/chat-history/history.sqlite` (chats), `memory/memory.sqlite`, `agents/<uuid>/db.sqlite`, `skills/`, `themes/`, `config/*.json`, attachments as content-addressed blobs.
- Local models are separate, in `~/MLXModels/`.

## Encryption

- Default: plaintext SQLite protected by macOS FileVault. If you don't use FileVault, backups of `~/.osaurus` are readable.
- Opt-in at-rest encryption: Management (⌘⇧M) → Storage → "Encrypt local data at rest (SQLCipher)". Migration runs both ways.
- The encryption key lives in this device's Keychain only (not iCloud-synced). Losing the key means losing the data — export a plaintext backup first.
- Rotate storage key is available while encryption is on.

## Backup and recovery

- Storage → "Export plaintext backup…" copies databases, attachments, and config to a folder you choose (decrypting if needed). Do this before a macOS reinstall or Mac migration.
- "Stores needing attention" lists degraded stores with Retry / Reset; Reset quarantines the file to `~/.osaurus/quarantine/` — nothing is deleted.

## Secrets

API keys and tokens are always stored in the macOS Keychain, never in JSON config, and never pass through chat text.
