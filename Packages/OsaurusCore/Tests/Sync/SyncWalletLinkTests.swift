//
//  SyncWalletLinkTests.swift
//  OsaurusCoreTests
//
//  The sync recovery phrase derived from the Osaurus wallet: deterministic,
//  encoded the way the sync core reads phrases, the same identity on every
//  Mac linked from one wallet, and dropped when the identity changes to one
//  the wallet didn't derive.
//

import CryptoKit
import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncWalletLinkTests {
    private static let wallet = Data((0..<32).map { UInt8($0) })

    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func openOtherCore(_ name: String, network: Bool = false) throws -> SyncCore {
        let directory = OsaurusPaths.root().appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = localNetworkConfig()
        config.enabled = network
        return try SyncCore.open(
            dataDirectory: directory,
            deviceName: name,
            network: config,
            keyStore: SyncKeyStores.make(dataDirectory: directory)
        )
    }

    @Test
    func thePhraseIsTheHKDFOfTheWalletAsBIP39() throws {
        let words = try SyncWalletLink.phrase(masterKey: Self.wallet)
        #expect(words.count == 24)
        #expect(try SyncWalletLink.phrase(masterKey: Self.wallet) == words)
        #expect(try SyncWalletLink.phrase(masterKey: Data(repeating: 9, count: 32)) != words)

        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Self.wallet),
            info: Data("osaurus-sync/user-secret/v1".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        #expect(try MasterKeyMnemonic.key(fromMnemonic: words) == expected)
        #expect(try MasterKeyMnemonic.mnemonic(forKey: Self.wallet) != words)
    }

    @Test
    func theEncodingMatchesBIP39AndTheSyncCore() async throws {
        let vectors: [(UInt8, String)] = [
            (0x00, Array(repeating: "abandon", count: 23).joined(separator: " ") + " art"),
            (
                0x7f,
                "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
            ),
            (
                0x80,
                "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"
            ),
            (0xff, Array(repeating: "zoo", count: 23).joined(separator: " ") + " vote"),
        ]
        for (byte, phrase) in vectors {
            #expect(try MasterKeyMnemonic.mnemonic(forKey: Data(repeating: byte, count: 32)).joined(separator: " ") == phrase)
        }

        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let words = try SyncWalletLink.phrase(masterKey: Self.wallet)
            try core.recoverFromPhrase(phrase: words.joined(separator: " "))
            #expect(try core.recoveryPhrase() == words)
        }
    }

    @Test
    func twoMacsLinkedFromOneWalletShareTheirSyncIdentity() async throws {
        try await ChatHistoryTestStorage.run {
            let mac = try SyncService.shared.open()
            let other = try openOtherCore("other-mac")
            #expect(try mac.userKey() != other.userKey())

            ChatSessionStore.save(ChatSessionData(title: "Kept", turns: [ChatTurnData(role: .user, content: "keep me")]))
            try SyncWalletLink.link(masterKey: Self.wallet, core: mac)
            try SyncWalletLink.link(masterKey: Self.wallet, core: other)

            #expect(try mac.userKey() == other.userKey())
            let configuration = SyncConfigurationStore.load()
            #expect(configuration.walletLinked)
            #expect(configuration.walletUserKey == (try mac.userKey()))
            #expect(SyncConversationStore.shared.loadAllMetadata().map(\.title) == ["Kept"])
            try await other.close()
        }
    }

    @Test
    func theLinkSurvivesItsOwnIdentityChangeAndEndsOnRotationAndHandoff() async throws {
        try await ChatHistoryTestStorage.run {
            SyncWalletLink._resetForTesting()
            SyncWalletLink.start()
            defer { SyncWalletLink._resetForTesting() }
            let mac = try SyncService.shared.open()

            try SyncWalletLink.link(masterKey: Self.wallet, core: mac)
            try await Task.sleep(for: .milliseconds(300))
            #expect(SyncWalletLink.isLinked)

            _ = try mac.revokeAndRotate(devices: [])
            try await waitUntil("unlinked by rotation") { !SyncWalletLink.isLinked }
            #expect(throws: (any Error).self) { try SyncWalletLink.link(masterKey: Self.wallet, core: mac) }

            try SyncWalletLink.link(masterKey: Data(repeating: 7, count: 32), core: mac)
            #expect(SyncWalletLink.isLinked)
            try await mac.resume()
            let other = try openOtherCore("other-mac", network: true)
            try mac.addPeerAddress(address: #require(other.localAddress()))
            try other.addPeerAddress(address: #require(mac.localAddress()))
            let offer = try other.pairingOffer(ttlMs: 300_000)
            try await mac.pairWithOffer(payload: offer.payload)
            try await waitUntil("paired") { try mac.userKey() == other.userKey() }
            try await waitUntil("unlinked by the handoff") { !SyncWalletLink.isLinked }
            try await other.close()
        }
    }
}
