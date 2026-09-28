import Foundation
import Testing

@testable import OsaurusCore

@Suite("Restore-only handoff protected target")
struct RestoreOnlyProtectedTargetTests {
    @Test("swap ON refuses a protected child before a nonresident parent restore")
    func protectedTargetRefusesRestoreOnlySwap() {
        do {
            _ = try plan(handoffEnabled: true, protectedResidents: ["API-B"])
            Issue.record("Protected target must refuse before child work when the installed parent needs restoration")
        } catch let error as SubagentError {
            guard case .unavailable(let message) = error else {
                Issue.record("Expected unavailable, got \(error)")
                return
            }
            #expect(message.localizedCaseInsensitiveContains("api-b"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("swap OFF permits protected target reuse without a parent reload")
    func protectedTargetRemainsAllowedWithSwapOff() throws {
        let result = try plan(handoffEnabled: false, protectedResidents: ["API-B"])
        #expect(!result.shouldUnload)
        #expect(result.coexists)
        #expect(result.requiredBytes == 4096)
        #expect(result.ramSafetyEnabled)
    }

    @Test("swap ON retains restore-only behavior for an unprotected child")
    func unprotectedTargetStillRestoresParent() throws {
        let result = try plan(handoffEnabled: true, protectedResidents: [])
        #expect(result.shouldUnload)
        #expect(!result.coexists)
        #expect(result.requiredBytes == 4096)
        #expect(result.ramSafetyEnabled)
    }

    @Test("protected target reuse remains allowed when there is no local parent to restore")
    func protectedTargetWithoutLocalParentNeedsNoSwap() throws {
        let result = try plan(
            handoffEnabled: true,
            protectedResidents: ["API-B"],
            invokingParentModelName: nil
        )
        #expect(!result.shouldUnload)
        #expect(!result.coexists)
        #expect(result.requiredBytes == 4096)
        #expect(result.ramSafetyEnabled)
    }

    private func plan(
        handoffEnabled: Bool,
        protectedResidents: [String],
        invokingParentModelName: String? = "local-a"
    ) throws -> ResidencyPlan {
        try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "api-b",
            residentChatModels: [],
            protectedResidentModels: protectedResidents,
            handoffEnabled: handoffEnabled,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: "handoff disabled",
            invokingParentModelName: invokingParentModelName
        )
    }
}
