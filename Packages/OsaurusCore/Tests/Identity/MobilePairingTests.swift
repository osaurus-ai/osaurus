//
//  MobilePairingTests.swift
//  OsaurusCoreTests
//
//  Osaurus Connect 6-digit pairing: code generation, expiry, the global
//  wrong-guess lockout, and the sealed `POST /pair/code` payload.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

struct PairingCodeTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func generatedCodesAreSixDigits() {
        for _ in 0 ..< 200 {
            let code = PairingCode.generate()
            #expect(code.count == 6)
            #expect(code.allSatisfy(\.isNumber))
        }
    }

    @Test func correctCodeIsAccepted() {
        var code = PairingCode(code: "042317", issuedAt: t0)
        #expect(code.attempt("042317", at: t0.addingTimeInterval(10)) == .accepted)
    }

    @Test func codeExpiresAfterTTL() {
        var code = PairingCode(code: "042317", issuedAt: t0)
        let late = t0.addingTimeInterval(PairingCode.ttl)
        #expect(code.isExpired(at: late))
        #expect(code.attempt("042317", at: late) == .expired)
    }

    @Test func wrongGuessesLockOutAfterBudget() {
        var code = PairingCode(code: "042317", issuedAt: t0)
        for _ in 1 ..< PairingCode.maxFailedAttempts {
            #expect(code.attempt("000000", at: t0) == .rejected)
        }
        #expect(code.attempt("000000", at: t0) == .lockedOut)
    }

    @Test func constantTimeEqualsHandlesLengthMismatch() {
        #expect(PairingCode.constantTimeEquals("123456", "123456"))
        #expect(!PairingCode.constantTimeEquals("123456", "123457"))
        #expect(!PairingCode.constantTimeEquals("123456", "1234567"))
        #expect(!PairingCode.constantTimeEquals("", "1"))
    }
}

@MainActor
struct MobilePairingServiceTests {
    private func makeService() -> MobilePairingService {
        let defaults = UserDefaults(suiteName: "MobilePairingTests.\(UUID().uuidString)")!
        defaults.set(false, forKey: MobilePairingService.keepAwakeDefaultsKey)
        return MobilePairingService(defaults: defaults)
    }

    private func keyInfo() -> AccessKeyInfo {
        AccessKeyInfo(
            id: UUID(),
            label: "Osaurus Connect",
            prefix: "osk-v1.test",
            nonce: "n",
            cnt: 1,
            iss: "0x0000000000000000000000000000000000000001",
            aud: "0x0000000000000000000000000000000000000001",
            createdAt: Date(),
            expiration: .days90,
            expiresAt: Date().addingTimeInterval(90 * 86_400)
        )
    }

    private func request(code: String, encPub: String, deviceId: String = "device-1") -> MobilePairRequest {
        MobilePairRequest(v: 1, code: code, deviceId: deviceId, deviceName: "Test iPhone", encPub: encPub)
    }

    @Test func redeemWithoutActiveCodeIsInvalid() {
        let service = makeService()
        let (_, pub) = PairingKeyEnvelope.generateRecipientKey()
        #expect(service.redeem(request(code: "123456", encPub: pub)) == .invalidCode)
    }

    @Test func wrongCodeKeepsCodeAliveUntilLockout() {
        let service = makeService()
        service.installPendingCodeForTesting(
            PairingCode(code: "123456", issuedAt: Date()),
            fullKey: "osk-v1.secret",
            info: keyInfo()
        )
        let (_, pub) = PairingKeyEnvelope.generateRecipientKey()
        #expect(service.redeem(request(code: "000000", encPub: pub)) == .invalidCode)
        #expect(service.activeCode != nil)
        #expect(service.activeCode?.failedAttempts == 1)
    }

    @Test func correctCodeSealsKeyToPhoneAndRecordsDevice() throws {
        let service = makeService()
        let info = keyInfo()
        service.installPendingCodeForTesting(
            PairingCode(code: "123456", issuedAt: Date()),
            fullKey: "osk-v1.secret",
            info: info
        )
        let (privateKey, pub) = PairingKeyEnvelope.generateRecipientKey()

        guard case .paired(let response, let name) = service.redeem(request(code: "123456", encPub: pub)) else {
            Issue.record("expected pairing to succeed")
            return
        }
        #expect(name == "Test iPhone")
        #expect(response.v == 1)

        let plaintext = try PairingKeyEnvelope.open(
            response.sealed,
            privateKey: privateKey,
            info: MobilePairingService.envelopeInfo(deviceId: "device-1")
        )
        let payload = try JSONDecoder().decode(MobilePairPayload.self, from: Data(plaintext.utf8))
        #expect(payload.apiKey == "osk-v1.secret")
        #expect(payload.agents.allSatisfy { $0.address.hasPrefix("0x") })

        #expect(service.activeCode == nil)
        #expect(service.pairedDevice?.deviceId == "device-1")
        #expect(service.pairedDevice?.keyId == info.id)

        // Single use: the same code can't be redeemed twice.
        #expect(service.redeem(request(code: "123456", encPub: pub)) == .invalidCode)
    }

    @Test func simulatorFlagIsRecordedOnTheDevice() {
        let service = makeService()
        service.installPendingCodeForTesting(
            PairingCode(code: "123456", issuedAt: Date()),
            fullKey: "osk-v1.secret",
            info: keyInfo()
        )
        let (_, pub) = PairingKeyEnvelope.generateRecipientKey()
        var req = request(code: "123456", encPub: pub)
        req.isSimulator = true
        guard case .paired = service.redeem(req) else {
            Issue.record("expected pairing to succeed")
            return
        }
        #expect(service.pairedDevice?.isSimulator == true)
    }

    @Test func pairedDeviceWithoutSimulatorFieldDecodes() throws {
        let json = #"{"deviceId":"d","name":"n","keyId":"6F9619FF-8B86-D011-B42D-00C04FC964FF","pairedAt":0}"#
        let device = try JSONDecoder().decode(PairedMobileDevice.self, from: Data(json.utf8))
        #expect(device.isSimulator == nil)
    }

    @Test func envelopeIsBoundToDevice() throws {
        let service = makeService()
        service.installPendingCodeForTesting(
            PairingCode(code: "123456", issuedAt: Date()),
            fullKey: "osk-v1.secret",
            info: keyInfo()
        )
        let (privateKey, pub) = PairingKeyEnvelope.generateRecipientKey()
        guard case .paired(let response, _) = service.redeem(request(code: "123456", encPub: pub)) else {
            Issue.record("expected pairing to succeed")
            return
        }
        #expect(throws: (any Error).self) {
            _ = try PairingKeyEnvelope.open(
                response.sealed,
                privateKey: privateKey,
                info: MobilePairingService.envelopeInfo(deviceId: "someone-else")
            )
        }
    }

    @Test func malformedEncryptionKeyDoesNotBurnCode() {
        let service = makeService()
        service.installPendingCodeForTesting(
            PairingCode(code: "123456", issuedAt: Date()),
            fullKey: "osk-v1.secret",
            info: keyInfo()
        )
        #expect(service.redeem(request(code: "123456", encPub: "not-a-key")) == .badRequest("Invalid encryption key"))
        #expect(service.activeCode != nil)
    }

    @Test func missingDeviceNameIsBadRequest() {
        let service = makeService()
        let (_, pub) = PairingKeyEnvelope.generateRecipientKey()
        let req = MobilePairRequest(v: 1, code: "123456", deviceId: "d", deviceName: "  ", encPub: pub)
        #expect(service.redeem(req) == .badRequest("Missing device id or name"))
    }
}
