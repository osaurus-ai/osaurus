//
//  MasterKeyMnemonicTests.swift
//  OsaurusCoreTests
//
//  Round-trip and validation tests for the BIP39 24-word backup of the
//  master secp256k1 key.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("MasterKeyMnemonic")
struct MasterKeyMnemonicTests {

    // MARK: - Round-trip

    @Test
    func roundTripDeterministic() throws {
        // Alice's deterministic test key. The mnemonic must be reproducible
        // across runs and machines.
        let key = TestKeys.alicePrivateKey
        let mnemonic = try MasterKeyMnemonic.mnemonic(forKey: key)
        #expect(mnemonic.count == 24)

        let recovered = try MasterKeyMnemonic.key(fromMnemonic: mnemonic)
        #expect(recovered == key)
    }

    @Test
    func roundTripRandom() throws {
        // Generate 10 random 32-byte keys and confirm round-trip integrity for
        // each. Catches encoding/decoding bit-packing bugs that wouldn't show
        // up in a single deterministic case.
        for _ in 0 ..< 10 {
            var bytes = [UInt8](repeating: 0, count: 32)
            #expect(SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess)
            let key = Data(bytes)

            let mnemonic = try MasterKeyMnemonic.mnemonic(forKey: key)
            #expect(mnemonic.count == 24)

            let recovered = try MasterKeyMnemonic.key(fromMnemonic: mnemonic)
            #expect(recovered == key)
        }
    }

    // MARK: - Validation

    @Test
    func wrongWordCountIsRejected() {
        let too_few = Array(repeating: "abandon", count: 12)
        #expect(throws: OsaurusIdentityError.self) {
            _ = try MasterKeyMnemonic.key(fromMnemonic: too_few)
        }
    }

    @Test
    func unknownWordIsRejected() throws {
        let mnemonic = try MasterKeyMnemonic.mnemonic(forKey: TestKeys.alicePrivateKey)
        var tampered = mnemonic
        tampered[5] = "notavalidword"
        do {
            _ = try MasterKeyMnemonic.key(fromMnemonic: tampered)
            Issue.record("Expected unknown-word error")
        } catch let error as OsaurusIdentityError {
            switch error {
            case .mnemonicUnknownWord:
                break
            default:
                Issue.record("Expected .mnemonicUnknownWord, got \(error)")
            }
        } catch {
            Issue.record("Expected OsaurusIdentityError, got \(error)")
        }
    }

    @Test
    func badChecksumIsRejected() throws {
        // Swap two words that are both in the wordlist but produce a different
        // entropy (and therefore a checksum mismatch).
        let mnemonic = try MasterKeyMnemonic.mnemonic(forKey: TestKeys.alicePrivateKey)
        var tampered = mnemonic
        // Swap the first word with a different valid word.
        tampered[0] = tampered[0] == "ability" ? "able" : "ability"

        do {
            _ = try MasterKeyMnemonic.key(fromMnemonic: tampered)
            Issue.record("Expected checksum failure")
        } catch let error as OsaurusIdentityError {
            switch error {
            case .mnemonicChecksumFailed, .mnemonicUnknownWord:
                break
            default:
                Issue.record("Expected checksum failure, got \(error)")
            }
        } catch {
            Issue.record("Expected OsaurusIdentityError, got \(error)")
        }
    }

    // MARK: - Phrase Parser

    @Test
    func phraseParserSplitsOnWhitespace() {
        let raw = "  abandon\nabandon\tabandon  abandon "
        let parsed = MasterKeyMnemonic.words(fromPhrase: raw)
        #expect(parsed == ["abandon", "abandon", "abandon", "abandon"])
    }

    @Test
    func phraseParserNormalizesCase() {
        let raw = "Abandon ABANDON aBaNdOn"
        let parsed = MasterKeyMnemonic.words(fromPhrase: raw)
        #expect(parsed == ["abandon", "abandon", "abandon"])
    }

    // MARK: - Wordlist Sanity

    @Test
    func wordlistHasCanonicalSize() {
        #expect(MasterKeyMnemonic.wordlist.count == 2048)
        #expect(MasterKeyMnemonic.wordlist.first == "abandon")
        #expect(MasterKeyMnemonic.wordlist.last == "zoo")
    }

    @Test
    func wordlistContainsKnownWords() {
        // Spot check: BIP39 sentinel words from the canonical list.
        #expect(MasterKeyMnemonic.contains("ability"))
        #expect(MasterKeyMnemonic.contains("about"))
        #expect(MasterKeyMnemonic.contains("zone"))
        #expect(MasterKeyMnemonic.contains("zoo"))
        #expect(!MasterKeyMnemonic.contains("notabip39word"))
    }
}
