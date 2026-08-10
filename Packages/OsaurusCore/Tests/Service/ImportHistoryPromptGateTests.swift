//
//  ImportHistoryPromptGateTests.swift
//  osaurusTests
//
//  Locks the one-time post-onboarding import-history prompt's
//  eligibility contract: the persisted once-per-user seen flag, the
//  in-memory duplicate-presentation guard, and that a blocked/deferred
//  check never consumes eligibility. Uses an isolated UserDefaults
//  suite so every case is deterministic.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ImportHistoryPromptGateTests {

    /// A gate backed by an isolated defaults suite.
    private func makeGate() -> (gate: ImportHistoryPromptGate, defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "import-history-prompt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let gate = ImportHistoryPromptGate(defaults: defaults)
        return (gate, defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    // MARK: - Seen flag

    /// Fresh install (no stored flag) is eligible.
    @Test func freshInstall_is_eligible() {
        let (gate, defaults, cleanup) = makeGate()
        defer { cleanup() }
        #expect(defaults.object(forKey: ImportHistoryPromptGate.seenDefaultsKey) == nil)
        #expect(!gate.hasSeen)
        #expect(gate.isEligible)
    }

    @Test func seen_flag_blocks_eligibility() {
        let (gate, _, cleanup) = makeGate()
        defer { cleanup() }
        gate.markSeen()
        #expect(!gate.isEligible)
    }

    /// `markSeen` is idempotent; every dismissal path may call it safely.
    @Test func markSeen_is_idempotent() {
        let (gate, _, cleanup) = makeGate()
        defer { cleanup() }
        gate.markSeen()
        gate.markSeen()
        #expect(gate.hasSeen)
        #expect(!gate.isEligible)
    }

    /// The dismissal must survive a restart: a NEW gate instance backed
    /// by the same defaults suite stays ineligible.
    @Test func dismissal_persists_across_gate_instances() {
        let suiteName = "import-history-prompt-restart-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = ImportHistoryPromptGate(defaults: defaults)
        #expect(first.isEligible)
        first.willPresent()
        first.didDismiss()

        let second = ImportHistoryPromptGate(defaults: defaults)
        #expect(second.hasSeen)
        #expect(!second.isEligible)
    }

    // MARK: - Presentation lifecycle

    /// `willPresent` persists seen IMMEDIATELY (crash-during-presentation
    /// can't resurrect the prompt) and guards duplicate activations while
    /// the dialog is on screen.
    @Test func willPresent_marks_seen_and_blocks_duplicate_activation() {
        let (gate, defaults, cleanup) = makeGate()
        defer { cleanup() }

        #expect(gate.isEligible)
        gate.willPresent()

        #expect(gate.isPresenting)
        #expect(defaults.bool(forKey: ImportHistoryPromptGate.seenDefaultsKey))
        // A second check arriving mid-presentation must not stack.
        #expect(!gate.isEligible)

        gate.didDismiss()
        #expect(!gate.isPresenting)
        // Still seen — never shows a second time.
        #expect(!gate.isEligible)
    }

    // MARK: - Deferral does not consume eligibility

    /// A blocked check (competing modal — the caller simply never
    /// presents) must leave both the persisted flag and eligibility
    /// untouched.
    @Test func blocked_check_leaves_eligibility_and_persistence_untouched() {
        let (gate, defaults, cleanup) = makeGate()
        defer { cleanup() }

        for _ in 0..<5 {
            #expect(gate.isEligible)
        }
        #expect(defaults.object(forKey: ImportHistoryPromptGate.seenDefaultsKey) == nil)
        #expect(!gate.hasSeen)
        #expect(gate.isEligible)
    }

    // MARK: - DEBUG reset hook

    #if DEBUG
        /// The debug reset clears the seen flag so the normal
        /// eligibility/presentation path can run another pass.
        @Test func debugReset_rearms_eligibility() {
            let (gate, _, cleanup) = makeGate()
            defer { cleanup() }

            gate.willPresent()
            gate.didDismiss()
            #expect(!gate.isEligible)

            gate.resetForDebugTesting()
            #expect(gate.isEligible)
        }
    #endif
}
