//
//  RouterBillingLedger.swift
//  osaurus
//
//  Thin, failure-tolerant facade over `RouterBillingDatabase`. The chat hot
//  path calls this to (a) record a charge the instant the router's summary
//  frame lands and (b) finalize the rendered outcome once the run completes.
//  Every method is a no-op when the storage key is locked or the ledger can't
//  open — billing reliability must never break sending a message.
//
//  Metadata only: cost, token counts, status, outcome, and ids. No prompt or
//  response text ever reaches this layer.
//

import Foundation

public final class RouterBillingLedger: @unchecked Sendable {
    public static let shared = RouterBillingLedger()

    private let database: RouterBillingDatabase
    private let lock = NSLock()
    /// Tri-state: nil = not attempted, true/false = last open outcome. Lets us
    /// skip repeated open attempts after a hard failure within a launch.
    private var openState: Bool?

    init(database: RouterBillingDatabase = .shared) {
        self.database = database
    }

    // MARK: - Open gate

    /// Open the ledger on first use and return whether it's usable now. Cheap
    /// and non-prompting: returns false when the storage key isn't already
    /// unlocked, so the chat path never blocks on the Keychain.
    @discardableResult
    private func ensureOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // An already-open database is ready (e.g. an injected in-memory store
        // in tests). Production's shared DB isn't open until we open it below,
        // so this never bypasses the key gate for the real on-disk file.
        if database.isOpen { return true }
        if let openState { return openState && database.isOpen }
        // The DEK is non-biometric but can be unreadable before first unlock.
        // In plaintext mode (the default) no key is needed, so readiness is
        // always true; in encrypted mode it's true once any core DB has opened
        // (always the case by the time a router stream runs) and never prompts.
        guard StorageKeyManager.shared.isStorageReadyForWrites else { return false }
        do {
            try database.open()
            try? database.pruneIfNeeded()
            openState = true
        } catch {
            openState = false
        }
        return openState == true && database.isOpen
    }

    // MARK: - Write

    /// Record a charge. Returns the new entry id (to stash on the turn for
    /// later `finalizeOutcome`) or nil when the ledger is unavailable.
    @discardableResult
    public func record(
        summary: RouterBillingSummary,
        sessionId: UUID?,
        turnId: UUID,
        model: String?,
        outcome: RouterBillingOutcome = .pending
    ) -> String? {
        guard ensureOpen() else { return nil }
        let entry = RouterBillingEntry(
            id: UUID().uuidString,
            requestId: summary.requestId,
            createdAt: Date(),
            sessionId: sessionId?.uuidString,
            turnId: turnId.uuidString,
            model: model,
            tokenSource: summary.tokenSource,
            inputTokens: summary.inputTokens,
            outputTokens: summary.outputTokens,
            costMicro: summary.costMicro,
            status: summary.status,
            outcome: outcome,
            appVersion: Self.appVersion
        )
        do {
            let stored = try database.upsertByRequestId(entry)
            return stored.id
        } catch {
            return nil
        }
    }

    /// Finalize the rendered outcome for a previously recorded charge.
    public func finalizeOutcome(entryId: String, outcome: RouterBillingOutcome) {
        guard ensureOpen() else { return }
        try? database.updateOutcome(entryId: entryId, outcome: outcome)
    }

    // MARK: - Read

    public func recent(limit: Int = 200, offset: Int = 0) -> [RouterBillingEntry] {
        guard ensureOpen() else { return [] }
        return (try? database.recent(limit: limit, offset: offset)) ?? []
    }

    public func findByRequestId(_ requestId: String) -> RouterBillingEntry? {
        guard ensureOpen() else { return nil }
        return try? database.findByRequestId(requestId)
    }

    public func findByRequestIds(_ requestIds: [String]) -> [RouterBillingEntry] {
        guard ensureOpen() else { return [] }
        return (try? database.findByRequestIds(requestIds)) ?? []
    }

    public func count() -> Int {
        guard ensureOpen() else { return 0 }
        return (try? database.count()) ?? 0
    }

    // MARK: - Diagnostics export

    /// Current export schema. Bump when the diagnostics shape changes so support
    /// tooling can branch on it.
    public static let diagnosticsSchemaVersion = 2

    /// Metadata-only diagnostics bundle for support. Composed solely of
    /// `RouterBillingEntry` rows (no prompt/response text by construction) plus
    /// environment tags and optional public wallet-address correlation status.
    public struct Diagnostics: Codable, Sendable {
        public let schemaVersion: Int
        public let generatedAt: Date
        public let appVersion: String?
        public let osVersion: String
        /// Public Osaurus ID (wallet address) the router bills, for server-side
        /// correlation. Nil when no non-prompting source is available.
        public let walletAddress: String?
        /// Explains why `walletAddress` is present or absent. Support exports
        /// should not trigger biometric auth only to fill the address.
        public let walletAddressStatus: RouterSupportWalletAddressStatus
        public let entries: [RouterBillingEntry]
    }

    /// Build a metadata-only diagnostics bundle. `walletAddress`, when present,
    /// is supplied by the caller from a non-prompting source so this layer never
    /// touches the Keychain.
    public func buildDiagnostics(
        walletAddress: String?,
        walletAddressStatus: RouterSupportWalletAddressStatus? = nil,
        limit: Int = RouterBillingDatabase.maxRows
    ) -> Diagnostics {
        let hasWalletAddress = walletAddress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return Diagnostics(
            schemaVersion: Self.diagnosticsSchemaVersion,
            generatedAt: Date(),
            appVersion: Self.appVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            walletAddress: walletAddress,
            walletAddressStatus: walletAddressStatus ?? (hasWalletAddress ? .available : .unavailableWithoutPrompt),
            entries: recent(limit: limit)
        )
    }

    // MARK: - Helpers

    static let appVersion: String? =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
}
