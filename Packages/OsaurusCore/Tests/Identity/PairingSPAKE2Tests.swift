//
//  PairingSPAKE2Tests.swift
//  OsaurusCoreTests
//
//  Pairing v2: the SPAKE2 exchange itself, and the Mac's two-step
//  `POST /pair/code` + `POST /pair/confirm` flow built on it. The same
//  exchange tests run in iOSaurus against its twin of PairingSPAKE2.swift.
//

import Foundation
import Testing

@testable import OsaurusCore

struct PairingSPAKE2Tests {
    private let identity = PairingSPAKE2.phoneIdentity(deviceId: "device-1", deviceName: "Test iPhone")

    @Test func sameCodeAgreesOnKeysAndConfirmations() throws {
        let phone = try PairingSPAKE2.Party(role: .phone, code: "123456")
        let mac = try PairingSPAKE2.Party(role: .mac, code: "123456")
        let phoneKeys = try phone.finish(peerShare: mac.share, phoneIdentity: identity)
        let macKeys = try mac.finish(peerShare: phone.share, phoneIdentity: identity)
        #expect(phoneKeys.phoneConfirmation == macKeys.phoneConfirmation)
        #expect(phoneKeys.macConfirmation == macKeys.macConfirmation)
        #expect(phoneKeys.phoneConfirmation != phoneKeys.macConfirmation)

        let sealed = try PairingSPAKE2.seal(Data("payload".utf8), key: macKeys.sessionKey, deviceId: "device-1")
        #expect(try PairingSPAKE2.open(sealed, key: phoneKeys.sessionKey, deviceId: "device-1") == Data("payload".utf8))
    }

    @Test func wrongCodeFailsConfirmation() throws {
        let phone = try PairingSPAKE2.Party(role: .phone, code: "000000")
        let mac = try PairingSPAKE2.Party(role: .mac, code: "123456")
        let phoneKeys = try phone.finish(peerShare: mac.share, phoneIdentity: identity)
        let macKeys = try mac.finish(peerShare: phone.share, phoneIdentity: identity)
        #expect(phoneKeys.macConfirmation != macKeys.macConfirmation)
        #expect(phoneKeys.phoneConfirmation != macKeys.phoneConfirmation)
    }

    /// A man in the middle relabelling the device breaks the transcript.
    @Test func differentDeviceIdentityFailsConfirmation() throws {
        let phone = try PairingSPAKE2.Party(role: .phone, code: "123456")
        let mac = try PairingSPAKE2.Party(role: .mac, code: "123456")
        let phoneKeys = try phone.finish(peerShare: mac.share, phoneIdentity: identity)
        let other = PairingSPAKE2.phoneIdentity(deviceId: "device-1", deviceName: "Attacker")
        let macKeys = try mac.finish(peerShare: phone.share, phoneIdentity: other)
        #expect(phoneKeys.macConfirmation != macKeys.macConfirmation)
    }

    @Test func payloadIsBoundToTheDevice() throws {
        let mac = try PairingSPAKE2.Party(role: .mac, code: "123456")
        let phone = try PairingSPAKE2.Party(role: .phone, code: "123456")
        let keys = try mac.finish(peerShare: phone.share, phoneIdentity: identity)
        let sealed = try PairingSPAKE2.seal(Data("payload".utf8), key: keys.sessionKey, deviceId: "device-1")
        #expect(throws: PairingSPAKE2.Failure.invalidSealedPayload) {
            try PairingSPAKE2.open(sealed, key: keys.sessionKey, deviceId: "device-2")
        }
    }

    @Test func rejectsSharesThatAreNotPoints() throws {
        let mac = try PairingSPAKE2.Party(role: .mac, code: "123456")
        #expect(throws: PairingSPAKE2.Failure.invalidShare) {
            try mac.finish(peerShare: Data(repeating: 0, count: 33), phoneIdentity: identity)
        }
        #expect(throws: PairingSPAKE2.Failure.invalidShare) {
            try mac.finish(peerShare: Data([0x04]) + Data(repeating: 1, count: 64), phoneIdentity: identity)
        }
    }

    @Test func fixedPointsAreDistinctAndStable() {
        #expect(PairingSPAKE2.pointM != PairingSPAKE2.pointN)
        #expect(PairingSPAKE2.hashToPoint("M") == PairingSPAKE2.pointM)
        #expect((try? PairingSPAKE2.point(PairingSPAKE2.pointM)) != nil)
        #expect(PairingSPAKE2.passwordScalar(code: "123456") != PairingSPAKE2.passwordScalar(code: "123457"))
    }
}

@MainActor
struct MobilePairingV2Tests {
    private func makeService() -> MobilePairingService {
        let defaults = UserDefaults(suiteName: "MobilePairingV2Tests.\(UUID().uuidString)")!
        defaults.set(false, forKey: MobilePairingService.keepAwakeDefaultsKey)
        defaults.set(false, forKey: MobilePairingService.reachAnywhereDefaultsKey)
        let service = MobilePairingService(defaults: defaults)
        service.installPendingCodeForTesting(
            PairingCode(code: "123456", issuedAt: Date()),
            fullKey: "osk-v1.secret",
            info: AccessKeyInfo(
                id: UUID(),
                label: "Mobile",
                prefix: "osk-v1.test",
                nonce: "n",
                cnt: 1,
                iss: "0x0000000000000000000000000000000000000001",
                aud: "0x0000000000000000000000000000000000000001",
                createdAt: Date(),
                expiration: .days90,
                expiresAt: Date().addingTimeInterval(90 * 86_400)
            )
        )
        return service
    }

    private func start(_ service: MobilePairingService, phone: PairingSPAKE2.Party) -> MobilePairStartResponse? {
        let request = MobilePairStartRequest(
            v: 2,
            deviceId: "device-1",
            deviceName: "Test iPhone",
            share: phone.share.base64urlEncoded
        )
        guard case .answered(let body, _) = service.startExchange(request) else { return nil }
        return try? JSONDecoder().decode(MobilePairStartResponse.self, from: Data(body.utf8))
    }

    @Test func rightCodePairsAndSealsTheKey() throws {
        let service = makeService()
        let phone = try PairingSPAKE2.Party(role: .phone, code: "123456")
        let started = try #require(start(service, phone: phone))
        let keys = try phone.finish(
            peerShare: try #require(Data(base64urlEncoded: started.share)),
            phoneIdentity: PairingSPAKE2.phoneIdentity(deviceId: "device-1", deviceName: "Test iPhone")
        )
        #expect(Data(base64urlEncoded: started.confirm) == keys.macConfirmation)
        #expect(service.pairedDevice == nil)

        let confirm = MobilePairConfirmRequest(
            v: 2,
            exchange: started.exchange,
            confirm: keys.phoneConfirmation.base64urlEncoded
        )
        guard case .answered(let body, _) = service.confirmExchange(confirm) else {
            Issue.record("expected pairing to succeed")
            return
        }
        let response = try JSONDecoder().decode(MobilePairConfirmResponse.self, from: Data(body.utf8))
        let plaintext = try PairingSPAKE2.open(response.sealed, key: keys.sessionKey, deviceId: "device-1")
        let payload = try JSONDecoder().decode(MobilePairPayload.self, from: plaintext)
        #expect(payload.apiKey == "osk-v1.secret")
        #expect(service.pairedDevice?.deviceId == "device-1")
        #expect(service.activeCode == nil)
    }

    @Test func wrongCodeNeverPairs() throws {
        let service = makeService()
        let phone = try PairingSPAKE2.Party(role: .phone, code: "000000")
        let started = try #require(start(service, phone: phone))
        let keys = try phone.finish(
            peerShare: try #require(Data(base64urlEncoded: started.share)),
            phoneIdentity: PairingSPAKE2.phoneIdentity(deviceId: "device-1", deviceName: "Test iPhone")
        )
        // The phone notices first: the Mac's confirmation doesn't match.
        #expect(Data(base64urlEncoded: started.confirm) != keys.macConfirmation)
        let confirm = MobilePairConfirmRequest(
            v: 2,
            exchange: started.exchange,
            confirm: keys.phoneConfirmation.base64urlEncoded
        )
        #expect(service.confirmExchange(confirm) == .invalidCode)
        #expect(service.pairedDevice == nil)
        #expect(service.activeCode != nil)
    }

    /// Every answered exchange spends a guess, so the budget caps guessing.
    @Test func eachExchangeSpendsAnAttempt() throws {
        let service = makeService()
        for _ in 0 ..< PairingCode.maxFailedAttempts {
            #expect(start(service, phone: try PairingSPAKE2.Party(role: .phone, code: "000000")) != nil)
        }
        #expect(start(service, phone: try PairingSPAKE2.Party(role: .phone, code: "123456")) == nil)
        #expect(service.activeCode == nil)
    }

    @Test func anExchangeConfirmsOnlyOnce() throws {
        let service = makeService()
        let phone = try PairingSPAKE2.Party(role: .phone, code: "123456")
        let started = try #require(start(service, phone: phone))
        let wrong = MobilePairConfirmRequest(v: 2, exchange: started.exchange, confirm: Data(count: 32).base64urlEncoded)
        #expect(service.confirmExchange(wrong) == .invalidCode)
        let keys = try phone.finish(
            peerShare: try #require(Data(base64urlEncoded: started.share)),
            phoneIdentity: PairingSPAKE2.phoneIdentity(deviceId: "device-1", deviceName: "Test iPhone")
        )
        let right = MobilePairConfirmRequest(
            v: 2,
            exchange: started.exchange,
            confirm: keys.phoneConfirmation.base64urlEncoded
        )
        #expect(service.confirmExchange(right) == .invalidCode)
    }
}
