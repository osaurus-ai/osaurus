//
//  SyncSignedRecordsTests.swift
//  OsaurusCoreTests
//
//  A device's records on the manage conversation (push registrations, Live
//  Activity grants, call answers) count only when that device signed them:
//  an unsigned value, or one another device wrote under its key, is ignored.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Sync signed records")
struct SyncSignedRecordsTests {

    private static func registration(_ grantId: String) throws -> Data {
        try SyncHostedRunContract.encode(
            SyncDeviceFeedContract.PushRegistration(
                grant: "Z3JhbnQ=", grantId: grantId, expiresMs: .max,
                contentKey: Data(count: 32).base64EncodedString(), installId: "install",
                events: ["completed"], updatedMs: 1))
    }

    @Test
    func onlyARecordItsOwnDeviceSignedCounts() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let scope = try core.createConversation(title: "Manage", replication: .synced)
            let prefix = SyncDeviceFeedContract.pushRegistrationNamespacePrefix
            let me = core.deviceKey()
            let other = String(repeating: "ab", count: 32)
            // Signed by this device, under its own key: counts.
            try core.setConversationAppData(scope: scope, namespace: prefix + me, bytes: Self.registration("mine"))
            // Signed by this device under another device's key: a forged record for that device.
            try core.setConversationAppData(scope: scope, namespace: prefix + other, bytes: Self.registration("forged"))

            var conversation = try #require(try core.conversation(scope: scope))
            func read(_ conversation: Conversation) -> [String: SyncDeviceFeedContract.PushRegistration] {
                SyncDeviceFeedContract.perDevice(
                    SyncDeviceFeedContract.PushRegistration.self, prefix: prefix, in: conversation,
                    writtenByThatDevice: true, signedOnly: true)
            }
            let found = read(conversation)
            #expect(found[me]?.grantId == "mine")
            #expect(found[other] == nil)

            // The same value with no signature (written before signing, or changed since): ignored.
            conversation.appData = conversation.appData.map { entry in
                var unsigned = entry
                unsigned.authorDevice = nil
                unsigned.hlc = nil
                return unsigned
            }
            #expect(read(conversation).isEmpty)
        }
    }
}
