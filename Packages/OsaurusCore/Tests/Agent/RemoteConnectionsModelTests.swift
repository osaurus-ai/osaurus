//
//  RemoteConnectionsModelTests.swift
//  osaurusTests
//
//  Pins the host-side "Remote Connections" list assembly (the owner view of
//  who can reach a shared agent). `RemoteConnectionsModel.rows` merges minted
//  agent-scoped access keys with still-pending relay invites and maps each to a
//  status badge: revoked → .revoked, expired → .expired, temporary LAN key →
//  .temporary, otherwise .active; unredeemed invites → .pending. Redeemed
//  invites already appear as their minted key, so they must not be double
//  listed.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote connections list assembly")
struct RemoteConnectionsModelTests {

    private func makeKey(
        id: UUID = UUID(),
        label: String,
        audience: OsaurusID = "agent-addr",
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        expiration: AccessKeyExpiration = .never,
        revoked: Bool = false
    ) -> AccessKeyInfo {
        AccessKeyInfo(
            id: id,
            label: label,
            prefix: "osk-v1.aaaa",
            nonce: "nonce-\(id.uuidString)",
            cnt: 1,
            iss: "issuer",
            aud: audience,
            createdAt: createdAt,
            expiration: expiration,
            expiresAt: expiresAt,
            revoked: revoked
        )
    }

    private func makeInvite(
        nonce: String = UUID().uuidString,
        status: IssuedInviteRecord.Status,
        expiresInSeconds: TimeInterval = 3600,
        accessKeyId: UUID? = nil
    ) -> IssuedInviteRecord {
        IssuedInviteRecord(
            nonce: nonce,
            exp: Int64(Date().addingTimeInterval(expiresInSeconds).timeIntervalSince1970),
            status: status,
            issuedAt: Date(),
            usedAt: nil,
            revokedAt: nil,
            accessKeyId: accessKeyId,
            redeemedFrom: nil
        )
    }

    // MARK: - Status mapping

    @Test func activeKey_mapsToActiveRow() {
        let key = makeKey(label: "Paired – mac")
        let rows = RemoteConnectionsModel.rows(
            keys: [key],
            invites: [],
            isTemporary: { _ in false }
        )
        #expect(rows.count == 1)
        #expect(rows.first?.status == .active)
        #expect(rows.first?.keyId == key.id)
        #expect(rows.first?.accessKeyNonce == key.nonce)
        #expect(rows.first?.canRevoke == true)
    }

    /// "Revoke flips a row to Revoked": a key marked revoked maps to the
    /// .revoked badge and is no longer revocable.
    @Test func revokedKey_mapsToRevokedRow() {
        let key = makeKey(label: "Invite – Bob").withRevoked()
        let rows = RemoteConnectionsModel.rows(
            keys: [key],
            invites: [],
            isTemporary: { _ in false }
        )
        #expect(rows.first?.status == .revoked)
        #expect(rows.first?.canRevoke == false)
    }

    @Test func expiredKey_mapsToExpiredRow() {
        let key = makeKey(
            label: "Invite – Carol",
            expiresAt: Date().addingTimeInterval(-60),
            expiration: .days30
        )
        let rows = RemoteConnectionsModel.rows(
            keys: [key],
            invites: [],
            isTemporary: { _ in false }
        )
        #expect(rows.first?.status == .expired)
        #expect(rows.first?.canRevoke == false)
    }

    @Test func temporaryKey_mapsToTemporaryRow() {
        let key = makeKey(label: "Paired – iPhone")
        let rows = RemoteConnectionsModel.rows(
            keys: [key],
            invites: [],
            isTemporary: { $0 == key.id }
        )
        #expect(rows.first?.status == .temporary)
    }

    // MARK: - Invites

    @Test func pendingInvite_appendsPendingRow() {
        let invite = makeInvite(status: .active)
        let rows = RemoteConnectionsModel.rows(
            keys: [],
            invites: [invite],
            isTemporary: { _ in false }
        )
        #expect(rows.count == 1)
        #expect(rows.first?.status == .pending)
        #expect(rows.first?.inviteNonce == invite.nonce)
        #expect(rows.first?.accessKeyNonce == nil)
        #expect(rows.first?.canRevoke == true)
    }

    @Test func redeemedInvite_isNotDoubleListed() {
        // A `.used` invite already has its key in the keys list, so it must not
        // also surface as a pending invite row.
        let usedInvite = makeInvite(status: .used, accessKeyId: UUID())
        let rows = RemoteConnectionsModel.rows(
            keys: [],
            invites: [usedInvite],
            isTemporary: { _ in false }
        )
        #expect(rows.isEmpty)
    }

    @Test func activeInviteWithMintedKey_isNotPending() {
        // Defensive: an active invite that already carries an accessKeyId means
        // a key exists for it — don't show a redundant pending row.
        let invite = makeInvite(status: .active, accessKeyId: UUID())
        let rows = RemoteConnectionsModel.rows(
            keys: [],
            invites: [invite],
            isTemporary: { _ in false }
        )
        #expect(rows.isEmpty)
    }

    @Test func expiredInvite_isNotPending() {
        let invite = makeInvite(status: .active, expiresInSeconds: -60)
        let rows = RemoteConnectionsModel.rows(
            keys: [],
            invites: [invite],
            isTemporary: { _ in false }
        )
        #expect(rows.isEmpty)
    }

    // MARK: - Ordering + merge

    @Test func keysSortedNewestFirst_thenPendingInvites() {
        let older = makeKey(
            label: "Older",
            createdAt: Date().addingTimeInterval(-1000)
        )
        let newer = makeKey(
            label: "Newer",
            createdAt: Date().addingTimeInterval(-10)
        )
        let pending = makeInvite(status: .active)

        let rows = RemoteConnectionsModel.rows(
            keys: [older, newer],
            invites: [pending],
            isTemporary: { _ in false }
        )
        #expect(rows.count == 3)
        // Newest key first.
        #expect(rows[0].keyId == newer.id)
        #expect(rows[1].keyId == older.id)
        // Pending invites trail the minted keys.
        #expect(rows[2].status == .pending)
    }
}
