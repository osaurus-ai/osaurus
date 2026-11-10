//
//  SyncWalletLink.swift
//  osaurus
//
//  One recovery phrase for both: the sync user secret is derived from the
//  Osaurus wallet's master key, so restoring the wallet restores sync. The
//  link is recorded in `config/sync.json`, which survives Keychain loss, and
//  cleared when anything other than the link replaces the sync identity.
//

import CryptoKit
import Foundation
import OsaurusSync
import os

@MainActor
enum SyncWalletLink {
    nonisolated static let derivationInfo = "osaurus-sync/user-secret/v1"

    private static let log = Logger(subsystem: "ai.osaurus", category: "sync.wallet")
    private static var observer: NSObjectProtocol?

    /// The sync recovery phrase `masterKey` derives:
    /// HKDF-SHA256(master, info: `derivationInfo`) as 24 BIP39 words.
    nonisolated static func phrase(masterKey: Data) throws -> [String] {
        let secret = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            info: Data(derivationInfo.utf8),
            outputByteCount: 32
        )
        var entropy = secret.withUnsafeBytes { Data($0) }
        defer { entropy.zeroOut() }
        return try MasterKeyMnemonic.mnemonic(forKey: entropy)
    }

    /// Adopts the sync identity `masterKey` derives, keeping this Mac's
    /// chats, and records the link.
    static func link(masterKey: Data, core: SyncCore) throws {
        let words = try phrase(masterKey: masterKey)
        if try core.recoveryPhrase() != words {
            try core.recoverFromPhrase(phrase: words.joined(separator: " "))
        }
        record(userKey: try core.userKey())
    }

    /// Links a wallet just created or restored on this Mac. Skipped while the
    /// sync account has other devices: changing identity here alone would
    /// split this Mac from them, so that case waits for the Settings action
    /// (and an earlier link, to another wallet, no longer holds).
    static func linkNewWallet(masterKey: Data) async {
        if SyncService.shared.core == nil {
            _ = await Task.detached(priority: .userInitiated) { try? SyncService.shared.open() }.value
        }
        guard let core = SyncService.shared.core else { return }
        do {
            guard try !core.devices().contains(where: { !$0.isSelf && !$0.revoked }) else {
                clear()
                return
            }
            try link(masterKey: masterKey, core: core)
            SyncStatusModel.shared.refresh()
        } catch {
            log.error("wallet link failed: \(error.syncLogDetail, privacy: .public)")
        }
    }

    /// Settings → Sync: link with the wallet on this Mac, or unlock chats
    /// after the sync keys were lost. One biometric read of the master key.
    static func useWalletPhrase() throws {
        guard let core = SyncService.shared.core else { throw SyncConversationStoreError.notOpen }
        var masterKey = try MasterKey.getPrivateKey(context: OsaurusIdentityContext.biometric())
        defer { masterKey.zeroOut() }
        try link(masterKey: masterKey, core: core)
    }

    static var isLinked: Bool { SyncConfigurationStore.load().walletLinked }

    static func clear() {
        var configuration = SyncConfigurationStore.load()
        guard configuration.walletLinked || configuration.walletUserKey != nil else { return }
        configuration.walletLinked = false
        configuration.walletUserKey = nil
        SyncConfigurationStore.save(configuration)
        SyncStatusModel.shared.refresh()
    }

    /// Clears the link when the identity changes to one the wallet didn't
    /// derive. A store waiting for its recovery phrase keeps it, so the
    /// wallet can still unlock it.
    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: SyncService.didReplaceIdentityNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { SyncWalletLink.identityReplaced() }
        }
    }

    static func identityReplaced() {
        let configuration = SyncConfigurationStore.load()
        guard configuration.walletLinked else { return }
        guard let core = SyncService.shared.core else {
            clear()
            return
        }
        if (try? core.recoveryAvailable()) == true { return }
        if (try? core.userKey()) != configuration.walletUserKey { clear() }
    }

    private static func record(userKey: String) {
        var configuration = SyncConfigurationStore.load()
        configuration.walletLinked = true
        configuration.walletUserKey = userKey
        SyncConfigurationStore.save(configuration)
    }

    #if DEBUG
        static func _resetForTesting() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    #endif
}
