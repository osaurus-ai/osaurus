//
//  IdentityRestoreTests.swift
//  OsaurusCoreTests
//
//  Validation and safety-gate tests for the mnemonic restore flow:
//  `OsaurusIdentity.restore(words:)` (the shared engine behind drift repair,
//  fresh restore, and replace-existing) and the pure helpers backing
//  `RecoverFromMnemonicSheet`. Live-Keychain effects (master install, agent
//  re-derivation) can't run under OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS, so
//  these tests pin the decode/validation/gating behavior and prove the
//  engine fails loudly — no partial state, no identity-changed signal —
//  when the install can't happen.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Restore engine

@Suite("OsaurusIdentity.restore")
@MainActor
struct OsaurusIdentityRestoreTests {

    /// Observe `.osaurusIdentityChanged` for the duration of `body`.
    private func identityChangedCount(during body: () -> Void) -> Int {
        final class Counter { var value = 0 }
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: .osaurusIdentityChanged,
            object: nil,
            queue: nil
        ) { _ in counter.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        return counter.value
    }

    @Test("invalid word count is rejected before any state changes")
    func invalidWordCountRejected() {
        let posts = identityChangedCount {
            #expect(throws: OsaurusIdentityError.self) {
                _ = try OsaurusIdentity.restore(words: Array(repeating: "abandon", count: 12))
            }
        }
        #expect(posts == 0)
    }

    @Test("unknown word is rejected before any state changes")
    func unknownWordRejected() throws {
        var words = try MasterKeyMnemonic.mnemonic(forKey: TestKeys.alicePrivateKey)
        words[7] = "notavalidword"
        let posts = identityChangedCount {
            #expect(throws: OsaurusIdentityError.self) {
                _ = try OsaurusIdentity.restore(words: words)
            }
        }
        #expect(posts == 0)
    }

    // Only meaningful when the keychain is disabled for the process; the CI
    // xcodebuild lane runs against a real keychain, where restore succeeding
    // is the correct behavior — so skip instead of asserting the environment.
    @Test(
        "keychain-disabled install failure surfaces as an error, not a fake success",
        .enabled(if: KeychainQueryHelpers.disablesKeychainForProcess)
    )
    func disabledKeychainFailsLoudly() throws {
        // Under OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS the install must throw —
        // a silent no-op would tell the user their identity was restored
        // when nothing was persisted. No identity-changed signal either.
        let words = try MasterKeyMnemonic.mnemonic(forKey: TestKeys.alicePrivateKey)
        let posts = identityChangedCount {
            #expect(throws: OsaurusIdentityError.self) {
                _ = try OsaurusIdentity.restore(words: words)
            }
        }
        #expect(posts == 0)
    }
}

// MARK: - Sheet validation helpers

@Suite("RecoverFromMnemonicSheet validation")
struct RecoverFromMnemonicSheetLogicTests {

    private func aliceWords() throws -> [String] {
        try MasterKeyMnemonic.mnemonic(forKey: TestKeys.alicePrivateKey)
    }

    // MARK: canRestore gating

    @Test("incomplete phrases never enable Restore")
    func incompletePhraseDisablesRestore() throws {
        let partial = Array(try aliceWords().prefix(23))
        #expect(
            !RecoverFromMnemonicSheet.canRestore(
                words: partial, mode: .freshRestore, acknowledgedReplace: true))
        #expect(
            !RecoverFromMnemonicSheet.canRestore(
                words: [], mode: .freshRestore, acknowledgedReplace: true))
    }

    @Test("24 words enable Restore for drift repair and fresh restore")
    func completePhraseEnablesRestore() throws {
        let words = try aliceWords()
        let drift = IdentityDrift(mismatchedAgents: [], staleAccessKeys: [])
        #expect(
            RecoverFromMnemonicSheet.canRestore(
                words: words, mode: .driftRepair(drift), acknowledgedReplace: false))
        #expect(
            RecoverFromMnemonicSheet.canRestore(
                words: words, mode: .freshRestore, acknowledgedReplace: false))
    }

    @Test("replace-existing additionally requires the acknowledgment")
    func replaceExistingRequiresAcknowledgment() throws {
        let words = try aliceWords()
        let mode = RecoverFromMnemonicMode.replaceExisting(current: TestKeys.bobAddress)
        #expect(
            !RecoverFromMnemonicSheet.canRestore(
                words: words, mode: mode, acknowledgedReplace: false))
        #expect(
            RecoverFromMnemonicSheet.canRestore(
                words: words, mode: mode, acknowledgedReplace: true))
    }

    // MARK: Candidate address preview

    @Test("a valid phrase previews the address it would restore")
    func candidateAddressForValidPhrase() throws {
        let words = try aliceWords()
        #expect(RecoverFromMnemonicSheet.candidateAddress(for: words) == TestKeys.aliceAddress)
    }

    @Test("incomplete or checksum-failing phrases preview no address")
    func candidateAddressRejectsInvalidPhrases() throws {
        var words = try aliceWords()
        #expect(RecoverFromMnemonicSheet.candidateAddress(for: Array(words.prefix(23))) == nil)

        // Swap in a different valid word: still 24 wordlist words, but the
        // checksum no longer matches the entropy.
        words[0] = words[0] == "ability" ? "able" : "ability"
        #expect(RecoverFromMnemonicSheet.candidateAddress(for: words) == nil)
    }

    // MARK: Drift-repair previous-master guard

    private func agentDerived(from masterKey: Data, index: UInt32) throws -> Agent {
        var agent = Agent(
            id: UUID(),
            name: "agent-\(index)",
            description: "",
            systemPrompt: "",
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        agent.agentIndex = index
        agent.agentAddress = try AgentKey.deriveAddress(masterKey: masterKey, index: index)
        return agent
    }

    @Test("the previous master's phrase passes the drift guard")
    func previousMasterPassesGuard() throws {
        // Agents on disk were derived from Alice; the candidate seed is Alice.
        let drift = IdentityDrift(
            mismatchedAgents: [try agentDerived(from: TestKeys.alicePrivateKey, index: 3)],
            staleAccessKeys: []
        )
        let message = RecoverFromMnemonicSheet.previousSeedMismatchMessage(
            drift: drift,
            seed: TestKeys.alicePrivateKey,
            candidate: TestKeys.aliceAddress
        )
        #expect(message == nil)
    }

    @Test("an unrelated valid phrase is flagged for explicit override")
    func unrelatedMasterIsFlagged() throws {
        // Agents on disk were derived from Alice; the candidate seed is Bob —
        // a valid mnemonic, but not the previous master.
        let stranded = try agentDerived(from: TestKeys.alicePrivateKey, index: 3)
        let drift = IdentityDrift(mismatchedAgents: [stranded], staleAccessKeys: [])
        let message = RecoverFromMnemonicSheet.previousSeedMismatchMessage(
            drift: drift,
            seed: TestKeys.bobPrivateKey,
            candidate: TestKeys.bobAddress
        )
        #expect(message != nil)
        #expect(message?.contains(TestKeys.bobAddress) == true)
    }

    @Test("no mismatched agents means nothing to verify against")
    func emptyDriftPassesGuard() {
        let drift = IdentityDrift(mismatchedAgents: [], staleAccessKeys: [])
        let message = RecoverFromMnemonicSheet.previousSeedMismatchMessage(
            drift: drift,
            seed: TestKeys.bobPrivateKey,
            candidate: TestKeys.bobAddress
        )
        #expect(message == nil)
    }
}
