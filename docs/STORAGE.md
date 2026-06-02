# Storage

Osaurus encrypts everything sensitive on disk — chats, memory, methods, tool indexes, plugin databases, and large attachments — with a per-device key kept in your macOS Keychain. Nothing leaves your Mac and nothing is readable by another user account, by Spotlight, or by Time Machine snapshots without the same Keychain entry.

This document covers what's encrypted, how the key is managed, and the user-facing controls in **Settings → Storage**.

---

## Table of Contents

- [Overview](#overview)
- [Getting Started](#getting-started)
- [What's Encrypted](#whats-encrypted)
- [Key Management](#key-management)
- [Storage Settings](#storage-settings)
- [Background Maintenance](#background-maintenance)
- [Storage Paths Reference](#storage-paths-reference)
- [Limitations and Trade-offs](#limitations-and-trade-offs)

---

## Overview

Osaurus encrypts everything sensitive on disk under `~/.osaurus/`:

- Every SQLite database is created and opened through a vendored build of [SQLCipher 4.6.1](https://www.zetetic.net/sqlcipher/), keyed with a 32-byte symmetric key. Databases are encrypted from the moment they're first created — there is no plaintext-to-encrypted conversion step.
- Large chat attachments (images and pasted documents) are spilled out of the SQLite TEXT column into AES-GCM-encrypted `.osec` files, content-addressed by SHA-256 so duplicates dedup automatically.
- The data-encryption key (DEK) lives in the macOS Keychain, scoped to your account on this device. It's not synced to iCloud by default and never leaves the machine.

---

## Getting Started

Nothing to configure. On first launch:

1. Osaurus generates a fresh 32-byte key with `SecRandomCopyBytes` and persists it to your Keychain (you won't see a Touch ID prompt — see [Key Management](#key-management) below).
2. Each database is created already SQLCipher-encrypted on first open via [`EncryptedSQLiteOpener`](../Packages/OsaurusCore/Storage/EncryptedSQLiteOpener.swift).

If you want to back up your data in plaintext (for example, before reinstalling macOS), open **Settings → Storage** → **Export plaintext backup**.

---

## What's Encrypted

| Artifact | Mechanism | On-disk location |
|---|---|---|
| Chat history | SQLCipher | `~/.osaurus/chat-history/history.sqlite` |
| Memory (identity, pinned facts, episodes, transcript, FTS5 mirrors) | SQLCipher | `~/.osaurus/memory/memory.sqlite` |
| Methods catalog | SQLCipher | `~/.osaurus/methods/methods.sqlite` |
| Tool index | SQLCipher | `~/.osaurus/tool-index/tool_index.sqlite` |
| Per-plugin databases | SQLCipher | `~/.osaurus/Tools/<plugin-id>/data/data.db` |
| Per-agent database (opt-in) | SQLCipher | `~/.osaurus/agents/<uuid>/db.sqlite` |
| Self-scheduling slots | SQLCipher | `~/.osaurus/scheduler.sqlite` |
| Large chat attachments | AES-GCM (`.osec`) | `~/.osaurus/chat-history/blobs/<sha256>.osec` |

**Attachment spillover.** Every `Attachment.image` or `Attachment.document` payload greater than or equal to **16 KB** is hashed, encrypted, and written to its own `.osec` file via [`AttachmentBlobStore`](../Packages/OsaurusCore/Storage/AttachmentBlobStore.swift). The chat row stores only `{ "ref": "<sha256>", ... }`, so resaving a session no longer rewrites every attachment byte. Smaller payloads (icons, short text snippets) stay inline in the row to avoid filesystem chatter.

**Plaintext, by design.** A few artifacts deliberately stay plaintext:

- JSON config under `~/.osaurus/config/`, `agents/`, `themes/`, `providers/`, `schedules/`, `watchers/`, `skills/`. These are read as raw JSON by various consumers and stay plaintext by design.
- Plugin manifests under `~/.osaurus/sandbox-plugins/`.
- Vector index files under `~/.osaurus/memory/vectura/<agentId>/`. These are rebuilt from the encrypted SQLite source on demand; see [Limitations](#limitations-and-trade-offs).

---

## Key Management

The DEK is managed by [`StorageKeyManager`](../Packages/OsaurusCore/Identity/StorageKeyManager.swift).

### Storage

The DEK is a 32-byte raw `SymmetricKey` persisted as a Keychain generic password:

| Attribute | Value |
|---|---|
| `kSecAttrService` | `com.osaurus.storage` |
| `kSecAttrAccount` | `data-encryption-key` |
| Accessibility | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

### Why not biometric?

Unlike the Identity master key, the DEK is **not** wrapped behind Face/Touch ID. Every Osaurus launch — including background relaunches by `launchd`, Sparkle auto-updates, and watcher-driven wakeups — needs to open the encrypted databases without a user-facing prompt. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` means the key is available any time the user has unlocked the Mac at least once since boot, and is never copied off the device.

### Optional: derive from the master key

For users who want their DEK to be reproducible across devices via the iCloud-synced Identity master key, `StorageKeyManager.deriveFromMasterKey(context:)` replaces the Keychain entry with `HKDF-SHA256(masterKeyBytes, salt, "osaurus-storage-v1")`. The salt is persisted in two places:

- The Keychain (`com.osaurus.storage` / `data-encryption-salt`), bound to the device.
- A sidecar file at `~/.osaurus/.storage-key.salt` so the salt travels with the rest of the encrypted artifacts during a manual restore.

The salt by itself is harmless without the master key (HKDF is one-way). The master key fetch triggers a one-time biometric prompt; the derived DEK is then cached and behaves identically to a generated one.

### Cache

The DEK is cached in-process behind an `os_unfair_lock`. The first `currentKey()` call performs the Keychain read (and HKDF derivation, if applicable); subsequent calls return the cached value without IO. `wipeCache()` zeroes the cached bytes — used during graceful shutdown and after key rotation.

### Rotation and reset

| Operation | Effect |
|---|---|
| `rotate()` | Generate a fresh CSPRNG key, persist it to Keychain, return both old + new keys. Caller (the export service) is responsible for re-keying every database before unblocking the gate. |
| `install(key:)` | Replace the Keychain entry with a caller-provided key. Used inside `rotateStorageKey` so the rotation pipeline doesn't introduce a third key. |
| `wipeCache()` | Clear in-process cache only; Keychain entry remains. |
| `resetForWipe()` | Delete the Keychain key + salt + sidecar file and clear the cache. **Irreversible without the original key or a plaintext backup.** Used when the user explicitly wipes Osaurus state. |

---

## Storage Settings

Open the Management window (`Cmd+Shift+M`) → **Storage**. The panel explains the encryption posture and lets you back up your data in plaintext or rotate the storage key.

### Export plaintext backup

Writes a tarball of every encrypted artifact in plaintext to a folder you pick (Downloads by default). Use this **before**:

- Reinstalling macOS or migrating to a new Mac without a Time Machine restore.
- Rotating the storage key (the rotate confirmation dialog offers this as a one-click shortcut).
- Manually wiping Osaurus state.

Export does not delete or change anything on disk; you can run it as often as you want.

### Rotate storage key

Generates a fresh DEK and re-keys every registered database in place. The flow:

1. Confirmation alert (with a "Back up first" shortcut that runs the export).
2. [`StorageMutationGate`](../Packages/OsaurusCore/Storage/StorageMutationGate.swift) flips `isMutating = true`, parking new `blockingAwaitNotMutating()` callers so no `*Database.open()` can race a half-rekeyed file.
3. Every registered handle is closed via `withAllHandlesQuiesced`.
4. SQLCipher's `PRAGMA rekey` rewrites each database (enumerated from [`StorageDatabaseCatalog`](../Packages/OsaurusCore/Storage/StorageDatabaseCatalog.swift)) with the new key.
5. `EncryptedFileStore` artifacts are re-wrapped.
6. The new key is installed in the Keychain via `install(key:)`.
7. Handles reopen, gate clears.

### Idle state

When everything is healthy, the panel shows a green "Encrypted" badge and a single line confirming your data is encrypted at rest.

---

## Background Maintenance

[`StorageMaintenance`](../Packages/OsaurusCore/Storage/StorageMaintenance.swift) is a background actor that runs three SQLite housekeeping operations on every registered database:

| Operation | Default cadence | Why |
|---|---|---|
| `PRAGMA optimize` | every 6 hours | Lets SQLite re-plan based on observed query patterns. |
| `PRAGMA wal_checkpoint(TRUNCATE)` | every 7 days | Bounds the size of the `-wal` sidecar so it doesn't grow indefinitely. |
| `VACUUM` | every 30 days | Reclaims space after large deletes (e.g. session purges, memory consolidation). |

State is persisted in `~/.osaurus/.storage-maintenance.json` so cadence survives restarts. The first load stamps the "last run" times to now, so the first tick after install never triggers a 30-day-old VACUUM.

The ticker is started from [`AppDelegate`](../Packages/OsaurusCore/AppDelegate.swift) via `Task.detached` during launch.

**Plugin databases are intentionally not registered.** With hundreds of installed plugins, a global maintenance pass would either thrash IO or queue forever. Plugin DBs are still SQLCipher-encrypted, but their lifecycle is owned by the plugin host, not the maintenance ticker.

---

## Storage Paths Reference

| Path | Description |
|---|---|
| `~/.osaurus/.storage-maintenance.json` | Last `optimize` / `checkpoint` / `vacuum` timestamps |
| `~/.osaurus/.storage-key.salt` | HKDF salt sidecar (only present when DEK is master-derived) |
| `~/.osaurus/chat-history/history.sqlite` | SQLCipher chat database |
| `~/.osaurus/chat-history/blobs/<sha256>.osec` | AES-GCM-encrypted spilled attachments |
| `~/.osaurus/memory/memory.sqlite` | SQLCipher memory database |
| `~/.osaurus/memory/vectura/<agentId>/` | Per-agent VecturaKit vector index (plaintext, see Limitations) |
| `~/.osaurus/methods/methods.sqlite` | SQLCipher methods catalog |
| `~/.osaurus/tool-index/tool_index.sqlite` | SQLCipher tool index |
| `~/.osaurus/Tools/<plugin-id>/data/data.db` | Per-plugin SQLCipher database |
| `~/.osaurus/agents/<uuid>/db.sqlite` | Per-agent SQLCipher database (see [Agent DB & Self-Scheduling](AGENT_DB.md)) |
| `~/.osaurus/scheduler.sqlite` | SQLCipher cross-agent next-run + pause slots |

The DEK lives in macOS Keychain, **not** in `~/.osaurus/`.

---

## Limitations and Trade-offs

- **`kdf_iter = 256000`.** SQLCipher's PBKDF2 round count is fixed at the SQLCipher 4 default. Lowering it would make opens faster (especially on large plugin sets) but would require re-keying every database, since `kdf_iter` is part of the file format. We use a CSPRNG key, so the PBKDF2 work is largely wasted overhead — but the safer, slower default stays.
- **Device-bound by default.** The Keychain entry is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and is **not** synced to iCloud. If you wipe the Keychain, restore a different `~/.osaurus/` directory than the one your Keychain was paired with, or migrate to a new Mac without a Time Machine restore, you need a plaintext backup to recover. Use **Settings → Storage → Export plaintext backup** before any of these.
- **VecturaKit indexes are plaintext.** The on-disk vector index files under `~/.osaurus/memory/vectura/<agentId>/` are written by VecturaKit, which doesn't yet support pluggable storage encryption. They are rebuilt from the encrypted SQLite source via `MemorySearchService.shared.rebuildIndex()`. The vectors leak some information (clustering, approximate counts) but no raw text. Wrapping these via `EncryptedVecturaStorage` is tracked as a follow-up.
- **Plugin database maintenance is per-plugin.** Skipping global `StorageMaintenance` registration means plugin DBs can grow large `-wal` files if a misbehaving plugin opens a transaction it never commits. Plugin authors should run `PRAGMA wal_checkpoint` themselves on long-lived connections.
- **Recovery requires either the Keychain entry or a plaintext backup.** This is by design — there's no escrow key. See [`SECURITY.md`](SECURITY.md) for the recovery posture.
