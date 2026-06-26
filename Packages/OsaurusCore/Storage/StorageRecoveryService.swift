//
//  StorageRecoveryService.swift
//  osaurus
//
//  Recovery actions for stores that can't be opened — almost always an
//  encrypted store whose Keychain key is gone after a Mac migration or
//  app re-sign. The walk-back to plaintext-by-default prevents this for new
//  data, but existing encrypted users who already lost the key need a way
//  forward that never silently destroys data.
//
//  Two actions:
//    - `retryStore`  : re-attempt the open (e.g. after the keychain unlocked
//                      or a signing fix), clearing the recorded issue on success.
//    - `resetStore`  : quarantine the unreadable file (kept under
//                      `~/.osaurus/quarantine/`, never deleted) and recreate an
//                      empty store so the feature works again. Memory also
//                      rebuilds its Vectura index from the fresh (empty) DB.
//

import Foundation
import os

public actor StorageRecoveryService {
    public static let shared = StorageRecoveryService()

    private let log = Logger(subsystem: "ai.osaurus", category: "storage.recovery")

    private init() {}

    /// Canonical store identifiers shared by health, diagnostics, and recovery.
    public enum Store: String, Sendable, CaseIterable {
        case memory
        case agentChannels = "agent-channels"
        case chatHistory = "chat-history"
        case method
        case tool = "tool-index"
        case scheduler
        case routerBilling = "router-billing"

        public var path: String {
            switch self {
            case .memory: return OsaurusPaths.memoryDatabaseFile().path
            case .agentChannels: return OsaurusPaths.agentChannelMessagesDatabaseFile().path
            case .chatHistory: return OsaurusPaths.chatHistoryDatabaseFile().path
            case .method: return OsaurusPaths.methodsDatabaseFile().path
            case .tool: return OsaurusPaths.toolIndexDatabaseFile().path
            case .scheduler: return OsaurusPaths.schedulerDatabaseFile().path
            case .routerBilling: return OsaurusPaths.billingLedgerDatabaseFile().path
            }
        }

        /// Human-readable label for the recovery UI.
        public var displayName: String {
            switch self {
            case .memory: return "Memory"
            case .agentChannels: return "Agent channels"
            case .chatHistory: return "Chat history"
            case .method: return "Methods"
            case .tool: return "Tool index"
            case .scheduler: return "Scheduler"
            case .routerBilling: return "Router billing"
            }
        }

        /// Map an on-disk database path back to its canonical store, if it is
        /// one of the core stores (plugin/agent DBs return nil).
        public static func store(forPath path: String) -> Store? {
            let std = URL(fileURLWithPath: path).standardizedFileURL.path
            return Store.allCases.first {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == std
            }
        }
    }

    // MARK: - Retry

    /// Re-attempt opening a known store. Returns true on success.
    @discardableResult
    public func retryStore(_ store: Store) async -> Bool {
        do {
            switch store {
            case .memory:
                try MemoryDatabase.shared.open()
                await MemorySearchService.shared.initialize()
            case .agentChannels:
                try AgentChannelMessageStore.shared.open()
            case .chatHistory:
                try ChatHistoryDatabase.shared.open()
            case .method:
                try MethodDatabase.shared.open()
            case .tool:
                try ToolDatabase.shared.open()
            case .scheduler:
                try SchedulerDatabase.shared.open()
            case .routerBilling:
                try RouterBillingDatabase.shared.open()
            }
            PersistenceHealth.shared.clearStoreIssue(store: store.rawValue)
            log.info("recovery: \(store.rawValue, privacy: .public) reopened")
            return true
        } catch {
            PersistenceHealth.shared.recordDatabaseOpenFailure(
                subsystem: store.rawValue,
                error: error,
                path: store.path
            )
            log.error(
                "recovery: \(store.rawValue, privacy: .public) retry failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Reset (quarantine + recreate)

    /// Quarantine an unrecoverable store and recreate it empty so the feature
    /// works again. Never deletes the original — it's moved to
    /// `~/.osaurus/quarantine/`. Returns the quarantine destination, if any.
    @discardableResult
    public func resetStore(_ store: Store) async -> URL? {
        let path = store.path

        // Park concurrent opens and close every live handle before we move
        // files. Reopen after the gate is released to avoid the gated-open
        // deadlock. A locked store has no live handle, so we explicitly reopen
        // it below.
        await MainActor.run { StorageMutationGate.shared.beginMutating() }
        let handles = OsaurusDatabaseHandle.allOpenHandles
        for handle in handles { handle.closer() }

        // Close the (unregistered) plugin/agent connections too so the
        // quarantine move can't run underneath a live fd.
        AgentDatabaseStore.shared.closeAll()
        PluginDatabase.closeAllOpen()

        let destination = StorageFile.quarantine(path: path, reason: "reset \(store.rawValue)")
        StorageFile.removeSidecars(for: path)

        await MainActor.run { StorageMutationGate.shared.endMutating() }
        for handle in handles { handle.reopener() }

        // Reopen the reset store (its handle may not have been registered if it
        // was locked) so detection-first recreates it empty in the desired mode.
        _ = await retryStore(store)
        PersistenceHealth.shared.clearStoreIssue(store: store.rawValue)

        if store == .memory {
            // The vector index pointed at the now-quarantined DB; rebuild it
            // from the fresh (empty) source of truth.
            await MemorySearchService.shared.resetAndRebuildAfterKeyRotation()
        }

        log.info("recovery: \(store.rawValue, privacy: .public) reset (quarantined)")
        return destination
    }
}
