//
//  TemporaryPairedKeyStore.swift
//  osaurus
//
//  Tracks API keys generated for temporary (non-permanent) Bonjour pairings.
//  On app termination, all tracked keys are revoked and removed from APIKeyManager
//  so they cannot be reused in future sessions.
//

import AppKit
import Foundation

public final class TemporaryPairedKeyStore: @unchecked Sendable {
    public static let shared = TemporaryPairedKeyStore()

    private let queue = DispatchQueue(label: "com.osaurus.temporary-paired-keys")
    private var keyIds: [UUID] = []

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    public func register(keyId: UUID) {
        queue.sync(flags: .barrier) {
            keyIds.append(keyId)
        }
    }

    public func isTemporary(id: UUID) -> Bool {
        queue.sync { keyIds.contains(id) }
    }

    @objc private func applicationWillTerminate() {
        let ids = queue.sync { keyIds }
        for id in ids {
            APIKeyManager.shared.delete(id: id)
        }
    }
}
