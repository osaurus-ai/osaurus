//
//  StorageMigrationCoordinator.swift
//  osaurus
//
//  Converges the on-disk storage format to the resolved
//  `StorageEncryptionPolicy` posture. Runs once per launch — decrypting an
//  existing encrypted install to plaintext only when FileVault already
//  protects the disk, otherwise keeping it encrypted (see `resolveLaunchMode`)
//  — and on demand when the user toggles encryption in Settings.
//
//  Convergence is:
//    - Detection-first: each file is converted based on its *actual* format,
//      so a re-run after a crash/partial run is a safe no-op for finished
//      files.
//    - Quiesced: open DB handles are closed before conversion and reopened
//      after the mutation gate is released (reopening under the gate would
//      deadlock the gated `open()` path).
//    - Non-destructive: if the key needed to decrypt is unavailable, the
//      encrypted stores are left intact and reported as "locked" for the
//      recovery UI — never auto-deleted.
//

import CryptoKit
import Foundation
import os

/// The actual on-disk encryption state of the core databases, derived by
/// sniffing each file's header (independent of the desired policy).
public enum StorageOnDiskPosture: Sendable, Equatable {
    case empty
    case plaintext
    case encrypted
    case mixed
}

public actor StorageMigrationCoordinator {
    public static let shared = StorageMigrationCoordinator()

    /// One logger for the whole coordinator. `static` so `nonisolated static`
    /// helpers (`resolveLaunchMode`, `convertOffActor`) can use it too.
    private static let log = Logger(subsystem: "ai.osaurus", category: "storage.migrate")
    private var didConvergeThisLaunch = false

    /// Tail of the convergence chain: each `converge(to:)` links its work after
    /// this task and replaces it, so concurrent calls (e.g. launch convergence
    /// racing a Settings toggle) run one-at-a-time. Actor reentrancy lets a
    /// second `converge` enter while the first is suspended at an `await`, so
    /// the boolean `StorageMutationGate` alone can't serialize the
    /// quiesce -> convert -> reopen section. Starts completed so the first call
    /// proceeds immediately.
    private var convergeTail: Task<Void, Never> = Task {}

    public struct Report: Sendable {
        public var mode: StorageEncryptionMode
        public var converted: Int = 0
        public var alreadyMatching: Int = 0
        /// Labels of encrypted stores we could not decrypt (key unavailable).
        public var locked: [String] = []
        /// Labels that errored for other reasons (corruption, IO).
        public var failed: [String] = []
        /// Labels skipped this run because there wasn't enough free disk space
        /// to safely write the temp copy the converter needs. Left untouched
        /// on disk (still openable via detection-first) and retried next launch.
        public var skipped: [String] = []

        public var isFullyConverged: Bool {
            locked.isEmpty && failed.isEmpty && skipped.isEmpty
        }
    }

    private init() {}

    // MARK: - Launch

    /// Run convergence once per launch: resolve the target posture (see
    /// `resolveLaunchMode`) and converge to it. A safe no-op when nothing needs
    /// converting; an in-place decrypt/encrypt otherwise.
    public func convergeOnLaunch() async {
        if didConvergeThisLaunch { return }
        didConvergeThisLaunch = true

        // Rollout kill-switch: leave on-disk files exactly as they are. Stores
        // still open via detection-first opening; only the automatic format
        // migration is suppressed. No code rollback needed to disable it.
        if RuntimeEnvironment.storageConvergenceDisabled {
            Self.log.notice(
                "convergence: disabled via OSAURUS_DISABLE_STORAGE_CONVERGENCE; leaving storage as-is"
            )
            PersistenceHealth.shared.recordInfo(
                key: "storage_convergence",
                message: "disabled via kill-switch"
            )
            return
        }

        let mode = Self.resolveLaunchMode()
        let report = await converge(to: mode)

        if report.converted > 0 {
            Self.log.info("convergence: converted \(report.converted) store(s) to \(mode.rawValue, privacy: .public)")
        }
        if !report.locked.isEmpty {
            Self.log.error(
                "convergence: \(report.locked.count) store(s) locked (key unavailable): \(report.locked.joined(separator: ", "), privacy: .public)"
            )
        }
        if !report.failed.isEmpty {
            Self.log.error(
                "convergence: \(report.failed.count) store(s) failed: \(report.failed.joined(separator: ", "), privacy: .public)"
            )
        }
        if !report.skipped.isEmpty {
            Self.log.error(
                "convergence: \(report.skipped.count) store(s) skipped (insufficient disk space): \(report.skipped.joined(separator: ", "), privacy: .public)"
            )
        }

        // Fleet observability: a compact, non-degraded per-launch summary in
        // `/health` so the rollout can be monitored across users.
        PersistenceHealth.shared.recordInfo(
            key: "storage_convergence",
            message:
                "mode=\(mode.rawValue) converted=\(report.converted) matching=\(report.alreadyMatching) locked=\(report.locked.count) failed=\(report.failed.count) skipped=\(report.skipped.count)"
        )
    }

    // MARK: - Settings toggle

    /// Persist the desired posture and converge on-disk storage to match.
    /// Used by the Settings encryption toggle.
    @discardableResult
    public func setEncryptionEnabled(_ enabled: Bool) async throws -> Report {
        let mode: StorageEncryptionMode = enabled ? .encrypted : .plaintext
        try StorageEncryptionPolicy.shared.setDesiredMode(mode)
        return await converge(to: mode)
    }

    // MARK: - Core convergence

    /// Converge on-disk storage to `mode`, serialized against any other
    /// in-flight convergence. The actual work runs in `performConverge(to:)`;
    /// this wrapper chains it after `convergeTail` so two callers never run the
    /// quiesce/convert/reopen dance at the same time. `performConverge` is
    /// idempotent and detection-first, so a duplicate request is a cheap no-op
    /// and an opposite-direction toggle simply applies after the one ahead of
    /// it finishes.
    @discardableResult
    public func converge(to mode: StorageEncryptionMode) async -> Report {
        let predecessor = convergeTail
        let work = Task { () -> Report in
            await predecessor.value
            return await self.performConverge(to: mode)
        }
        // Replace the tail synchronously (no `await` before this point) so the
        // chain order matches call order even under actor reentrancy.
        convergeTail = Task { _ = await work.value }
        return await work.value
    }

    /// Convert every catalog database whose detected format differs from
    /// `mode`. Databases already in the target format are left untouched.
    /// Always invoked through `converge(to:)` so runs are serialized.
    private func performConverge(to mode: StorageEncryptionMode) async -> Report {
        var report = Report(mode: mode)

        let dbTargets = StorageDatabaseCatalog.databaseTargets()
        let needing = dbTargets.filter { Self.needsConversion(path: $0.path, to: mode) }
        let needsBlobs = Self.blobsNeedConversion(to: mode)

        guard !needing.isEmpty || needsBlobs else {
            report.alreadyMatching = dbTargets.count
            return report
        }

        // Resolve the key required for this direction. Decrypt reads the
        // existing key (fail-closed if gone -> locked); encrypt mints/persists
        // one when the user opts in.
        let key: SymmetricKey
        do {
            key = try StorageKeyManager.shared.currentKey()
        } catch {
            // Cannot proceed without the key. Report encrypted stores as
            // locked (recovery UI surfaces them); never destroy data.
            for target in needing where StorageFileFormat.detect(path: target.path) == .encrypted {
                report.locked.append(target.label)
                if let store = StorageRecoveryService.Store.store(forPath: target.path) {
                    PersistenceHealth.shared.recordStoreIssue(
                        store: store.rawValue,
                        kind: .locked,
                        message:
                            "Encrypted store can't be opened: the storage key is unavailable on this Mac.",
                        path: target.path
                    )
                }
            }
            report.alreadyMatching = dbTargets.count - report.locked.count
            return report
        }

        // Quiesce: park concurrent opens, close live handles, convert, release
        // the gate, then reopen. Reopening *after* `endMutating()` avoids the
        // gated-open deadlock that an in-`defer` reopen would hit.
        await MainActor.run { StorageMutationGate.shared.beginMutating() }
        let openHandles = OsaurusDatabaseHandle.allOpenHandles
        for handle in openHandles { handle.closer() }

        // Plugin and per-agent DBs are intentionally not registered as
        // maintenance handles, so they won't be in `allOpenHandles`. Close
        // their live connections explicitly before the swap — otherwise the
        // converter would `replaceItemAt`/`removeSidecars` underneath an open
        // fd and corrupt that store. Both reopen lazily after the gate clears.
        AgentDatabaseStore.shared.closeAll()
        PluginDatabase.closeAllOpen()

        let outcome = await Self.convertOffActor(targets: dbTargets, mode: mode, key: key)
        report.converted = outcome.converted
        report.failed = outcome.failed
        report.skipped = outcome.skipped
        report.alreadyMatching += outcome.matched

        await MainActor.run { StorageMutationGate.shared.endMutating() }
        for handle in openHandles { handle.reopener() }

        return report
    }

    // MARK: - On-disk posture

    /// Sniff the core databases to report what's actually on disk right now.
    /// Used by Settings/diagnostics so the UI reflects reality, not a flag.
    public nonisolated static func detectOnDiskPosture() -> StorageOnDiskPosture {
        var sawPlaintext = false
        var sawEncrypted = false
        for target in StorageDatabaseCatalog.databaseTargets() {
            switch StorageFileFormat.detect(path: target.path) {
            case .plaintext: sawPlaintext = true
            case .encrypted: sawEncrypted = true
            case .empty: break
            }
        }
        switch (sawPlaintext, sawEncrypted) {
        case (true, true): return .mixed
        case (false, true): return .encrypted
        case (true, false): return .plaintext
        case (false, false): return .empty
        }
    }

    // MARK: - Launch mode resolution

    /// Decide which at-rest mode to converge to on launch, persisting it as the
    /// marker so every later gate (`isEncryptionEnabled`, the AppDelegate key
    /// prewarm, the Settings UI) stays coherent with what's actually on disk.
    ///
    /// - A marker already on disk is authoritative — a prior launch resolved it
    ///   or the user chose it explicitly in Settings. Honor it verbatim.
    /// - Otherwise this is the first launch on the opt-in build:
    ///   - An existing encrypted (or partially converted) install is decrypted
    ///     to plaintext **only when FileVault is on** — the disk is already
    ///     encrypted at rest, so SQLCipher is redundant and plaintext is the
    ///     reliability win. With FileVault **off** the data is kept encrypted
    ///     rather than silently stripping its only at-rest protection.
    ///   - A fresh or already-plaintext install chooses plaintext.
    ///
    /// The marker is sticky once written: later FileVault changes are handled
    /// through the explicit Settings toggle, not by silent re-migration.
    nonisolated static func resolveLaunchMode() -> StorageEncryptionMode {
        if let existing = StorageEncryptionPolicy.shared.persistedMode() {
            return existing
        }
        let target: StorageEncryptionMode
        switch detectOnDiskPosture() {
        case .encrypted, .mixed:
            if FileVaultStatus.isEnabled() {
                target = .plaintext
                Self.log.notice(
                    "launch: existing encrypted install will converge to plaintext (FileVault on)"
                )
            } else {
                // FileVault off: keep it encrypted rather than strip the data's
                // only at-rest protection. The user stays on the legacy
                // key-dependent posture until they enable FileVault and
                // re-toggle (or change it in Settings); record a non-degraded
                // info note so the fleet prevalence is observable.
                target = .encrypted
                Self.log.notice(
                    "launch: existing encrypted install kept encrypted (FileVault off); not migrating to plaintext"
                )
                PersistenceHealth.shared.recordInfo(
                    key: "storage_posture",
                    message: "kept encrypted at rest (FileVault off)"
                )
            }
        case .empty, .plaintext:
            target = .plaintext
        }
        try? StorageEncryptionPolicy.shared.setDesiredMode(target)
        return target
    }

    // MARK: - Helpers

    static func needsConversion(path: String, to mode: StorageEncryptionMode) -> Bool {
        switch StorageFileFormat.detect(path: path) {
        case .empty:
            // Nothing on disk yet; the file will be created in the desired
            // mode on first open.
            return false
        case .plaintext:
            return mode == .encrypted
        case .encrypted:
            return mode == .plaintext
        }
    }

    /// True when any attachment blob's on-disk form differs from `mode`
    /// (encrypted `.osec` while plaintext is desired, or vice versa).
    static func blobsNeedConversion(to mode: StorageEncryptionMode) -> Bool {
        let fm = FileManager.default
        let dir = AttachmentBlobStore.blobsDir()
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return false }
        switch mode {
        case .plaintext:
            return entries.contains { $0.pathExtension == "osec" }
        case .encrypted:
            return entries.contains { $0.pathExtension != "osec" && !$0.hasDirectoryPath }
        }
    }

    /// Convert attachment blobs to `mode` (AES-GCM `.osec` twin <-> plaintext).
    private static func convergeBlobs(to mode: StorageEncryptionMode, key: SymmetricKey) {
        let fm = FileManager.default
        let dir = AttachmentBlobStore.blobsDir()
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where !entry.hasDirectoryPath {
            switch mode {
            case .plaintext:
                guard entry.pathExtension == "osec" else { continue }
                guard let data = try? EncryptedFileStore.read(entry, key: key) else { continue }
                let plain = EncryptedFileStore.plaintextURL(for: entry)
                guard (try? data.write(to: plain, options: [.atomic])) != nil else { continue }
                try? fm.removeItem(at: entry)
            case .encrypted:
                guard entry.pathExtension != "osec" else { continue }
                guard let data = try? Data(contentsOf: entry) else { continue }
                let enc = EncryptedFileStore.encryptedURL(for: entry)
                guard (try? EncryptedFileStore.write(data, to: enc, key: key)) != nil else { continue }
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Run the (synchronous, IO-heavy) conversions on a utility queue so we
    /// never pin a Swift cooperative-executor thread inside SQLCipher export.
    private static func convertOffActor(
        targets: [StorageDatabaseCatalog.DatabaseTarget],
        mode: StorageEncryptionMode,
        key: SymmetricKey
    ) async -> (converted: Int, failed: [String], matched: Int, skipped: [String]) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var converted = 0
                var failed: [String] = []
                var matched = 0
                var skipped: [String] = []
                for target in targets {
                    guard needsConversion(path: target.path, to: mode) else {
                        matched += 1
                        continue
                    }
                    // Pre-flight free space: the converter writes a full temp
                    // copy before the atomic swap, so a large DB transiently
                    // needs ~2x its size. Skip (leave as-is, retry next launch)
                    // rather than start an export that would fail mid-write on a
                    // nearly-full disk.
                    guard hasRoomToConvert(path: target.path) else {
                        skipped.append(target.label)
                        Self.log.error(
                            "convergence: skipping \(target.label, privacy: .public) — insufficient free disk space for a safe conversion"
                        )
                        continue
                    }
                    do {
                        switch mode {
                        case .plaintext:
                            try StorageFormatConverter.decryptInPlace(path: target.path, key: key)
                        case .encrypted:
                            try StorageFormatConverter.encryptInPlace(path: target.path, key: key)
                        }
                        converted += 1
                    } catch {
                        failed.append(target.label)
                    }
                }
                // Attachment blobs (AES-GCM, not SQLCipher) ride along with the
                // databases so the whole tree matches the chosen posture.
                convergeBlobs(to: mode, key: key)
                continuation.resume(returning: (converted, failed, matched, skipped))
            }
        }
    }

    /// True when there is enough free space to safely convert the database at
    /// `path` (which needs room for a full temp copy plus headroom). Unknown
    /// sizes or capacities never block — the converter still fails safe if an
    /// export runs out of room, leaving the original intact.
    static func hasRoomToConvert(path: String) -> Bool {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value,
            size > 0
        else {
            return true
        }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let available =
            (try? dir.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ))?.volumeAvailableCapacityForImportantUsage
        guard let available else { return true }
        // Require 2x the file size (temp copy + original) plus a 64 MiB floor.
        let needed = size * 2 + 64 * 1024 * 1024
        return available >= needed
    }
}
