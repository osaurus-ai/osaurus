//
//  AgentInviteStore.swift
//  osaurus
//
//  Per-agent ledger of issued invites. Used by the sender to:
//    1. List previously-issued invites in the Share sheet.
//    2. Enforce single-use semantics at /pair-invite verification time.
//    3. Revoke individual invites and the access keys they spawned.
//
//  One JSON file per agent at `~/.osaurus/agent-invites/<id>.json`. The
//  directory is a sibling of `agents/` (not a child) so `AgentStore.loadAll`
//  doesn't try to decode the ledger files as agent records.
//

import Foundation

// MARK: - Issued Invite Record

public struct IssuedInviteRecord: Codable, Identifiable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// Active, never used. Will become `.used` after a /pair-invite redemption,
        /// or `.expired` once `exp` passes (computed lazily — never written to disk
        /// because the wall-clock could change).
        case active
        /// Consumed by a successful /pair-invite redemption.
        case used
        /// Legacy: previously written by an older `revoke(...)` that marked
        /// records instead of deleting them. New code never writes this value
        /// — `revoke(...)` now removes the record outright. Records that still
        /// carry it are filtered out at load time so they don't surface.
        case revoked
    }

    public let nonce: String
    public let exp: Int64
    public var status: Status
    public let issuedAt: Date
    public var usedAt: Date?
    public var revokedAt: Date?
    /// Local UUID of the `osk-v1` access key minted on redemption.
    /// Set when `status == .used` so revocation can also revoke the key.
    public var accessKeyId: UUID?
    /// Convenience: Host part of the connecting client at redemption time
    /// (e.g. relay-edge IP). For the issued-list UI only.
    public var redeemedFrom: String?

    public var id: String { nonce }

    public var expirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(exp))
    }

    public var isPastExpiry: Bool {
        Date() >= expirationDate
    }

    /// Effective display status: collapses `.active && isPastExpiry` to a
    /// pseudo-`.expired` state for the UI without writing it to disk. Legacy
    /// `.revoked` rows are filtered out before we get here; if one slips
    /// through, treat it as expired so the UI never renders a "Revoked" pill.
    public enum DisplayStatus: String, Sendable {
        case active, used, expired
    }

    public var displayStatus: DisplayStatus {
        switch status {
        case .used: return .used
        case .revoked: return .expired
        case .active: return isPastExpiry ? .expired : .active
        }
    }
}

// MARK: - Store

@MainActor
public enum AgentInviteStore {

    public enum ConsumeResult: Sendable, Equatable {
        /// The nonce is unknown to this store (no record at all).
        case unknownNonce
        /// Nonce is valid and now marked as used. Caller can mint the access key.
        case consumed
        /// Nonce was already consumed by a prior request.
        case alreadyUsed
        /// Issuer revoked this invite.
        case revoked
        /// Past `exp` — invite cannot be redeemed.
        case expired
    }

    // MARK: Public API

    /// Append a freshly-issued invite to this agent's ledger.
    public static func record(_ invite: AgentInvite, for agentId: UUID) {
        var ledger = load(for: agentId)
        // Idempotent: if the same nonce somehow shows up twice (shouldn't —
        // 32 random bytes — but cheap to be safe), the latest wins.
        ledger.removeAll { $0.nonce == invite.nonce }
        ledger.insert(
            IssuedInviteRecord(
                nonce: invite.nonce,
                exp: invite.exp,
                status: .active,
                issuedAt: Date(),
                usedAt: nil,
                revokedAt: nil,
                accessKeyId: nil,
                redeemedFrom: nil
            ),
            at: 0
        )
        save(ledger, for: agentId)
    }

    /// Return all invites for an agent (newest first).
    public static func list(for agentId: UUID) -> [IssuedInviteRecord] {
        load(for: agentId).sorted { $0.issuedAt > $1.issuedAt }
    }

    /// Atomic "verify + consume" used by /pair-invite. Returns whether the caller
    /// is allowed to mint a key. On `.consumed`, the record is moved to `.used`
    /// and persisted before this returns; the caller MUST then call
    /// `attachAccessKey(...)` after the access key is created so revocation
    /// works end-to-end.
    public static func verifyAndConsume(
        nonce: String,
        for agentId: UUID,
        from origin: String?
    ) -> ConsumeResult {
        var ledger = load(for: agentId)
        guard let idx = ledger.firstIndex(where: { $0.nonce == nonce }) else {
            return .unknownNonce
        }
        var record = ledger[idx]
        switch record.status {
        case .used: return .alreadyUsed
        case .revoked: return .revoked
        case .active:
            if record.isPastExpiry { return .expired }
            record.status = .used
            record.usedAt = Date()
            record.redeemedFrom = origin
            ledger[idx] = record
            save(ledger, for: agentId)
            return .consumed
        }
    }

    /// Rewind a `.used` record back to `.active` if the caller failed to mint
    /// the access key. Keeps the ledger honest if /pair-invite errors after
    /// consuming the nonce.
    public static func rollbackConsume(nonce: String, for agentId: UUID) {
        var ledger = load(for: agentId)
        guard let idx = ledger.firstIndex(where: { $0.nonce == nonce }) else { return }
        var record = ledger[idx]
        if record.status == .used {
            record.status = .active
            record.usedAt = nil
            record.redeemedFrom = nil
            ledger[idx] = record
            save(ledger, for: agentId)
        }
    }

    /// Bind the access key the redemption created to the consumed record so
    /// `revoke(...)` can also revoke the underlying key.
    public static func attachAccessKey(
        nonce: String,
        for agentId: UUID,
        accessKeyId: UUID
    ) {
        var ledger = load(for: agentId)
        guard let idx = ledger.firstIndex(where: { $0.nonce == nonce }) else { return }
        ledger[idx].accessKeyId = accessKeyId
        save(ledger, for: agentId)
    }

    /// Revoke an invite by removing it from the ledger entirely. Returns the
    /// access key (if any) that was minted from it so the caller can revoke
    /// that as well via APIKeyManager.
    ///
    /// Removing the record (rather than just marking it `.revoked`) keeps the
    /// share sheet honest with what the user expects from "Revoke" and lets
    /// `purgeOld` stay simple. Server-side replay protection is unaffected:
    /// `verifyAndConsume` returns `.unknownNonce` for missing records and the
    /// HTTP layer rejects with 401 — exactly what we want for stolen links.
    @discardableResult
    public static func revoke(nonce: String, for agentId: UUID) -> UUID? {
        var ledger = load(for: agentId)
        guard let idx = ledger.firstIndex(where: { $0.nonce == nonce }) else { return nil }
        let accessKeyId = ledger[idx].accessKeyId
        ledger.remove(at: idx)
        save(ledger, for: agentId)
        return accessKeyId
    }

    /// Garbage-collect ledger entries older than `keepFor` past their expiry.
    /// Cheap; safe to run at app launch or from the share sheet.
    public static func purgeOld(for agentId: UUID, keepFor: TimeInterval = 30 * 24 * 3600) {
        let now = Date()
        var ledger = load(for: agentId)
        let before = ledger.count
        ledger.removeAll { record in
            guard record.isPastExpiry else { return false }
            return now.timeIntervalSince(record.expirationDate) > keepFor
        }
        if ledger.count != before {
            save(ledger, for: agentId)
        }
    }

    // MARK: Storage

    private static func ledgerURL(for agentId: UUID) -> URL {
        OsaurusPaths.agentInvites().appendingPathComponent("\(agentId.uuidString).json")
    }

    private static func load(for agentId: UUID) -> [IssuedInviteRecord] {
        let url = ledgerURL(for: agentId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Filter out legacy `.revoked` rows so the new UI never has to
            // know about them. New `revoke(...)` deletes records outright.
            return try decoder.decode([IssuedInviteRecord].self, from: data)
                .filter { $0.status != .revoked }
        } catch {
            print("[Osaurus] Failed to load invite ledger for \(agentId): \(error)")
            return []
        }
    }

    private static func save(_ records: [IssuedInviteRecord], for agentId: UUID) {
        let url = ledgerURL(for: agentId)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save invite ledger for \(agentId): \(error)")
        }
    }
}
