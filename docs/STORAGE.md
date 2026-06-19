# Storage

Osaurus stores your local data — chats, memory, methods, tool indexes, plugin databases, and large attachments — under `~/.osaurus/`. As of 0.21.0, that data is stored **as plaintext SQLite by default**, relying on macOS **FileVault** for at-rest protection, with **SQLCipher whole-database encryption available as an explicit opt-in** in **Settings → Storage**.

This is a deliberate change from the earlier always-on encryption model. The "why" is documented in [Why encryption is opt-in](#why-encryption-is-opt-in) below — the short version is reliability: an always-required Keychain key coupled every store's ability to open to a secret that breaks on Mac migration, app re-signing, or a Keychain wipe, and when it broke it failed closed with no recovery.

This document covers how data is stored, how opening is decided per-file, how to opt in to encryption, how migration and recovery work, and the trade-offs.

---

## Table of Contents

- [Overview](#overview)
- [Why encryption is opt-in](#why-encryption-is-opt-in)
- [Detection-first opening](#detection-first-opening)
- [Getting Started](#getting-started)
- [What's Stored](#whats-stored)
- [Migration and Convergence](#migration-and-convergence)
- [Recovery](#recovery)
- [Key Management (encrypted mode)](#key-management-encrypted-mode)
- [Storage Settings](#storage-settings)
- [Background Maintenance](#background-maintenance)
- [Storage Paths Reference](#storage-paths-reference)
- [Storage Location Standards](#storage-location-standards)
- [Limitations and Trade-offs](#limitations-and-trade-offs)

---

## Overview

Everything Osaurus persists lives under `~/.osaurus/`:

- **Default (plaintext).** Every SQLite database is a normal SQLite file, and large attachments / `.osec`-class artifacts are written as plaintext. On a modern Mac, **FileVault** already encrypts the entire disk at rest, so plaintext-on-disk is still protected when the Mac is powered off or logged out — without depending on an app-managed key that can go missing.
- **Opt-in (encrypted).** When you enable encryption in **Settings → Storage**, every SQLite database is converted to a [SQLCipher 4.6.1](https://www.zetetic.net/sqlcipher/) database keyed with a 32-byte symmetric key, and app-layer artifacts are written as AES-GCM `.osec` files. The data-encryption key (DEK) lives in the macOS Keychain, scoped to your account on this device.

The posture (plaintext vs. encrypted) is your choice and is persisted in a small, deliberately **non-encrypted** marker file (`~/.osaurus/.storage-encryption.json`). It cannot itself be encrypted — that would reintroduce the chicken-and-egg key dependency this design removes.

---

## Why encryption is opt-in

SQLCipher whole-database encryption is sound, and it does **not** break FTS5 full-text search while the database is open. The problem was never the cipher — it was **availability coupling**.

In the always-on model, every store's ability to open depended on a Keychain DEK. That key breaks in ordinary, non-malicious situations:

- Migrating to a new Mac without iCloud Keychain sync.
- Re-signing the app (different team/identity) so the Keychain ACL no longer matches.
- Wiping or resetting the login Keychain.
- Restoring `~/.osaurus/` into a different user account than the one the key was paired with.

When that happened, `StorageKeyManager.currentKey()` threw `keyUnavailableForExistingData`, the database refused to open, and the app **failed closed with an opaque error** — silently bricking memory and search for real users, with no recovery path. Reliability is the priority, and FileVault already provides full-disk at-rest encryption on modern macOS. So the default is now plaintext, and SQLCipher is an explicit, reversible opt-in.

### Threat model (what each mode protects against)

| Threat | Plaintext + FileVault (default) | Opt-in SQLCipher |
|---|---|---|
| Lost/stolen Mac, powered off | Protected by FileVault full-disk encryption | Protected (FileVault **and** SQLCipher) |
| Another logged-in user on the same Mac reading your files | Filesystem permissions only (`~/.osaurus` is user-owned); **not** cryptographically separated | Cryptographically separated — the DEK is scoped to your account |
| You don't use FileVault | Data is readable from the raw disk | Encrypted at rest regardless of FileVault |
| Backups / Time Machine / cloud sync of `~/.osaurus` | Copied as plaintext | Copied as ciphertext |
| Keychain key lost (migration, re-sign, wipe) | **No impact** — nothing depends on the key | Encrypted stores can't be opened until the key is restored or the store is reset |

Plain-language summary: **plaintext is the most reliable option and is well-protected if FileVault is on.** Turn on SQLCipher if you share the Mac account, don't run FileVault, or sync/back up `~/.osaurus` to a place you don't fully trust — and keep a plaintext backup in case the key is ever lost.

---

## Detection-first opening

The core reliability fix is that **the on-disk reality always wins over any flag**. A plaintext SQLite file always begins with the 16-byte magic header `SQLite format 3\0`; a SQLCipher file's header is encrypted and looks random. Osaurus uses this to decide, per file, how to open it.

- [`StorageFileFormat.detect(path:)`](../Packages/OsaurusCore/Storage/StorageFileFormat.swift) reads the first 16 bytes and returns `.empty` (missing/zero-length), `.plaintext` (SQLite magic present), or `.encrypted` (non-empty, no magic).
- [`OsaurusStorageOpener.open(path:)`](../Packages/OsaurusCore/Storage/OsaurusStorageOpener.swift) is the single chokepoint every database open goes through:
  - `.plaintext` → open with **no key**; the Keychain is never touched.
  - `.encrypted` → open with `StorageKeyManager.shared.currentKey()`.
  - `.empty` / missing → create in the **desired mode** from [`StorageEncryptionPolicy`](../Packages/OsaurusCore/Storage/StorageEncryptionPolicy.swift) (plaintext unless you opted in).

The consequence: in the default (plaintext) world, `currentKey()` is **never called**, so the "missing key bricks the store" class of bug is structurally impossible. A stale or missing key can never prevent a plaintext store from opening, because opening a plaintext file doesn't consult the key at all.

---

## Getting Started

Nothing to configure. On first launch of a fresh install:

1. The posture marker is created in plaintext mode (`~/.osaurus/.storage-encryption.json`).
2. Each database is created as a plaintext SQLite file on first open via [`OsaurusStorageOpener`](../Packages/OsaurusCore/Storage/OsaurusStorageOpener.swift).

If you upgraded from a version that used always-on encryption, your existing encrypted data is **migrated automatically and invisibly on first launch** (see [Migration and Convergence](#migration-and-convergence)): it is decrypted to plaintext when macOS FileVault is enabled, or kept encrypted when FileVault is off so the migration never silently removes its only at-rest protection. There is no prompt or notice — the change is seamless, and you can always flip the posture later from **Settings → Storage**.

To turn encryption back on, open **Settings → Storage** and enable **Encrypt local data at rest (SQLCipher)**.

To back up your data in plaintext (for example, before reinstalling macOS), open **Settings → Storage → Export plaintext backup**.

---

## What's Stored

| Artifact | Default (plaintext) | Opt-in (encrypted) | On-disk location |
|---|---|---|---|
| Chat history | SQLite | SQLCipher | `~/.osaurus/chat-history/history.sqlite` |
| Router billing ledger | SQLite | SQLCipher | `~/.osaurus/billing/ledger.sqlite` |
| Memory (identity, pinned facts, episodes, transcript, FTS5 mirrors) | SQLite | SQLCipher | `~/.osaurus/memory/memory.sqlite` |
| Methods catalog | SQLite | SQLCipher | `~/.osaurus/methods/methods.sqlite` |
| Tool index | SQLite | SQLCipher | `~/.osaurus/tool-index/tool_index.sqlite` |
| Per-plugin databases | SQLite | SQLCipher | `~/.osaurus/Tools/<plugin-id>/data/data.db` |
| Per-agent database (opt-in feature) | SQLite | SQLCipher | `~/.osaurus/agents/<uuid>/db.sqlite` |
| Self-scheduling slots | SQLite | SQLCipher | `~/.osaurus/scheduler.sqlite` |
| Large chat attachments | plaintext blob | AES-GCM (`.osec`) | `~/.osaurus/chat-history/blobs/<sha256>` |

**Attachment spillover.** Every `Attachment.image` or `Attachment.document` payload greater than or equal to **16 KB** is hashed (SHA-256, content-addressed so duplicates dedup) and written to its own file via [`AttachmentBlobStore`](../Packages/OsaurusCore/Storage/AttachmentBlobStore.swift). In plaintext mode the blob is written raw; in encrypted mode it is written as an AES-GCM `.osec` twin. Reads are detection-first (sniff the file, prefer the plaintext twin, fall back to `.osec`) via [`EncryptedFileStore`](../Packages/OsaurusCore/Storage/EncryptedFileStore.swift), so a posture change never strands existing blobs. The chat row stores only `{ "ref": "<sha256>", ... }`. Smaller payloads stay inline in the row.

**Router billing ledger.** Osaurus Router charge diagnostics are metadata-only: request id, session id, assistant turn id, model, token counts, cost, status, app version, and rendered outcome. The ledger never stores prompt text, response text, tool arguments, or tool results, regardless of posture. See [`OSAURUS_ROUTER.md`](OSAURUS_ROUTER.md).

**Always plaintext, by design.** A few artifacts stay plaintext in both modes:

- The encryption posture marker `~/.osaurus/.storage-encryption.json` (it cannot be encrypted — see [Overview](#overview)).
- JSON config under `~/.osaurus/config/`, `agents/`, `themes/`, `providers/`, `schedules/`, `watchers/`, `skills/` that is read as raw JSON by various consumers. (In encrypted mode, sensitive app-layer artifacts that go through `EncryptedFileStore` are wrapped; pure config that must be world-readable JSON stays plaintext.)
- Plugin manifests under `~/.osaurus/sandbox-plugins/`.
- Vector index files under `~/.osaurus/memory/vectura/<agentId>/`. These are rebuilt from the SQLite source on demand; see [Limitations](#limitations-and-trade-offs).

---

## Migration and Convergence

[`StorageMigrationCoordinator`](../Packages/OsaurusCore/Storage/StorageMigrationCoordinator.swift) drives convergence — bringing all on-disk artifacts in line with the desired posture. It runs once on launch (`convergeOnLaunch()`) and again whenever you flip the Settings toggle (`setEncryptionEnabled(_:)`).

### Choosing the launch target (FileVault-gated)

On launch, `convergeOnLaunch()` first resolves *which* posture to converge to via `resolveLaunchMode()` — it does not blindly decrypt:

- **Marker already present** (a prior launch resolved it, or you chose explicitly in Settings) → honored verbatim. The marker is sticky; later FileVault changes are handled through the Settings toggle, not silent re-migration.
- **No marker yet** (first launch on an opt-in build) → the on-disk posture is sniffed and macOS FileVault is consulted via [`FileVaultStatus`](../Packages/OsaurusCore/Storage/FileVaultStatus.swift) (a cached `/usr/bin/fdesetup status` probe; failures conservatively read as *off*):
  - Existing **encrypted** install + FileVault **on** → **decrypt to plaintext** (the disk is already encrypted at rest, so SQLCipher is redundant and plaintext is the reliable default).
  - Existing **encrypted** install + FileVault **off** → **keep encrypted** (decrypting would silently strip the data's only at-rest protection).
  - Fresh / already-plaintext install → **plaintext**.

The resolved posture is persisted as the marker, then convergence runs to match. The whole sequence is **invisible** — there is no migration prompt or "What's New" notice. An explicit choice in **Settings → Storage** always converts regardless of FileVault.

For each database in [`StorageDatabaseCatalog`](../Packages/OsaurusCore/Storage/StorageDatabaseCatalog.swift) whose detected format differs from the desired mode:

- **encrypted → plaintext** (the default migration off SQLCipher): decrypt in place using SQLCipher's `sqlcipher_export` into a temporary file, fsync, atomically replace the original, then remove the `-wal`/`-shm` sidecars.
- **plaintext → encrypted** (opt-in): the inverse — export into a new SQLCipher database keyed with the DEK, then atomically replace.

Convergence reuses the proven rotation machinery: it parks new opens on [`StorageMutationGate`](../Packages/OsaurusCore/Storage/StorageMutationGate.swift), closes every live handle, performs the conversions off the main actor, **releases the gate, then reopens** the handles (so a re-opening handle never deadlocks waiting on a still-held gate). Attachment blobs and `.osec` trees converge alongside the databases.

The process is **idempotent and crash-safe**: it's re-runnable, and because opening is detection-first, a partially converged tree recovers on the next launch — each file is opened according to what it actually is on disk.

---

## Recovery

Convergence **never auto-deletes data**. If a store can't be converted or opened — almost always an encrypted store whose Keychain key is gone after a migration or re-sign — Osaurus keeps running on whatever opens and surfaces the failure instead of hiding it.

- Failures are classified by [`PersistenceHealth`](../Packages/OsaurusCore/Storage/PersistenceHealth.swift) into `locked` (key unavailable), `corrupt` (unreadable / key mismatch), `migration` (schema upgrade failed), or `unknown`, with the underlying error message and file path retained.
- The **Memory → Diagnostics** panel shows the real cause for the memory DB and offers inline **Retry** and **Reset** actions.
- **Settings → Storage** shows a "Stores needing attention" panel listing every degraded store with its cause and the same actions.

Recovery actions are provided by [`StorageRecoveryService`](../Packages/OsaurusCore/Storage/StorageRecoveryService.swift):

- **Retry** re-attempts the open (e.g. after you restore the Keychain key or fix signing) and clears the recorded issue on success.
- **Reset** quarantines the unreadable file to `~/.osaurus/quarantine/` (it is **moved, never deleted**), removes the `-wal`/`-shm` sidecars via [`StorageFile`](../Packages/OsaurusCore/Storage/StorageFile.swift), and recreates an empty store in the current posture so the feature works again. Resetting the memory store also rebuilds its VecturaKit vector index from the fresh (empty) source.

Because the original file is only quarantined, a user who later recovers the key can still export the old data from the quarantined copy.

---

## Key Management (encrypted mode)

> Key management only applies when you opt in to encryption. In the default plaintext mode there is no DEK and the Keychain is never read for storage.

The DEK is managed by [`StorageKeyManager`](../Packages/OsaurusCore/Identity/StorageKeyManager.swift).

### Storage

The DEK is a 32-byte raw `SymmetricKey` persisted as a Keychain generic password:

| Attribute | Value |
|---|---|
| `kSecAttrService` | `com.osaurus.storage` |
| `kSecAttrAccount` | `data-encryption-key` |
| Accessibility | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

### Why not biometric?

When encryption is on, every Osaurus launch — including background relaunches by `launchd`, Sparkle auto-updates, and watcher-driven wakeups — needs to open the encrypted databases without a user-facing prompt. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` means the key is available any time the user has unlocked the Mac at least once since boot, and is never copied off the device.

### `isStorageReadyForWrites`

Code that needs to know whether it can safely persist checks `StorageKeyManager.shared.isStorageReadyForWrites` rather than `hasCachedKey` directly. In plaintext mode this is always `true` (no key needed); in encrypted mode it reflects whether the key is resident. This is the single gate used by the chat session store, chat-history writer, router billing ledger, and the scheduler startup so plaintext installs always come up.

### Optional: derive from the master key

For users who want their DEK reproducible across devices via the iCloud-synced Identity master key, `StorageKeyManager.deriveFromMasterKey(context:)` replaces the Keychain entry with `HKDF-SHA256(masterKeyBytes, salt, "osaurus-storage-v1")`. The salt is persisted in the Keychain (`com.osaurus.storage` / `data-encryption-salt`) and in a sidecar file at `~/.osaurus/.storage-key.salt` so it travels with a manual restore. The salt is harmless without the master key (HKDF is one-way).

### Rotation and reset

| Operation | Effect |
|---|---|
| `rotate()` | Generate a fresh CSPRNG key, persist it to Keychain, return both old + new keys. The export service re-keys every database before unblocking the gate. |
| `install(key:)` | Replace the Keychain entry with a caller-provided key (used inside `rotateStorageKey`). |
| `wipeCache()` | Clear in-process cache only; Keychain entry remains. |
| `resetForWipe()` | Delete the Keychain key + salt + sidecar and clear the cache. **Irreversible without the original key or a plaintext backup.** |

---

## Storage Settings

Open the Management window (`Cmd+Shift+M`) → **Storage** ([`StorageSettingsView`](../Packages/OsaurusCore/Views/Settings/StorageSettingsView.swift)). The panel reflects the **detected on-disk reality** (plaintext / encrypted / mixed), not a flag guess.

### Encrypt local data at rest (the opt-in toggle)

The primary control is a toggle — **off by default**. Turning it on prompts a confirmation that explains the key-loss risk, then runs convergence (plaintext → encrypted) with progress. Turning it off runs the inverse (encrypted → plaintext). Both directions migrate every database and attachment.

### Why encryption is opt-in (trade-offs panel)

The panel includes a plain-language trade-offs section covering FileVault reliance, the key-loss brick risk, and the fact that search and all features work identically in both modes. This mirrors [Why encryption is opt-in](#why-encryption-is-opt-in) above. It also surfaces your machine's **live FileVault status** (probed via `FileVaultStatus`), so the plaintext recommendation reflects whether the disk is actually encrypted at rest — and a kept-encrypted upgrader can see *why* their data stayed encrypted.

### Export plaintext backup

Writes a plaintext copy of every database, attachment, and config under `~/.osaurus/` to a folder you pick. In encrypted mode this decrypts on the way out; in plaintext mode it copies as-is. Use it **before** reinstalling macOS, migrating Macs, rotating the key, or wiping state. Export never changes anything on disk.

### Rotate storage key (encrypted mode only)

Shown only when encryption is on. Generates a fresh DEK and re-keys every registered database in place via [`StorageExportService.rotateStorageKey()`](../Packages/OsaurusCore/Storage/StorageExportService.swift). Rotation is a no-op / disabled in plaintext mode (there is no key to rotate).

### Stores needing attention

Appears only when one or more stores failed to open this session. Lists each degraded store with its classified cause and **Retry** / **Reset** actions (see [Recovery](#recovery)).

---

## Background Maintenance

[`StorageMaintenance`](../Packages/OsaurusCore/Storage/StorageMaintenance.swift) is a background actor that runs SQLite housekeeping on every registered database, in either posture:

| Operation | Default cadence | Why |
|---|---|---|
| `PRAGMA optimize` | every 6 hours | Lets SQLite re-plan based on observed query patterns. |
| `PRAGMA wal_checkpoint(TRUNCATE)` | every 7 days | Bounds the size of the `-wal` sidecar. |
| `VACUUM` | every 30 days | Reclaims space after large deletes. |

State is persisted in `~/.osaurus/.storage-maintenance.json`. The first load stamps "last run" to now, so the first tick never triggers a 30-day-old VACUUM. The ticker is started from [`AppDelegate`](../Packages/OsaurusCore/AppDelegate.swift) during launch.

**Plugin databases are intentionally not registered.** With hundreds of installed plugins, a global maintenance pass would thrash IO. Plugin DBs are still maintained by the plugin host, not the maintenance ticker.

---

## Storage Paths Reference

| Path | Description |
|---|---|
| `~/.osaurus/.storage-encryption.json` | Desired at-rest posture marker (always plaintext) |
| `~/.osaurus/.storage-maintenance.json` | Last `optimize` / `checkpoint` / `vacuum` timestamps |
| `~/.osaurus/.storage-key.salt` | HKDF salt sidecar (only present when DEK is master-derived) |
| `~/.osaurus/quarantine/` | Unreadable stores moved here by Reset recovery (never deleted) |
| `~/.osaurus/billing/ledger.sqlite` | Router billing ledger (SQLite, or SQLCipher when encrypted) |
| `~/.osaurus/chat-history/history.sqlite` | Chat database (SQLite, or SQLCipher when encrypted) |
| `~/.osaurus/chat-history/blobs/<sha256>` | Spilled attachments (plaintext blob, or `.osec` when encrypted) |
| `~/.osaurus/memory/memory.sqlite` | Memory database (SQLite, or SQLCipher when encrypted) |
| `~/.osaurus/memory/vectura/<agentId>/` | Per-agent VecturaKit vector index (plaintext, see Limitations) |
| `~/.osaurus/methods/methods.sqlite` | Methods catalog (SQLite, or SQLCipher when encrypted) |
| `~/.osaurus/tool-index/tool_index.sqlite` | Tool index (SQLite, or SQLCipher when encrypted) |
| `~/.osaurus/Tools/<plugin-id>/data/data.db` | Per-plugin database (SQLite, or SQLCipher when encrypted) |
| `~/.osaurus/agents/<uuid>/db.sqlite` | Per-agent database (see [Agent DB & Self-Scheduling](AGENT_DB.md)) |
| `~/.osaurus/scheduler.sqlite` | Cross-agent next-run + pause slots (SQLite, or SQLCipher when encrypted) |

When encryption is on, the DEK lives in macOS Keychain, **not** in `~/.osaurus/`.

---

## Storage Location Standards

Issue [#1422](https://github.com/osaurus-ai/osaurus/issues/1422) is right: the app-data root `~/.osaurus/` follows neither [Apple's file-system guidance](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively) (app data belongs under `~/Library/Application Support/`) nor the [XDG base-directory spec](https://specifications.freedesktop.org/basedir/latest/). Historically the data deliberately moved *out of* `~/Library/Application Support/com.dinoki.osaurus/` *into* `~/.osaurus/` (see `OsaurusPaths.defaultRoot`), so this is a known trade-off, not an accident.

### Where things stand

| Root | Current location | Spec-compliant target |
|---|---|---|
| App data | `~/.osaurus/` | `~/Library/Application Support/Osaurus/` |
| Legacy app data | `~/Library/Application Support/com.dinoki.osaurus/` (copied/merged once into `~/.osaurus/` when the marker is missing; never deleted) | n/a — retired by `~/.osaurus/.legacy-application-support-merge.done` |
| Model weights | `~/MLXModels/` (legacy `~/Documents/MLXModels/`, env override, or user-picked folder) | separate decision — weights are user-managed and home-visible by design |

### The audit surface

`GET /admin/cache-stats` returns a read-only `storage_locations` block (built by [`StorageLocationStandards`](../Packages/OsaurusCore/Utils/StorageLocationStandards.swift)) reporting: the active root and its classification, `spec_compliant`, whether the legacy `com.dinoki.osaurus` root still exists, whether the one-shot merge marker is present, the models root classification, and stable snake_case `reason_codes`. The audit never creates, copies, moves, or deletes anything.

### Why the root has not moved (yet)

Relocating `~/.osaurus/` is a data-safety decision pending an explicit maintainer call, because the (optional) Keychain DEK and HKDF salt sidecar are paired with the existing tree, sandbox tooling references `~/.osaurus/` literally, and plugin/container trees can be many gigabytes. Until that decision, paths resolve exclusively through `OsaurusPaths`, and no code outside `OsaurusPaths` may invent a storage root.

---

## Limitations and Trade-offs

- **Plaintext default relies on FileVault.** In the default mode, on-disk files are plaintext; their at-rest protection comes from FileVault full-disk encryption. If FileVault is off, the raw disk and any backups of `~/.osaurus/` are readable. Turn on FileVault, or opt in to SQLCipher, if that matters for your threat model. See [Why encryption is opt-in](#why-encryption-is-opt-in).
- **Encrypted mode is device-bound and key-loss is unrecoverable.** When you opt in, the Keychain entry is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and is **not** synced to iCloud. There is no escrow key. If you wipe the Keychain, restore a different `~/.osaurus/` than the one your Keychain was paired with, or migrate Macs without bringing the key, the encrypted stores can't be opened — Reset recovery quarantines them and recreates empty stores. Export a plaintext backup before any risky migration.
- **`kdf_iter = 256000`.** SQLCipher's PBKDF2 round count is the SQLCipher 4 default. We use a CSPRNG key, so the PBKDF2 work is largely overhead, but the safer default stays. This only affects encrypted mode.
- **VecturaKit indexes are plaintext in both modes.** The vector index files under `~/.osaurus/memory/vectura/<agentId>/` are written by VecturaKit, which doesn't support pluggable storage encryption. They are rebuilt from the SQLite source via `MemorySearchService.shared.rebuildIndex()`. The vectors leak some information (clustering, approximate counts) but no raw text.
- **Plugin database maintenance is per-plugin.** Skipping global `StorageMaintenance` registration means plugin DBs can grow large `-wal` files if a plugin opens a transaction it never commits. Plugin authors should run `PRAGMA wal_checkpoint` on long-lived connections.
- **Recovery requires the data itself, plus the Keychain entry only in encrypted mode.** In plaintext mode nothing extra is needed. In encrypted mode, recovery requires either the Keychain entry or a plaintext backup. See [`SECURITY.md`](SECURITY.md) for the recovery posture.
