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

    private let log = Logger(subsystem: "ai.osaurus", category: "storage.migrate")
    private var didConvergeThisLaunch = false

    public struct Report: Sendable {
        public var mode: StorageEncryptionMode
        public var converted: Int = 0
        public var alreadyMatching: Int = 0
        /// Labels of encrypted stores we could not decrypt (key unavailable).
        public var locked: [String] = []
        /// Labels that errored for other reasons (corruption, IO).
        public var failed: [String] = []

        public var isFullyConverged: Bool { locked.isEmpty && failed.isEmpty }
    }

    private init() {}

    // MARK: - Launch

    /// Run convergence once per launch: resolve the target posture (see
    /// `resolveLaunchMode`) and converge to it. A safe no-op when nothing needs
    /// converting; an in-place decrypt/encrypt otherwise.
    public func convergeOnLaunch() async {
        if didConvergeThisLaunch { return }
        didConvergeThisLaunch = true

        let mode = Self.resolveLaunchMode()
        let report = await converge(to: mode)

        if report.converted > 0 {
            log.info("convergence: converted \(report.converted) store(s) to \(mode.rawValue, privacy: .public)")
        }
        if !report.locked.isEmpty {
            log.error(
                "convergence: \(report.locked.count) store(s) locked (key unavailable): \(report.locked.joined(separator: ", "), privacy: .public)"
            )
        }
        if !report.failed.isEmpty {
            log.error(
                "convergence: \(report.failed.count) store(s) failed: \(report.failed.joined(separator: ", "), privacy: .public)"
            )
        }
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

    /// Convert every catalog database whose detected format differs from
    /// `mode`. Databases already in the target format are left untouched.
    @discardableResult
    public func converge(to mode: StorageEncryptionMode) async -> Report {
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

        let outcome = await Self.convertOffActor(targets: dbTargets, mode: mode, key: key)
        report.converted = outcome.converted
        report.failed = outcome.failed
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
            target = FileVaultStatus.isEnabled() ? .plaintext : .encrypted
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
    ) async -> (converted: Int, failed: [String], matched: Int) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var converted = 0
                var failed: [String] = []
                var matched = 0
                for target in targets {
                    guard needsConversion(path: target.path, to: mode) else {
                        matched += 1
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
                continuation.resume(returning: (converted, failed, matched))
            }
        }
    }
}
